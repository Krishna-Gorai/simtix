/*
 * apps_ara.c - the SIMTiX application suite (sw/ps_host/apps.c) on CVA6 and Ara.
 *
 * Every application and size of apps.c, with the inputs built by the same code in
 * the same order (same generator, same draws), so the data are those of the SIMTiX
 * board runs. The runs of SIMTiX-only kernel variants (gemm_rb, scan_seg, ...) draw
 * their inputs and stop, which keeps the generator in step. Per application:
 *   1. inputs in DDR4 (arena at AK_ARENA, inside Ara's window), plus the layouts the
 *      kernels use (not timed): CPU layouts for CVA6, vector-friendly ones for Ara,
 *   2. the A53 reference, timed as in apps.c,
 *   3. the RISC-V program (ak.elf) twice: mode 0 = scalar kernel on CVA6, mode 1 =
 *      RVV kernel on Ara; each output compared with the A53 reference exactly.
 * One CSV row per run:
 *   ARAK,<app>,<size>,<cva6|ara>,<cycles>,<us>,<a53 us>,<hw counter cycles>,<errors>
 * cycles = mcycle around the kernel (fences on both sides: Ara idle); the hardware
 * counter (wrapper HWCNT, enabled by the program) must agree within a few cycles.
 * us = cycles at the PL clock.
 */
#pragma GCC optimize("fp-contract=off")
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "ak.h"            /* ../kernels/ak.h, copied in by build_vitis_ara.py */

/* output through main.c's console (UART + DDR buffer for run_board_ara.tcl); it
   formats with vsnprintf, so %llu works */
void con_printf(const char *fmt, ...);
#undef xil_printf
#define xil_printf con_printf

#define ARA_BASE   0xA0000000u
#define R_CTRL     0x00u
#define R_STATUS   0x04u
#define R_EXIT     0x08u
#define R_HW_LO    0x14u
#define R_HW_HI    0x18u
#define UNSEEN     0xFFFFFFFFu
#define TIMEOUT_S  3600u   /* per run; CVA6 alone needs more than 300 s for hotspot3D (Rodinia) */

static inline uint32_t rd(uint32_t off) { return Xil_In32(ARA_BASE + off); }
static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(ARA_BASE + off, v); }

static double us(XTime t0, XTime t1) { return (double)(t1 - t0) * 1e6 / (double)COUNTS_PER_SECOND; }

/* ── arena ──────────────────────────────────────────────────────────────────── */
static uintptr_t top;
static void arena_reset(void) { top = AK_ARENA; }
static void *alloc(size_t bytes)
{
    uintptr_t a = (top + 63u) & ~(uintptr_t)63u;
    top = a + bytes;
    if (top > AK_ARENA + AK_ARENA_SZ) { xil_printf("arena overflow\r\n"); for (;;) ; }
    return (void *)a;
}
static uint32_t *alloc_u32(size_t n) { return (uint32_t *)alloc(4u * n); }
static uint32_t addr(const void *p) { return (uint32_t)(uintptr_t)p; }
static void clean_all(void)      { Xil_DCacheFlushRange((INTPTR)AK_ARENA, top - AK_ARENA); }
static void invalidate_all(void) { Xil_DCacheInvalidateRange((INTPTR)AK_ARENA, top - AK_ARENA); }

/* ── deterministic data (apps.c) ────────────────────────────────────────────── */
static uint32_t rng = 2027u;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static float rnd_f32(void) { return (float)(int32_t)(rnd() >> 8) * (1.0f / 8388608.0f) - 1.0f; }
static uint32_t f2u(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }

static unsigned diff(const uint32_t *a, const uint32_t *b, size_t n)
{
    unsigned e = 0;
    for (size_t i = 0; i < n; i++) e += (a[i] != b[i]);
    return e;
}

/* ── running the RISC-V program ─────────────────────────────────────────────── */
static const uint32_t *ak_img;
static uint32_t ak_words;
static double pl_mhz;
static uint64_t run_cyc, run_hw;

/* Starts the program on one kernel; returns 0 if it finished with exit 0. The
   program image is copied again for every run (its stack and .bss start clean). */
static unsigned ara_run(uint32_t app, uint32_t mode, const uint32_t *args, unsigned nargs)
{
    volatile struct ak_mb *mb = (volatile struct ak_mb *)(uintptr_t)AK_MB_HOST;
    wr(R_CTRL, 0);
    memcpy((void *)(uintptr_t)AK_IMG_HOST, ak_img, 4u * ak_words);
    Xil_DCacheFlushRange((INTPTR)AK_IMG_HOST, 4u * ak_words);
    mb->magic = AK_MAGIC; mb->app = app; mb->mode = mode; mb->done = 0; mb->cycles = 0;
    for (unsigned i = 0; i < AK_NARGS; i++) mb->args[i] = i < nargs ? args[i] : 0;
    Xil_DCacheFlushRange((INTPTR)AK_MB_HOST, sizeof *mb);
    clean_all();
    XTime t0, t1;
    XTime_GetTime(&t0);
    wr(R_CTRL, 1);
    uint32_t st;
    for (;;) {
        st = rd(R_STATUS);
        if (st & 1u) break;
        XTime_GetTime(&t1);
        if ((t1 - t0) > (XTime)TIMEOUT_S * COUNTS_PER_SECOND) break;
    }
    Xil_DCacheInvalidateRange((INTPTR)AK_MB_HOST, sizeof *mb);
    invalidate_all();
    uint32_t ex = rd(R_EXIT);
    run_hw = ((uint64_t)rd(R_HW_HI) << 32) | rd(R_HW_LO);
    run_cyc = mb->cycles;
    unsigned bad = !(st & 1u) || ex != 0 || mb->done != 1u;
    if (bad) xil_printf("ARAK run failed: app %u mode %u status %x exit %u done %u\r\n",
                        (unsigned)app, (unsigned)mode, (unsigned)st, (unsigned)ex, (unsigned)mb->done);
    wr(R_CTRL, 0);
    return bad;
}

static void report(const char *app, uint32_t size, uint32_t mode, double a53_us, unsigned errs)
{
    /* 64-bit tenths of a microsecond: CVA6's kmeans (726 s) overflowed 32 bits */
    unsigned long long a10 = (unsigned long long)(a53_us * 10.0 + 0.5);
    unsigned long long u10 = (unsigned long long)((double)run_cyc / pl_mhz * 10.0 + 0.5);
    xil_printf("ARAK,%s,%u,%s,%llu,%llu.%llu,%llu.%llu,%llu,%u\r\n", app, (unsigned)size, mode ? "ara" : "cva6",
               (unsigned long long)run_cyc, u10 / 10, u10 % 10, a10 / 10, a10 % 10,
               (unsigned long long)run_hw, errs);
}

/* Runs both modes; before each, prep(mode) resets the outputs; check(mode) counts
   the words that differ from the reference. ARA_SKIP(app) would leave an application's
   Ara run out (row "ARAK,<app>,<n>,ara,skip"); Mandelbrot was, until its deadlock was
   traced to vid.v (kernels/ak_vector.c header, item 6). */
#define ARA_SKIP(app) 0   /* none: mandel's deadlock was vid.v (ak_vector.c header, item 6) */
#define BOTH(name, size, a53, app, argv_s, argv_v, prep, check)                             \
    do {                                                                                    \
        for (uint32_t m_ = 0; m_ < 2; m_++) {                                               \
            if (m_ && ARA_SKIP(app)) {                                                      \
                xil_printf("ARAK,%s,%u,ara,skip\r\n", name, (unsigned)(size));              \
                continue;                                                                   \
            }                                                                               \
            const uint32_t *av_ = m_ ? (argv_v) : (argv_s);                                 \
            unsigned na_ = m_ ? sizeof(argv_v) / 4u : sizeof(argv_s) / 4u;                  \
            prep;                                                                           \
            unsigned bad_ = ara_run(app, m_, av_, na_);                                     \
            unsigned e_ = (check);                                                          \
            report(name, size, m_, a53, e_ + bad_);                                         \
            errs_ += e_ + bad_;                                                             \
        }                                                                                   \
    } while (0)

/* ── GEMM ───────────────────────────────────────────────────────────────────── */
static unsigned app_gemm(uint32_t n, int run)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    float *a = alloc(4u * n * n), *b = alloc(4u * n * n), *c = alloc(4u * n * n), *ref = alloc(4u * n * n);
    for (uint32_t i = 0; i < n * n; i++) { a[i] = rnd_f32(); b[i] = rnd_f32(); }
    if (!run) return 0;
    XTime_GetTime(&t2);
    for (uint32_t i = 0; i < n; i++) {
        float *cr = ref + i * n;
        for (uint32_t j = 0; j < n; j++) cr[j] = 0.0f;
        for (uint32_t k = 0; k < n; k++) {
            float av = a[i * n + k];
            const float *br = b + k * n;
            for (uint32_t j = 0; j < n; j++) cr[j] = fmaf(av, br[j], cr[j]);
        }
    }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(a), addr(b), addr(c), n };
    BOTH("gemm", n, us(t2, t3), AK_GEMM, p, p, memset(c, 0xA5, 4u * n * n),
         diff((uint32_t *)c, (uint32_t *)ref, n * n));
    return errs_;
}

/* ── SpMV ───────────────────────────────────────────────────────────────────── */
static unsigned app_spmv(uint32_t rows, uint32_t maxnnz, int run)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t *rowptr = alloc_u32(rows + 1), *col = alloc_u32(rows * maxnnz);
    float *val = alloc(4u * rows * maxnnz);
    float *x = alloc(4u * rows), *y = alloc(4u * rows), *ref = alloc(4u * rows);
    uint32_t nnz = 0;
    for (uint32_t r = 0; r < rows; r++) {
        rowptr[r] = nnz;
        uint32_t k = rnd() % (maxnnz + 1);
        for (uint32_t j = 0; j < k; j++) { col[nnz] = rnd() % rows; val[nnz] = rnd_f32(); nnz++; }
    }
    rowptr[rows] = nnz;
    for (uint32_t i = 0; i < rows; i++) x[i] = rnd_f32();
    if (!run) return 0;
    XTime_GetTime(&t2);
    for (uint32_t r = 0; r < rows; r++) {
        float acc = 0.0f;
        for (uint32_t j = rowptr[r]; j < rowptr[r + 1]; j++) acc = fmaf(val[j], x[col[j]], acc);
        ref[r] = acc;
    }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(rowptr), addr(col), addr(val), addr(x), addr(y), rows };
    BOTH("spmv", rows, us(t2, t3), AK_SPMV, p, p, memset(y, 0xA5, 4u * rows),
         diff((uint32_t *)y, (uint32_t *)ref, rows));
    return errs_;
}

/* ── Stencil ────────────────────────────────────────────────────────────────── */
static void stencil_ref(const float *in, float *out, uint32_t n, uint32_t s, float c0, float c1)
{
    for (uint32_t i = 0; i < n; i++)
        for (uint32_t j = 0; j < n; j++) {
            uint32_t q = (i + 1) * s + 8 + j;
            float sm = (in[q - s] + in[q + s]) + (in[q - 1] + in[q + 1]);
            out[q] = fmaf(c1, sm, c0 * in[q]);
        }
}

static unsigned app_stencil(uint32_t n, uint32_t sweeps, int run)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t s = n + 16, words = (n + 2) * s;
    float *g[2] = { alloc(4u * words), alloc(4u * words) };
    float *r[2] = { alloc(4u * words), alloc(4u * words) };
    float *init = alloc(4u * words);
    const float c0 = 0.5f, c1 = 0.125f;
    for (uint32_t i = 0; i < words; i++) g[0][i] = g[1][i] = r[0][i] = r[1][i] = init[i] = rnd_f32();
    if (!run) return 0;
    XTime_GetTime(&t2);
    for (uint32_t t = 0; t < sweeps; t++) stencil_ref(r[t % 2], r[(t + 1) % 2], n, s, c0, c1);
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(g[0]), addr(g[1]), n, s, f2u(c0), f2u(c1), sweeps };
    BOTH("stencil", n, us(t2, t3), AK_STENCIL, p, p,
         (memcpy(g[0], init, 4u * words), memcpy(g[1], init, 4u * words)),
         diff((uint32_t *)g[sweeps % 2], (uint32_t *)r[sweeps % 2], words) +
         diff((uint32_t *)g[(sweeps + 1) % 2], (uint32_t *)r[(sweeps + 1) % 2], words));
    return errs_;
}

/* ── k-means ────────────────────────────────────────────────────────────────── */
static unsigned app_kmeans(uint32_t npts, uint32_t k, int run)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t *px = alloc_u32(npts), *py = alloc_u32(npts), *as = alloc_u32(npts);
    uint32_t *cx = alloc_u32(k), *cy = alloc_u32(k);
    uint32_t *sx = alloc_u32(k), *sy = alloc_u32(k), *cn = alloc_u32(k);
    uint32_t *ras = alloc_u32(npts), *rsx = alloc_u32(k), *rsy = alloc_u32(k), *rcn = alloc_u32(k);
    for (uint32_t i = 0; i < npts; i++) { px[i] = rnd() & 0x3FFFu; py[i] = rnd() & 0x3FFFu; }
    for (uint32_t j = 0; j < k; j++) {
        uint32_t q = rnd() % npts;
        cx[j] = px[q]; cy[j] = py[q];
    }
    if (!run) return 0;
    XTime_GetTime(&t2);
    for (uint32_t j = 0; j < k; j++) rsx[j] = rsy[j] = rcn[j] = 0;
    for (uint32_t i = 0; i < npts; i++) {
        int32_t x = (int32_t)px[i], y = (int32_t)py[i];
        uint32_t best = 0x7FFFFFFFu, bk = 0;
        for (uint32_t j = 0; j < k; j++) {
            int32_t dx = x - (int32_t)cx[j], dy = y - (int32_t)cy[j];
            uint32_t d = (uint32_t)(dx * dx + dy * dy);
            if (d < best) { best = d; bk = j; }
        }
        ras[i] = bk; rsx[bk] += (uint32_t)x; rsy[bk] += (uint32_t)y; rcn[bk]++;
    }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(px), addr(py), addr(cx), addr(cy), k, addr(as), addr(sx), addr(sy), addr(cn), npts };
    BOTH("kmeans", npts, us(t2, t3), AK_KMEANS, p, p,
         (memset(as, 0xA5, 4u * npts), memset(sx, 0xA5, 4u * k), memset(sy, 0xA5, 4u * k), memset(cn, 0xA5, 4u * k)),
         diff(as, ras, npts) + diff(sx, rsx, k) + diff(sy, rsy, k) + diff(cn, rcn, k));
    return errs_;
}

/* ── BFS ────────────────────────────────────────────────────────────────────── */
static unsigned app_bfs(uint32_t nv, uint32_t deg, int run)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t ne = 2 * (nv - 1) + nv * (deg - 2);
    uint32_t *eu = alloc_u32(ne), *ev = alloc_u32(ne);
    uint32_t *rowptr = alloc_u32(nv + 1), *col = alloc_u32(ne);
    uint32_t *lev = alloc_u32(nv), *rlev = alloc_u32(nv), *queue = alloc_u32(nv), *q2 = alloc_u32(nv);
    uint32_t m = 0;
    for (uint32_t v = 1; v < nv; v++) {
        uint32_t u = rnd() % v;
        eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u;
    }
    while (m + 1 < ne) {
        uint32_t u = rnd() % nv, v = rnd() % nv;
        if (u == v) continue;
        eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u;
    }
    if (!run) return 0;
    for (uint32_t v = 0; v <= nv; v++) rowptr[v] = 0;
    for (uint32_t i = 0; i < m; i++) rowptr[eu[i] + 1]++;
    for (uint32_t v = 0; v < nv; v++) rowptr[v + 1] += rowptr[v];
    for (uint32_t v = 0; v < nv; v++) queue[v] = rowptr[v];
    for (uint32_t i = 0; i < m; i++) col[queue[eu[i]]++] = ev[i];
    XTime_GetTime(&t2);
    for (uint32_t v = 0; v < nv; v++) rlev[v] = UNSEEN;
    uint32_t head = 0, tail = 0;
    rlev[0] = 0; queue[tail++] = 0;
    while (head < tail) {
        uint32_t v = queue[head++];
        for (uint32_t j = rowptr[v]; j < rowptr[v + 1]; j++) {
            uint32_t u = col[j];
            if (rlev[u] == UNSEEN) { rlev[u] = rlev[v] + 1; queue[tail++] = u; }
        }
    }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(rowptr), addr(col), addr(lev), nv, addr(q2) };
    BOTH("bfs", nv, us(t2, t3), AK_BFS, p, p, memset(lev, 0xA5, 4u * nv), diff(lev, rlev, nv));
    return errs_;
}

/* ── Scan ───────────────────────────────────────────────────────────────────── */
static unsigned app_scan(uint32_t n, int run)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t *in = alloc_u32(n), *ref = alloc_u32(n), *out = alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) in[i] = rnd() & 0xFFFFu;
    if (!run) return 0;
    XTime_GetTime(&t2);
    uint32_t acc = 0;
    for (uint32_t i = 0; i < n; i++) { acc += in[i]; ref[i] = acc; }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(in), addr(out), n };
    BOTH("scan", n, us(t2, t3), AK_SCAN, p, p, memset(out, 0xA5, 4u * n), diff(out, ref, n));
    return errs_;
}

/* ── MLP ────────────────────────────────────────────────────────────────────── */
static uint8_t rne_u8(float v)
{
    int32_t i = (int32_t)v;
    float   f = v - (float)i;
    if (f > 0.5f || (f == 0.5f && (i & 1))) i++;
    return (uint8_t)i;
}

static unsigned app_mlp(uint32_t batch)
{
    static const uint32_t dims[] = { 784, 256, 128, 10 };
    const unsigned nl = 3;
    const float scale = 1.0f / 1024.0f, zp = 3.0f;
    unsigned errs_ = 0;
    XTime t2, t3;
    uint8_t *x0 = alloc(batch * dims[0]);
    int8_t *w[3], *wT[3], *wkn[3];
    uint32_t npad[3], k[3];
    k[0] = dims[0];
    for (uint32_t i = 0; i < batch * dims[0]; i++) x0[i] = rnd() & 0x7Fu;
    for (unsigned l = 0; l < nl; l++) {                 /* draws as apps.c (packed layout) */
        npad[l] = 8;
        while (npad[l] < dims[l + 1]) npad[l] <<= 1;
        w[l] = alloc(k[l] * npad[l]);
        for (uint32_t kk = 0; kk < k[l] / 4; kk++)
            for (uint32_t n = 0; n < npad[l]; n++)
                for (uint32_t i = 0; i < 4; i++)
                    w[l][(kk * npad[l] + n) * 4 + i] =
                        (n < dims[l + 1]) ? (int8_t)((int32_t)(rnd() % 128u) - 64) : 0;
        if (l + 1 < nl) k[l + 1] = npad[l];
    }
    for (unsigned l = 0; l < nl; l++) {                 /* CVA6: wT[n][k]; Ara: W[k][n] */
        wT[l] = alloc(k[l] * npad[l]);
        wkn[l] = alloc(k[l] * npad[l]);
        for (uint32_t n = 0; n < npad[l]; n++)
            for (uint32_t kk = 0; kk < k[l]; kk++) {
                int8_t v = w[l][((kk / 4) * npad[l] + n) * 4 + kk % 4];
                wT[l][n * k[l] + kk] = v;
                wkn[l][kk * npad[l] + n] = v;
            }
    }
    uint32_t *dimv = alloc_u32(8);
    for (unsigned l = 0; l < nl; l++) { dimv[l] = k[l]; dimv[4 + l] = npad[l]; }
    uint8_t *act = alloc(batch * 256), *nxt = alloc(batch * 256);
    uint8_t *bact = alloc(batch * 256), *bnxt = alloc(batch * 256);
    int32_t *logit = alloc(4u * batch * npad[nl - 1]), *out = alloc(4u * batch * npad[nl - 1]);
    XTime_GetTime(&t2);                                 /* the A53 reference of apps.c */
    const uint8_t *src = x0;
    for (unsigned l = 0; l < nl; l++) {
        int last = (l == nl - 1);
        for (uint32_t b = 0; b < batch; b++)
            for (uint32_t n = 0; n < npad[l]; n++) {
                int32_t acc = 0;
                for (uint32_t kk = 0; kk < k[l]; kk++)
                    acc += (int32_t)(int8_t)src[b * k[l] + kk] * w[l][((kk / 4) * npad[l] + n) * 4 + kk % 4];
                if (last) {
                    logit[b * npad[l] + n] = acc;
                } else {
                    float v = fmaf((float)acc, scale, zp);
                    v = v > 127.0f ? 127.0f : (v < 0.0f ? 0.0f : v);
                    nxt[b * npad[l] + n] = rne_u8(v);
                }
            }
        if (!last) {
            for (uint32_t i = 0; i < batch * npad[l]; i++) act[i] = nxt[i];
            src = act;
        }
    }
    XTime_GetTime(&t3);
    uint32_t ps[] = { addr(x0), batch, nl, addr(dimv), addr(wT[0]), addr(wT[1]), addr(wT[2]),
                      addr(bact), addr(bnxt), addr(out), f2u(scale), f2u(zp) };
    uint32_t pv[] = { addr(x0), batch, nl, addr(dimv), addr(wkn[0]), addr(wkn[1]), addr(wkn[2]),
                      addr(bact), addr(bnxt), addr(out), f2u(scale), f2u(zp) };
    BOTH("mlp", batch, us(t2, t3), AK_MLP, ps, pv, memset(out, 0xA5, 4u * batch * npad[nl - 1]),
         diff((uint32_t *)out, (uint32_t *)logit, batch * npad[nl - 1]));
    return errs_;
}

/* ── CNN: 3x3 INT8 convolutions 16 -> 32 -> 32 ──────────────────────────────── */
static unsigned app_conv(uint32_t n)
{
    static const uint32_t ch[] = { 16, 32, 32 };
    enum { NL = 2 };
    const float scale = 1.0f / 1024.0f, zp = 3.0f;
    const uint32_t wp = n + 2, rows = n + 2;
    unsigned errs_ = 0;
    XTime t2, t3;
    int8_t *xc[NL + 1], *xs[NL + 1], *xv[NL + 1], *wt[NL];
    for (unsigned l = 0; l <= NL; l++) {
        xc[l] = alloc(rows * wp * ch[l]);               /* A53 (NHWC) */
        xs[l] = alloc(rows * wp * ch[l]);               /* CVA6 (NHWC) */
        xv[l] = alloc(rows * wp * ch[l]);               /* Ara ([row][channel][column]) */
        memset(xc[l], 0, rows * wp * ch[l]);
    }
    for (uint32_t r = 1; r <= n; r++)
        for (uint32_t x = 1; x <= n; x++)
            for (uint32_t c = 0; c < ch[0]; c++)
                xc[0][(r * wp + x) * ch[0] + c] = (int8_t)(rnd() & 0x7Fu);
    for (unsigned l = 0; l < NL; l++) {
        uint32_t ci = ch[l], co = ch[l + 1];
        wt[l] = alloc(co * 9u * ci);
        for (uint32_t i = 0; i < co * 9u * ci; i++) wt[l][i] = (int8_t)((int32_t)(rnd() % 128u) - 64);
    }
    XTime_GetTime(&t2);
    for (unsigned l = 0; l < NL; l++) {
        const uint32_t ci = ch[l], co = ch[l + 1];
        const int8_t *in = xc[l];
        int8_t *out = xc[l + 1];
        for (uint32_t y = 0; y < n; y++)
            for (uint32_t x = 0; x < n; x++)
                for (uint32_t o = 0; o < co; o++) {
                    int32_t acc = 0;
                    for (uint32_t ky = 0; ky < 3; ky++)
                        for (uint32_t kx = 0; kx < 3; kx++) {
                            const int8_t *a = in + ((y + ky) * wp + x + kx) * ci;
                            const int8_t *b = wt[l] + ((o * 3u + ky) * 3u + kx) * ci;
                            for (uint32_t c = 0; c < ci; c++) acc += (int32_t)a[c] * b[c];
                        }
                    float v = fmaf((float)acc, scale, zp);
                    v = v > 127.0f ? 127.0f : (v < 0.0f ? 0.0f : v);
                    out[((y + 1) * wp + x + 1) * co + o] = (int8_t)rne_u8(v);
                }
    }
    XTime_GetTime(&t3);
    uint32_t ps[] = { addr(xs[0]), addr(xs[1]), addr(xs[2]), addr(wt[0]), addr(wt[1]), n, ch[0], ch[1], ch[2],
                      f2u(scale), f2u(zp) };
    uint32_t pv[] = { addr(xv[0]), addr(xv[1]), addr(xv[2]), addr(wt[0]), addr(wt[1]), n, ch[0], ch[1], ch[2],
                      f2u(scale), f2u(zp) };
    /* prep: layer-0 input in the run's layout, outputs zero (their padding is read) */
#define CONV_PREP(m)                                                                          \
    do {                                                                                      \
        int8_t **x_ = (m) ? xv : xs;                                                          \
        for (unsigned l = 0; l <= NL; l++) memset(x_[l], 0, rows * wp * ch[l]);               \
        for (uint32_t r = 0; r < rows; r++)                                                   \
            for (uint32_t x = 0; x < wp; x++)                                                 \
                for (uint32_t c = 0; c < ch[0]; c++) {                                        \
                    int8_t v = xc[0][(r * wp + x) * ch[0] + c];                               \
                    if (m) xv[0][(r * ch[0] + c) * wp + x] = v; else xs[0][(r * wp + x) * ch[0] + c] = v; \
                }                                                                             \
    } while (0)
#define CONV_CHECK(m)                                                                         \
    ({  unsigned e_c = 0;                                                                     \
        for (unsigned l = 1; l <= NL; l++)                                                    \
            for (uint32_t r = 0; r < rows; r++)                                               \
                for (uint32_t x = 0; x < wp; x++)                                             \
                    for (uint32_t c = 0; c < ch[l]; c++)                                      \
                        e_c += ((m) ? xv[l][(r * ch[l] + c) * wp + x] : xs[l][(r * wp + x) * ch[l] + c]) != \
                               xc[l][(r * wp + x) * ch[l] + c];                               \
        e_c; })
    BOTH("conv8", n, us(t2, t3), AK_CONV, ps, pv, CONV_PREP(m_), CONV_CHECK(m_));
    return errs_;
}

/* ── Embedding bag ──────────────────────────────────────────────────────────── */
static unsigned app_embag(uint32_t nrows, uint32_t bags, uint32_t k)
{
    const uint32_t D = AK_EMBAG_D;
    unsigned errs_ = 0;
    XTime t2, t3;
    float *t = alloc(4u * nrows * D);
    uint32_t *idx = alloc_u32(bags * k);
    float *out = alloc(4u * bags * D), *ref = alloc(4u * bags * D);
    for (uint32_t i = 0; i < nrows * D; i++) t[i] = rnd_f32();
    for (uint32_t i = 0; i < bags * k; i++) idx[i] = rnd() % nrows;
    XTime_GetTime(&t2);
    for (uint32_t b = 0; b < bags; b++) {
        float *o = ref + b * D;
        for (uint32_t d = 0; d < D; d++) o[d] = 0.0f;
        for (uint32_t j = 0; j < k; j++) {
            const float *row = t + idx[b * k + j] * D;
            for (uint32_t d = 0; d < D; d++) o[d] += row[d];
        }
    }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(t), addr(idx), addr(out), bags, k };
    BOTH("embag", bags, us(t2, t3), AK_EMBAG, p, p, memset(out, 0xA5, 4u * bags * D),
         diff((uint32_t *)out, (uint32_t *)ref, bags * D));
    return errs_;
}

/* ── Hash join ──────────────────────────────────────────────────────────────── */
static unsigned app_hashj(uint32_t s, uint32_t nprobe)
{
    const uint32_t nslot = 1u << s, mask = nslot - 1u, nins = nslot / 2u;
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t *slot = alloc_u32(2u * nslot), *ins = alloc_u32(nins);
    uint32_t *key = alloc_u32(nprobe), *out = alloc_u32(nprobe), *ref = alloc_u32(nprobe);
    for (uint32_t i = 0; i < 2u * nslot; i++) slot[i] = 0;
    for (uint32_t i = 0; i < nins; ) {
        uint32_t kk = rnd(), h = (kk * 0x9E3779B1u) >> (32u - s);
        if (kk == 0) continue;
        while (slot[2u * h] && slot[2u * h] != kk) h = (h + 1u) & mask;
        if (slot[2u * h] == kk) continue;
        slot[2u * h] = kk;
        slot[2u * h + 1u] = rnd() >> 1;
        ins[i++] = kk;
    }
    for (uint32_t i = 0; i < nprobe; i++) {
        uint32_t r = rnd();
        key[i] = (r & 1u) ? ins[(r >> 1) % nins] : (rnd() | 1u);
    }
    XTime_GetTime(&t2);
    for (uint32_t i = 0; i < nprobe; i++) {
        uint32_t kk = key[i], h = (kk * 0x9E3779B1u) >> (32u - s);
        while (slot[2u * h] != kk && slot[2u * h] != 0) h = (h + 1u) & mask;
        ref[i] = (slot[2u * h] == kk) ? slot[2u * h + 1u] : 0xFFFFFFFFu;
    }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(slot), addr(key), addr(out), nprobe, s };
    BOTH("hashj", s, us(t2, t3), AK_HASHJ, p, p, memset(out, 0xA5, 4u * nprobe), diff(out, ref, nprobe));
    return errs_;
}

/* ── Mandelbrot ─────────────────────────────────────────────────────────────── */
static unsigned app_mandel(uint32_t n, uint32_t m)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    const float x0 = -2.0f, y0 = -1.25f, d = 2.5f / (float)n;
    uint32_t *out = alloc_u32(n * n), *ref = alloc_u32(n * n);
    XTime_GetTime(&t2);
    for (uint32_t py = 0; py < n; py++) {
        const float ci = fmaf((float)py, d, y0);
        for (uint32_t px = 0; px < n; px++) {
            const float cr = fmaf((float)px, d, x0);
            float zr = 0.0f, zi = 0.0f;
            uint32_t k = 0;
            int esc;
            do {
                float zr2 = zr * zr, zi2 = zi * zi;
                esc = (zr2 + zi2) > 4.0f;
                zi = fmaf(zr * zi, 2.0f, ci);
                zr = (zr2 - zi2) + cr;
                k++;
            } while (!esc && k < m);
            ref[py * n + px] = k;
        }
    }
    XTime_GetTime(&t3);
    uint32_t p[] = { addr(out), n, f2u(x0), f2u(y0), f2u(d), m };
    BOTH("mandel", n, us(t2, t3), AK_MANDEL, p, p, memset(out, 0xA5, 4u * n * n), diff(out, ref, n * n));
    return errs_;
}

/* ── Smith-Waterman ─────────────────────────────────────────────────────────── */
static unsigned app_swat(uint32_t pairs, uint32_t lq, uint32_t lt)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint8_t *qs = alloc(pairs * lq), *ts = alloc(pairs * lt);
    uint8_t *qv = alloc(pairs * lq), *tv = alloc(pairs * lt);
    uint32_t *out = alloc_u32(pairs), *ref = alloc_u32(pairs);
    int16_t *scr = alloc(2u * lq * 256u * 2u);
    for (uint32_t i = 0; i < pairs * lq; i++) qs[i] = rnd() & 3u;
    for (uint32_t i = 0; i < pairs * lt; i++) ts[i] = rnd() & 3u;
    for (uint32_t pp = 0; pp < pairs; pp++) {           /* Ara: one pair per element */
        for (uint32_t i = 0; i < lq; i++) qv[i * pairs + pp] = qs[pp * lq + i];
        for (uint32_t j = 0; j < lt; j++) tv[j * pairs + pp] = ts[pp * lt + j];
    }
    int32_t hrow[64], erow[64];
    XTime_GetTime(&t2);
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
        ref[pp] = (uint32_t)best;
    }
    XTime_GetTime(&t3);
    uint32_t ps[] = { addr(qs), addr(ts), addr(out), pairs, lq, lt, 0 };
    uint32_t pv[] = { addr(qv), addr(tv), addr(out), pairs, lq, lt, addr(scr) };
    BOTH("swat", pairs, us(t2, t3), AK_SWAT, ps, pv, memset(out, 0xA5, 4u * pairs), diff(out, ref, pairs));
    return errs_;
}

/* ── Suite: the order of apps.c run_apps() ──────────────────────────────────── */
#define RUN(call) do { arena_reset(); errs += (call); } while (0)

static unsigned run_suite2(void);   /* suite2.inc, at the end of this file */
static unsigned run_rodinia(void);  /* rodinia.inc, at the end of this file */

unsigned run_ara_apps(const uint32_t *img, uint32_t words, double mhz)
{
    unsigned errs = 0;
    ak_img = img; ak_words = words; pl_mhz = mhz;
    if (4u * words > AK_IMG_MAX) { xil_printf("ak image too large\r\n"); return 1; }
    xil_printf("ARAK,app,size,core,cycles,us,a53_us,hwcnt_cycles,errors\r\n");
#ifdef RD_ONLY                          /* the Rodinia suite alone (docs/rodinia_plan.md) */
    errs += run_rodinia();
    return errs;
#endif
    RUN(app_gemm(64, 1));          RUN(app_gemm(256, 1));
    RUN(app_spmv(4096, 16, 1));    RUN(app_spmv(65536, 16, 1));
    RUN(app_stencil(128, 4, 1));   RUN(app_stencil(512, 4, 1));
    RUN(app_kmeans(16384, 16, 1)); RUN(app_kmeans(262144, 16, 1));
    RUN(app_bfs(16384, 8, 1));     RUN(app_bfs(262144, 8, 1));
    RUN(app_scan(65536, 1));       RUN(app_scan(1u << 20, 1));
    RUN(app_mlp(16));              RUN(app_mlp(256));
    /* the SIMTiX v3 variants of apps.c: inputs drawn only, to keep the generator in step */
    RUN(app_gemm(64, 0));          RUN(app_gemm(256, 0));
    RUN(app_scan(65536, 0));       RUN(app_scan(1u << 20, 0));
    RUN(app_stencil(128, 4, 0));   RUN(app_stencil(512, 4, 0));
    RUN(app_kmeans(16384, 16, 0)); RUN(app_kmeans(262144, 16, 0));
    RUN(app_spmv(4096, 16, 0));    RUN(app_spmv(65536, 16, 0));
    RUN(app_conv(32));             RUN(app_conv(128));
    RUN(app_embag(16384, 256, 16)); RUN(app_embag(1u << 18, 4096, 32));
    RUN(app_hashj(16, 16384));     RUN(app_hashj(22, 1u << 20));
    RUN(app_mandel(256, 256));     RUN(app_mandel(1024, 256));
    RUN(app_swat(2048, 32, 128));  RUN(app_swat(16384, 32, 128));
    errs += run_suite2();
    return errs;
}

/* ── Suite 2 (docs/suite2_plan.md): CVA6 and Ara ─────────────────────────────── */
#define S2_ARA
#include "suite2.inc"

/* ── The Rodinia suite (docs/rodinia_plan.md): CVA6 and Ara ──────────────────── */
#include "rodinia.inc"
