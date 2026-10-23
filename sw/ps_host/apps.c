/*
 * apps.c  -  SIMTiX v2 application suite on the board (A53 host, DDR4)
 *
 * The kernels are those of kernels/apps/ (checked in simulation by tb_apps).
 * For every application and size the host builds the input in DDR4, cleans the
 * data cache, runs the accelerator (one or more launches; each launch passes a
 * parameter block in REG_BASE_A), invalidates the cache, and then times the
 * same computation on the A53 with an ordinary sequential algorithm: a queue
 * for BFS, a running sum for scan, i-k-j order for GEMM. FP32 results use the
 * same operations in the same order (fmaf), so every output is compared exactly.
 * One CSV row per run:
 *   BOARD,<app>,<size>,<accel cycles>,<accel us>,<a53 us>,<L1 hits>,<L1 misses>,<errors>
 * Cycles and L1 counts are summed over the run's launches; accel us is the wall
 * time from the first GO to the last DONE, including host work between launches.
 *
 * Buffers live in a 256 MB window of DDR4 at ARENA_BASE, outside the program
 * image; accelerator data must lie below 0x4000_0000 (simt_ps_top).
 */
/* The references must do exactly the kernels' FP operations: no contraction of
   a multiply and an add into an FMA beyond the explicit fmaf calls. */
#pragma GCC optimize("fp-contract=off")
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "kernels.h"

#define SIMT_BASE      0xA0000000u
#define REG_KERNEL_PC  0x00u
#define REG_BASE_A     0x04u
#define REG_N          0x10u
#define REG_CTRL       0x14u
#define REG_STATUS     0x18u
#define REG_CYCLES     0x1Cu
#define REG_BLOCK      0x20u
#define REG_L1_HITS    0x100u
#define REG_L1_MISSES  0x104u
#define IRAM           0x1000u

/* Instruction-RAM byte offsets (slots 0 and 1 hold reduce_shfl / histogram). */
#define PC_GEMM        0x200u
#define PC_SPMV        0x300u
#define PC_STENCIL     0x400u
#define PC_KMEANS      0x500u
#define PC_BFS         0x600u
#define PC_SCAN        0x700u
#define PC_SCAN_ADD    0x800u
#define PC_MLP         0x900u

#define ARENA_BASE     0x10000000u
#define ARENA_SIZE     0x10000000u
#define UNSEEN         0xFFFFFFFFu

static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(SIMT_BASE + off, v); }
static inline uint32_t rd(uint32_t off)         { return Xil_In32(SIMT_BASE + off); }

static double us(XTime t0, XTime t1)
{
    return (double)(t1 - t0) * 1e6 / (double)COUNTS_PER_SECOND;
}

/* ── DDR4 arena ─────────────────────────────────────────────────────────────── */
static uintptr_t top;

static void arena_reset(void) { top = ARENA_BASE; }

static void *alloc(size_t bytes)
{
    uintptr_t a = (top + 63u) & ~(uintptr_t)63u;
    top = a + bytes;
    if (top > ARENA_BASE + ARENA_SIZE) {
        xil_printf("arena overflow\r\n");
        for (;;) ;
    }
    return (void *)a;
}

static uint32_t *alloc_u32(size_t n) { return (uint32_t *)alloc(4u * n); }
static uint32_t  addr(const void *p) { return (uint32_t)(uintptr_t)p; }

static void clean_all(void)      { Xil_DCacheFlushRange((INTPTR)ARENA_BASE, top - ARENA_BASE); }
static void invalidate_all(void) { Xil_DCacheInvalidateRange((INTPTR)ARENA_BASE, top - ARENA_BASE); }

/* ── Deterministic data ─────────────────────────────────────────────────────── */
static uint32_t rng = 2027u;

static uint32_t rnd(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

static float rnd_f32(void) { return (float)(int32_t)(rnd() >> 8) * (1.0f / 8388608.0f) - 1.0f; }

static uint32_t f2u(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }

/* ── Launches ───────────────────────────────────────────────────────────────── */
static uint32_t run_cycles, run_hits, run_miss;

static void launch(uint32_t pc, const uint32_t *params, uint32_t n, uint32_t blk)
{
    wr(REG_KERNEL_PC, pc);
    wr(REG_BASE_A, addr(params));
    wr(REG_N, n);
    wr(REG_BLOCK, blk);
    wr(REG_CTRL, 1);
    while (!(rd(REG_STATUS) & 1u)) ;
    run_cycles += rd(REG_CYCLES);
    run_hits   += rd(REG_L1_HITS);
    run_miss   += rd(REG_L1_MISSES);
}

static uint32_t *params(unsigned n) { return alloc_u32(n); }

static void report(const char *app, uint32_t size, double acc_us, double cpu_us, unsigned errs)
{
    unsigned a10 = (unsigned)(acc_us * 10.0 + 0.5), c10 = (unsigned)(cpu_us * 10.0 + 0.5);
    xil_printf("BOARD,%s,%u,%u,%u.%u,%u.%u,%u,%u,%u\r\n", app, size, run_cycles,
               a10 / 10, a10 % 10, c10 / 10, c10 % 10, run_hits, run_miss, errs);
}

static unsigned diff(const uint32_t *a, const uint32_t *b, size_t n)
{
    unsigned e = 0;
    for (size_t i = 0; i < n; i++) e += (a[i] != b[i]);
    return e;
}

/* ── GEMM: C = A * B, FP32, n x n ───────────────────────────────────────────── */
static unsigned app_gemm(uint32_t n)
{
    XTime t0, t1, t2, t3;
    float *a = alloc(4u * n * n), *b = alloc(4u * n * n), *c = alloc(4u * n * n);
    float *ref = alloc(4u * n * n);
    uint32_t lg = 0;
    while ((1u << lg) < n) lg++;
    for (uint32_t i = 0; i < n * n; i++) { a[i] = rnd_f32(); b[i] = rnd_f32(); }
    uint32_t *p = params(5);
    p[0] = addr(a); p[1] = addr(b); p[2] = addr(c); p[3] = n; p[4] = lg;
    clean_all();
    XTime_GetTime(&t0);
    launch(PC_GEMM, p, n * n, 0);
    XTime_GetTime(&t1);
    invalidate_all();

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
    unsigned e = diff((uint32_t *)c, (uint32_t *)ref, n * n);
    report("gemm", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── SpMV: y = M x, CSR, FP32 ───────────────────────────────────────────────── */
static unsigned app_spmv(uint32_t rows, uint32_t maxnnz)
{
    XTime t0, t1, t2, t3;
    uint32_t *rowptr = alloc_u32(rows + 1);
    uint32_t *col = alloc_u32(rows * maxnnz);
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
    uint32_t *p = params(5);
    p[0] = addr(rowptr); p[1] = addr(col); p[2] = addr(val); p[3] = addr(x); p[4] = addr(y);
    clean_all();
    XTime_GetTime(&t0);
    launch(PC_SPMV, p, rows, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (uint32_t r = 0; r < rows; r++) {
        float acc = 0.0f;
        for (uint32_t j = rowptr[r]; j < rowptr[r + 1]; j++) acc = fmaf(val[j], x[col[j]], acc);
        ref[r] = acc;
    }
    XTime_GetTime(&t3);
    unsigned e = diff((uint32_t *)y, (uint32_t *)ref, rows);
    report("spmv", rows, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Stencil: sweeps of a 5-point Jacobi stencil, FP32, n x n interior ──────── */
static void stencil_ref(const float *in, float *out, uint32_t n, uint32_t s, float c0, float c1)
{
    for (uint32_t i = 0; i < n; i++)
        for (uint32_t j = 0; j < n; j++) {
            uint32_t q = (i + 1) * s + 8 + j;
            float sm = (in[q - s] + in[q + s]) + (in[q - 1] + in[q + 1]);
            out[q] = fmaf(c1, sm, c0 * in[q]);
        }
}

static unsigned app_stencil(uint32_t n, uint32_t sweeps)
{
    XTime t0, t1, t2, t3;
    uint32_t s = n + 16, words = (n + 2) * s, lg = 0;
    while ((1u << lg) < n) lg++;
    float *g[2] = { alloc(4u * words), alloc(4u * words) };
    float *r[2] = { alloc(4u * words), alloc(4u * words) };
    const float c0 = 0.5f, c1 = 0.125f;
    for (uint32_t i = 0; i < words; i++) g[0][i] = g[1][i] = r[0][i] = r[1][i] = rnd_f32();
    uint32_t *p[16];
    for (uint32_t t = 0; t < sweeps && t < 16; t++) {
        p[t] = params(6);
        p[t][0] = addr(g[t % 2]); p[t][1] = addr(g[(t + 1) % 2]);
        p[t][2] = lg; p[t][3] = s; p[t][4] = f2u(c0); p[t][5] = f2u(c1);
    }
    clean_all();
    XTime_GetTime(&t0);
    for (uint32_t t = 0; t < sweeps && t < 16; t++) launch(PC_STENCIL, p[t], n * n, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (uint32_t t = 0; t < sweeps && t < 16; t++)
        stencil_ref(r[t % 2], r[(t + 1) % 2], n, s, c0, c1);
    XTime_GetTime(&t3);
    unsigned e = diff((uint32_t *)g[sweeps % 2], (uint32_t *)r[sweeps % 2], words);
    report("stencil", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── k-means: assignment + accumulation, integer 2-D points ─────────────────── */
static unsigned app_kmeans(uint32_t npts, uint32_t k)
{
    XTime t0, t1, t2, t3;
    uint32_t *px = alloc_u32(npts), *py = alloc_u32(npts), *as = alloc_u32(npts);
    uint32_t *cx = alloc_u32(k), *cy = alloc_u32(k);
    uint32_t *sx = alloc_u32(k), *sy = alloc_u32(k), *cn = alloc_u32(k);
    uint32_t *ras = alloc_u32(npts), *rsx = alloc_u32(k), *rsy = alloc_u32(k), *rcn = alloc_u32(k);
    for (uint32_t i = 0; i < npts; i++) { px[i] = rnd() & 0x3FFFu; py[i] = rnd() & 0x3FFFu; }
    for (uint32_t j = 0; j < k; j++) {
        uint32_t q = rnd() % npts;
        cx[j] = px[q]; cy[j] = py[q]; sx[j] = sy[j] = cn[j] = 0;
    }
    uint32_t *p = params(9);
    p[0] = addr(px); p[1] = addr(py); p[2] = addr(cx); p[3] = addr(cy); p[4] = k;
    p[5] = addr(as); p[6] = addr(sx); p[7] = addr(sy); p[8] = addr(cn);
    clean_all();
    XTime_GetTime(&t0);
    launch(PC_KMEANS, p, npts, 0);
    XTime_GetTime(&t1);
    invalidate_all();

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
    unsigned e = diff(as, ras, npts) + diff(sx, rsx, k) + diff(sy, rsy, k) + diff(cn, rcn, k);
    report("kmeans", npts, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── BFS: level-synchronous on the accelerator, a queue on the A53 ──────────── */
static unsigned app_bfs(uint32_t nv, uint32_t deg)
{
    XTime t0, t1, t2, t3;
    uint32_t ne = 2 * (nv - 1) + nv * (deg - 2);       /* directed edges */
    uint32_t *eu = alloc_u32(ne), *ev = alloc_u32(ne);
    uint32_t *rowptr = alloc_u32(nv + 1), *col = alloc_u32(ne);
    uint32_t *lev = alloc_u32(nv), *rlev = alloc_u32(nv), *queue = alloc_u32(nv);
    uint32_t m = 0;
    for (uint32_t v = 1; v < nv; v++) {                 /* a random tree keeps it connected */
        uint32_t u = rnd() % v;
        eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u;
    }
    while (m + 1 < ne) {
        uint32_t u = rnd() % nv, v = rnd() % nv;
        if (u == v) continue;
        eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u;
    }
    for (uint32_t v = 0; v <= nv; v++) rowptr[v] = 0;  /* CSR by counting sort */
    for (uint32_t i = 0; i < m; i++) rowptr[eu[i] + 1]++;
    for (uint32_t v = 0; v < nv; v++) rowptr[v + 1] += rowptr[v];
    for (uint32_t v = 0; v < nv; v++) queue[v] = rowptr[v];
    for (uint32_t i = 0; i < m; i++) col[queue[eu[i]]++] = ev[i];
    for (uint32_t v = 0; v < nv; v++) lev[v] = UNSEEN;
    lev[0] = 0;
    uint32_t *p[64], *flag[64];
    for (uint32_t L = 0; L < 64; L++) {
        p[L] = params(5);
        flag[L] = alloc_u32(8);
        flag[L][0] = 0;
        p[L][0] = addr(rowptr); p[L][1] = addr(col); p[L][2] = addr(lev);
        p[L][3] = L; p[L][4] = addr(flag[L]);
    }
    clean_all();
    XTime_GetTime(&t0);
    for (uint32_t L = 0; L < 64; L++) {
        launch(PC_BFS, p[L], nv, 0);
        Xil_DCacheInvalidateRange((INTPTR)flag[L], 32);
        if (!flag[L][0]) break;
    }
    XTime_GetTime(&t1);
    invalidate_all();

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
    unsigned e = diff(lev, rlev, nv);
    report("bfs", nv, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Scan: inclusive prefix sum, recursive over 32-thread blocks ────────────── */
/* The launches are planned (buffers and parameter blocks allocated) before the
   timed run: scan of the block totals, then scan_add, at every level. */
struct step { uint32_t pc, n, blk; const uint32_t *p; };
static struct step plan[16];
static unsigned nplan;

static uint32_t *scan_level(const uint32_t *src, uint32_t m)
{
    uint32_t *out = alloc_u32(m), nb = m / 32u, nbp = (nb + 31u) & ~31u;
    uint32_t *bs = alloc_u32(nbp);
    for (uint32_t i = 0; i < nbp; i++) bs[i] = 0;
    uint32_t *p = params(3);
    p[0] = addr(src); p[1] = addr(out); p[2] = addr(bs);
    plan[nplan++] = (struct step){ PC_SCAN, m, 2, p };
    if (nb > 1) {
        uint32_t *bsc = scan_level(bs, nbp);
        uint32_t *q = params(2);
        q[0] = addr(out); q[1] = addr(bsc);
        plan[nplan++] = (struct step){ PC_SCAN_ADD, m, 0, q };
    }
    return out;
}

static unsigned app_scan(uint32_t n)
{
    XTime t0, t1, t2, t3;
    uint32_t *in = alloc_u32(n), *ref = alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) in[i] = rnd() & 0xFFFFu;
    nplan = 0;
    uint32_t *out = scan_level(in, n);
    clean_all();
    XTime_GetTime(&t0);
    for (unsigned s = 0; s < nplan; s++) launch(plan[s].pc, plan[s].p, plan[s].n, plan[s].blk);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    uint32_t acc = 0;
    for (uint32_t i = 0; i < n; i++) { acc += in[i]; ref[i] = acc; }
    XTime_GetTime(&t3);
    unsigned e = diff(out, ref, n);
    report("scan", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── MLP: INT8 fully connected layers, ReLU between, INT32 logits ───────────── */
/* Layer l: acc = x . W (pdot8 on the accelerator); hidden layers requantize to
   trunc(clamp(fmaf((float)acc, scale, zp), 0, 127)) (the engine's fcvt.w.s
   truncates; zp holds the +0.5 of round-half-up). Columns are padded to Npad, a
   power of two of at least 8; each image's activations are Npad bytes. */
static unsigned app_mlp(uint32_t batch)
{
    static const uint32_t dims[] = { 784, 256, 128, 10 };
    const unsigned nl = sizeof dims / sizeof dims[0] - 1;
    const float scale = 1.0f / 1024.0f, zp = 3.5f;
    XTime t0, t1, t2, t3;
    uint8_t  *x0 = alloc(batch * dims[0]);
    int8_t   *w[3];
    uint32_t *p[3], npad[3], k[3];
    void     *out[3];
    k[0] = dims[0];
    for (uint32_t i = 0; i < batch * dims[0]; i++) x0[i] = rnd() & 0x7Fu;
    const void *in = x0;
    for (unsigned l = 0; l < nl; l++) {
        npad[l] = 8;
        while (npad[l] < dims[l + 1]) npad[l] <<= 1;
        uint32_t lg = 0;
        while ((1u << lg) < npad[l]) lg++;
        /* packed [k/4][npad] words, byte i of word (kk, n) = W[4kk+i][n] */
        w[l] = alloc(k[l] * npad[l]);
        for (uint32_t kk = 0; kk < k[l] / 4; kk++)
            for (uint32_t n = 0; n < npad[l]; n++)
                for (uint32_t i = 0; i < 4; i++)
                    w[l][(kk * npad[l] + n) * 4 + i] =
                        (n < dims[l + 1]) ? (int8_t)((int32_t)(rnd() % 128u) - 64) : 0;
        int last = (l == nl - 1);
        out[l] = alloc(batch * npad[l] * (last ? 4u : 1u));
        p[l] = params(8);
        p[l][0] = addr(in); p[l][1] = addr(w[l]); p[l][2] = addr(out[l]);
        p[l][3] = k[l] / 4; p[l][4] = lg; p[l][5] = f2u(scale); p[l][6] = f2u(zp);
        p[l][7] = last ? 0 : 1;
        in = out[l];
        if (!last) k[l + 1] = npad[l];
    }
    clean_all();
    XTime_GetTime(&t0);
    for (unsigned l = 0; l < nl; l++) launch(PC_MLP, p[l], batch * npad[l], 0);
    XTime_GetTime(&t1);
    invalidate_all();

    /* A53: the same layers, one image at a time */
    uint8_t *act = alloc(batch * 256), *nxt = alloc(batch * 256);
    int32_t *logit = alloc(4u * batch * npad[nl - 1]);
    XTime_GetTime(&t2);
    const uint8_t *src = x0;
    for (unsigned l = 0; l < nl; l++) {
        int last = (l == nl - 1);
        for (uint32_t b = 0; b < batch; b++)
            for (uint32_t n = 0; n < npad[l]; n++) {
                int32_t acc = 0;
                for (uint32_t kk = 0; kk < k[l]; kk++)
                    acc += (int32_t)(int8_t)src[b * k[l] + kk] *
                           w[l][((kk / 4) * npad[l] + n) * 4 + kk % 4];
                if (last) {
                    logit[b * npad[l] + n] = acc;
                } else {
                    float v = fmaf((float)acc, scale, zp);
                    v = v > 127.0f ? 127.0f : (v < 0.0f ? 0.0f : v);
                    nxt[b * npad[l] + n] = (uint8_t)(int32_t)v;
                }
            }
        if (!last) {
            for (uint32_t i = 0; i < batch * npad[l]; i++) act[i] = nxt[i];
            src = act;
        }
    }
    XTime_GetTime(&t3);
    unsigned e = diff((uint32_t *)out[nl - 1], (uint32_t *)logit, batch * npad[nl - 1]);
    report("mlp", batch, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Suite ──────────────────────────────────────────────────────────────────── */
static void load(uint32_t pc, const uint32_t *w, unsigned n)
{
    for (unsigned i = 0; i < n; i++) wr(IRAM + pc + 4u * i, w[i]);
}

#define RUN(call) do { arena_reset(); run_cycles = run_hits = run_miss = 0; errs += (call); } while (0)

unsigned run_apps(void)
{
    unsigned errs = 0;
    load(PC_GEMM,     k_gemm,     sizeof k_gemm / 4u);
    load(PC_SPMV,     k_spmv,     sizeof k_spmv / 4u);
    load(PC_STENCIL,  k_stencil,  sizeof k_stencil / 4u);
    load(PC_KMEANS,   k_kmeans,   sizeof k_kmeans / 4u);
    load(PC_BFS,      k_bfs,      sizeof k_bfs / 4u);
    load(PC_SCAN,     k_scan,     sizeof k_scan / 4u);
    load(PC_SCAN_ADD, k_scan_add, sizeof k_scan_add / 4u);
    load(PC_MLP,      k_mlp,      sizeof k_mlp / 4u);

    RUN(app_gemm(64));          RUN(app_gemm(256));
    RUN(app_spmv(4096, 16));    RUN(app_spmv(65536, 16));
    RUN(app_stencil(128, 4));   RUN(app_stencil(512, 4));
    RUN(app_kmeans(16384, 16)); RUN(app_kmeans(262144, 16));
    RUN(app_bfs(16384, 8));     RUN(app_bfs(262144, 8));
    RUN(app_scan(65536));       RUN(app_scan(1u << 20));
    RUN(app_mlp(16));           RUN(app_mlp(256));
    return errs;
}
