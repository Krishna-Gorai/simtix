/*
 * ak_vector.c - RVV 1.0 kernels for Ara (2 lanes, VLEN 2048), GCC intrinsics.
 *
 * Every kernel does, per output element, the same operations in the same order as
 * the A53 reference (ak_scalar.c), so the results are compared exactly: the vector
 * runs over independent outputs (columns of C, rows of the sparse matrix, points,
 * pixels, pairs, ...), never re-associates a sum of floats. Integer sums (k-means,
 * scan) may be reordered (exact modulo 2^32).
 *
 * Ordering: Ara makes a vector memory access wait for CVA6's pending stores. Where a
 * later access (vector or scalar) reads what a vector store wrote (the next stencil
 * sweep, BFS level, MLP or conv layer), a fence (CVA6 waits until Ara is idle)
 * separates the two phases.
 *
 * Ara (pulp-platform/ara 34bd3bc, the latest) runs legal RVV 1.0 code from GCC 15
 * wrongly in several ways; every kernel passes under QEMU 10.2 (VLEN 1024) as written
 * with plain intrinsics. The kernels below avoid each case found in the Verilator
 * model of the board wrapper (and, where checked, Ara's own testbench):
 *  1. Under LMUL > 1 the dispatcher applies the register-group alignment check also
 *     to the destination of a mask-producing compare (vmseq v2, v4, ... traps) and to
 *     the scalar operand of a reduction. Kernels that compare run at LMUL 1.
 *  2. Masks: vcpop.m / vfirst.m count set bits that are not there when vl is not a
 *     multiple of 64; masked loads, stores and arithmetic (mask undisturbed) and the
 *     mask-logical instructions lost elements, hung or gave timing-dependent results
 *     in some code shapes. Masks are used only as vmerge selectors of compares;
 *     counts and sums are unmasked reductions; indexed loads read element 0 for the
 *     inactive elements; BFS's scatter is unmasked (inactive elements write level 0
 *     to the root). The Mandelbrot loop uses no mask at all (integer escape test).
 *  3. A widening .vx instruction takes the whole scalar register, not its low SEW bits
 *     sign-extended (GCC loads an int8 scalar with lbu): sx8() below.
 *  4. Narrowing into the low part of the source group (vnsrl.wi v4, v4, 0, GCC's
 *     vncvt) gave wrong elements: requant() narrows in inline assembly with
 *     early-clobber outputs; indexed loads likewise never write their index register.
 *  5. Spills (whole-register vs1r / vl1re32) are reloaded wrongly: no kernel spills
 *     (conv: two output channels per pass, not four), and build.sh turns GCC's
 *     auto-vectorizer off for this file (it vectorized scalar set-up code).
 *  6. vid.v deadlocks Ara (mandel, backprop and sort hung exactly when they used it, in
 *     every other form tried): element indices come from a table (ak_iota) instead.
 *  7. Gaussian's Fan1 (strided load of a column, vfdiv.vf by the pivot, strided store
 *     of the multipliers) gave wrong multipliers when it ran after nn's kernel (vfsqrt),
 *     and not after hotspot or hotspot3D or alone: 70 wrong words at n = 40 in the
 *     self-test, 1,831 in the full Rodinia sequence; in another build of the same test
 *     Ara deadlocked in it (busy until the 5M-cycle limit). Fan1 runs on CVA6's scalar divider
 *     (v_rd_gaussian; -DAK_RD_GAUSS_VDIV restores the vector form), which gives the same
 *     quotients; it is O(n) per step against Fan2's O(n^2).
 */
#include <riscv_vector.h>
#include "ak.h"

#define UNSEEN 0xFFFFFFFFu
#define FENCE() __asm__ volatile("fence" ::: "memory")

/* Element indices 0..255 (VLMAX at e32 LMUL 4). Ara deadlocks on vid.v (its mask unit
   generates it): mandel, backprop and sort hung exactly when they used it, so the
   kernels load the indices from this table with an ordinary unit-stride load. */
static const uint32_t ak_iota[256] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255 };
#define IOTA1(vl) __riscv_vle32_v_u32m1(ak_iota, (vl))
#define IOTA4(vl) __riscv_vle32_v_u32m4(ak_iota, (vl))

/* Masks are used only as vmerge selectors (from compares): masked loads, stores,
   arithmetic and reductions and the mask unit's own instructions all misbehave on
   Ara in some code shapes (see the header). */

/* Sum of the first vl elements of v (unmasked reduction). */
static inline uint32_t sum_u32(vuint32m1_t v, size_t vl)
{
    return __riscv_vmv_x_s_u32m1_u32(__riscv_vredsum_vs_u32m1_u32m1(v, __riscv_vmv_v_x_u32m1(0, 1), vl));
}
/* Number of set elements among the first vl of m. */
static inline uint32_t count_b32(vbool32_t m, size_t vl)
{
    return sum_u32(__riscv_vmerge_vxm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), 1, m, vl), vl);
}
#define any_b32(m, vl) (count_b32((m), (vl)) != 0)

/* Unmasked indexed load, e32 LMUL 1 (early-clobber output: never the index register). */
static inline vuint32m1_t ld_idx(const void *base, vuint32m1_t off, size_t vl)
{
    vuint32m1_t r;
    __asm__ volatile("vsetvli zero, %[vl], e32, m1, ta, ma\n\t"
                     "vluxei32.v %[r], (%[b]), %[o]"
                     : [r] "=&vr"(r)
                     : [o] "vr"(off), [b] "r"(base), [vl] "r"(vl)
                     : "memory", "vl", "vtype");
    return r;
}
/* Element i (m set) = *(base + off[i] bytes), the others = mo[i]; the others read
   base[0] (every array here has an element 0). */
static inline vuint32m1_t gather_u32(vbool32_t m, vuint32m1_t mo, const void *base,
                                     vuint32m1_t off, size_t vl)
{
    const vuint32m1_t o = __riscv_vmerge_vvm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), off, m, vl);
    return __riscv_vmerge_vvm_u32m1(mo, ld_idx(base, o, vl), m, vl);
}
static inline vfloat32m1_t gather_f32(vbool32_t m, const float *base, vuint32m1_t off, size_t vl)
{
    return __riscv_vreinterpret_v_u32m1_f32m1(
        gather_u32(m, __riscv_vmv_v_x_u32m1(0, vl), base, off, vl));
}

/* An int8 scalar for a widening .vx instruction, sign-extended to the full register.
   RVV uses only the low SEW bits of the scalar, so GCC loads it with lbu; Ara's
   widening multiply(-add) takes the whole register instead (-44 became 212). The
   empty asm keeps the lb result as it is. */
static inline int32_t sx8(const int8_t *p)
{
    int32_t w = *p;
    __asm__("" : "+r"(w));
    return w;
}

/* ── GEMM: four rows of C per pass, a strip of columns per vector ─────────────── */
static void v_gemm(const uint32_t *a)
{
    const float *A = AKP(const float, a[0]), *B = AKP(const float, a[1]);
    float *C = AKP(float, a[2]);
    const uint32_t n = a[3];
    for (uint32_t j0 = 0; j0 < n; ) {
        size_t vl = __riscv_vsetvl_e32m4(n - j0);
        uint32_t i = 0;
        for (; i + 4 <= n; i += 4) {
            const float *a0 = A + i * n, *a1 = a0 + n, *a2 = a1 + n, *a3 = a2 + n;
            vfloat32m4_t c0 = __riscv_vfmv_v_f_f32m4(0.0f, vl), c1 = c0, c2 = c0, c3 = c0;
            for (uint32_t k = 0; k < n; k++) {
                vfloat32m4_t b = __riscv_vle32_v_f32m4(B + k * n + j0, vl);
                c0 = __riscv_vfmacc_vf_f32m4(c0, a0[k], b, vl);
                c1 = __riscv_vfmacc_vf_f32m4(c1, a1[k], b, vl);
                c2 = __riscv_vfmacc_vf_f32m4(c2, a2[k], b, vl);
                c3 = __riscv_vfmacc_vf_f32m4(c3, a3[k], b, vl);
            }
            __riscv_vse32_v_f32m4(C + i * n + j0, c0, vl);
            __riscv_vse32_v_f32m4(C + (i + 1) * n + j0, c1, vl);
            __riscv_vse32_v_f32m4(C + (i + 2) * n + j0, c2, vl);
            __riscv_vse32_v_f32m4(C + (i + 3) * n + j0, c3, vl);
        }
        for (; i < n; i++) {
            vfloat32m4_t c0 = __riscv_vfmv_v_f_f32m4(0.0f, vl);
            for (uint32_t k = 0; k < n; k++)
                c0 = __riscv_vfmacc_vf_f32m4(c0, A[i * n + k], __riscv_vle32_v_f32m4(B + k * n + j0, vl), vl);
            __riscv_vse32_v_f32m4(C + i * n + j0, c0, vl);
        }
        j0 += vl;
    }
}

/* ── SpMV: one row per element, the j-th nonzero of every row per step ─────────── */
static void v_spmv(const uint32_t *a)
{
    const uint32_t *rowptr = AKP(const uint32_t, a[0]), *col = AKP(const uint32_t, a[1]);
    const float *val = AKP(const float, a[2]), *x = AKP(const float, a[3]);
    float *y = AKP(float, a[4]);
    const uint32_t rows = a[5];
    for (uint32_t r0 = 0; r0 < rows; ) {
        size_t vl = __riscv_vsetvl_e32m1(rows - r0);
        vuint32m1_t beg = __riscv_vle32_v_u32m1(rowptr + r0, vl);
        vuint32m1_t len = __riscv_vsub_vv_u32m1(__riscv_vle32_v_u32m1(rowptr + r0 + 1, vl), beg, vl);
        vuint32m1_t zero = __riscv_vmv_v_x_u32m1(0, vl);
        vuint32m1_t off = __riscv_vsll_vx_u32m1(beg, 2, vl);
        vfloat32m1_t acc = __riscv_vfmv_v_f_f32m1(0.0f, vl);
        for (uint32_t j = 0; ; j++) {
            vbool32_t m = __riscv_vmsgtu_vx_u32m1_b32(len, j, vl);
            if (!any_b32(m, vl)) break;
            vfloat32m1_t v = gather_f32(m, val, off, vl);
            vuint32m1_t c = gather_u32(m, zero, col, off, vl);
            vfloat32m1_t xv = gather_f32(m, x, __riscv_vsll_vx_u32m1(c, 2, vl), vl);
            acc = __riscv_vmerge_vvm_f32m1(acc, __riscv_vfmacc_vv_f32m1(acc, v, xv, vl), m, vl);
            off = __riscv_vadd_vx_u32m1(off, 4, vl);
        }
        __riscv_vse32_v_f32m1(y + r0, acc, vl);
        r0 += vl;
    }
}

/* ── Stencil: a strip of a row per vector ─────────────────────────────────────── */
static void v_stencil(const uint32_t *a)
{
    float *g[2] = { AKP(float, a[0]), AKP(float, a[1]) };
    const uint32_t n = a[2], s = a[3], sweeps = a[6];
    const float c0 = ak_f(a[4]), c1 = ak_f(a[5]);
    for (uint32_t t = 0; t < sweeps; t++) {
        const float *in = g[t % 2];
        float *out = g[(t + 1) % 2];
        for (uint32_t i = 0; i < n; i++)
            for (uint32_t j0 = 0; j0 < n; ) {
                size_t vl = __riscv_vsetvl_e32m4(n - j0);
                const float *q = in + (i + 1) * s + 8 + j0;
                vfloat32m4_t sm = __riscv_vfadd_vv_f32m4(
                    __riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(q - s, vl), __riscv_vle32_v_f32m4(q + s, vl), vl),
                    __riscv_vfadd_vv_f32m4(__riscv_vle32_v_f32m4(q - 1, vl), __riscv_vle32_v_f32m4(q + 1, vl), vl), vl);
                vfloat32m4_t o = __riscv_vfmul_vf_f32m4(__riscv_vle32_v_f32m4(q, vl), c0, vl);
                o = __riscv_vfmacc_vf_f32m4(o, c1, sm, vl);
                __riscv_vse32_v_f32m4(out + (i + 1) * s + 8 + j0, o, vl);
                j0 += vl;
            }
        FENCE();
    }
}

/* ── k-means: assignment per point, sums by masked reductions per centroid ────── */
static void v_kmeans(const uint32_t *a)
{
    const uint32_t *px = AKP(const uint32_t, a[0]), *py = AKP(const uint32_t, a[1]);
    const uint32_t *cx = AKP(const uint32_t, a[2]), *cy = AKP(const uint32_t, a[3]);
    const uint32_t k = a[4], npts = a[9];
    uint32_t *as = AKP(uint32_t, a[5]), *sx = AKP(uint32_t, a[6]);
    uint32_t *sy = AKP(uint32_t, a[7]), *cn = AKP(uint32_t, a[8]);
    for (uint32_t j = 0; j < k; j++) sx[j] = sy[j] = cn[j] = 0;
    for (uint32_t p0 = 0; p0 < npts; ) {
        size_t vl = __riscv_vsetvl_e32m1(npts - p0);
        vuint32m1_t x = __riscv_vle32_v_u32m1(px + p0, vl), y = __riscv_vle32_v_u32m1(py + p0, vl);
        vuint32m1_t best = __riscv_vmv_v_x_u32m1(0x7FFFFFFFu, vl), bk = __riscv_vmv_v_x_u32m1(0, vl);
        const vuint32m1_t z0 = __riscv_vmv_v_x_u32m1(0, vl);
        for (uint32_t j = 0; j < k; j++) {
            vuint32m1_t dx = __riscv_vsub_vx_u32m1(x, cx[j], vl), dy = __riscv_vsub_vx_u32m1(y, cy[j], vl);
            vuint32m1_t d = __riscv_vmacc_vv_u32m1(__riscv_vmul_vv_u32m1(dx, dx, vl), dy, dy, vl);
            vbool32_t m = __riscv_vmsltu_vv_u32m1_b32(d, best, vl);
            best = __riscv_vmerge_vvm_u32m1(best, d, m, vl);
            bk = __riscv_vmerge_vxm_u32m1(bk, j, m, vl);
        }
        __riscv_vse32_v_u32m1(as + p0, bk, vl);
        for (uint32_t j = 0; j < k; j++) {
            vbool32_t m = __riscv_vmseq_vx_u32m1_b32(bk, j, vl);
            const uint32_t c = count_b32(m, vl);
            if (!c) continue;
            sx[j] += sum_u32(__riscv_vmerge_vvm_u32m1(z0, x, m, vl), vl);
            sy[j] += sum_u32(__riscv_vmerge_vvm_u32m1(z0, y, m, vl), vl);
            cn[j] += c;
        }
        p0 += vl;
    }
}

/* ── BFS: level-synchronous, one vertex per element (as SIMTiX's bfs.S) ────────── */
static void v_bfs(const uint32_t *a)
{
    const uint32_t *rowptr = AKP(const uint32_t, a[0]), *col = AKP(const uint32_t, a[1]);
    uint32_t *lev = AKP(uint32_t, a[2]);
    const uint32_t nv = a[3];
    for (uint32_t v0 = 0; v0 < nv; ) {
        size_t vl = __riscv_vsetvl_e32m8(nv - v0);
        __riscv_vse32_v_u32m8(lev + v0, __riscv_vmv_v_x_u32m8(UNSEEN, vl), vl);
        v0 += vl;
    }
    FENCE();
    lev[0] = 0;
    for (uint32_t L = 0; ; L++) {
        int changed = 0;
        for (uint32_t v0 = 0; v0 < nv; ) {
            size_t vl = __riscv_vsetvl_e32m1(nv - v0);
            vbool32_t m = __riscv_vmseq_vx_u32m1_b32(__riscv_vle32_v_u32m1(lev + v0, vl), L, vl);
            if (any_b32(m, vl)) {
                vuint32m1_t beg = __riscv_vle32_v_u32m1(rowptr + v0, vl);
                vuint32m1_t len = __riscv_vsub_vv_u32m1(__riscv_vle32_v_u32m1(rowptr + v0 + 1, vl), beg, vl);
                vuint32m1_t zero = __riscv_vmv_v_x_u32m1(0, vl), nxt = __riscv_vmv_v_x_u32m1(L + 1, vl);
                len = __riscv_vmerge_vvm_u32m1(zero, len, m, vl);   /* 0 off level L */
                vuint32m1_t off = __riscv_vsll_vx_u32m1(beg, 2, vl);
                for (uint32_t j = 0; ; j++) {
                    vbool32_t mj = __riscv_vmsgtu_vx_u32m1_b32(len, j, vl);
                    if (!any_b32(mj, vl)) break;
                    vuint32m1_t u = gather_u32(mj, zero, col, off, vl);
                    vuint32m1_t uo = __riscv_vsll_vx_u32m1(u, 2, vl);
                    vuint32m1_t lu = gather_u32(mj, zero, lev, uo, vl);
                    vbool32_t mu = __riscv_vmseq_vx_u32m1_b32(lu, UNSEEN, vl);   /* lu = 0 off mj */
                    if (any_b32(mu, vl)) {
                        /* unmasked scatter: the others write level 0 to vertex 0 (the root) */
                        __riscv_vsuxei32_v_u32m1(lev, __riscv_vmerge_vvm_u32m1(zero, uo, mu, vl),
                                                 __riscv_vmerge_vvm_u32m1(zero, nxt, mu, vl), vl);
                        changed = 1;
                    }
                    off = __riscv_vadd_vx_u32m1(off, 4, vl);
                }
            }
            v0 += vl;
        }
        FENCE();
        if (!changed) break;
    }
}

/* ── Scan: log-step scan inside a vector, carry between vectors ───────────────── */
static void v_scan(const uint32_t *a)
{
    const uint32_t *in = AKP(const uint32_t, a[0]);
    uint32_t *out = AKP(uint32_t, a[1]);
    const uint32_t n = a[2];
    uint32_t carry = 0;
    for (uint32_t i0 = 0; i0 < n; ) {
        size_t vl = __riscv_vsetvl_e32m8(n - i0);
        vuint32m8_t v = __riscv_vle32_v_u32m8(in + i0, vl), z = __riscv_vmv_v_x_u32m8(0, vl);
        for (size_t s = 1; s < vl; s <<= 1)
            v = __riscv_vadd_vv_u32m8(v, __riscv_vslideup_vx_u32m8(z, v, s, vl), vl);
        v = __riscv_vadd_vx_u32m8(v, carry, vl);
        __riscv_vse32_v_u32m8(out + i0, v, vl);
        carry = __riscv_vmv_x_s_u32m8_u32(__riscv_vslidedown_vx_u32m8(v, vl - 1, vl));
        i0 += vl;
    }
}

/* Requantization as the reference: rne(clamp(fmaf((float)acc, scale, zp), 0, 127)).
   The conversion back uses the dynamic rounding mode, round to nearest even. */
static inline vint8m1_t requant(vint32m4_t acc, float scale, float zp, size_t vl)
{
    vfloat32m4_t f = __riscv_vfcvt_f_x_v_f32m4(acc, vl);
    f = __riscv_vfmadd_vf_f32m4(f, scale, __riscv_vfmv_v_f_f32m4(zp, vl), vl);
    f = __riscv_vfmax_vf_f32m4(__riscv_vfmin_vf_f32m4(f, 127.0f, vl), 0.0f, vl);
    /* f32 -> i16 (round to nearest even, frm = 0) -> i8. Ara computes a narrowing op
       wrongly when vd is the low part of its own source group (vnsrl.wi v4, v4, 0,
       legal RVV and what GCC emits for vncvt); the early-clobber outputs keep every
       destination off the sources. */
    vint16m2_t h;
    vint8m1_t b;
    __asm__("vsetvli zero, %[vl], e16, m2, ta, ma\n\t"
            "vfncvt.x.f.w %[h], %[f]\n\t"
            "vsetvli zero, %[vl], e8, m1, ta, ma\n\t"
            "vnsrl.wi %[b], %[h], 0"
            : [h] "=&vr"(h), [b] "=&vr"(b)
            : [f] "vr"(f), [vl] "r"(vl)
            : "vl", "vtype");
    return b;
}

/* ── MLP: outputs of an image per vector; four INT8 products summed in INT16
   (|x w| <= 127 * 64, four fit), then added into INT32 ───────────────────────── */
static void v_mlp(const uint32_t *a)
{
    const uint8_t *x0 = AKP(const uint8_t, a[0]);
    const uint32_t batch = a[1], nl = a[2];
    const uint32_t *dims = AKP(const uint32_t, a[3]);
    const int8_t *w[3] = { AKP(const int8_t, a[4]), AKP(const int8_t, a[5]), AKP(const int8_t, a[6]) };
    uint8_t *buf[2] = { AKP(uint8_t, a[7]), AKP(uint8_t, a[8]) };
    int32_t *logit = AKP(int32_t, a[9]);
    const float scale = ak_f(a[10]), zp = ak_f(a[11]);
    const int8_t *src = (const int8_t *)x0;
    for (uint32_t l = 0; l < nl; l++) {
        const uint32_t k = dims[l], np = dims[4 + l];
        const int last = (l == nl - 1);
        const int8_t *W = w[l];
        uint8_t *dst = buf[l % 2];
        for (uint32_t b = 0; b < batch; b++) {
            const int8_t *xb = src + b * k;
            for (uint32_t n0 = 0; n0 < np; ) {
                size_t vl = __riscv_vsetvl_e32m4(np - n0);
                vint32m4_t acc = __riscv_vmv_v_x_i32m4(0, vl);
                for (uint32_t kk = 0; kk < k; kk += 4) {
                    const int8_t *wr_ = W + kk * np + n0;
                    vint16m2_t s = __riscv_vwmul_vx_i16m2(__riscv_vle8_v_i8m1(wr_, vl), sx8(&xb[kk]), vl);
                    s = __riscv_vwmacc_vx_i16m2(s, sx8(&xb[kk + 1]), __riscv_vle8_v_i8m1(wr_ + np, vl), vl);
                    s = __riscv_vwmacc_vx_i16m2(s, sx8(&xb[kk + 2]), __riscv_vle8_v_i8m1(wr_ + 2 * np, vl), vl);
                    s = __riscv_vwmacc_vx_i16m2(s, sx8(&xb[kk + 3]), __riscv_vle8_v_i8m1(wr_ + 3 * np, vl), vl);
                    acc = __riscv_vwadd_wv_i32m4(acc, s, vl);
                }
                if (last)
                    __riscv_vse32_v_i32m4(logit + b * np + n0, acc, vl);
                else
                    __riscv_vse8_v_i8m1((int8_t *)dst + b * np + n0, requant(acc, scale, zp, vl), vl);
                n0 += vl;
            }
        }
        FENCE();
        src = (const int8_t *)dst;
    }
}

/* ── CONV: activations [row][channel][column] bytes; a strip of an output row per
   vector, four output channels per pass so each input vector is loaded once ─── */
static void v_conv(const uint32_t *a)
{
    int8_t *x[3] = { AKP(int8_t, a[0]), AKP(int8_t, a[1]), AKP(int8_t, a[2]) };
    const int8_t *wt[2] = { AKP(const int8_t, a[3]), AKP(const int8_t, a[4]) };
    const uint32_t n = a[5], ch[3] = { a[6], a[7], a[8] }, wp = n + 2;
    const float scale = ak_f(a[9]), zp = ak_f(a[10]);
    for (unsigned l = 0; l < 2; l++) {
        const uint32_t ci = ch[l], co = ch[l + 1];
        const int8_t *in = x[l], *W = wt[l];
        int8_t *out = x[l + 1];
        for (uint32_t y = 0; y < n; y++)
            for (uint32_t x0 = 0; x0 < n; ) {
                size_t vl = __riscv_vsetvl_e32m4(n - x0);
                for (uint32_t o = 0; o < co; o += 2) {
                    vint32m4_t a0 = __riscv_vmv_v_x_i32m4(0, vl), a1 = a0;
                    for (uint32_t ky = 0; ky < 3; ky++)
                        for (uint32_t kx = 0; kx < 3; kx++) {
                            const int8_t *w0 = W + ((o * 3u + ky) * 3u + kx) * ci;
                            const uint32_t ws = 9u * ci;          /* next output channel */
                            for (uint32_t c = 0; c < ci; c += 4) {
                                const int8_t *ip = in + ((y + ky) * ci + c) * wp + x0 + kx;
                                vint8m1_t v = __riscv_vle8_v_i8m1(ip, vl);
                                vint16m2_t s0 = __riscv_vwmul_vx_i16m2(v, sx8(&w0[c]), vl);
                                vint16m2_t s1 = __riscv_vwmul_vx_i16m2(v, sx8(&w0[ws + c]), vl);
                                for (uint32_t i = 1; i < 4; i++) {
                                    v = __riscv_vle8_v_i8m1(ip + i * wp, vl);
                                    s0 = __riscv_vwmacc_vx_i16m2(s0, sx8(&w0[c + i]), v, vl);
                                    s1 = __riscv_vwmacc_vx_i16m2(s1, sx8(&w0[ws + c + i]), v, vl);
                                }
                                a0 = __riscv_vwadd_wv_i32m4(a0, s0, vl);
                                a1 = __riscv_vwadd_wv_i32m4(a1, s1, vl);
                            }
                        }
                    int8_t *op = out + ((y + 1) * co + o) * wp + 1 + x0;
                    __riscv_vse8_v_i8m1(op, requant(a0, scale, zp, vl), vl);
                    __riscv_vse8_v_i8m1(op + wp, requant(a1, scale, zp, vl), vl);
                }
                x0 += vl;
            }
        FENCE();
    }
}

/* ── Embedding bag: the 32 floats of a bag per vector ─────────────────────────── */
static void v_embag(const uint32_t *a)
{
    const float *t = AKP(const float, a[0]);
    const uint32_t *idx = AKP(const uint32_t, a[1]);
    float *out = AKP(float, a[2]);
    const uint32_t bags = a[3], k = a[4], D = AK_EMBAG_D;
    size_t vl = __riscv_vsetvl_e32m1(D);
    for (uint32_t b = 0; b < bags; b++) {
        vfloat32m1_t acc = __riscv_vfmv_v_f_f32m1(0.0f, vl);
        for (uint32_t j = 0; j < k; j++)
            acc = __riscv_vfadd_vv_f32m1(acc, __riscv_vle32_v_f32m1(t + idx[b * k + j] * D, vl), vl);
        __riscv_vse32_v_f32m1(out + b * D, acc, vl);
    }
}

/* ── Hash join: one probe per element, the still-searching ones step on ───────── */
static void v_hashj(const uint32_t *a)
{
    const uint32_t *slot = AKP(const uint32_t, a[0]), *key = AKP(const uint32_t, a[1]);
    uint32_t *out = AKP(uint32_t, a[2]);
    const uint32_t nprobe = a[3], s = a[4], mask = (1u << s) - 1u;
    for (uint32_t i0 = 0; i0 < nprobe; ) {
        size_t vl = __riscv_vsetvl_e32m1(nprobe - i0);
        vuint32m1_t kv = __riscv_vle32_v_u32m1(key + i0, vl);
        vuint32m1_t h = __riscv_vsrl_vx_u32m1(__riscv_vmul_vx_u32m1(kv, 0x9E3779B1u, vl), 32u - s, vl);
        vuint32m1_t res = __riscv_vmv_v_x_u32m1(0xFFFFFFFFu, vl), zero = __riscv_vmv_v_x_u32m1(0, vl);
        vuint32m1_t act = __riscv_vmv_v_x_u32m1(1, vl);          /* 1 = still probing */
        for (;;) {
            vuint32m1_t off = __riscv_vsll_vx_u32m1(h, 3, vl);    /* every h is a valid slot */
            vuint32m1_t sk = ld_idx(slot, off, vl);
            vuint32m1_t hit = __riscv_vmerge_vvm_u32m1(zero, act, __riscv_vmseq_vv_u32m1_b32(sk, kv, vl), vl);
            vuint32m1_t emp = __riscv_vmerge_vvm_u32m1(zero, act, __riscv_vmseq_vx_u32m1_b32(sk, 0, vl), vl);
            const vbool32_t mh = __riscv_vmsne_vx_u32m1_b32(hit, 0, vl);
            if (any_b32(mh, vl))
                res = __riscv_vmerge_vvm_u32m1(res, ld_idx(slot + 1, off, vl), mh, vl);
            act = __riscv_vsub_vv_u32m1(__riscv_vsub_vv_u32m1(act, hit, vl), emp, vl);
            if (!sum_u32(act, vl)) break;
            h = __riscv_vand_vx_u32m1(__riscv_vadd_vx_u32m1(h, 1, vl), mask, vl);
        }
        __riscv_vse32_v_u32m1(out + i0, res, vl);
        i0 += vl;
    }
}

/* ── Mandelbrot: a strip of a row per vector, iterate while any pixel is live ─── */
static void v_mandel(const uint32_t *a)
{
    uint32_t *out = AKP(uint32_t, a[0]);
    const uint32_t n = a[1], m = a[5];
    const float x0 = ak_f(a[2]), y0 = ak_f(a[3]), d = ak_f(a[4]);
    for (uint32_t py = 0; py < n; py++) {
        const float ci = __builtin_fmaf((float)py, d, y0);
        for (uint32_t px0 = 0; px0 < n; ) {
            size_t vl = __riscv_vsetvl_e32m1(n - px0);
            vfloat32m1_t civ = __riscv_vfmv_v_f_f32m1(ci, vl);
            vfloat32m1_t pxf = __riscv_vfcvt_f_xu_v_f32m1(__riscv_vadd_vx_u32m1(IOTA1(vl), px0, vl), vl);
            vfloat32m1_t cr = __riscv_vfmadd_vf_f32m1(pxf, d, __riscv_vfmv_v_f_f32m1(x0, vl), vl);
            vfloat32m1_t zr = __riscv_vfmv_v_f_f32m1(0.0f, vl), zi = __riscv_vfmv_v_f_f32m1(0.0f, vl);
            vuint32m1_t k = __riscv_vmv_v_x_u32m1(0, vl);
            vuint32m1_t act = __riscv_vmv_v_x_u32m1(1, vl);     /* 1 = still iterating */
            /* No mask and no FP compare in this loop: in every masked or fenced form tried,
               Ara deadlocked or returned wrong counts here (timing-dependent); this form
               matches the reference on Ara. */
            do {
                vfloat32m1_t zr2 = __riscv_vfmul_vv_f32m1(zr, zr, vl), zi2 = __riscv_vfmul_vv_f32m1(zi, zi, vl);
                /* 1 where |z|^2 <= 4: |z|^2 of a live pixel is finite and >= +0, where float
                   order is the order of the bit patterns (sign of 0x40800000 - bits) */
                vuint32m1_t in = __riscv_vsrl_vx_u32m1(__riscv_vnot_v_u32m1(__riscv_vrsub_vx_u32m1(
                                     __riscv_vreinterpret_v_f32m1_u32m1(__riscv_vfadd_vv_f32m1(zr2, zi2, vl)),
                                     0x40800000u, vl), vl), 31, vl);
                zi = __riscv_vfmadd_vf_f32m1(__riscv_vfmul_vv_f32m1(zr, zi, vl), 2.0f, civ, vl);
                zr = __riscv_vfadd_vv_f32m1(__riscv_vfsub_vv_f32m1(zr2, zi2, vl), cr, vl);
                /* keep escaped pixels finite (no inf or NaN); live ones are far inside */
                zi = __riscv_vfmax_vf_f32m1(__riscv_vfmin_vf_f32m1(zi, 1e10f, vl), -1e10f, vl);
                zr = __riscv_vfmax_vf_f32m1(__riscv_vfmin_vf_f32m1(zr, 1e10f, vl), -1e10f, vl);
                k = __riscv_vadd_vv_u32m1(k, act, vl);
                vuint32m1_t lt = __riscv_vsrl_vx_u32m1(__riscv_vsub_vx_u32m1(k, m, vl), 31, vl);   /* k < m */
                act = __riscv_vand_vv_u32m1(__riscv_vand_vv_u32m1(act, in, vl), lt, vl);
            } while (sum_u32(act, vl));
            __riscv_vse32_v_u32m1(out + py * n + px0, k, vl);
            px0 += vl;
        }
    }
}

/* ── Smith-Waterman: one pair per element (INT16 scores: |score| < 2^14), the
   query rows H and E of the current strip in a scratch buffer ────────────────── */
#define SW_STRIP 256u
static void v_swat(const uint32_t *a)
{
    const uint8_t *qv = AKP(const uint8_t, a[0]), *tv = AKP(const uint8_t, a[1]);
    uint32_t *out = AKP(uint32_t, a[2]);
    const uint32_t pairs = a[3], lq = a[4], lt = a[5];
    int16_t *H = AKP(int16_t, a[6]), *E = H + lq * SW_STRIP;
    for (uint32_t p0 = 0; p0 < pairs; ) {
        size_t vl = __riscv_vsetvl_e16m2(pairs - p0 < SW_STRIP ? pairs - p0 : SW_STRIP);
        vint16m2_t zero = __riscv_vmv_v_x_i16m2(0, vl), neg = __riscv_vmv_v_x_i16m2(AK_SW_NEG, vl);
        vint16m2_t best = zero;
        for (uint32_t i = 0; i < lq; i++) {
            __riscv_vse16_v_i16m2(H + i * SW_STRIP, zero, vl);
            __riscv_vse16_v_i16m2(E + i * SW_STRIP, neg, vl);
        }
        FENCE();
        for (uint32_t j = 0; j < lt; j++) {
            vuint8m1_t tj = __riscv_vle8_v_u8m1(tv + j * pairs + p0, vl);
            vint16m2_t hup = zero, f = neg, diag = zero;
            for (uint32_t i = 0; i < lq; i++) {
                vint16m2_t hi = __riscv_vle16_v_i16m2(H + i * SW_STRIP, vl);
                vint16m2_t e = __riscv_vmax_vv_i16m2(__riscv_vsub_vx_i16m2(__riscv_vle16_v_i16m2(E + i * SW_STRIP, vl), 1, vl),
                                                     __riscv_vsub_vx_i16m2(hi, 3, vl), vl);
                f = __riscv_vmax_vv_i16m2(__riscv_vsub_vx_i16m2(f, 1, vl), __riscv_vsub_vx_i16m2(hup, 3, vl), vl);
                vbool8_t eq = __riscv_vmseq_vv_u8m1_b8(__riscv_vle8_v_u8m1(qv + i * pairs + p0, vl), tj, vl);
                vint16m2_t h = __riscv_vadd_vv_i16m2(diag, __riscv_vmerge_vxm_i16m2(__riscv_vmv_v_x_i16m2(-1, vl), 2, eq, vl), vl);
                h = __riscv_vmax_vv_i16m2(h, e, vl);
                h = __riscv_vmax_vv_i16m2(h, f, vl);
                h = __riscv_vmax_vx_i16m2(h, 0, vl);
                diag = hi;
                __riscv_vse16_v_i16m2(H + i * SW_STRIP, h, vl);
                __riscv_vse16_v_i16m2(E + i * SW_STRIP, e, vl);
                hup = h;
                best = __riscv_vmax_vv_i16m2(best, h, vl);
            }
            FENCE();
        }
        __riscv_vse32_v_u32m4(out + p0, __riscv_vzext_vf2_u32m4(__riscv_vreinterpret_v_i16m2_u16m2(best), vl), vl);
        p0 += vl;
    }
}

#include "s2_ref.h"
#include "ak_vector_s2.inc"
#include "ak_vector_rd.inc"
#include "rv_ref.h"                  /* RV_LAVA_NP */
#include "ak_vector_rv.inc"

const ak_fn ak_vector[AK_NAPPS] = {
    [AK_GEMM] = v_gemm, [AK_SPMV] = v_spmv, [AK_STENCIL] = v_stencil, [AK_KMEANS] = v_kmeans,
    [AK_BFS] = v_bfs, [AK_SCAN] = v_scan, [AK_MLP] = v_mlp, [AK_CONV] = v_conv,
    [AK_EMBAG] = v_embag, [AK_HASHJ] = v_hashj, [AK_MANDEL] = v_mandel, [AK_SWAT] = v_swat,
    [AK_PATHFINDER] = v_pathfinder, [AK_HOTSPOT] = v_hotspot, [AK_JACOBI2D] = v_jacobi2d,
    [AK_ATAX] = v_atax, [AK_BICG] = v_bicg, [AK_PAGERANK] = v_pagerank, [AK_CC] = v_cc,
    [AK_BACKPROP] = v_backprop, [AK_SORT] = v_sort, [AK_BLACKSCHOLES] = v_blackscholes,
    [AK_RD_HOTSPOT] = v_rd_hotspot, [AK_RD_NN] = v_rd_nn, [AK_RD_HOTSPOT3D] = v_rd_hotspot3d,
    [AK_RD_GAUSSIAN] = v_rd_gaussian, [AK_RD_KMEANS] = v_rd_kmeans,
    [AK_RV_AXPY] = v_rv_axpy, [AK_RV_MATMUL] = v_rv_matmul, [AK_RV_SPMV] = v_rv_spmv,
    [AK_RV_JACOBI] = v_rv_jacobi, [AK_RV_PATHFINDER] = v_rv_pathfinder, [AK_RV_BS] = v_rv_bs,
    [AK_RV_LAVAMD] = v_rv_lavamd,
};
