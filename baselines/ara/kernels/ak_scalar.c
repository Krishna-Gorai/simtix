/*
 * ak_scalar.c - scalar kernels for CVA6: the A53 reference loops of sw/ps_host/apps.c,
 * unchanged, compiled for RV64GC (no vector extension, so GCC cannot vectorize them)
 * with -O3 -ffp-contract=off: the only fused multiply-adds are the explicit fmaf.
 * MLP and CONV use the A53's CPU layouts (weights wT[n][k], NHWC activations).
 */
#include "ak.h"

#define UNSEEN 0xFFFFFFFFu

static void s_gemm(const uint32_t *a)
{
    const float *A = AKP(const float, a[0]), *B = AKP(const float, a[1]);
    float *C = AKP(float, a[2]);
    const uint32_t n = a[3];
    for (uint32_t i = 0; i < n; i++) {
        float *cr = C + i * n;
        for (uint32_t j = 0; j < n; j++) cr[j] = 0.0f;
        for (uint32_t k = 0; k < n; k++) {
            float av = A[i * n + k];
            const float *br = B + k * n;
            for (uint32_t j = 0; j < n; j++) cr[j] = __builtin_fmaf(av, br[j], cr[j]);
        }
    }
}

static void s_spmv(const uint32_t *a)
{
    const uint32_t *rowptr = AKP(const uint32_t, a[0]), *col = AKP(const uint32_t, a[1]);
    const float *val = AKP(const float, a[2]), *x = AKP(const float, a[3]);
    float *y = AKP(float, a[4]);
    const uint32_t rows = a[5];
    for (uint32_t r = 0; r < rows; r++) {
        float acc = 0.0f;
        for (uint32_t j = rowptr[r]; j < rowptr[r + 1]; j++) acc = __builtin_fmaf(val[j], x[col[j]], acc);
        y[r] = acc;
    }
}

static void s_stencil(const uint32_t *a)
{
    float *g[2] = { AKP(float, a[0]), AKP(float, a[1]) };
    const uint32_t n = a[2], s = a[3], sweeps = a[6];
    const float c0 = ak_f(a[4]), c1 = ak_f(a[5]);
    for (uint32_t t = 0; t < sweeps; t++) {
        const float *in = g[t % 2];
        float *out = g[(t + 1) % 2];
        for (uint32_t i = 0; i < n; i++)
            for (uint32_t j = 0; j < n; j++) {
                uint32_t q = (i + 1) * s + 8 + j;
                float sm = (in[q - s] + in[q + s]) + (in[q - 1] + in[q + 1]);
                out[q] = __builtin_fmaf(c1, sm, c0 * in[q]);
            }
    }
}

static void s_kmeans(const uint32_t *a)
{
    const uint32_t *px = AKP(const uint32_t, a[0]), *py = AKP(const uint32_t, a[1]);
    const uint32_t *cx = AKP(const uint32_t, a[2]), *cy = AKP(const uint32_t, a[3]);
    const uint32_t k = a[4], npts = a[9];
    uint32_t *as = AKP(uint32_t, a[5]), *sx = AKP(uint32_t, a[6]);
    uint32_t *sy = AKP(uint32_t, a[7]), *cn = AKP(uint32_t, a[8]);
    for (uint32_t j = 0; j < k; j++) sx[j] = sy[j] = cn[j] = 0;
    for (uint32_t i = 0; i < npts; i++) {
        int32_t x = (int32_t)px[i], y = (int32_t)py[i];
        uint32_t best = 0x7FFFFFFFu, bk = 0;
        for (uint32_t j = 0; j < k; j++) {
            int32_t dx = x - (int32_t)cx[j], dy = y - (int32_t)cy[j];
            uint32_t d = (uint32_t)(dx * dx + dy * dy);
            if (d < best) { best = d; bk = j; }
        }
        as[i] = bk; sx[bk] += (uint32_t)x; sy[bk] += (uint32_t)y; cn[bk]++;
    }
}

static void s_bfs(const uint32_t *a)
{
    const uint32_t *rowptr = AKP(const uint32_t, a[0]), *col = AKP(const uint32_t, a[1]);
    uint32_t *lev = AKP(uint32_t, a[2]), *queue = AKP(uint32_t, a[4]);
    const uint32_t nv = a[3];
    for (uint32_t v = 0; v < nv; v++) lev[v] = UNSEEN;
    uint32_t head = 0, tail = 0;
    lev[0] = 0; queue[tail++] = 0;
    while (head < tail) {
        uint32_t v = queue[head++];
        for (uint32_t j = rowptr[v]; j < rowptr[v + 1]; j++) {
            uint32_t u = col[j];
            if (lev[u] == UNSEEN) { lev[u] = lev[v] + 1; queue[tail++] = u; }
        }
    }
}

static void s_scan(const uint32_t *a)
{
    const uint32_t *in = AKP(const uint32_t, a[0]);
    uint32_t *out = AKP(uint32_t, a[1]);
    const uint32_t n = a[2];
    uint32_t acc = 0;
    for (uint32_t i = 0; i < n; i++) { acc += in[i]; out[i] = acc; }
}

static uint8_t rne_u8(float v)          /* 0 <= v <= 127 */
{
    int32_t i = (int32_t)v;
    float   f = v - (float)i;           /* exact */
    if (f > 0.5f || (f == 0.5f && (i & 1))) i++;
    return (uint8_t)i;
}

/* MLP with the A53T layout (one contiguous row of k weights per output) */
static void s_mlp(const uint32_t *a)
{
    const uint8_t *x0 = AKP(const uint8_t, a[0]);
    const uint32_t batch = a[1], nl = a[2];
    const uint32_t *dims = AKP(const uint32_t, a[3]);
    const int8_t *w[3] = { AKP(const int8_t, a[4]), AKP(const int8_t, a[5]), AKP(const int8_t, a[6]) };
    uint8_t *act = AKP(uint8_t, a[7]), *nxt = AKP(uint8_t, a[8]);
    int32_t *logit = AKP(int32_t, a[9]);
    const float scale = ak_f(a[10]), zp = ak_f(a[11]);
    const uint8_t *src = x0;
    for (uint32_t l = 0; l < nl; l++) {
        const uint32_t k = dims[l], npad = dims[4 + l];
        const int last = (l == nl - 1);
        for (uint32_t b = 0; b < batch; b++) {
            const int8_t *xb = (const int8_t *)src + b * k;
            for (uint32_t n = 0; n < npad; n++) {
                const int8_t *wr_ = w[l] + n * k;
                int32_t acc = 0;
                for (uint32_t kk = 0; kk < k; kk++) acc += (int32_t)xb[kk] * wr_[kk];
                if (last) {
                    logit[b * npad + n] = acc;
                } else {
                    float v = __builtin_fmaf((float)acc, scale, zp);
                    v = v > 127.0f ? 127.0f : (v < 0.0f ? 0.0f : v);
                    nxt[b * npad + n] = rne_u8(v);
                }
            }
        }
        if (!last) {
            for (uint32_t i = 0; i < batch * npad; i++) act[i] = nxt[i];
            src = act;
        }
    }
}

/* CONV: NHWC activations, OHWI weights (the A53 loop) */
static void s_conv(const uint32_t *a)
{
    int8_t *x[3] = { AKP(int8_t, a[0]), AKP(int8_t, a[1]), AKP(int8_t, a[2]) };
    const int8_t *wt[2] = { AKP(const int8_t, a[3]), AKP(const int8_t, a[4]) };
    const uint32_t n = a[5], ch[3] = { a[6], a[7], a[8] }, wp = n + 2;
    const float scale = ak_f(a[9]), zp = ak_f(a[10]);
    for (unsigned l = 0; l < 2; l++) {
        const uint32_t ci = ch[l], co = ch[l + 1];
        const int8_t *in = x[l];
        int8_t *out = x[l + 1];
        for (uint32_t y = 0; y < n; y++)
            for (uint32_t xx = 0; xx < n; xx++)
                for (uint32_t o = 0; o < co; o++) {
                    int32_t acc = 0;
                    for (uint32_t ky = 0; ky < 3; ky++)
                        for (uint32_t kx = 0; kx < 3; kx++) {
                            const int8_t *p = in + ((y + ky) * wp + xx + kx) * ci;
                            const int8_t *q = wt[l] + ((o * 3u + ky) * 3u + kx) * ci;
                            for (uint32_t c = 0; c < ci; c++) acc += (int32_t)p[c] * q[c];
                        }
                    float v = __builtin_fmaf((float)acc, scale, zp);
                    v = v > 127.0f ? 127.0f : (v < 0.0f ? 0.0f : v);
                    out[((y + 1) * wp + xx + 1) * co + o] = (int8_t)rne_u8(v);
                }
    }
}

static void s_embag(const uint32_t *a)
{
    const float *t = AKP(const float, a[0]);
    const uint32_t *idx = AKP(const uint32_t, a[1]);
    float *out = AKP(float, a[2]);
    const uint32_t bags = a[3], k = a[4], D = AK_EMBAG_D;
    for (uint32_t b = 0; b < bags; b++) {
        float *o = out + b * D;
        for (uint32_t d = 0; d < D; d++) o[d] = 0.0f;
        for (uint32_t j = 0; j < k; j++) {
            const float *row = t + idx[b * k + j] * D;
            for (uint32_t d = 0; d < D; d++) o[d] += row[d];
        }
    }
}

static void s_hashj(const uint32_t *a)
{
    const uint32_t *slot = AKP(const uint32_t, a[0]), *key = AKP(const uint32_t, a[1]);
    uint32_t *out = AKP(uint32_t, a[2]);
    const uint32_t nprobe = a[3], s = a[4], mask = (1u << s) - 1u;
    for (uint32_t i = 0; i < nprobe; i++) {
        uint32_t kk = key[i], h = (kk * 0x9E3779B1u) >> (32u - s);
        while (slot[2u * h] != kk && slot[2u * h] != 0) h = (h + 1u) & mask;
        out[i] = (slot[2u * h] == kk) ? slot[2u * h + 1u] : 0xFFFFFFFFu;
    }
}

static void s_mandel(const uint32_t *a)
{
    uint32_t *out = AKP(uint32_t, a[0]);
    const uint32_t n = a[1], m = a[5];
    const float x0 = ak_f(a[2]), y0 = ak_f(a[3]), d = ak_f(a[4]);
    for (uint32_t py = 0; py < n; py++) {
        const float ci = __builtin_fmaf((float)py, d, y0);
        for (uint32_t px = 0; px < n; px++) {
            const float cr = __builtin_fmaf((float)px, d, x0);
            float zr = 0.0f, zi = 0.0f;
            uint32_t k = 0;
            int esc;
            do {
                float zr2 = zr * zr, zi2 = zi * zi;
                esc = (zr2 + zi2) > 4.0f;
                zi = __builtin_fmaf(zr * zi, 2.0f, ci);
                zr = (zr2 - zi2) + cr;
                k++;
            } while (!esc && k < m);
            out[py * n + px] = k;
        }
    }
}

static void s_swat(const uint32_t *a)
{
    const uint8_t *qs = AKP(const uint8_t, a[0]), *ts = AKP(const uint8_t, a[1]);
    uint32_t *out = AKP(uint32_t, a[2]);
    const uint32_t pairs = a[3], lq = a[4], lt = a[5];
    int32_t hrow[64], erow[64];
    for (uint32_t pp = 0; pp < pairs; pp++) {
        const uint8_t *q = qs + pp * lq, *t = ts + pp * lt;
        int32_t best = 0;
        for (uint32_t i = 0; i < lq; i++) { hrow[i] = 0; erow[i] = AK_SW_NEG; }
        for (uint32_t j = 0; j < lt; j++) {
            int32_t hup = 0, f = AK_SW_NEG, diag = 0;
            const uint8_t tj = t[j];
            for (uint32_t i = 0; i < lq; i++) {
                int32_t e = erow[i] - 1, h3 = hrow[i] - 3;
                e = e > h3 ? e : h3;
                int32_t f1 = f - 1, u3 = hup - 3;
                f = f1 > u3 ? f1 : u3;
                int32_t h = diag + (q[i] == tj ? 2 : -1);
                h = h > e ? h : e;
                h = h > f ? h : f;
                h = h > 0 ? h : 0;
                diag = hrow[i];
                hrow[i] = h;
                erow[i] = e;
                hup = h;
                best = best > h ? best : h;
            }
        }
        out[pp] = (uint32_t)best;
    }
}

/* ── Suite 2: the plain-C versions of kernels/suite2/s2_ref.h ────────────────── */
#include "s2_ref.h"
static void s_pathfinder(const uint32_t *a)
{ s2_pathfinder(AKP(const int32_t, a[0]), AKP(int32_t, a[1]), AKP(int32_t, a[2]), a[3], a[4]); }
static void s_hotspot(const uint32_t *a)
{
    float k[5] = { ak_f(a[5]), ak_f(a[6]), ak_f(a[7]), ak_f(a[8]), ak_f(a[9]) };
    s2_hotspot(AKP(float, a[0]), AKP(float, a[1]), AKP(const float, a[2]), a[3], a[4], k, a[10]);
}
static void s_jacobi2d(const uint32_t *a)
{ s2_jacobi2d(AKP(float, a[0]), AKP(float, a[1]), a[2], a[3], ak_f(a[4]), a[5]); }
static void s_atax(const uint32_t *a)
{
    s2_mv_row(AKP(const float, a[0]), AKP(const float, a[1]), AKP(float, a[2]), a[4]);
    s2_mv_col(AKP(const float, a[0]), AKP(const float, a[2]), AKP(float, a[3]), a[4]);
}
static void s_bicg(const uint32_t *a)
{
    s2_mv_row(AKP(const float, a[0]), AKP(const float, a[1]), AKP(float, a[3]), a[5]);
    s2_mv_col(AKP(const float, a[0]), AKP(const float, a[2]), AKP(float, a[4]), a[5]);
}
static void s_pagerank(const uint32_t *a)
{
    s2_pagerank(AKP(const uint32_t, a[0]), AKP(const uint32_t, a[1]), AKP(const float, a[2]),
                AKP(float, a[3]), AKP(float, a[4]), AKP(float, a[5]), a[6], ak_f(a[7]), ak_f(a[8]), a[9]);
}
static void s_cc(const uint32_t *a)
{
    *AKP(uint32_t, a[5]) = s2_cc(AKP(const uint32_t, a[0]), AKP(const uint32_t, a[1]),
                                 AKP(uint32_t, a[2]), AKP(uint32_t, a[3]), a[4]);
}
static void s_backprop(const uint32_t *a)
{
    s2_bp_forward(AKP(const float, a[0]), AKP(const float, a[1]), AKP(float, a[4]), a[5]);
    s2_bp_adjust(AKP(const float, a[0]), AKP(float, a[1]), AKP(float, a[2]), AKP(const float, a[3]),
                 a[5], ak_f(a[6]));
}
static void s_sort(const uint32_t *a)
{ s2_sort(AKP(uint32_t, a[0]), AKP(uint32_t, a[1]), AKP(uint32_t, a[2]), AKP(uint32_t, a[3]), a[4]); }
static void s_blackscholes(const uint32_t *a)
{
    s2_blackscholes(AKP(const float, a[0]), AKP(const float, a[1]), AKP(const float, a[2]),
                    AKP(const float, a[3]), AKP(const float, a[4]), AKP(float, a[5]), AKP(float, a[6]),
                    AKP(const float, a[7]), a[8]);
}

/* ── Rodinia: the plain-C versions of kernels/rodinia/rd_ref.h ──────────────────── */
#include "rd_ref.h"
static void s_rd_hotspot(const uint32_t *a)
{   /* a = t0 t1 pw n rx1 ry1 rz1 amb sdc steps */
    float k[5] = { ak_f(a[4]), ak_f(a[5]), ak_f(a[6]), ak_f(a[7]), ak_f(a[8]) };
    rd_hotspot(AKP(float, a[0]), AKP(float, a[1]), AKP(const float, a[2]), a[3], k, a[9]);
}
static void s_rd_hotspot3d(const uint32_t *a)
{   /* a = t0 t1 pw n nz cc ce cn ct sdc amb iters */
    float k[6] = { ak_f(a[5]), ak_f(a[6]), ak_f(a[7]), ak_f(a[8]), ak_f(a[9]), ak_f(a[10]) };
    rd_hotspot3d(AKP(float, a[0]), AKP(float, a[1]), AKP(const float, a[2]), a[3], a[4], k, a[11]);
}
static void s_rd_gaussian(const uint32_t *a)
{   /* a = A (augmented n x (n+1)) m n */
    rd_gaussian(AKP(float, a[0]), AKP(float, a[1]), a[2]);
}
static void s_rd_kmeans(const uint32_t *a)
{   /* a = f (point-major on CVA6) c membership n k nf */
    rd_kmeans_assign(AKP(const float, a[0]), AKP(const float, a[1]), AKP(int32_t, a[2]), a[3], a[4], a[5]);
}
static void s_rd_nn(const uint32_t *a)
{   /* a = loc dist n lat lng */
    rd_nn(AKP(const float, a[0]), AKP(float, a[1]), a[2], ak_f(a[3]), ak_f(a[4]));
}

/* ── RiVEC batch 1: the plain-C versions of kernels/rivec/rv_ref.h ───────────────── */
#include "rv_ref.h"
static void s_rv_axpy(const uint32_t *a)
{   /* a = dx dy a n */
    rv_axpy(ak_f(a[2]), AKP(const float, a[0]), AKP(float, a[1]), a[3]);
}
static void s_rv_matmul(const uint32_t *a)
{   /* a = A B C m n p */
    rv_matmul(AKP(const float, a[0]), AKP(const float, a[1]), AKP(float, a[2]), a[3], a[4], a[5]);
}
static void s_rv_spmv(const uint32_t *a)
{   /* a = ia ja val x y nrows */
    rv_spmv(a[5], AKP(const uint32_t, a[0]), AKP(const uint32_t, a[1]), AKP(const float, a[2]),
            AKP(const float, a[3]), AKP(float, a[4]));
}
static void s_rv_jacobi(const uint32_t *a)
{   /* a = A B n tsteps */
    rv_jacobi2d(AKP(float, a[0]), AKP(float, a[1]), a[2], a[3]);
}
static void s_rv_pathfinder(const uint32_t *a)
{   /* a = wall dst tmp rows cols runs */
    rv_pathfinder(AKP(const int32_t, a[0]), a[3], a[4], AKP(int32_t, a[1]), AKP(int32_t, a[2]), a[5]);
}
static void s_rv_bs(const uint32_t *a)
{   /* a = S K r v T type price n runs */
    for (uint32_t j = 0; j < a[8]; j++)
        rv_blackscholes(a[7], AKP(const float, a[0]), AKP(const float, a[1]), AKP(const float, a[2]),
                        AKP(const float, a[3]), AKP(const float, a[4]), AKP(const int32_t, a[5]),
                        AKP(float, a[6]));
}
static void s_rv_lavamd(const uint32_t *a)
{   /* a = rv qv fv nn nei a2 nbox */
    rv_lavamd(a[6], AKP(const uint32_t, a[3]), AKP(const uint32_t, a[4]), AKP(const float, a[0]),
              AKP(const float, a[1]), AKP(float, a[2]), ak_f(a[5]));
}

const ak_fn ak_scalar[AK_NAPPS] = {
    [AK_GEMM] = s_gemm, [AK_SPMV] = s_spmv, [AK_STENCIL] = s_stencil, [AK_KMEANS] = s_kmeans,
    [AK_BFS] = s_bfs, [AK_SCAN] = s_scan, [AK_MLP] = s_mlp, [AK_CONV] = s_conv,
    [AK_EMBAG] = s_embag, [AK_HASHJ] = s_hashj, [AK_MANDEL] = s_mandel, [AK_SWAT] = s_swat,
    [AK_PATHFINDER] = s_pathfinder, [AK_HOTSPOT] = s_hotspot, [AK_JACOBI2D] = s_jacobi2d,
    [AK_ATAX] = s_atax, [AK_BICG] = s_bicg, [AK_PAGERANK] = s_pagerank, [AK_CC] = s_cc,
    [AK_BACKPROP] = s_backprop, [AK_SORT] = s_sort, [AK_BLACKSCHOLES] = s_blackscholes,
    [AK_RD_HOTSPOT] = s_rd_hotspot, [AK_RD_NN] = s_rd_nn, [AK_RD_HOTSPOT3D] = s_rd_hotspot3d,
    [AK_RD_GAUSSIAN] = s_rd_gaussian, [AK_RD_KMEANS] = s_rd_kmeans,
    [AK_RV_AXPY] = s_rv_axpy, [AK_RV_MATMUL] = s_rv_matmul, [AK_RV_SPMV] = s_rv_spmv,
    [AK_RV_JACOBI] = s_rv_jacobi, [AK_RV_PATHFINDER] = s_rv_pathfinder, [AK_RV_BS] = s_rv_bs,
    [AK_RV_LAVAMD] = s_rv_lavamd,
};
