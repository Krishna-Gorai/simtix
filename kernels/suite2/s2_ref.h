/*
 * s2_ref.h - suite 2 (docs/suite2_plan.md) as plain C: the CVA6 kernels
 * (baselines/ara/kernels/ak_scalar.c), the A53 references of the board hosts, and the
 * reference of the Ara self-test. Every FP32 operation is the one of the kernels'
 * definitions, in the same order (compile with -ffp-contract=off; fmaf is fused).
 * Data layouts are those of sim/gen_suite2.py and kernels/suite2/<name>.S.
 */
#ifndef S2_REF_H
#define S2_REF_H
#include <stdint.h>

#define S2_LANES 8u                     /* padding of the stencil grids (stencil.S) */
#define S2_INF   0x7FFFFFFF

static inline float s2_f(uint32_t u) { union { uint32_t u; float f; } v = { .u = u }; return v.f; }
static inline uint32_t s2_u(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }

/* Rodinia pathfinder: rows padded with INT_MAX on both sides (element c at c + 1);
   buf0 holds row 0. The result is in buf[(rows - 1) & 1]. */
static inline void s2_pathfinder(const int32_t *wall, int32_t *buf0, int32_t *buf1,
                                 uint32_t rows, uint32_t cols)
{
    int32_t *b[2] = { buf0, buf1 };
    for (uint32_t r = 1; r < rows; r++) {
        const int32_t *src = b[(r - 1) & 1], *w = wall + r * cols;
        int32_t *dst = b[r & 1];
        for (uint32_t c = 0; c < cols; c++) {
            int32_t m = src[c];
            if (src[c + 1] < m) m = src[c + 1];
            if (src[c + 2] < m) m = src[c + 2];
            dst[c + 1] = w[c] + m;
        }
    }
}

/* Rodinia hotspot, steps in ping-pong; k[] = rx1 ry1 rz1 amb sdc. Result t[steps % 2]. */
static inline void s2_hotspot(float *t0, float *t1, const float *pw, uint32_t n, uint32_t s,
                              const float *k, uint32_t steps)
{
    float *t[2] = { t0, t1 };
    for (uint32_t st = 0; st < steps; st++) {
        const float *in = t[st & 1];
        float *out = t[(st + 1) & 1];
        for (uint32_t i = 0; i < n; i++)
            for (uint32_t j = 0; j < n; j++) {
                uint32_t q = (i + 1) * s + S2_LANES + j;
                float tt = in[q], t2 = tt + tt;
                float a = (in[q - s] + in[q + s]) - t2;
                float b = (in[q + 1] + in[q - 1]) - t2;
                float c = k[3] - tt;
                float acc = __builtin_fmaf(a, k[1], pw[q]);
                acc = __builtin_fmaf(b, k[0], acc);
                acc = __builtin_fmaf(c, k[2], acc);
                out[q] = __builtin_fmaf(k[4], acc, tt);
            }
    }
}

/* PolyBench jacobi-2d: 2*tsteps sweeps A -> B -> A; the result is in a. */
static inline void s2_jacobi2d(float *a, float *b, uint32_t n, uint32_t s, float c02, uint32_t tsteps)
{
    float *g[2] = { a, b };
    for (uint32_t k = 0; k < 2 * tsteps; k++) {
        const float *in = g[k & 1];
        float *out = g[(k + 1) & 1];
        for (uint32_t i = 0; i < n; i++)
            for (uint32_t j = 0; j < n; j++) {
                uint32_t q = (i + 1) * s + S2_LANES + j;
                out[q] = c02 * ((((in[q] + in[q - 1]) + in[q + 1]) + in[q + s]) + in[q - s]);
            }
    }
}

/* y[i] = fma chain over j of A[i][j] * x[j] (mv_row.S) */
static inline void s2_mv_row(const float *A, const float *x, float *y, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        float acc = 0.0f;
        for (uint32_t j = 0; j < n; j++) acc = __builtin_fmaf(A[i * n + j], x[j], acc);
        y[i] = acc;
    }
}

/* y[j] = fma chain over i of A[i][j] * x[i] (mv_col.S), in the i-j order a CPU likes */
static inline void s2_mv_col(const float *A, const float *x, float *y, uint32_t n)
{
    for (uint32_t j = 0; j < n; j++) y[j] = 0.0f;
    for (uint32_t i = 0; i < n; i++) {
        float xi = x[i];
        const float *row = A + i * n;
        for (uint32_t j = 0; j < n; j++) y[j] = __builtin_fmaf(row[j], xi, y[j]);
    }
}

/* GAP PageRank, pull, fixed iterations; pr0 holds the start; the result is in pr[iters % 2]. */
static inline void s2_pagerank(const uint32_t *rowptr, const uint32_t *col, const float *invdeg,
                               float *c, float *pr0, float *pr1, uint32_t nv, float d, float base,
                               uint32_t iters)
{
    float *pr[2] = { pr0, pr1 };
    for (uint32_t k = 0; k < iters; k++) {
        const float *src = pr[k & 1];
        float *dst = pr[(k + 1) & 1];
        for (uint32_t u = 0; u < nv; u++) c[u] = src[u] * invdeg[u];
        for (uint32_t v = 0; v < nv; v++) {
            float acc = 0.0f;
            for (uint32_t e = rowptr[v]; e < rowptr[v + 1]; e++) acc = acc + c[col[e]];
            dst[v] = __builtin_fmaf(d, acc, base);
        }
    }
}

/* GAP connected components by label propagation between two arrays (lab0 holds the
   start); returns the number of rounds, the last of which changed nothing; the result
   is in lab[rounds % 2]. */
static inline uint32_t s2_cc(const uint32_t *rowptr, const uint32_t *col, uint32_t *lab0,
                             uint32_t *lab1, uint32_t nv)
{
    uint32_t *lab[2] = { lab0, lab1 }, k = 0;
    for (;;) {
        const uint32_t *in = lab[k & 1];
        uint32_t *out = lab[(k + 1) & 1];
        int changed = 0;
        for (uint32_t v = 0; v < nv; v++) {
            uint32_t m = in[v];
            for (uint32_t e = rowptr[v]; e < rowptr[v + 1]; e++)
                if (in[col[e]] < m) m = in[col[e]];
            out[v] = m;
            changed |= (m != in[v]);
        }
        k++;
        if (!changed) return k;
    }
}

/* Rodinia backprop: forward partial sums ps[t] (t = 16b + j) and the weight update */
static inline void s2_bp_forward(const float *in, const float *w, float *ps, uint32_t n)
{
    for (uint32_t t = 0; t < n; t++) {
        uint32_t j = t & 15, b = t >> 4;
        float acc = 0.0f;
        for (uint32_t i = 16 * b; i < 16 * b + 16; i++) acc = __builtin_fmaf(w[i * 16 + j], in[i], acc);
        ps[t] = acc;
    }
}
static inline void s2_bp_adjust(const float *in, float *w, float *ow, const float *ed, uint32_t n, float m)
{
    for (uint32_t t = 0; t < n * 16; t++) {
        float dw = __builtin_fmaf(ed[t & 15], in[t >> 4], m * ow[t]);
        w[t] = w[t] + dw;
        ow[t] = dw;
    }
}

/* SHOC sort: stable LSD radix sort, 4 bits per pass, 8 passes, ping-pong; the sorted
   pairs end in k0, v0. */
static inline void s2_sort(uint32_t *k0, uint32_t *v0, uint32_t *k1, uint32_t *v1, uint32_t n)
{
    uint32_t *k[2] = { k0, k1 }, *v[2] = { v0, v1 };
    for (uint32_t p = 0; p < 8; p++) {
        const uint32_t *ks = k[p & 1], *vs = v[p & 1];
        uint32_t *kd = k[(p + 1) & 1], *vd = v[(p + 1) & 1];
        uint32_t cnt[16] = { 0 }, sh = 4 * p;
        for (uint32_t i = 0; i < n; i++) cnt[(ks[i] >> sh) & 15]++;
        for (uint32_t d = 0, s = 0; d < 16; d++) { uint32_t c = cnt[d]; cnt[d] = s; s += c; }
        for (uint32_t i = 0; i < n; i++) {
            uint32_t pos = cnt[(ks[i] >> sh) & 15]++;
            kd[pos] = ks[i];
            vd[pos] = vs[i];
        }
    }
}

/* Rodinia hotspot.c's constants for an n x n grid of its 16 mm chip, in double as
   gen_suite2.hotspot_consts (the same expressions in the same order), then rounded:
   k = rx1 ry1 rz1 amb sdc. */
static inline void s2_hotspot_consts(uint32_t n, float *k)
{
    const double t_chip = 0.0005, h = 0.016, w = 0.016, amb = 80.0;
    const double MAX_PD = 3.0e6, PRECISION = 0.001, SPEC_HEAT_SI = 1.75e6, K_SI = 100.0, FACTOR_CHIP = 0.5;
    double gh = h / n, gw = w / n;
    double cap = FACTOR_CHIP * SPEC_HEAT_SI * t_chip * gw * gh;
    double rx = gw / (2.0 * K_SI * t_chip * gh);
    double ry = gh / (2.0 * K_SI * t_chip * gw);
    double rz = t_chip / (K_SI * gh * gw);
    double max_slope = MAX_PD / (FACTOR_CHIP * t_chip * SPEC_HEAT_SI);
    double step = PRECISION / max_slope;
    k[0] = (float)(1.0 / rx); k[1] = (float)(1.0 / ry); k[2] = (float)(1.0 / rz);
    k[3] = (float)amb; k[4] = (float)(step / cap);
}

/* Black-Scholes constant table (the bits of sim/gen_suite2.py BS_C) */
static const uint32_t S2_BS_C[26] = {
    0x3f000000u, 0x3f800000u, 0x40000000u, 0x3fb8aa3bu, 0x3f317200u, 0x35bfbe8eu,
    0x3f800000u, 0x3f800000u, 0x3f000000u, 0x3e2aaaabu, 0x3d2aaaabu, 0x3c088889u,
    0x3ab60b61u, 0x3f317218u, 0x3f2aaaabu, 0x3ecccccdu, 0x3e924925u, 0x3e638e39u,
    0x3fb504f3u, 0x3ecc422au, 0x3e6d3389u, 0x3ea385fau, 0xbeb68f87u, 0x3fe40778u,
    0xbfe91eeau, 0x3faa466fu,
};

/* RiVEC / PARSEC Black-Scholes with the exp and log of blackscholes.S; C[] is the
   constant table (S2_BS_C). Its separate multiplies and adds must stay separate: a build
   without -ffp-contract=off (the A53 hosts) would otherwise fuse some into FMAs, which
   changes about 26% of the outputs (seen on the ZCU102 2026-11-09). The pragma applies only
   while s2_blackscholes stays a function of its own, hence its noinline. */
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC push_options
#pragma GCC optimize("fp-contract=off")
#endif
static inline float s2_bs_exp(float x, const float *C)
{
    int32_t k;
    float t = x * C[3];
#if defined(__riscv)
    __asm__ ("fcvt.w.s %0, %1, rne" : "=r"(k) : "f"(t));
#elif defined(__aarch64__)
    __asm__ ("fcvtns %w0, %s1" : "=r"(k) : "w"(t));
#else
    k = (int32_t)__builtin_rintf(t);
#endif
    float kf = -(float)k;
    float f = __builtin_fmaf(kf, C[4], x);
    f = __builtin_fmaf(kf, C[5], f);
    float p = __builtin_fmaf(f, C[12], C[11]);
    p = __builtin_fmaf(f, p, C[10]);
    p = __builtin_fmaf(f, p, C[9]);
    p = __builtin_fmaf(f, p, C[8]);
    p = __builtin_fmaf(f, p, C[7]);
    p = __builtin_fmaf(f, p, C[6]);
    return s2_f(s2_u(p) + ((uint32_t)k << 23));
}
static inline float s2_bs_log(float x, const float *C)
{
    uint32_t b = s2_u(x);
    int32_t e = (int32_t)((b >> 23) & 0xFF) - 127;
    float m = s2_f((b & 0x7FFFFFu) | 0x3F800000u);
    if (s2_u(m) > s2_u(C[18])) { m = m * C[0]; e++; }       /* m > sqrt2 (both positive) */
    float f = m - C[1];
    float s = f / (f + C[2]);
    float z = s * s;
    float R = __builtin_fmaf(z, C[17], C[16]);
    R = __builtin_fmaf(z, R, C[15]);
    R = __builtin_fmaf(z, R, C[14]);
    R = R * z;
    float l = __builtin_fmaf(s, R, s + s);
    return __builtin_fmaf((float)e, C[13], l);
}
static inline float s2_bs_cndf(float x, const float *C)
{
    uint32_t sign = s2_u(x) >> 31;
    float xa = s2_f(s2_u(x) & 0x7FFFFFFFu);
    float n = s2_bs_exp(-((xa * xa) * C[0]), C) * C[19];
    float k2 = C[1] / (C[1] + C[20] * xa);
    float k22 = k2 * k2, k23 = k22 * k2, k24 = k23 * k2, k25 = k24 * k2;
    float l1 = k2 * C[21];
    float l2 = k22 * C[22];
    l2 = l2 + k23 * C[23];
    l2 = l2 + k24 * C[24];
    l2 = l2 + k25 * C[25];
    l1 = l1 + l2;
    float loc = C[1] - l1 * n;
    return sign ? C[1] - loc : loc;
}
/* Hardware square root, correctly rounded (IEEE 754) on every target. The A53 host build has
 * no -fno-math-errno and no libm, so __builtin_sqrtf there would keep a call to sqrtf. */
static inline float s2_sqrtf(float x)
{
#if defined(__aarch64__)
    float r;
    __asm__("fsqrt %s0, %s1" : "=w"(r) : "w"(x));
    return r;
#else
    return __builtin_sqrtf(x);
#endif
}
/* noinline: inlined into a caller built without the pragma, GCC fuses again (2026-11-09). */
__attribute__((noinline)) static void s2_blackscholes(const float *S, const float *K, const float *r, const float *v,
                                   const float *T, float *call, float *put, const float *C, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        float sq = s2_sqrtf(T[i]);
        float lt = s2_bs_log(S[i] / K[i], C);
        float pw = (v[i] * v[i]) * C[0];
        float d1 = (r[i] + pw) * T[i] + lt;
        float den = v[i] * sq;
        d1 = d1 / den;
        float d2 = d1 - den;
        float n1 = s2_bs_cndf(d1, C), n2 = s2_bs_cndf(d2, C);
        float fv = K[i] * s2_bs_exp(-(r[i] * T[i]), C);
        call[i] = S[i] * n1 - fv * n2;
        put[i] = fv * (C[1] - n2) - S[i] * (C[1] - n1);
    }
}
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC pop_options
#endif

#endif
