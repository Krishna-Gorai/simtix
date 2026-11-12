/* ak_vector_s2.inc - suite 2 (docs/suite2_plan.md) for Ara, included by ak_vector.c
 * (its helpers and rules: masks only as vmerge selectors of compares, compares at LMUL 1,
 * indexed loads with early-clobber destinations, a fence wherever a later access reads
 * what a vector store wrote). Every element computes the operations of
 * kernels/suite2/s2_ref.h in the same order. */

/* Unmasked indexed load, e32 LMUL 4 (early-clobber output). */
static inline vuint32m4_t ld_idx4(const void *base, vuint32m4_t off, size_t vl)
{
    vuint32m4_t r;
    __asm__ volatile("vsetvli zero, %[vl], e32, m4, ta, ma\n\t"
                     "vluxei32.v %[r], (%[b]), %[o]"
                     : [r] "=&vr"(r)
                     : [o] "vr"(off), [b] "r"(base), [vl] "r"(vl)
                     : "memory", "vl", "vtype");
    return r;
}
#define F4(u) __riscv_vreinterpret_v_u32m4_f32m4(u)

/* ── Rodinia pathfinder: a row per step, strips of LMUL 4 ─────────────────────── */
static void v_pathfinder(const uint32_t *a)
{
    const int32_t *wall = AKP(const int32_t, a[0]);
    int32_t *b[2] = { AKP(int32_t, a[1]), AKP(int32_t, a[2]) };
    const uint32_t rows = a[3], cols = a[4];
    for (uint32_t r = 1; r < rows; r++) {
        const int32_t *src = b[(r - 1) & 1], *w = wall + r * cols;
        int32_t *dst = b[r & 1];
        for (uint32_t c0 = 0; c0 < cols; ) {
            size_t vl = __riscv_vsetvl_e32m4(cols - c0);
            vint32m4_t m = __riscv_vmin_vv_i32m4(__riscv_vle32_v_i32m4(src + c0, vl),
                                                 __riscv_vle32_v_i32m4(src + c0 + 1, vl), vl);
            m = __riscv_vmin_vv_i32m4(m, __riscv_vle32_v_i32m4(src + c0 + 2, vl), vl);
            __riscv_vse32_v_i32m4(dst + c0 + 1, __riscv_vadd_vv_i32m4(m, __riscv_vle32_v_i32m4(w + c0, vl), vl), vl);
            c0 += vl;
        }
        FENCE();
    }
}

/* ── Rodinia hotspot ──────────────────────────────────────────────────────────── */
static void v_hotspot(const uint32_t *a)
{
    float *t[2] = { AKP(float, a[0]), AKP(float, a[1]) };
    const float *pw = AKP(const float, a[2]);
    const uint32_t n = a[3], s = a[4], steps = a[10];
    const float rx1 = ak_f(a[5]), ry1 = ak_f(a[6]), rz1 = ak_f(a[7]), amb = ak_f(a[8]), sdc = ak_f(a[9]);
    for (uint32_t st = 0; st < steps; st++) {
        const float *in = t[st & 1];
        float *out = t[(st + 1) & 1];
        for (uint32_t i = 0; i < n; i++)
            for (uint32_t j0 = 0; j0 < n; ) {
                size_t vl = __riscv_vsetvl_e32m4(n - j0);
                const uint32_t q = (i + 1) * s + 8 + j0;
                vfloat32m4_t tt = __riscv_vle32_v_f32m4(in + q, vl);
                vfloat32m4_t t2 = __riscv_vfadd_vv_f32m4(tt, tt, vl);
                vfloat32m4_t av = __riscv_vfsub_vv_f32m4(__riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(in + q - s, vl),
                                      __riscv_vle32_v_f32m4(in + q + s, vl), vl), t2, vl);
                vfloat32m4_t bv = __riscv_vfsub_vv_f32m4(__riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(in + q + 1, vl),
                                      __riscv_vle32_v_f32m4(in + q - 1, vl), vl), t2, vl);
                vfloat32m4_t cv = __riscv_vfrsub_vf_f32m4(tt, amb, vl);          /* amb - t */
                vfloat32m4_t acc = __riscv_vle32_v_f32m4(pw + q, vl);
                acc = __riscv_vfmacc_vf_f32m4(acc, ry1, av, vl);                 /* fma(a, ry1, p) */
                acc = __riscv_vfmacc_vf_f32m4(acc, rx1, bv, vl);
                acc = __riscv_vfmacc_vf_f32m4(acc, rz1, cv, vl);
                __riscv_vse32_v_f32m4(out + q, __riscv_vfmacc_vf_f32m4(tt, sdc, acc, vl), vl);
                j0 += vl;
            }
        FENCE();
    }
}

/* ── PolyBench jacobi-2d ──────────────────────────────────────────────────────── */
static void v_jacobi2d(const uint32_t *a)
{
    float *g[2] = { AKP(float, a[0]), AKP(float, a[1]) };
    const uint32_t n = a[2], s = a[3], ts = a[5];
    const float c02 = ak_f(a[4]);
    for (uint32_t k = 0; k < 2 * ts; k++) {
        const float *in = g[k & 1];
        float *out = g[(k + 1) & 1];
        for (uint32_t i = 0; i < n; i++)
            for (uint32_t j0 = 0; j0 < n; ) {
                size_t vl = __riscv_vsetvl_e32m4(n - j0);
                const uint32_t q = (i + 1) * s + 8 + j0;
                vfloat32m4_t sm = __riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(in + q, vl),
                                                         __riscv_vle32_v_f32m4(in + q - 1, vl), vl);
                sm = __riscv_vfadd_vv_f32m4(sm, __riscv_vle32_v_f32m4(in + q + 1, vl), vl);
                sm = __riscv_vfadd_vv_f32m4(sm, __riscv_vle32_v_f32m4(in + q + s, vl), vl);
                sm = __riscv_vfadd_vv_f32m4(sm, __riscv_vle32_v_f32m4(in + q - s, vl), vl);
                __riscv_vse32_v_f32m4(out + q, __riscv_vfmul_vf_f32m4(sm, c02, vl), vl);
                j0 += vl;
            }
        FENCE();
    }
}

/* ── PolyBench atax / bicg: rows by strided loads (each row's chain in j order),
   columns by unit-stride rows ──────────────────────────────────────────────────── */
static void v_mv_row(const float *A, const float *x, float *y, uint32_t n)
{
    for (uint32_t i0 = 0; i0 < n; ) {
        size_t vl = __riscv_vsetvl_e32m4(n - i0);
        vfloat32m4_t acc = __riscv_vfmv_v_f_f32m4(0.0f, vl);
        for (uint32_t j = 0; j < n; j++)
            acc = __riscv_vfmacc_vf_f32m4(acc, x[j], __riscv_vlse32_v_f32m4(A + i0 * n + j, 4 * n, vl), vl);
        __riscv_vse32_v_f32m4(y + i0, acc, vl);
        i0 += vl;
    }
}
static void v_mv_col(const float *A, const float *x, float *y, uint32_t n)
{
    for (uint32_t j0 = 0; j0 < n; ) {
        size_t vl = __riscv_vsetvl_e32m4(n - j0);
        vfloat32m4_t acc = __riscv_vfmv_v_f_f32m4(0.0f, vl);
        for (uint32_t i = 0; i < n; i++)
            acc = __riscv_vfmacc_vf_f32m4(acc, x[i], __riscv_vle32_v_f32m4(A + i * n + j0, vl), vl);
        __riscv_vse32_v_f32m4(y + j0, acc, vl);
        j0 += vl;
    }
}
static void v_atax(const uint32_t *a)
{
    v_mv_row(AKP(const float, a[0]), AKP(const float, a[1]), AKP(float, a[2]), a[4]);
    FENCE();                                   /* tmp is read by scalar loads next */
    v_mv_col(AKP(const float, a[0]), AKP(const float, a[2]), AKP(float, a[3]), a[4]);
    FENCE();
}
static void v_bicg(const uint32_t *a)
{
    v_mv_row(AKP(const float, a[0]), AKP(const float, a[1]), AKP(float, a[3]), a[5]);
    v_mv_col(AKP(const float, a[0]), AKP(const float, a[2]), AKP(float, a[4]), a[5]);
    FENCE();
}

/* ── GAP PageRank: contributions (LMUL 4), then the pull as v_spmv (LMUL 1) ───── */
static void v_pagerank(const uint32_t *a)
{
    const uint32_t *rowptr = AKP(const uint32_t, a[0]), *col = AKP(const uint32_t, a[1]);
    const float *invdeg = AKP(const float, a[2]);
    float *c = AKP(float, a[3]);
    float *pr[2] = { AKP(float, a[4]), AKP(float, a[5]) };
    const uint32_t nv = a[6], iters = a[9];
    const float d = ak_f(a[7]), base = ak_f(a[8]);
    for (uint32_t k = 0; k < iters; k++) {
        const float *src = pr[k & 1];
        float *dst = pr[(k + 1) & 1];
        for (uint32_t u0 = 0; u0 < nv; ) {
            size_t vl = __riscv_vsetvl_e32m4(nv - u0);
            __riscv_vse32_v_f32m4(c + u0, __riscv_vfmul_vv_f32m4(__riscv_vle32_v_f32m4(src + u0, vl),
                                                                 __riscv_vle32_v_f32m4(invdeg + u0, vl), vl), vl);
            u0 += vl;
        }
        FENCE();
        for (uint32_t v0 = 0; v0 < nv; ) {
            size_t vl = __riscv_vsetvl_e32m1(nv - v0);
            vuint32m1_t beg = __riscv_vle32_v_u32m1(rowptr + v0, vl);
            vuint32m1_t len = __riscv_vsub_vv_u32m1(__riscv_vle32_v_u32m1(rowptr + v0 + 1, vl), beg, vl);
            vuint32m1_t zero = __riscv_vmv_v_x_u32m1(0, vl);
            vuint32m1_t off = __riscv_vsll_vx_u32m1(beg, 2, vl);
            vfloat32m1_t acc = __riscv_vfmv_v_f_f32m1(0.0f, vl);
            for (uint32_t j = 0; ; j++) {
                vbool32_t m = __riscv_vmsgtu_vx_u32m1_b32(len, j, vl);
                if (!any_b32(m, vl)) break;
                vuint32m1_t u = gather_u32(m, zero, col, off, vl);
                vfloat32m1_t cv = gather_f32(m, c, __riscv_vsll_vx_u32m1(u, 2, vl), vl);
                acc = __riscv_vmerge_vvm_f32m1(acc, __riscv_vfadd_vv_f32m1(acc, cv, vl), m, vl);
                off = __riscv_vadd_vx_u32m1(off, 4, vl);
            }
            /* fma(d, acc, base) */
            __riscv_vse32_v_f32m1(dst + v0, __riscv_vfmadd_vf_f32m1(acc, d, __riscv_vfmv_v_f_f32m1(base, vl), vl), vl);
            v0 += vl;
        }
        FENCE();
    }
}

/* ── GAP connected components: label propagation rounds until nothing changes ── */
static void v_cc(const uint32_t *a)
{
    const uint32_t *rowptr = AKP(const uint32_t, a[0]), *col = AKP(const uint32_t, a[1]);
    uint32_t *lab[2] = { AKP(uint32_t, a[2]), AKP(uint32_t, a[3]) };
    const uint32_t nv = a[4];
    uint32_t k = 0;
    for (;;) {
        const uint32_t *in = lab[k & 1];
        uint32_t *out = lab[(k + 1) & 1];
        uint32_t changed = 0;
        for (uint32_t v0 = 0; v0 < nv; ) {
            size_t vl = __riscv_vsetvl_e32m1(nv - v0);
            vuint32m1_t own = __riscv_vle32_v_u32m1(in + v0, vl);
            vuint32m1_t beg = __riscv_vle32_v_u32m1(rowptr + v0, vl);
            vuint32m1_t len = __riscv_vsub_vv_u32m1(__riscv_vle32_v_u32m1(rowptr + v0 + 1, vl), beg, vl);
            vuint32m1_t zero = __riscv_vmv_v_x_u32m1(0, vl), ones = __riscv_vmv_v_x_u32m1(0xFFFFFFFFu, vl);
            vuint32m1_t off = __riscv_vsll_vx_u32m1(beg, 2, vl);
            vuint32m1_t mn = own;
            for (uint32_t j = 0; ; j++) {
                vbool32_t m = __riscv_vmsgtu_vx_u32m1_b32(len, j, vl);
                if (!any_b32(m, vl)) break;
                vuint32m1_t u = gather_u32(m, zero, col, off, vl);
                vuint32m1_t lu = gather_u32(m, ones, in, __riscv_vsll_vx_u32m1(u, 2, vl), vl);
                mn = __riscv_vminu_vv_u32m1(mn, lu, vl);
                off = __riscv_vadd_vx_u32m1(off, 4, vl);
            }
            __riscv_vse32_v_u32m1(out + v0, mn, vl);
            changed += count_b32(__riscv_vmsne_vv_u32m1_b32(mn, own, vl), vl);
            v0 += vl;
        }
        FENCE();
        k++;
        if (!changed) break;
    }
    *AKP(uint32_t, a[5]) = k;
}

/* ── Rodinia backprop: forward partial sums and the weight update (LMUL 4) ────── */
static void v_backprop(const uint32_t *a)
{
    const float *in = AKP(const float, a[0]);
    float *w = AKP(float, a[1]), *ow = AKP(float, a[2]), *ps = AKP(float, a[4]);
    const float *ed = AKP(const float, a[3]);
    const uint32_t n = a[5];
    const float m = ak_f(a[6]);
    for (uint32_t t0 = 0; t0 < n; ) {                  /* t = 16b + j */
        size_t vl = __riscv_vsetvl_e32m4(n - t0);
        vuint32m4_t t = __riscv_vadd_vx_u32m4(IOTA4(vl), t0, vl);
        vuint32m4_t j = __riscv_vand_vx_u32m4(t, 15, vl), b = __riscv_vsrl_vx_u32m4(t, 4, vl);
        vuint32m4_t woff = __riscv_vsll_vx_u32m4(__riscv_vadd_vv_u32m4(__riscv_vsll_vx_u32m4(b, 8, vl), j, vl), 2, vl);
        vuint32m4_t ioff = __riscv_vsll_vx_u32m4(b, 6, vl);
        vfloat32m4_t acc = __riscv_vfmv_v_f_f32m4(0.0f, vl);
        for (uint32_t k = 0; k < 16; k++)               /* fma(w[16b+k][j], in[16b+k], acc) */
            acc = __riscv_vfmacc_vv_f32m4(acc, F4(ld_idx4(w + 16 * k, woff, vl)), F4(ld_idx4(in + k, ioff, vl)), vl);
        __riscv_vse32_v_f32m4(ps + t0, acc, vl);
        t0 += vl;
    }
    FENCE();
    for (uint32_t t0 = 0; t0 < 16 * n; ) {
        size_t vl = __riscv_vsetvl_e32m4(16 * n - t0);
        vuint32m4_t t = __riscv_vadd_vx_u32m4(IOTA4(vl), t0, vl);
        vfloat32m4_t iv = F4(ld_idx4(in, __riscv_vsll_vx_u32m4(__riscv_vsrl_vx_u32m4(t, 4, vl), 2, vl), vl));
        vfloat32m4_t ev = F4(ld_idx4(ed, __riscv_vsll_vx_u32m4(__riscv_vand_vx_u32m4(t, 15, vl), 2, vl), vl));
        vfloat32m4_t dw = __riscv_vfmul_vf_f32m4(__riscv_vle32_v_f32m4(ow + t0, vl), m, vl);
        dw = __riscv_vfmacc_vv_f32m4(dw, ev, iv, vl);   /* fma(ed[j], in[i], m * ow) */
        __riscv_vse32_v_f32m4(w + t0, __riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(w + t0, vl), dw, vl), vl);
        __riscv_vse32_v_f32m4(ow + t0, dw, vl);
        t0 += vl;
    }
    FENCE();
}

/* ── SHOC sort: one element per worker (W workers, chunks of C = n / W pairs), as
   kernels/suite2/rs_*.S: per pass the digit histograms, the per-digit prefix (on
   CVA6), the stable scatter. A fence after every step that a later load depends on. */
static void v_sort(const uint32_t *a)
{
    uint32_t *kk[2] = { AKP(uint32_t, a[0]), AKP(uint32_t, a[2]) };
    uint32_t *vv[2] = { AKP(uint32_t, a[1]), AKP(uint32_t, a[3]) };
    const uint32_t n = a[4], W = a[6], C = n / W;
    uint32_t *hist = AKP(uint32_t, a[5]), *off = hist + 16 * W, *tot = off + 16 * W;
    for (uint32_t p = 0; p < 8; p++) {
        const uint32_t *ks = kk[p & 1], *vs = vv[p & 1];
        uint32_t *kd = kk[(p + 1) & 1], *vd = vv[(p + 1) & 1];
        const uint32_t sh = 4 * p;
        for (uint32_t w0 = 0; w0 < W; ) {               /* histograms */
            size_t vl = __riscv_vsetvl_e32m1(W - w0);
            for (uint32_t d = 0; d < 16; d++)
                __riscv_vse32_v_u32m1(hist + d * W + w0, __riscv_vmv_v_x_u32m1(0, vl), vl);
            FENCE();
            vuint32m1_t wofs = __riscv_vsll_vx_u32m1(__riscv_vadd_vx_u32m1(IOTA1(vl), w0, vl), 2, vl);
            for (uint32_t i = 0; i < C; i++) {
                vuint32m1_t key = __riscv_vlse32_v_u32m1(ks + w0 * C + i, 4 * C, vl);
                vuint32m1_t dg = __riscv_vand_vx_u32m1(__riscv_vsrl_vx_u32m1(key, sh, vl), 15, vl);
                vuint32m1_t ho = __riscv_vadd_vv_u32m1(__riscv_vmul_vx_u32m1(dg, 4 * W, vl), wofs, vl);
                vuint32m1_t h = ld_idx(hist, ho, vl);
                __riscv_vsuxei32_v_u32m1(hist, ho, __riscv_vadd_vx_u32m1(h, 1, vl), vl);
                FENCE();
            }
            w0 += vl;
        }
        for (uint32_t d = 0; d < 16; d++) {             /* prefix, on CVA6 */
            uint32_t run = 0;
            for (uint32_t w = 0; w < W; w++) { uint32_t h = hist[d * W + w]; off[d * W + w] = run; run += h; }
            tot[d] = run;
        }
        for (uint32_t w0 = 0; w0 < W; ) {               /* scatter */
            size_t vl = __riscv_vsetvl_e32m1(W - w0);
            for (uint32_t d = 0, base = 0; d < 16; d++) {
                __riscv_vse32_v_u32m1(off + d * W + w0,
                                      __riscv_vadd_vx_u32m1(__riscv_vle32_v_u32m1(off + d * W + w0, vl), base, vl), vl);
                base += tot[d];
            }
            FENCE();
            vuint32m1_t wofs = __riscv_vsll_vx_u32m1(__riscv_vadd_vx_u32m1(IOTA1(vl), w0, vl), 2, vl);
            for (uint32_t i = 0; i < C; i++) {
                vuint32m1_t key = __riscv_vlse32_v_u32m1(ks + w0 * C + i, 4 * C, vl);
                vuint32m1_t val = __riscv_vlse32_v_u32m1(vs + w0 * C + i, 4 * C, vl);
                vuint32m1_t dg = __riscv_vand_vx_u32m1(__riscv_vsrl_vx_u32m1(key, sh, vl), 15, vl);
                vuint32m1_t oo = __riscv_vadd_vv_u32m1(__riscv_vmul_vx_u32m1(dg, 4 * W, vl), wofs, vl);
                vuint32m1_t pos = ld_idx(off, oo, vl);
                __riscv_vsuxei32_v_u32m1(off, oo, __riscv_vadd_vx_u32m1(pos, 1, vl), vl);
                vuint32m1_t po = __riscv_vsll_vx_u32m1(pos, 2, vl);
                __riscv_vsuxei32_v_u32m1(kd, po, key, vl);
                __riscv_vsuxei32_v_u32m1(vd, po, val, vl);
                FENCE();
            }
            w0 += vl;
        }
    }
}

/* ── RiVEC / PARSEC Black-Scholes (LMUL 1: the branches are compares) ─────────── */
#define VF(x) __riscv_vfmv_v_f_f32m1((x), vl)
static inline vfloat32m1_t vbs_exp(vfloat32m1_t x, const float *C, size_t vl)
{
    vint32m1_t k = __riscv_vfcvt_x_f_v_i32m1(__riscv_vfmul_vf_f32m1(x, C[3], vl), vl);   /* rne */
    vfloat32m1_t kf = __riscv_vfneg_v_f32m1(__riscv_vfcvt_f_x_v_f32m1(k, vl), vl);
    vfloat32m1_t f = __riscv_vfmacc_vf_f32m1(x, C[4], kf, vl);                         /* fma(kf, hi, x) */
    f = __riscv_vfmacc_vf_f32m1(f, C[5], kf, vl);
    vfloat32m1_t p = __riscv_vfmacc_vf_f32m1(VF(C[11]), C[12], f, vl);                 /* fma(f, E6, E5) */
    for (int i = 10; i >= 6; i--) p = __riscv_vfmacc_vv_f32m1(VF(C[i]), f, p, vl);     /* fma(f, p, Ei) */
    vuint32m1_t bits = __riscv_vadd_vv_u32m1(__riscv_vreinterpret_v_f32m1_u32m1(p),
                           __riscv_vsll_vx_u32m1(__riscv_vreinterpret_v_i32m1_u32m1(k), 23, vl), vl);
    return __riscv_vreinterpret_v_u32m1_f32m1(bits);
}
static inline vfloat32m1_t vbs_log(vfloat32m1_t x, const float *C, size_t vl)
{
    vuint32m1_t b = __riscv_vreinterpret_v_f32m1_u32m1(x);
    vint32m1_t e = __riscv_vsub_vx_i32m1(__riscv_vreinterpret_v_u32m1_i32m1(
                       __riscv_vand_vx_u32m1(__riscv_vsrl_vx_u32m1(b, 23, vl), 0xFF, vl)), 127, vl);
    vuint32m1_t mb = __riscv_vor_vx_u32m1(__riscv_vand_vx_u32m1(b, 0x7FFFFFu, vl), 0x3F800000u, vl);
    vfloat32m1_t m = __riscv_vreinterpret_v_u32m1_f32m1(mb);
    vbool32_t big = __riscv_vmsgtu_vx_u32m1_b32(mb, s2_u(C[18]), vl);                 /* m > sqrt2 */
    m = __riscv_vmerge_vvm_f32m1(m, __riscv_vfmul_vf_f32m1(m, C[0], vl), big, vl);
    e = __riscv_vmerge_vvm_i32m1(e, __riscv_vadd_vx_i32m1(e, 1, vl), big, vl);
    vfloat32m1_t f = __riscv_vfsub_vf_f32m1(m, C[1], vl);
    vfloat32m1_t s = __riscv_vfdiv_vv_f32m1(f, __riscv_vfadd_vf_f32m1(f, C[2], vl), vl);
    vfloat32m1_t z = __riscv_vfmul_vv_f32m1(s, s, vl);
    vfloat32m1_t R = __riscv_vfmacc_vf_f32m1(VF(C[16]), C[17], z, vl);                 /* fma(z, C4, C3) */
    R = __riscv_vfmacc_vv_f32m1(VF(C[15]), z, R, vl);
    R = __riscv_vfmacc_vv_f32m1(VF(C[14]), z, R, vl);
    R = __riscv_vfmul_vv_f32m1(R, z, vl);
    vfloat32m1_t l = __riscv_vfmacc_vv_f32m1(__riscv_vfadd_vv_f32m1(s, s, vl), s, R, vl);
    return __riscv_vfmacc_vf_f32m1(l, C[13], __riscv_vfcvt_f_x_v_f32m1(e, vl), vl);   /* fma(e, ln2, l) */
}
static inline vfloat32m1_t vbs_cndf(vfloat32m1_t x, const float *C, size_t vl)
{
    vuint32m1_t b = __riscv_vreinterpret_v_f32m1_u32m1(x);
    vbool32_t neg = __riscv_vmsne_vx_u32m1_b32(__riscv_vsrl_vx_u32m1(b, 31, vl), 0, vl);
    vfloat32m1_t xa = __riscv_vreinterpret_v_u32m1_f32m1(__riscv_vand_vx_u32m1(b, 0x7FFFFFFFu, vl));
    vfloat32m1_t ex = vbs_exp(__riscv_vfneg_v_f32m1(__riscv_vfmul_vf_f32m1(
                          __riscv_vfmul_vv_f32m1(xa, xa, vl), C[0], vl), vl), C, vl);
    vfloat32m1_t nn = __riscv_vfmul_vf_f32m1(ex, C[19], vl);
    vfloat32m1_t k2 = __riscv_vfrdiv_vf_f32m1(__riscv_vfadd_vf_f32m1(__riscv_vfmul_vf_f32m1(xa, C[20], vl), C[1], vl),
                                             C[1], vl);
    vfloat32m1_t k22 = __riscv_vfmul_vv_f32m1(k2, k2, vl), k23 = __riscv_vfmul_vv_f32m1(k22, k2, vl);
    vfloat32m1_t k24 = __riscv_vfmul_vv_f32m1(k23, k2, vl), k25 = __riscv_vfmul_vv_f32m1(k24, k2, vl);
    vfloat32m1_t l1 = __riscv_vfmul_vf_f32m1(k2, C[21], vl);
    vfloat32m1_t l2 = __riscv_vfmul_vf_f32m1(k22, C[22], vl);
    l2 = __riscv_vfadd_vv_f32m1(l2, __riscv_vfmul_vf_f32m1(k23, C[23], vl), vl);
    l2 = __riscv_vfadd_vv_f32m1(l2, __riscv_vfmul_vf_f32m1(k24, C[24], vl), vl);
    l2 = __riscv_vfadd_vv_f32m1(l2, __riscv_vfmul_vf_f32m1(k25, C[25], vl), vl);
    l1 = __riscv_vfadd_vv_f32m1(l1, l2, vl);
    vfloat32m1_t loc = __riscv_vfrsub_vf_f32m1(__riscv_vfmul_vv_f32m1(l1, nn, vl), C[1], vl);   /* 1 - l*n */
    return __riscv_vmerge_vvm_f32m1(loc, __riscv_vfrsub_vf_f32m1(loc, C[1], vl), neg, vl);
}
static void v_blackscholes(const uint32_t *a)
{
    const float *S = AKP(const float, a[0]), *K = AKP(const float, a[1]), *r = AKP(const float, a[2]);
    const float *v = AKP(const float, a[3]), *T = AKP(const float, a[4]), *C = AKP(const float, a[7]);
    float *call = AKP(float, a[5]), *put = AKP(float, a[6]);
    const uint32_t n = a[8];
    for (uint32_t i0 = 0; i0 < n; ) {
        size_t vl = __riscv_vsetvl_e32m1(n - i0);
        vfloat32m1_t s = __riscv_vle32_v_f32m1(S + i0, vl), k = __riscv_vle32_v_f32m1(K + i0, vl);
        vfloat32m1_t rr = __riscv_vle32_v_f32m1(r + i0, vl), vo = __riscv_vle32_v_f32m1(v + i0, vl);
        vfloat32m1_t t = __riscv_vle32_v_f32m1(T + i0, vl);
        vfloat32m1_t sq = __riscv_vfsqrt_v_f32m1(t, vl);
        vfloat32m1_t lt = vbs_log(__riscv_vfdiv_vv_f32m1(s, k, vl), C, vl);
        vfloat32m1_t pw = __riscv_vfmul_vf_f32m1(__riscv_vfmul_vv_f32m1(vo, vo, vl), C[0], vl);
        vfloat32m1_t d1 = __riscv_vfadd_vv_f32m1(__riscv_vfmul_vv_f32m1(__riscv_vfadd_vv_f32m1(rr, pw, vl), t, vl), lt, vl);
        vfloat32m1_t den = __riscv_vfmul_vv_f32m1(vo, sq, vl);
        d1 = __riscv_vfdiv_vv_f32m1(d1, den, vl);
        vfloat32m1_t d2 = __riscv_vfsub_vv_f32m1(d1, den, vl);
        vfloat32m1_t n1 = vbs_cndf(d1, C, vl), n2 = vbs_cndf(d2, C, vl);
        vfloat32m1_t fv = __riscv_vfmul_vv_f32m1(k, vbs_exp(__riscv_vfneg_v_f32m1(__riscv_vfmul_vv_f32m1(rr, t, vl), vl), C, vl), vl);
        __riscv_vse32_v_f32m1(call + i0, __riscv_vfsub_vv_f32m1(__riscv_vfmul_vv_f32m1(s, n1, vl),
                                                                __riscv_vfmul_vv_f32m1(fv, n2, vl), vl), vl);
        __riscv_vse32_v_f32m1(put + i0, __riscv_vfsub_vv_f32m1(
            __riscv_vfmul_vv_f32m1(fv, __riscv_vfrsub_vf_f32m1(n2, C[1], vl), vl),
            __riscv_vfmul_vv_f32m1(s, __riscv_vfrsub_vf_f32m1(n1, C[1], vl), vl), vl), vl);
        i0 += vl;
    }
}
#undef VF
