/*
 * ak_main.c - the RISC-V program of the Ara/CVA6 benchmarks (crt0.S of Ara's apps
 * calls main; the return value goes to the exit register).
 *
 * Board build: main reads the mailbox the A53 wrote (ak.h), runs one kernel between
 * two fences (CVA6 waits until Ara is idle), with the SoC's hardware counter enabled
 * (hw_cnt_en_reg -> the wrapper's HWCNT) and the cycle counter read around it (crt0
 * enters main in user mode: the user-level cycle CSR, enabled by crt0), returns 0.
 *
 * AK_SELFTEST build (Verilator, rtl/ara_ps_top.sv model with a 1 MB DDR): every
 * application on small inputs, built here with the same generator; the vector
 * result is compared with the scalar result (the A53 reference loop) word for word.
 * Prints one line per application; returns the number of errors.
 */
#include "ak.h"
#if defined(AK_QEMU)          /* AK_SELFTEST under qemu-riscv64 (reference RVV model) */
#include <stdio.h>
static volatile uint64_t hw_cnt_en_reg, eoc_address_reg;
static inline uint64_t cycles(void) { __asm__ volatile("fence" ::: "memory"); return 0; }
#else
#ifdef AK_SELFTEST
#include "printf.h"
#endif

extern volatile uint64_t hw_cnt_en_reg;   /* 0xD000_0020 (link.ld) */

static inline uint64_t cycles(void)
{
    uint64_t c;
    __asm__ volatile("fence; csrr %0, cycle" : "=r"(c) :: "memory");
    return c;
}
#endif

static uint64_t run(uint32_t app, uint32_t mode, const uint32_t *args)
{
    ak_fn f = (mode ? ak_vector : ak_scalar)[app];
#ifdef AK_SELFTEST
    printf("RUN %u %u\n", (unsigned)app, (unsigned)mode);   /* progress (the UART is read at the end) */
#endif
    hw_cnt_en_reg = 1;
    uint64_t c0 = cycles();
    f(args);
    uint64_t c1 = cycles();
    hw_cnt_en_reg = 0;
    return c1 - c0;
}

#ifndef AK_SELFTEST
int main(void)
{
    volatile struct ak_mb *mb = AKP(volatile struct ak_mb, AK_MB_HOST);
    uint32_t args[AK_NARGS];
    if (mb->magic != AK_MAGIC || mb->app == 0 || mb->app >= AK_NAPPS || mb->mode > 1) return 2;
    for (unsigned i = 0; i < AK_NARGS; i++) args[i] = mb->args[i];
    mb->cycles = run(mb->app, mb->mode, args);
    mb->done = 1;
    __asm__ volatile("fence" ::: "memory");
    return 0;
}
#else

/* ── bump allocator over a static pool (crt0 does not clear .bss: every buffer is
   written before it is read) ─────────────────────────────────────────────────── */
static uint8_t pool[600 * 1024] __attribute__((aligned(64)));
static uint32_t ptop;
static void *alloc(uint32_t bytes)
{
    ptop = (ptop + 63u) & ~63u;
    void *p = pool + ptop;
    ptop += bytes;
    if (ptop > sizeof pool) { printf("pool overflow\n"); for (;;) ; }
    return p;
}
static uint32_t *alloc_u32(uint32_t n) { return (uint32_t *)alloc(4u * n); }
static uint32_t H(const void *p) { return (uint32_t)((uintptr_t)p - AK_OFS); }   /* host address */

static uint32_t rng = 2027u;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static float rnd_f32(void) { return (float)(int32_t)(rnd() >> 8) * (1.0f / 8388608.0f) - 1.0f; }
static uint32_t f2u(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }
static void fill(void *p, uint8_t b, uint32_t n) { for (uint32_t i = 0; i < n; i++) ((uint8_t *)p)[i] = b; }
static uint32_t diffw(const void *a, const void *b, uint32_t nw)
{
    uint32_t e = 0;
    for (uint32_t i = 0; i < nw; i++) {
        uint32_t x = ((const uint32_t *)a)[i], y = ((const uint32_t *)b)[i];
        if (x != y && e++ < 4) printf("  [%u] %08x %08x\n", i, x, y);   /* first mismatches */
    }
    return e;
}

static unsigned total;

/* crt0's trap vector jumps here (weak symbol) instead of exiting with mcause alone:
   print the cause, the PC and mtval (the instruction, for an illegal one), then exit
   with the cause as crt0's _fail does. */
#ifndef AK_QEMU
extern volatile uint64_t eoc_address_reg;
void mtvec_handler(void)
{
    uint64_t cause, epc, tval;
    __asm__ volatile("csrr %0, mcause; csrr %1, mepc; csrr %2, mtval" : "=r"(cause), "=r"(epc), "=r"(tval));
    printf("TRAP cause %u pc %x tval %x\n", (unsigned)cause, (unsigned)epc, (unsigned)tval);
    eoc_address_reg = cause;
    for (;;) ;
}
#endif
static void report(const char *app, uint32_t size, uint64_t cs, uint64_t cv, uint32_t e)
{
    printf("ST %s %u scalar %u vector %u err %u\n", app, size, (unsigned)cs, (unsigned)cv, e);
    total += e;
}

static void t_gemm(uint32_t n)
{
    float *A = alloc(4 * n * n), *B = alloc(4 * n * n), *Cs = alloc(4 * n * n), *Cv = alloc(4 * n * n);
    for (uint32_t i = 0; i < n * n; i++) { A[i] = rnd_f32(); B[i] = rnd_f32(); }
    uint32_t as[] = { H(A), H(B), H(Cs), n }, av[] = { H(A), H(B), H(Cv), n };
    uint64_t cs = run(AK_GEMM, 0, as), cv = run(AK_GEMM, 1, av);
    report("gemm", n, cs, cv, diffw(Cs, Cv, n * n));
}

static void t_spmv(uint32_t rows, uint32_t maxnnz)
{
    uint32_t *rowptr = alloc_u32(rows + 1), *col = alloc_u32(rows * maxnnz);
    float *val = alloc(4 * rows * maxnnz), *x = alloc(4 * rows), *ys = alloc(4 * rows), *yv = alloc(4 * rows);
    uint32_t nnz = 0;
    for (uint32_t r = 0; r < rows; r++) {
        rowptr[r] = nnz;
        uint32_t k = rnd() % (maxnnz + 1);
        for (uint32_t j = 0; j < k; j++) { col[nnz] = rnd() % rows; val[nnz] = rnd_f32(); nnz++; }
    }
    rowptr[rows] = nnz;
    for (uint32_t i = 0; i < rows; i++) x[i] = rnd_f32();
    uint32_t as[] = { H(rowptr), H(col), H(val), H(x), H(ys), rows };
    uint32_t av[] = { H(rowptr), H(col), H(val), H(x), H(yv), rows };
    uint64_t cs = run(AK_SPMV, 0, as), cv = run(AK_SPMV, 1, av);
    report("spmv", rows, cs, cv, diffw(ys, yv, rows));
}

static void t_stencil(uint32_t n, uint32_t sweeps)
{
    uint32_t s = n + 16, words = (n + 2) * s;
    float *g[4] = { alloc(4 * words), alloc(4 * words), alloc(4 * words), alloc(4 * words) };
    for (uint32_t i = 0; i < words; i++) g[0][i] = g[1][i] = g[2][i] = g[3][i] = rnd_f32();
    uint32_t c0 = f2u(0.5f), c1 = f2u(0.125f);
    uint32_t as[] = { H(g[0]), H(g[1]), n, s, c0, c1, sweeps }, av[] = { H(g[2]), H(g[3]), n, s, c0, c1, sweeps };
    uint64_t cs = run(AK_STENCIL, 0, as), cv = run(AK_STENCIL, 1, av);
    report("stencil", n, cs, cv, diffw(g[0], g[2], words) + diffw(g[1], g[3], words));
}

static void t_kmeans(uint32_t npts, uint32_t k)
{
    uint32_t *px = alloc_u32(npts), *py = alloc_u32(npts), *cx = alloc_u32(k), *cy = alloc_u32(k);
    uint32_t *r[2][4];
    for (int m = 0; m < 2; m++) {
        r[m][0] = alloc_u32(npts);
        for (int i = 1; i < 4; i++) r[m][i] = alloc_u32(k);
    }
    for (uint32_t i = 0; i < npts; i++) { px[i] = rnd() & 0x3FFFu; py[i] = rnd() & 0x3FFFu; }
    for (uint32_t j = 0; j < k; j++) { uint32_t q = rnd() % npts; cx[j] = px[q]; cy[j] = py[q]; }
    uint64_t c[2];
    for (int m = 0; m < 2; m++) {
        uint32_t a[] = { H(px), H(py), H(cx), H(cy), k, H(r[m][0]), H(r[m][1]), H(r[m][2]), H(r[m][3]), npts };
        c[m] = run(AK_KMEANS, m, a);
    }
    uint32_t e = diffw(r[0][0], r[1][0], npts);
    for (int i = 1; i < 4; i++) e += diffw(r[0][i], r[1][i], k);
    report("kmeans", npts, c[0], c[1], e);
}

static void t_bfs(uint32_t nv, uint32_t deg)
{
    uint32_t ne = 2 * (nv - 1) + nv * (deg - 2);
    uint32_t *eu = alloc_u32(ne), *ev = alloc_u32(ne), *rowptr = alloc_u32(nv + 1), *col = alloc_u32(ne);
    uint32_t *ls = alloc_u32(nv), *lv = alloc_u32(nv), *queue = alloc_u32(nv);
    uint32_t m = 0;
    for (uint32_t v = 1; v < nv; v++) { uint32_t u = rnd() % v; eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u; }
    while (m + 1 < ne) {
        uint32_t u = rnd() % nv, v = rnd() % nv;
        if (u == v) continue;
        eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u;
    }
    for (uint32_t v = 0; v <= nv; v++) rowptr[v] = 0;
    for (uint32_t i = 0; i < m; i++) rowptr[eu[i] + 1]++;
    for (uint32_t v = 0; v < nv; v++) rowptr[v + 1] += rowptr[v];
    for (uint32_t v = 0; v < nv; v++) queue[v] = rowptr[v];
    for (uint32_t i = 0; i < m; i++) col[queue[eu[i]]++] = ev[i];
    uint32_t as[] = { H(rowptr), H(col), H(ls), nv, H(queue) }, av[] = { H(rowptr), H(col), H(lv), nv, H(queue) };
    uint64_t cs = run(AK_BFS, 0, as), cv = run(AK_BFS, 1, av);
    report("bfs", nv, cs, cv, diffw(ls, lv, nv));
}

static void t_scan(uint32_t n)
{
    uint32_t *in = alloc_u32(n), *os = alloc_u32(n), *ov = alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) in[i] = rnd() & 0xFFFFu;
    uint32_t as[] = { H(in), H(os), n }, av[] = { H(in), H(ov), n };
    uint64_t cs = run(AK_SCAN, 0, as), cv = run(AK_SCAN, 1, av);
    report("scan", n, cs, cv, diffw(os, ov, n));
}

/* MLP with small layers: dims k0 -> d1 -> d2 -> d3 (padded to npad, as apps.c) */
/* Self-test sizes of mlp and swat; -DAK_ST_MLP_DIMS=784,256,128,10 -DAK_ST_SWAT=300,32,128
   gives the board's layer sizes and sequence lengths. */
#ifndef AK_ST_MLP_DIMS
#define AK_ST_MLP_DIMS 64, 256, 32, 10
#endif
#ifndef AK_ST_MLP_BATCH
#define AK_ST_MLP_BATCH 2
#endif
#ifndef AK_ST_SWAT
#define AK_ST_SWAT 300, 8, 12
#endif
static void t_mlp(uint32_t batch)
{
    static const uint32_t d[] = { AK_ST_MLP_DIMS };
    const uint32_t nl = 3;
    uint32_t *dims = alloc_u32(8);
    uint32_t k[3], np[3];
    k[0] = d[0];
    int8_t *wkn[3], *wT[3];
    for (uint32_t l = 0; l < nl; l++) {
        np[l] = 8;
        while (np[l] < d[l + 1]) np[l] <<= 1;
        wkn[l] = alloc(k[l] * np[l]);
        wT[l] = alloc(k[l] * np[l]);
        for (uint32_t kk = 0; kk < k[l]; kk++)
            for (uint32_t n = 0; n < np[l]; n++) {
                int8_t w = (n < d[l + 1]) ? (int8_t)((int32_t)(rnd() % 128u) - 64) : 0;
                wkn[l][kk * np[l] + n] = w;
                wT[l][n * k[l] + kk] = w;
            }
        if (l + 1 < nl) k[l + 1] = np[l];
        dims[l] = k[l]; dims[4 + l] = np[l];
    }
    uint8_t *x0 = alloc(batch * k[0]);
    for (uint32_t i = 0; i < batch * k[0]; i++) x0[i] = rnd() & 0x7Fu;
    uint8_t *act[2], *nxt[2];
    int32_t *lg[2];
    uint64_t c[2];
    for (int m = 0; m < 2; m++) {
        act[m] = alloc(batch * 256); nxt[m] = alloc(batch * 256); lg[m] = alloc(4 * batch * np[nl - 1]);
        const int8_t **w = m ? (const int8_t **)wkn : (const int8_t **)wT;
        uint32_t a[] = { H(x0), batch, nl, H(dims), H(w[0]), H(w[1]), H(w[2]), H(act[m]), H(nxt[m]), H(lg[m]),
                         f2u(1.0f / 1024.0f), f2u(3.0f) };
        c[m] = run(AK_MLP, m, a);
    }
    report("mlp", batch, c[0], c[1], diffw(lg[0], lg[1], batch * np[nl - 1]));
}

static void t_conv(uint32_t n)
{
    static const uint32_t ch[] = { 8, 12, 8 };
    const uint32_t wp = n + 2, rows = n + 2;
    int8_t *xs[3], *xv[3], *wt[2];
    for (unsigned l = 0; l < 3; l++) {
        xs[l] = alloc(rows * wp * ch[l]); xv[l] = alloc(rows * wp * ch[l]);
        fill(xs[l], 0, rows * wp * ch[l]); fill(xv[l], 0, rows * wp * ch[l]);
    }
    for (uint32_t r = 1; r <= n; r++)
        for (uint32_t x = 1; x <= n; x++)
            for (uint32_t c = 0; c < ch[0]; c++) {
                int8_t v = (int8_t)(rnd() & 0x7Fu);
                xs[0][(r * wp + x) * ch[0] + c] = v;
                xv[0][(r * ch[0] + c) * wp + x] = v;
            }
    for (unsigned l = 0; l < 2; l++) {
        wt[l] = alloc(ch[l + 1] * 9u * ch[l]);
        for (uint32_t i = 0; i < ch[l + 1] * 9u * ch[l]; i++) wt[l][i] = (int8_t)((int32_t)(rnd() % 128u) - 64);
    }
    uint32_t sc = f2u(1.0f / 1024.0f), zp = f2u(3.0f);
    uint32_t as[] = { H(xs[0]), H(xs[1]), H(xs[2]), H(wt[0]), H(wt[1]), n, ch[0], ch[1], ch[2], sc, zp };
    uint32_t av[] = { H(xv[0]), H(xv[1]), H(xv[2]), H(wt[0]), H(wt[1]), n, ch[0], ch[1], ch[2], sc, zp };
    uint64_t cs = run(AK_CONV, 0, as), cv = run(AK_CONV, 1, av);
    uint32_t e = 0;
    for (unsigned l = 1; l < 3; l++)
        for (uint32_t r = 0; r < rows; r++)
            for (uint32_t x = 0; x < wp; x++)
                for (uint32_t c = 0; c < ch[l]; c++)
                    if (xs[l][(r * wp + x) * ch[l] + c] != xv[l][(r * ch[l] + c) * wp + x] && e++ < 6)
                        printf("  l%u r%u x%u c%u: %d %d\n", l, r, x, c, xs[l][(r * wp + x) * ch[l] + c],
                               xv[l][(r * ch[l] + c) * wp + x]);
    for (unsigned l = 1; l < 3 && e; l++) {          /* error map: per output channel */
        printf("  l%u errors per channel:", l);
        for (uint32_t c = 0; c < ch[l]; c++) {
            uint32_t ec = 0;
            for (uint32_t r = 0; r < rows; r++)
                for (uint32_t x = 0; x < wp; x++)
                    ec += xs[l][(r * wp + x) * ch[l] + c] != xv[l][(r * ch[l] + c) * wp + x];
            printf(" %u", ec);
        }
        printf("\n");
    }
    report("conv8", n, cs, cv, e);
}

static void t_embag(uint32_t nrows, uint32_t bags, uint32_t k)
{
    const uint32_t D = AK_EMBAG_D;
    float *t = alloc(4 * nrows * D), *os = alloc(4 * bags * D), *ov = alloc(4 * bags * D);
    uint32_t *idx = alloc_u32(bags * k);
    for (uint32_t i = 0; i < nrows * D; i++) t[i] = rnd_f32();
    for (uint32_t i = 0; i < bags * k; i++) idx[i] = rnd() % nrows;
    uint32_t as[] = { H(t), H(idx), H(os), bags, k }, av[] = { H(t), H(idx), H(ov), bags, k };
    uint64_t cs = run(AK_EMBAG, 0, as), cv = run(AK_EMBAG, 1, av);
    report("embag", bags, cs, cv, diffw(os, ov, bags * D));
}

static void t_hashj(uint32_t s, uint32_t nprobe)
{
    const uint32_t nslot = 1u << s, mask = nslot - 1u, nins = nslot / 2u;
    uint32_t *slot = alloc_u32(2u * nslot), *ins = alloc_u32(nins);
    uint32_t *key = alloc_u32(nprobe), *os = alloc_u32(nprobe), *ov = alloc_u32(nprobe);
    for (uint32_t i = 0; i < 2u * nslot; i++) slot[i] = 0;
    for (uint32_t i = 0; i < nins; ) {
        uint32_t kk = rnd(), h = (kk * 0x9E3779B1u) >> (32u - s);
        if (kk == 0) continue;
        while (slot[2u * h] && slot[2u * h] != kk) h = (h + 1u) & mask;
        if (slot[2u * h] == kk) continue;
        slot[2u * h] = kk; slot[2u * h + 1u] = rnd() >> 1; ins[i++] = kk;
    }
    for (uint32_t i = 0; i < nprobe; i++) {
        uint32_t r = rnd();
        key[i] = (r & 1u) ? ins[(r >> 1) % nins] : (rnd() | 1u);
    }
    uint32_t as[] = { H(slot), H(key), H(os), nprobe, s }, av[] = { H(slot), H(key), H(ov), nprobe, s };
    uint64_t cs = run(AK_HASHJ, 0, as), cv = run(AK_HASHJ, 1, av);
    report("hashj", s, cs, cv, diffw(os, ov, nprobe));
}

static void t_mandel(uint32_t n, uint32_t m)
{
    uint32_t *os = alloc_u32(n * n), *ov = alloc_u32(n * n);
    uint32_t x0 = f2u(-2.0f), y0 = f2u(-1.25f), d = f2u(2.5f / (float)n);
    uint32_t as[] = { H(os), n, x0, y0, d, m }, av[] = { H(ov), n, x0, y0, d, m };
    uint64_t cs = run(AK_MANDEL, 0, as), cv = run(AK_MANDEL, 1, av);
    report("mandel", n, cs, cv, diffw(os, ov, n * n));
}

static void t_swat(uint32_t pairs, uint32_t lq, uint32_t lt)
{
    uint8_t *qs = alloc(pairs * lq), *ts = alloc(pairs * lt), *qv = alloc(pairs * lq), *tv = alloc(pairs * lt);
    uint32_t *os = alloc_u32(pairs), *ov = alloc_u32(pairs);
    int16_t *scr = alloc(2u * lq * 256u * 2u);
    for (uint32_t i = 0; i < pairs * lq; i++) qs[i] = rnd() & 3u;
    for (uint32_t i = 0; i < pairs * lt; i++) ts[i] = rnd() & 3u;
    for (uint32_t p = 0; p < pairs; p++) {
        for (uint32_t i = 0; i < lq; i++) qv[i * pairs + p] = qs[p * lq + i];
        for (uint32_t j = 0; j < lt; j++) tv[j * pairs + p] = ts[p * lt + j];
    }
    uint32_t as[] = { H(qs), H(ts), H(os), pairs, lq, lt, 0 }, av[] = { H(qv), H(tv), H(ov), pairs, lq, lt, H(scr) };
    uint64_t cs = run(AK_SWAT, 0, as), cv = run(AK_SWAT, 1, av);
    report("swat", pairs, cs, cv, diffw(os, ov, pairs));
}

#include "s2_ref.h"
#include "ak_st_s2.inc"
#include "rd_ref.h"
#include "ak_st_rd.inc"
#include "rv_ref.h"
#include "ak_st_rv.inc"

/* bit (app - 1): which applications to test; 64 bits (the RiVEC apps are bits 27-33) */
#ifndef AK_ST_MASK
#define AK_ST_MASK ((1ull << (AK_NAPPS - 1)) - 1ull)
#endif
#define T(app, call) do { if ((unsigned long long)(AK_ST_MASK) & (1ull << ((app) - 1))) { ptop = 0; call; } } while (0)

int main(void)
{
    printf("AK selftest\n");
    T(AK_GEMM, t_gemm(18));
    T(AK_SPMV, t_spmv(300, 16));
    T(AK_STENCIL, t_stencil(24, 3));
    T(AK_KMEANS, t_kmeans(600, 16));
    T(AK_BFS, t_bfs(700, 8));
    T(AK_SCAN, t_scan(1500));
    T(AK_MLP, t_mlp(AK_ST_MLP_BATCH));
    T(AK_CONV, t_conv(6));
    T(AK_EMBAG, t_embag(200, 10, 5));
    T(AK_HASHJ, t_hashj(10, 300));
    T(AK_MANDEL, t_mandel(20, 40));
    T(AK_SWAT, t_swat(AK_ST_SWAT));
    T(AK_PATHFINDER, t_pathfinder(8, 300));
    T(AK_HOTSPOT, t_grid(1, 32, 3));
    T(AK_JACOBI2D, t_grid(0, 32, 2));
    T(AK_ATAX, t_mv(0, 72));
    T(AK_BICG, t_mv(1, 72));
    T(AK_PAGERANK, t_graph(1, 300, 6));
    T(AK_CC, t_graph(0, 300, 6));
    T(AK_BACKPROP, t_backprop(96));
    T(AK_SORT, t_sort(2048, 64));
    T(AK_BLACKSCHOLES, t_blackscholes(150));
    T(AK_RD_HOTSPOT, t_rd_hotspot(24, 2));
    T(AK_RD_NN, t_rd_nn(300));
    T(AK_RD_HOTSPOT3D, t_rd_hotspot3d(20, 4, 2));
    T(AK_RD_GAUSSIAN, t_rd_gaussian(40));
    T(AK_RD_KMEANS, t_rd_kmeans(300, 5, 34));
    T(AK_RV_AXPY, t_rv_axpy(1000));
    T(AK_RV_MATMUL, t_rv_matmul(12, 20, 150));
    T(AK_RV_SPMV, t_rv_spmv(150, 140));
    T(AK_RV_JACOBI, t_rv_jacobi(40, 2));
    T(AK_RV_PATHFINDER, t_rv_pathfinder(20, 150, 2));
    T(AK_RV_BS, t_rv_bs(300));
#ifndef AK_ST_LAVA_HOME
#define AK_ST_LAVA_HOME 8            /* home boxes of 2^3 (QEMU: all; the Ara model: -D... 1) */
#endif
    T(AK_RV_LAVAMD, t_rv_lavamd(2, AK_ST_LAVA_HOME));
#ifdef AK_RD_GAUSS_DBG
    ptop = 0; t_rd_gaussian_dbg(AK_RD_GAUSS_DBG);
#endif
    printf("AK selftest errors %u\n", total);
    return (int)total;
}
#endif
