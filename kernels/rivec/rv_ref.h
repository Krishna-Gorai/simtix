/*
 * rv_ref.h - plain-C reference versions of the RiVEC batch-1 applications
 * (docs/rivec_plan.md), shared by the A53 hosts (sw/ps_host/rivec.inc) and the CVA6
 * kernels (baselines/ara/kernels/ak_scalar.c). Each function performs the FP32 operations
 * of the definition in docs/rivec_plan.md in that order: per element, RiVEC's vector code
 * read per element (its fused multiply-adds, its Cephes exp and log); sums over many
 * elements in serial order. The SIMTiX kernels (kernels/rivec/<name>.S) and the Vortex
 * ports perform the same operations.
 *
 * RiVEC macro semantics used below (common/vector_defines.h, RVV 1.0 intrinsics):
 *   _MM_MACC(d, a, b) = vfmacc  = fma(a, b, d)      _MM_MADD(d, a, b) = vfmadd = fma(d, a, b)
 *   _MM_MERGE(x, y, m) = m ? y : x                  _MM_VFCVT_X_F = round to nearest even
 *
 * Contraction is off (the A53 hosts are built without -ffp-contract=off) and the
 * functions are kept out of line, as in kernels/rodinia/rd_ref.h.
 */
#ifndef RV_REF_H
#define RV_REF_H
#include <stdint.h>

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC push_options
#pragma GCC optimize("fp-contract=off")
#endif

static inline float rv_fma(float a, float b, float c) { return __builtin_fmaf(a, b, c); }
static inline float rv_sqrtf(float x)
{
#if defined(__aarch64__)
    float r; __asm__("fsqrt %s0, %s1" : "=w"(r) : "w"(x)); return r;
#else
    return __builtin_sqrtf(x);
#endif
}
/* float -> int32, round to nearest, ties to even (vfcvt.x.f.v with frm = RNE) */
static inline int32_t rv_cvt_rne(float x)
{
#if defined(__aarch64__)
    int32_t r; __asm__("fcvtns %w0, %s1" : "=r"(r) : "w"(x)); return r;
#elif defined(__riscv)
    long r; __asm__("fcvt.w.s %0, %1, rne" : "=r"(r) : "f"(x)); return (int32_t)r;
#elif defined(__x86_64__)
    return (int32_t)__builtin_rintf(x);    /* host checks: the default rounding is RNE */
#else
#error "rv_cvt_rne: unsupported target"
#endif
}
static inline float rv_bits_f(uint32_t u) { union { uint32_t u; float f; } c = { u }; return c.f; }
static inline uint32_t rv_f_bits(float f) { union { float f; uint32_t u; } c = { f }; return c.u; }
static inline float rv_minf(float a, float b) { return b < a ? b : a; }   /* vfmin, no NaNs */
static inline float rv_maxf(float a, float b) { return b > a ? b : a; }   /* vfmax, no NaNs */

/* RiVEC common/__exp.h __exp_2xf32, one element */
static inline float rv_exp(float x)
{
    const float exp_hi = 88.3762626647949, exp_low = -88.3762626647949;
    const float LOG2EF = 1.44269504088896341, C1 = 0.693359375, C2 = -2.12194440e-4;
    const float p0 = 1.9875691500E-4, p1 = 1.3981999507E-3, p2 = 8.3334519073E-3,
                p3 = 4.1665795894E-2, p4 = 1.6666665459E-1, p5 = 5.0000001201E-1;
    x = rv_minf(x, exp_hi);
    x = rv_maxf(x, exp_low);
    float fx = rv_fma(LOG2EF, x, 0.5f);                 /* MACC_VF(0.5, LOG2EF, x) */
    float tmp = (float)rv_cvt_rne(fx);
    fx = tmp - (fx < tmp ? 1.0f : 0.0f);                /* floor */
    float t1 = fx * C1, z = fx * C2;
    x = x - t1;
    x = x - z;
    z = x * x;
    float y = p0;
    y = rv_fma(y, x, p1);                               /* MADD(y, x, p1) */
    y = rv_fma(y, x, p2);
    y = rv_fma(y, x, p3);
    y = rv_fma(y, x, p4);
    y = rv_fma(y, x, p5);
    y = rv_fma(y, z, x);                                /* MADD(y, z, x) */
    y = y + 1.0f;
    int32_t e = rv_cvt_rne(fx) + 0x7f;
    return y * rv_bits_f((uint32_t)e << 23);
}

/* RiVEC common/__log.h __log_2xf32, one element (inputs > 0 here) */
static inline float rv_log(float x)
{
    const float SQRTHF = 0.707106781186547524;
    const float p0 = 7.0376836292E-2, p1 = -1.1514610310E-1, p2 = 1.1676998740E-1,
                p3 = -1.2420140846E-1, p4 = 1.4249322787E-1, p5 = -1.6668057665E-1,
                p6 = 2.0000714765E-1, p7 = -2.4999993993E-1, p8 = 3.3333331174E-1;
    const float q1 = -2.12194440e-4, q2 = 0.693359375;
    const int invalid = !(x > 0.0f);                    /* vmfle(x, 0) */
    x = rv_maxf(x, rv_bits_f(0x00800000u));
    int32_t imm0 = (int32_t)(rv_f_bits(x) >> 23);
    x = rv_bits_f((rv_f_bits(x) & ~0x7f800000u) | rv_f_bits(0.5f));
    imm0 = imm0 - 127;
    float e = (float)imm0;
    e = e + 1.0f;
    const int m = x < SQRTHF;
    float tmp = m ? x : 0.0f;
    x = x - 1.0f;
    e = e - (m ? 1.0f : 0.0f);
    x = x + tmp;
    float z = x * x;
    float y = rv_fma(p0, x, p1);                        /* MADD(p0, x, p1) */
    y = rv_fma(y, x, p2);
    y = rv_fma(y, x, p3);
    y = rv_fma(y, x, p4);
    y = rv_fma(y, x, p5);
    y = rv_fma(y, x, p6);
    y = rv_fma(y, x, p7);
    y = rv_fma(y, x, p8);
    y = y * z;
    y = rv_fma(e, q1, y);                               /* MACC(y, e, q1) */
    tmp = z * 0.5f;
    y = y - tmp;
    tmp = e * q2;
    x = x + y;
    x = x + tmp;
    return invalid ? rv_bits_f(0xffffffffu) : x;
}

/* axpy: dy[i] = fma(a, dx[i], dy[i]) (axpy_vector: vfmacc) */
__attribute__((noinline, unused)) static void rv_axpy(float a, const float *dx, float *dy, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) dy[i] = rv_fma(a, dx[i], dy[i]);
}

/* matmul: c (m x n) = a (m x p) * b (p x n), k ascending from 0 (integer-valued data:
   exact in any order) */
__attribute__((noinline, unused)) static void rv_matmul(const float *a, const float *b, float *c,
                                                 uint32_t m, uint32_t n, uint32_t p)
{
    for (uint32_t i = 0; i < m; i++)
        for (uint32_t j = 0; j < n; j++) {
            float s = 0.0f;
            for (uint32_t k = 0; k < p; k++) s = rv_fma(a[i * p + k], b[k * n + j], s);
            c[i * n + j] = s;
        }
}

/* spmv: CSR, y[row] = sum over the row of a*x[col], serial order */
__attribute__((noinline, unused)) static void rv_spmv(uint32_t nrows, const uint32_t *ia, const uint32_t *ja,
                                               const float *a, const float *x, float *y)
{
    for (uint32_t r = 0; r < nrows; r++) {
        float s = 0.0f;
        for (uint32_t k = ia[r]; k < ia[r + 1]; k++) s = rv_fma(a[k], x[ja[k]], s);
        y[r] = s;
    }
}

/* jacobi-2d: tsteps x (B from A, then A from B) over the interior of n x n row-major
   arrays; per point RiVEC's vector order: (((c + left) + right) + (bottom + top)) * 0.2 */
static inline void rv_jacobi_sweep(const float *s, float *d, uint32_t n)
{
    for (uint32_t i = 1; i + 1 < n; i++)
        for (uint32_t j = 1; j + 1 < n; j++) {
            float u = s[i * n + j] + s[i * n + j - 1];
            u = u + s[i * n + j + 1];
            float v = s[(i + 1) * n + j] + s[(i - 1) * n + j];
            d[i * n + j] = (u + v) * 0.20f;
        }
}
__attribute__((noinline, unused)) static void rv_jacobi2d(float *A, float *B, uint32_t n, uint32_t tsteps)
{
    for (uint32_t t = 0; t < tsteps; t++) {
        rv_jacobi_sweep(A, B, n);
        rv_jacobi_sweep(B, A, n);
    }
}
/* PolyBench init_array in FP32: A = (i*(j+2) + 2) / n, B = (i*(j+3) + 3) / n */
__attribute__((noinline, unused)) static void rv_jacobi_init(float *A, float *B, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++)
        for (uint32_t j = 0; j < n; j++) {
            A[i * n + j] = ((float)i * (float)(j + 2) + 2.0f) / (float)n;
            B[i * n + j] = ((float)i * (float)(j + 3) + 3.0f) / (float)n;
        }
}

/* pathfinder: dst = the last row of the minimum-path DP over rows x cols (edges: the
   missing neighbour left out); RiVEC repeats it `runs` times with the same result */
__attribute__((noinline, unused)) static void rv_pathfinder(const int32_t *wall, uint32_t rows, uint32_t cols,
                                                     int32_t *dst, int32_t *tmp, uint32_t runs)
{
    for (uint32_t run = 0; run < runs; run++) {
        int32_t *src = tmp, *d = dst;
        for (uint32_t x = 0; x < cols; x++) d[x] = wall[x];
        for (uint32_t t = 0; t + 1 < rows; t++) {
            int32_t *s = d; d = src; src = s;
            for (uint32_t c = 0; c < cols; c++) {
                int32_t m = src[c];
                if (c > 0 && src[c - 1] < m) m = src[c - 1];
                if (c + 1 < cols && src[c + 1] < m) m = src[c + 1];
                d[c] = wall[(t + 1) * cols + c] + m;
            }
        }
        if (d != dst) for (uint32_t x = 0; x < cols; x++) dst[x] = d[x];
    }
}

/* The constant table of kernels/rivec/bs_rv.S (word index: value), the same literals as
   rv_exp, rv_log and rv_cndf, rounded to FP32 by the C compiler. */
#define RV_BS_NC 34
__attribute__((unused)) static void rv_bs_consts(float *c)
{
    const float v[RV_BS_NC] = {
        0.5f, 1.0f,                                                    /*  0  1 */
        88.3762626647949, -88.3762626647949, 1.44269504088896341,      /*  2  3  4: exp hi lo log2e */
        0.693359375, -2.12194440e-4,                                   /*  5  6: exp C1 C2 */
        1.9875691500E-4, 1.3981999507E-3, 8.3334519073E-3,             /*  7  8  9: exp p0 p1 p2 */
        4.1665795894E-2, 1.6666665459E-1, 5.0000001201E-1,             /* 10 11 12: exp p3 p4 p5 */
        0.707106781186547524,                                          /* 13: log sqrt(1/2) */
        7.0376836292E-2, -1.1514610310E-1, 1.1676998740E-1,            /* 14 15 16: log p0 p1 p2 */
        -1.2420140846E-1, 1.4249322787E-1, -1.6668057665E-1,           /* 17 18 19: log p3 p4 p5 */
        2.0000714765E-1, -2.4999993993E-1, 3.3333331174E-1,            /* 20 21 22: log p6 p7 p8 */
        -2.12194440e-4, 0.693359375,                                   /* 23 24: log q1 q2 */
        0.39894228040143270286, 0.2316419f,                            /* 25 26: 1/sqrt(2 pi), k */
        0.319381530f, -0.356563782f, 1.781477937f, -1.821255978f, 1.330274429f,   /* 27-31: a1-a5 */
        -0.5f, 0.0f                                                    /* 32 33 (33: min normal, below) */
    };
    for (int i = 0; i < RV_BS_NC; i++) c[i] = v[i];
    c[33] = rv_bits_f(0x00800000u);
}

/* blackscholes: RiVEC's CNDF_SIMD and BlkSchlsEqEuroNoDiv_vector, one option */
static inline float rv_cndf(float x)
{
    const float inv_sqrt_2xPI = 0.39894228040143270286;
    const int neg = x < 0.0f;                           /* vmflt(x, 0) */
    float xa = x < 0.0f ? -x : x;                       /* vfsgnjx(x, x) */
    float ev = xa * xa;
    ev = ev * -0.5f;
    float np = rv_exp(ev);
    np = np * inv_sqrt_2xPI;
    float k2 = rv_fma(0.2316419f, xa, 1.0f);            /* MADD(0.2316419, xa, 1) */
    k2 = 1.0f / k2;
    float k2_2 = k2 * k2, k2_3 = k2_2 * k2, k2_4 = k2_3 * k2, k2_5 = k2_4 * k2;
    float l1 = k2 * 0.319381530f;
    float l2 = k2_2 * -0.356563782f;
    l2 = rv_fma(k2_3, 1.781477937f, l2);                /* MACC(l2, k2_3, a3) */
    l2 = rv_fma(k2_4, -1.821255978f, l2);
    l2 = rv_fma(k2_5, 1.330274429f, l2);
    l1 = l2 + l1;
    float loc = l1 * np;
    loc = 1.0f - loc;
    return neg ? 1.0f - loc : loc;                      /* RiVEC: a masked subtract */
}
__attribute__((noinline, unused)) static void rv_blackscholes(uint32_t n, const float *S, const float *K,
                                                       const float *r, const float *v, const float *T,
                                                       const int32_t *otype, float *price)
{
    for (uint32_t i = 0; i < n; i++) {
        float lt = rv_log(S[i] / K[i]);
        float sq = rv_sqrtf(T[i]);
        float rt = r[i] * T[i];
        float fv = rv_exp(-rt);                         /* vfsgnjn(rt, rt) */
        float pw = v[i] * v[i];
        pw = pw * 0.5f;
        float d1 = r[i] + pw;
        d1 = rv_fma(d1, T[i], lt);                      /* MADD(d1, T, lt) */
        float den = v[i] * sq;
        d1 = d1 / den;
        float d2 = d1 - den;
        float n1 = rv_cndf(d1), n2 = rv_cndf(d2);
        fv = fv * K[i];
        if (otype[i] != 0) { n1 = 1.0f - n1; n2 = 1.0f - n2; }   /* vmerge on otype == 0 */
        float o1 = S[i] * n1, o2 = fv * n2;
        float p = o2 - o1;
        price[i] = p < 0.0f ? -p : p;                   /* vfsgnjx(p, p) */
    }
}

/* lavaMD: boxes of RV_LAVA_NP particles; rv holds (v, x, y, z) per particle, qv the
   charges, fv the forces (accumulated). Neighbour lists as RiVEC's main.c builds them:
   nei[b * 26 + k], nn[b]. */
#define RV_LAVA_NP 96
__attribute__((noinline, unused)) static uint32_t rv_lava_boxes(uint32_t b1d, uint32_t *nn, uint32_t *nei)
{
    uint32_t nh = 0;
    for (int i = 0; i < (int)b1d; i++)
        for (int j = 0; j < (int)b1d; j++)
            for (int k = 0; k < (int)b1d; k++, nh++) {
                uint32_t c = 0;
                for (int l = -1; l < 2; l++)
                    for (int m = -1; m < 2; m++)
                        for (int q = -1; q < 2; q++) {
                            if (i + l < 0 || j + m < 0 || k + q < 0) continue;
                            if (i + l >= (int)b1d || j + m >= (int)b1d || k + q >= (int)b1d) continue;
                            if (l == 0 && m == 0 && q == 0) continue;
                            nei[nh * 26 + c++] = (uint32_t)((i + l) * (int)(b1d * b1d) + (j + m) * (int)b1d + (k + q));
                        }
                nn[nh] = c;
            }
    return nh;
}
__attribute__((noinline, unused)) static void rv_lavamd(uint32_t nbox, const uint32_t *nn, const uint32_t *nei,
                                                 const float *rv, const float *qv, float *fv, float a2)
{
    for (uint32_t l = 0; l < nbox; l++) {
        const float *rA = rv + 4 * l * RV_LAVA_NP;
        float *fA = fv + 4 * l * RV_LAVA_NP;
        for (uint32_t k = 0; k < 1 + nn[l]; k++) {
            const uint32_t pb = k ? nei[l * 26 + k - 1] : l;
            const float *rB = rv + 4 * pb * RV_LAVA_NP, *qB = qv + pb * RV_LAVA_NP;
            for (uint32_t i = 0; i < RV_LAVA_NP; i++) {
                const float Av = rA[4 * i], Ax = rA[4 * i + 1], Ay = rA[4 * i + 2], Az = rA[4 * i + 3];
                float fvv = fA[4 * i], fx = fA[4 * i + 1], fy = fA[4 * i + 2], fz = fA[4 * i + 3];
                for (uint32_t j = 0; j < RV_LAVA_NP; j++) {
                    const float Bv = rB[4 * j], Bx = rB[4 * j + 1], By = rB[4 * j + 2], Bz = rB[4 * j + 3];
                    float r2 = Bv + Av;
                    float dot = Bx * Ax;
                    dot = rv_fma(Ay, By, dot);          /* MACC_VF(dot, A.y, B.y) */
                    dot = rv_fma(Az, Bz, dot);
                    r2 = r2 - dot;
                    float u2 = r2 * a2;
                    float vij = rv_exp(-u2);
                    float fs = 2.0f * vij;
                    float dx = Ax - Bx, dy = Ay - By, dz = Az - Bz;
                    float fxij = fs * dx, fyij = fs * dy, fzij = fs * dz;
                    const float q = qB[j];
                    fvv = rv_fma(q, vij, fvv);
                    fx = rv_fma(q, fxij, fx);
                    fy = rv_fma(q, fyij, fy);
                    fz = rv_fma(q, fzij, fz);
                }
                fA[4 * i] = fvv; fA[4 * i + 1] = fx; fA[4 * i + 2] = fy; fA[4 * i + 3] = fz;
            }
        }
    }
}

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC pop_options
#endif
#endif
