/*
 * rd_ref.h - plain-C reference versions of the Rodinia kernels (docs/rodinia_plan.md),
 * shared by the A53 hosts (sw/ps_host/rodinia.inc) and the CVA6 kernels
 * (baselines/ara/kernels/ak_scalar.c). Each function performs the FP32 operations of
 * the matching kernels/rodinia/<name>.S in the same order; sim/gen_rodinia.py computes the
 * same values exactly.
 *
 * The A53 hosts are built without -ffp-contract=off, so the FP code is compiled with
 * contraction off (GCC; clang honours the command line) and kept out of line, so that
 * no caller compiled with contraction on inlines it.
 */
#ifndef RD_REF_H
#define RD_REF_H
#include <stdint.h>

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC push_options
#pragma GCC optimize("fp-contract=off")
#endif

/* Rodinia hotspot.cu's constants for an n x n grid of its 16 mm chip, with Rodinia's
   own mix of float and double arithmetic (its #defines are double literals, K_SI an
   int, the chip sizes float variables): k = rx1 ry1 rz1 amb sdc. */
__attribute__((noinline, unused)) static void rd_hotspot_consts(uint32_t n, float *k)
{
    const float t_chip = 0.0005f, chip_height = 0.016f, chip_width = 0.016f;
    float grid_height = chip_height / (float)n;
    float grid_width = chip_width / (float)n;
    float cap = (float)(0.5 * 1.75e6 * (double)t_chip * (double)grid_width * (double)grid_height);
    float rx = (float)((double)grid_width / (2.0 * 100 * (double)t_chip * (double)grid_height));
    float ry = (float)((double)grid_height / (2.0 * 100 * (double)t_chip * (double)grid_width));
    float rz = t_chip / ((float)100 * grid_height * grid_width);
    float max_slope = (float)(3.0e6 / (0.5 * (double)t_chip * 1.75e6));
    float step = (float)(0.001 / (double)max_slope);
    k[0] = 1.0f / rx;
    k[1] = 1.0f / ry;
    k[2] = 1.0f / rz;
    k[3] = 80.0f;
    k[4] = step / cap;
}

/* Rodinia hotspot: `steps` time steps in ping-pong on an n x n row-major grid, every
   cell, clamped neighbours (hotspot_rd.S). The result is in t[steps % 2]. */
__attribute__((noinline, unused)) static void rd_hotspot(float *t0, float *t1, const float *pw, uint32_t n,
                                                 const float *k, uint32_t steps)
{
    float *t[2] = { t0, t1 };
    for (uint32_t st = 0; st < steps; st++) {
        const float *in = t[st & 1];
        float *out = t[(st + 1) & 1];
        for (uint32_t i = 0; i < n; i++) {
            const uint32_t iN = i ? i - 1 : 0, iS = i + 1 < n ? i + 1 : n - 1;
            for (uint32_t j = 0; j < n; j++) {
                const uint32_t jW = j ? j - 1 : 0, jE = j + 1 < n ? j + 1 : n - 1;
                const uint32_t q = i * n + j;
                float tt = in[q], t2 = tt + tt;
                float a = (in[iN * n + j] + in[iS * n + j]) - t2;
                float b = (in[i * n + jE] + in[i * n + jW]) - t2;
                float c = k[3] - tt;
                float acc = __builtin_fmaf(a, k[1], pw[q]);
                acc = __builtin_fmaf(b, k[0], acc);
                acc = __builtin_fmaf(c, k[2], acc);
                out[q] = __builtin_fmaf(k[4], acc, tt);
            }
        }
    }
}

/* Rodinia nn: dist[r] = sqrt(dx*dx + dy*dy), dx = lat - loc[r].lat, dy = lng - loc[r].lng,
   every operation rounded once (nn.S); loc holds (lat, lng) pairs. sqrt is the
   hardware instruction (no libm call). */
static inline float rd_sqrtf(float x)
{
#if defined(__aarch64__)
    float r; __asm__("fsqrt %s0, %s1" : "=w"(r) : "w"(x)); return r;
#else
    return __builtin_sqrtf(x);
#endif
}
__attribute__((noinline, unused)) static void rd_nn(const float *loc, float *dist, uint32_t n, float lat, float lng)
{
    for (uint32_t r = 0; r < n; r++) {
        float dx = lat - loc[2 * r], dy = lng - loc[2 * r + 1];
        float s = dx * dx;
        s = s + dy * dy;
        dist[r] = rd_sqrtf(s);
    }
}

/* Rodinia hotspot3D (3D.cu main and hotspot_opt1): constants for an n x n x nz grid,
   with Rodinia's float and double steps. k = cc ce cn ct sdc amb (cw = ce, cs = cn,
   cb = ct). */
__attribute__((noinline, unused)) static void rd_hotspot3d_consts(uint32_t n, uint32_t nz, float *k)
{
    const float t_chip = 0.0005f, chip_height = 0.016f, chip_width = 0.016f;
    float dx = chip_height / (float)n, dy = chip_width / (float)n, dz = t_chip / (float)nz;
    float cap = (float)(0.5 * 1.75e6 * (double)t_chip * (double)dx * (double)dy);
    float rx = (float)((double)dy / (2.0 * 100 * (double)t_chip * (double)dx));
    float ry = (float)((double)dx / (2.0 * 100 * (double)t_chip * (double)dy));
    float rz = dz / ((float)100 * dx * dy);
    float max_slope = (float)(3.0e6 / (0.5 * (double)t_chip * 1.75e6));
    float dt = (float)(0.001 / (double)max_slope);
    float sdc = dt / cap;
    float ce = sdc / rx, cn = sdc / ry, ct = sdc / rz;
    k[0] = (float)(1.0 - (2.0 * (double)ce + 2.0 * (double)cn + 3.0 * (double)ct));
    k[1] = ce; k[2] = cn; k[3] = ct; k[4] = sdc; k[5] = 80.0f;
}

/* Rodinia hotspot3D: `iters` steps in ping-pong (hotspot3d.S); result in t[iters % 2]. */
__attribute__((noinline, unused)) static void rd_hotspot3d(float *t0, float *t1, const float *pw, uint32_t n,
                                                    uint32_t nz, const float *k, uint32_t iters)
{
    float *t[2] = { t0, t1 };
    const uint32_t xy = n * n;
    for (uint32_t it = 0; it < iters; it++) {
        const float *in = t[it & 1];
        float *out = t[(it + 1) & 1];
        for (uint32_t z = 0; z < nz; z++) {
            const uint32_t zb = z ? z - 1 : 0, zt = z + 1 < nz ? z + 1 : nz - 1;
            for (uint32_t j = 0; j < n; j++)
                for (uint32_t i = 0; i < n; i++) {
                    const uint32_t c = i + j * n + z * xy;
                    const uint32_t W = i ? c - 1 : c, E = i + 1 < n ? c + 1 : c;
                    const uint32_t N = j ? c - n : c, S = j + 1 < n ? c + n : c;
                    float s = k[0] * in[c];
                    s = __builtin_fmaf(k[1], in[W], s);
                    s = __builtin_fmaf(k[1], in[E], s);
                    s = __builtin_fmaf(k[2], in[S], s);
                    s = __builtin_fmaf(k[2], in[N], s);
                    s = __builtin_fmaf(k[3], in[i + j * n + zb * xy], s);
                    s = __builtin_fmaf(k[3], in[i + j * n + zt * xy], s);
                    s = __builtin_fmaf(k[4], pw[c], s);
                    s = __builtin_fmaf(k[3], k[5], s);
                    out[c] = s;
                }
        }
    }
}

/* Rodinia gaussian: forward elimination without pivoting (Fan1 then Fan2 per step t),
   on the augmented n x (n+1) matrix a (b in column n); m is n x n. As gauss_fan1.S and
   gauss_fan2.S: m[i][t] = a[i][t] / a[t][t]; a[i][j] = fma(-m[i][t], a[t][j], a[i][j])
   for j = t .. n. */
__attribute__((noinline, unused)) static void rd_gaussian(float *a, float *m, uint32_t n)
{
    const uint32_t s = n + 1;
    for (uint32_t t = 0; t + 1 < n; t++) {
        const float piv = a[t * s + t];
        for (uint32_t i = t + 1; i < n; i++) m[i * n + t] = a[i * s + t] / piv;
        for (uint32_t i = t + 1; i < n; i++) {
            const float mi = -m[i * n + t];
            for (uint32_t j = t; j <= n; j++) a[i * s + j] = __builtin_fmaf(mi, a[t * s + j], a[i * s + j]);
        }
    }
}

/* Rodinia kmeans, kmeansPoint (kmeans_rd.S) on point-major features f[p*nf + j]: the
   nearest of k centres, ans = fma(d, d, ans) over the features in order, the first
   strictly smaller distance wins. */
__attribute__((noinline, unused)) static void rd_kmeans_assign(const float *f, const float *c, int32_t *mem,
                                                       uint32_t n, uint32_t k, uint32_t nf)
{
    for (uint32_t p = 0; p < n; p++) {
        union { uint32_t u; float f; } fmax = { .u = 0x7F7FFFFFu };
        float best = fmax.f;
        int32_t idx = 0;
        for (uint32_t i = 0; i < k; i++) {
            float ans = 0.0f;
            for (uint32_t j = 0; j < nf; j++) {
                float d = f[p * nf + j] - c[i * nf + j];
                ans = __builtin_fmaf(d, d, ans);
            }
            if (ans < best) { best = ans; idx = (int32_t)i; }
        }
        mem[p] = idx;
    }
}

/* Rodinia kmeans' CPU part after each kernel run (kmeans_cuda.cu, kmeans_clustering.c):
   count the points whose cluster changed, sum the points of each cluster in point
   order, and divide by the counts. Returns the number of changes (Rodinia's delta). */
__attribute__((noinline, unused)) static uint32_t rd_kmeans_update(const float *f, const int32_t *mem_new,
        int32_t *mem, float *c, float *nc, int32_t *len, uint32_t n, uint32_t k, uint32_t nf)
{
    uint32_t delta = 0;
    for (uint32_t i = 0; i < k * nf; i++) nc[i] = 0.0f;
    for (uint32_t i = 0; i < k; i++) len[i] = 0;
    for (uint32_t p = 0; p < n; p++) {
        const int32_t id = mem_new[p];
        len[id]++;
        if (mem_new[p] != mem[p]) { delta++; mem[p] = mem_new[p]; }
        for (uint32_t j = 0; j < nf; j++) nc[id * nf + j] += f[p * nf + j];
    }
    for (uint32_t i = 0; i < k; i++)
        for (uint32_t j = 0; j < nf; j++)
            if (len[i] > 0) c[i * nf + j] = nc[i * nf + j] / (float)len[i];
    return delta;
}

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC pop_options
#endif
#endif
