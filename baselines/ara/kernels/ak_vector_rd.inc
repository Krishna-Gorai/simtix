/*
 * ak_vector_rd.inc - the Rodinia kernels (docs/rodinia_plan.md) for Ara, included by
 * ak_vector.c. Each follows the FP32 operation order of kernels/rodinia/rd_ref.h and
 * keeps to the Ara restrictions listed in the header of ak_vector.c (no masked
 * operations: edge elements are done by scalar code with the same operations).
 */

/* ── Rodinia hotspot: every cell, clamped neighbours (rd_ref.h rd_hotspot) ───────── */
/* One cell in scalar code (the edge columns), exactly as rd_hotspot. */
static float rd_hs_cell(const float *in, const float *pw, uint32_t n, uint32_t i, uint32_t j,
                        float rx1, float ry1, float rz1, float amb, float sdc)
{
    const uint32_t iN = i ? i - 1 : 0, iS = i + 1 < n ? i + 1 : n - 1;
    const uint32_t jW = j ? j - 1 : 0, jE = j + 1 < n ? j + 1 : n - 1;
    const uint32_t q = i * n + j;
    float tt = in[q], t2 = tt + tt;
    float a = (in[iN * n + j] + in[iS * n + j]) - t2;
    float b = (in[i * n + jE] + in[i * n + jW]) - t2;
    float c = amb - tt;
    float acc = __builtin_fmaf(a, ry1, pw[q]);
    acc = __builtin_fmaf(b, rx1, acc);
    acc = __builtin_fmaf(c, rz1, acc);
    return __builtin_fmaf(sdc, acc, tt);
}

/* a = t0 t1 pw n rx1 ry1 rz1 amb sdc steps; columns 1 .. n-2 in strips of LMUL 4. */
static void v_rd_hotspot(const uint32_t *a)
{
    float *t[2] = { AKP(float, a[0]), AKP(float, a[1]) };
    const float *pw = AKP(const float, a[2]);
    const uint32_t n = a[3], steps = a[9];
    const float rx1 = ak_f(a[4]), ry1 = ak_f(a[5]), rz1 = ak_f(a[6]), amb = ak_f(a[7]), sdc = ak_f(a[8]);
    for (uint32_t st = 0; st < steps; st++) {
        const float *in = t[st & 1];
        float *out = t[(st + 1) & 1];
        for (uint32_t i = 0; i < n; i++) {
            const uint32_t iN = i ? i - 1 : 0, iS = i + 1 < n ? i + 1 : n - 1;
            const float *row = in + i * n, *rn = in + iN * n, *rs = in + iS * n, *pr = pw + i * n;
            float *orow = out + i * n;
            orow[0] = rd_hs_cell(in, pw, n, i, 0, rx1, ry1, rz1, amb, sdc);
            orow[n - 1] = rd_hs_cell(in, pw, n, i, n - 1, rx1, ry1, rz1, amb, sdc);
            for (uint32_t j0 = 1; j0 < n - 1; ) {
                size_t vl = __riscv_vsetvl_e32m4(n - 1 - j0);
                vfloat32m4_t tt = __riscv_vle32_v_f32m4(row + j0, vl);
                vfloat32m4_t t2 = __riscv_vfadd_vv_f32m4(tt, tt, vl);
                vfloat32m4_t av = __riscv_vfsub_vv_f32m4(__riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(rn + j0, vl),
                                      __riscv_vle32_v_f32m4(rs + j0, vl), vl), t2, vl);
                vfloat32m4_t bv = __riscv_vfsub_vv_f32m4(__riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(row + j0 + 1, vl),
                                      __riscv_vle32_v_f32m4(row + j0 - 1, vl), vl), t2, vl);
                vfloat32m4_t cv = __riscv_vfrsub_vf_f32m4(tt, amb, vl);          /* amb - t */
                vfloat32m4_t acc = __riscv_vle32_v_f32m4(pr + j0, vl);
                acc = __riscv_vfmacc_vf_f32m4(acc, ry1, av, vl);                 /* fma(a, ry1, p) */
                acc = __riscv_vfmacc_vf_f32m4(acc, rx1, bv, vl);
                acc = __riscv_vfmacc_vf_f32m4(acc, rz1, cv, vl);
                __riscv_vse32_v_f32m4(orow + j0, __riscv_vfmacc_vf_f32m4(tt, sdc, acc, vl), vl);
                j0 += vl;
            }
        }
        FENCE();
    }
}

/* ── Rodinia nn: dist = sqrt(dx*dx + dy*dy) (rd_ref.h rd_nn) ────────────────────── */
/* a = loc dist n lat lng; loc holds (lat, lng) pairs: strided loads, LMUL 4. */
static void v_rd_nn(const uint32_t *a)
{
    const float *loc = AKP(const float, a[0]);
    float *dist = AKP(float, a[1]);
    const uint32_t n = a[2];
    const float lat = ak_f(a[3]), lng = ak_f(a[4]);
    for (uint32_t r0 = 0; r0 < n; ) {
        size_t vl = __riscv_vsetvl_e32m4(n - r0);
        vfloat32m4_t x = __riscv_vlse32_v_f32m4(loc + 2 * r0, 8, vl);
        vfloat32m4_t y = __riscv_vlse32_v_f32m4(loc + 2 * r0 + 1, 8, vl);
        vfloat32m4_t dx = __riscv_vfrsub_vf_f32m4(x, lat, vl);              /* lat - x */
        vfloat32m4_t dy = __riscv_vfrsub_vf_f32m4(y, lng, vl);
        vfloat32m4_t s = __riscv_vfmul_vv_f32m4(dx, dx, vl);
        s = __riscv_vfadd_vv_f32m4(s, __riscv_vfmul_vv_f32m4(dy, dy, vl), vl);
        __riscv_vse32_v_f32m4(dist + r0, __riscv_vfsqrt_v_f32m4(s, vl), vl);
        r0 += vl;
    }
    FENCE();
}

/* ── Rodinia hotspot3D: clamped 3-D neighbours (rd_ref.h rd_hotspot3d) ───────────── */
static float rd_h3_cell(const float *in, const float *pw, uint32_t n, uint32_t nz, uint32_t i, uint32_t j,
                        uint32_t z, const float *k)
{
    const uint32_t xy = n * n, c = i + j * n + z * xy;
    const uint32_t zb = z ? z - 1 : 0, zt = z + 1 < nz ? z + 1 : nz - 1;
    const uint32_t W = i ? c - 1 : c, E = i + 1 < n ? c + 1 : c, N = j ? c - n : c, S = j + 1 < n ? c + n : c;
    float s = k[0] * in[c];
    s = __builtin_fmaf(k[1], in[W], s);
    s = __builtin_fmaf(k[1], in[E], s);
    s = __builtin_fmaf(k[2], in[S], s);
    s = __builtin_fmaf(k[2], in[N], s);
    s = __builtin_fmaf(k[3], in[i + j * n + zb * xy], s);
    s = __builtin_fmaf(k[3], in[i + j * n + zt * xy], s);
    s = __builtin_fmaf(k[4], pw[c], s);
    return __builtin_fmaf(k[3], k[5], s);
}

/* a = t0 t1 pw n nz cc ce cn ct sdc amb iters; columns 1 .. n-2 of each row in strips
   of LMUL 4, the two edge columns in scalar code. */
static void v_rd_hotspot3d(const uint32_t *a)
{
    float *t[2] = { AKP(float, a[0]), AKP(float, a[1]) };
    const float *pw = AKP(const float, a[2]);
    const uint32_t n = a[3], nz = a[4], iters = a[11], xy = n * n;
    const float k[6] = { ak_f(a[5]), ak_f(a[6]), ak_f(a[7]), ak_f(a[8]), ak_f(a[9]), ak_f(a[10]) };
    for (uint32_t it = 0; it < iters; it++) {
        const float *in = t[it & 1];
        float *out = t[(it + 1) & 1];
        for (uint32_t z = 0; z < nz; z++) {
            const uint32_t zb = z ? z - 1 : 0, zt = z + 1 < nz ? z + 1 : nz - 1;
            for (uint32_t j = 0; j < n; j++) {
                const uint32_t jN = j ? j - 1 : 0, jS = j + 1 < n ? j + 1 : n - 1;
                const float *row = in + j * n + z * xy, *rn = in + jN * n + z * xy, *rs = in + jS * n + z * xy;
                const float *rb = in + j * n + zb * xy, *rt = in + j * n + zt * xy, *pr = pw + j * n + z * xy;
                float *orow = out + j * n + z * xy;
                orow[0] = rd_h3_cell(in, pw, n, nz, 0, j, z, k);
                orow[n - 1] = rd_h3_cell(in, pw, n, nz, n - 1, j, z, k);
                for (uint32_t i0 = 1; i0 < n - 1; ) {
                    size_t vl = __riscv_vsetvl_e32m4(n - 1 - i0);
                    vfloat32m4_t s = __riscv_vfmul_vf_f32m4(__riscv_vle32_v_f32m4(row + i0, vl), k[0], vl);
                    s = __riscv_vfmacc_vf_f32m4(s, k[1], __riscv_vle32_v_f32m4(row + i0 - 1, vl), vl);  /* W */
                    s = __riscv_vfmacc_vf_f32m4(s, k[1], __riscv_vle32_v_f32m4(row + i0 + 1, vl), vl);  /* E */
                    s = __riscv_vfmacc_vf_f32m4(s, k[2], __riscv_vle32_v_f32m4(rs + i0, vl), vl);       /* S */
                    s = __riscv_vfmacc_vf_f32m4(s, k[2], __riscv_vle32_v_f32m4(rn + i0, vl), vl);       /* N */
                    s = __riscv_vfmacc_vf_f32m4(s, k[3], __riscv_vle32_v_f32m4(rb + i0, vl), vl);       /* below */
                    s = __riscv_vfmacc_vf_f32m4(s, k[3], __riscv_vle32_v_f32m4(rt + i0, vl), vl);       /* above */
                    s = __riscv_vfmacc_vf_f32m4(s, k[4], __riscv_vle32_v_f32m4(pr + i0, vl), vl);       /* sdc*p */
                    s = __riscv_vfmacc_vf_f32m4(s, k[3], __riscv_vfmv_v_f_f32m4(k[5], vl), vl);         /* ct*amb */
                    __riscv_vse32_v_f32m4(orow + i0, s, vl);
                    i0 += vl;
                }
            }
        }
        FENCE();
    }
}

/* ── Rodinia gaussian: Fan1 and Fan2 per step (rd_ref.h rd_gaussian) ─────────────── */
/* a = A (augmented n x (n+1), b in column n) m n. Fan1: column t below the pivot,
   strided, divided by the pivot. Fan2: each row below the pivot, columns t .. n,
   a[i][j] - m[i][t]*a[t][j] in one rounding (vfnmsac). Fences after each phase: the
   multipliers and the next pivot are read back by scalar loads. */
static void v_rd_gaussian(const uint32_t *a)
{
    float *A = AKP(float, a[0]), *m = AKP(float, a[1]);
    const uint32_t n = a[2], s = n + 1;
    for (uint32_t t = 0; t + 1 < n; t++) {
        const float piv = A[t * s + t];
#ifdef AK_RD_GAUSS_VDIV
        for (uint32_t i0 = t + 1; i0 < n; ) {
            size_t vl = __riscv_vsetvl_e32m4(n - i0);
            vfloat32m4_t x = __riscv_vlse32_v_f32m4(A + i0 * s + t, 4 * s, vl);
            __riscv_vsse32_v_f32m4(m + i0 * n + t, 4 * n, __riscv_vfdiv_vf_f32m4(x, piv, vl), vl);
            i0 += vl;
        }
        FENCE();
#else
        /* Fan1 on CVA6's scalar divider: the vector form above gave wrong multipliers
           when it ran after nn (ak_vector.c header, item 7). O(n) per step against
           Fan2's O(n^2). */
        for (uint32_t i = t + 1; i < n; i++)
            m[i * n + t] = A[i * s + t] / piv;
#endif
        const float *rt = A + t * s;
        for (uint32_t i = t + 1; i < n; i++) {
            const float mi = m[i * n + t];
            float *ri = A + i * s;
            for (uint32_t j0 = t; j0 <= n; ) {
                size_t vl = __riscv_vsetvl_e32m4(n + 1 - j0);
                vfloat32m4_t r = __riscv_vle32_v_f32m4(ri + j0, vl);
                r = __riscv_vfnmsac_vf_f32m4(r, mi, __riscv_vle32_v_f32m4(rt + j0, vl), vl);
                __riscv_vse32_v_f32m4(ri + j0, r, vl);
                j0 += vl;
            }
        }
        FENCE();
    }
}

/* ── Rodinia kmeans: assignment (rd_ref.h rd_kmeans_assign) ───────────────────────── */
/* a = f (feature-major on Ara: f[j*n + p]) c membership n k nf. Points in strips of
   LMUL 1 (kernels that compare run at LMUL 1); the comparison mask is used only as a
   vmerge selector; best = vfmin (ties keep the earlier centre's index). */
static void v_rd_kmeans(const uint32_t *a)
{
    const float *f = AKP(const float, a[0]), *c = AKP(const float, a[1]);
    int32_t *mem = AKP(int32_t, a[2]);
    const uint32_t n = a[3], k = a[4], nf = a[5];
    for (uint32_t p0 = 0; p0 < n; ) {
        size_t vl = __riscv_vsetvl_e32m1(n - p0);
        vfloat32m1_t best = __riscv_vfmv_v_f_f32m1(ak_f(0x7F7FFFFFu), vl);
        vint32m1_t idx = __riscv_vmv_v_x_i32m1(0, vl);
        for (uint32_t i = 0; i < k; i++) {
            vfloat32m1_t ans = __riscv_vfmv_v_f_f32m1(0.0f, vl);
            for (uint32_t j = 0; j < nf; j++) {
                vfloat32m1_t d = __riscv_vfsub_vf_f32m1(__riscv_vle32_v_f32m1(f + j * n + p0, vl), c[i * nf + j], vl);
                ans = __riscv_vfmacc_vv_f32m1(ans, d, d, vl);
            }
            vbool32_t lt = __riscv_vmflt_vv_f32m1_b32(ans, best, vl);
            idx = __riscv_vmerge_vxm_i32m1(idx, (int32_t)i, lt, vl);
            best = __riscv_vfmin_vv_f32m1(best, ans, vl);
        }
        __riscv_vse32_v_i32m1(mem + p0, idx, vl);
        p0 += vl;
    }
    FENCE();
}
