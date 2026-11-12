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
 * If the board's power monitors answer (power.c), a second pass repeats the
 * DRAM-sized run of every application with power sampling: each phase (idle,
 * accelerator, A53 reference) is repeated for PW_US and sampled between
 * repetitions, and POWER rows replace the BOARD row. Outputs are not checked in
 * that pass (repeated sweeps and accumulations move them on).
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
#include "power.h"

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

/* Instruction-RAM byte offsets (0x000 and 0x080 hold reduce_shfl / histogram, main.c). */
#define PC_GEMM        0x200u
#define PC_SPMV        0x300u
#define PC_STENCIL     0x400u
#define PC_KMEANS      0x500u
#define PC_BFS         0x600u
#define PC_SCAN        0x700u
#define PC_SCAN_ADD    0x800u
#define PC_MLP         0x900u
#define PC_GEMM_RB     0xA00u      /* 98 words: 0xA00-0xB87 (v3) */
#define PC_SCAN_SEG    0xC00u      /* v3 segmented scan */
#define PC_SCAN_SEGADD 0xD00u
#define PC_STENCIL_RB  0x100u      /* v3 strip-mined stencil, up to 64 words */
#define PC_KMEANS_U    0xE00u      /* v3 two points per thread, up to 128 words */
#define PC_SPMV_Z      0x380u      /* v3 pointer walk + sh2add, up to 32 words (after spmv) */
/* Overlay window 0x000-0x1FF (128 words): main.c's sync kernels are done before the
   suite runs, so an application that uses the window loads its kernel there at its
   start (stencil_rb, conv8, embag, hashj). */
#define PC_OVL         0x000u
#define LANES          8u          /* the host drives the 8-lane accelerator */

#define ARENA_BASE     0x10000000u
#define ARENA_SIZE     0x10000000u
#define UNSEEN         0xFFFFFFFFu

static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(SIMT_BASE + off, v); }
static inline uint32_t rd(uint32_t off)         { return Xil_In32(SIMT_BASE + off); }

/* SIMTIX_A53_ONLY builds the A53 references alone (sw/a53_zcu102: a board without
   the accelerator); the system counter's frequency is then measured, not
   COUNTS_PER_SECOND of the BSP. */
#ifdef SIMTIX_A53_ONLY
extern double a53_counts_per_second;
#define CPS a53_counts_per_second
#else
#define CPS ((double)COUNTS_PER_SECOND)
#endif

static double us(XTime t0, XTime t1)
{
    return (double)(t1 - t0) * 1e6 / CPS;
}

/* ── Power pass ─────────────────────────────────────────────────────────────── */
#ifdef SIMTIX_A53_ONLY
#define PW_US 6000000.0                 /* long A53 runs need more samples */
#else
#define PW_US 2000000.0                 /* each phase is repeated for this long */
#endif
static int pmode;                       /* 1 during the power pass */
static uint32_t ph_reps[PW_PHASES];
static double   ph_ms[PW_PHASES];
static int      ph_cur;
static uint32_t ph_r;
static XTime    ph_t0;

/* for (ph_begin(ph); ph_again(); ) <code>  runs the code once; in the power pass
   it repeats it for PW_US, sampling the rails after every repetition, and keeps
   the number of repetitions and the time they took. */
static void ph_begin(int ph)
{
    ph_cur = ph;
    ph_r = 0;
    pw_phase(pmode ? ph : PW_NONE);
    XTime_GetTime(&ph_t0);
}

static int ph_again(void)
{
    XTime t;
#ifdef SIMTIX_A53_ONLY
    if (ph_cur == PW_ACCEL) return 0;   /* no accelerator: skip its phase */
#endif
    if (ph_r++ == 0) return 1;
    if (!pmode) return 0;
    pw_sample();
    XTime_GetTime(&t);
    if (us(ph_t0, t) < PW_US) return 1;
    pw_phase(PW_NONE);
    ph_reps[ph_cur] = ph_r - 1;
    ph_ms[ph_cur] = us(ph_t0, t) / 1000.0;
    return 0;
}

/* Idle reference for the power pass: the A53 polls the status register, as it
   does while the accelerator runs, and the accelerator is idle. */
static void idle_phase(void)
{
    if (!pmode) return;
#ifdef SIMTIX_A53_ONLY
    static volatile uint32_t poll_word;   /* the A53 polls, as it would the accelerator */
    for (ph_begin(PW_IDLE); ph_again(); ) (void)poll_word;
#else
    for (ph_begin(PW_IDLE); ph_again(); ) (void)Xil_In32(SIMT_BASE + REG_STATUS);
#endif
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
static uint64_t run_cycles;                /* 64-bit: Vortex's Rodinia kmeans (8.05e9) wrapped 32 bits */
static uint32_t run_hits, run_miss;

#ifdef SIMTIX_VORTEX
/* SIMTIX_VORTEX builds this file for Vortex 3.0 (baselines/vortex: vortex_ps_top at
   SIMT_BASE, host main_vortex.c). The kernels are Vortex ports of kernels/apps (.S)
   reading the same parameter blocks (baselines/vortex/simtix_apps/kernel.cpp), so the
   inputs, references and checks are those of the SIMTiX run. A launch programs the KMU
   DCRs, pulses START, waits for busy to clear and flushes Vortex's write-back L1 (DCR
   read of VX_DCR_BASE_CACHE_FLUSH). The v3 variants (gemm_rb, scan_seg, stencil_rb,
   kmeans_u, spmv_z) have no Vortex port: their runs draw their inputs (the generator
   stays in step) and print "VXB,<app>,<size>,skip". */
enum { VX_GEMM, VX_SPMV, VX_STENCIL, VX_KMEANS, VX_BFS, VX_SCAN, VX_SCAN_ADD, VX_MLP,
       VX_CONV8, VX_EMBAG, VX_HASHJ, VX_MANDEL, VX_SWAT,
       VX_PATHFINDER, VX_BP_FORWARD, VX_BP_ADJUST, VX_HOTSPOT_RD, VX_NN, VX_HOTSPOT3D,
       VX_GAUSS_FAN1, VX_GAUSS_FAN2, VX_KMEANS_RD };    /* Rodinia (rodinia.inc) */
#define VX_CTRL     0x00u
#define VX_START    0x04u
#define VX_STATUS   0x08u
#define VX_DCRA     0x0Cu
#define VX_DCRW     0x10u
#define VX_DCRR     0x14u
#define VX_BCYC_LO  0x1Cu
#define VX_BCYC_HI  0x20u
#define VX_ARGS_VA  0x00010000u            /* kernel_arg_t, Vortex address (window 0) */
#define VX_ARGS_DDR 0x40010000u            /* the same, DDR address (vortex_ps_top) */
#define VX_THREADS  8u                     /* threads per warp */
static uint32_t vx_img_base, vx_main_pc, run_flush;
static int vx_ovl_app = -1, vx_skip;
static int vx_rodinia;                     /* run_rodinia(): suite 2 + Rodinia kernel PCs */
static int vx_app_of_rd(uint32_t pc);      /* after rodinia.inc's kernels_rd.h */
void vx_set_image(uint32_t base, uint32_t main_pc) { vx_img_base = base; vx_main_pc = main_pc; }

static int vx_app_of(uint32_t pc)
{
    if (vx_rodinia) return vx_app_of_rd(pc);
    switch (pc) {
    case PC_GEMM: return VX_GEMM;          case PC_SPMV: return VX_SPMV;
    case PC_STENCIL: return VX_STENCIL;    case PC_KMEANS: return VX_KMEANS;
    case PC_BFS: return VX_BFS;            case PC_SCAN: return VX_SCAN;
    case PC_SCAN_ADD: return VX_SCAN_ADD;  case PC_MLP: return VX_MLP;
    case PC_OVL: return vx_ovl_app;
    default: return -1;                    /* the v3 variants */
    }
}

static void vx_dcr(uint32_t a, uint32_t v) { wr(VX_DCRA, a); wr(VX_DCRW, v); }
static uint64_t vx_busycyc(void)
{
    uint32_t lo = rd(VX_BCYC_LO);
    return ((uint64_t)rd(VX_BCYC_HI) << 32) | lo;
}

/* One launch: n threads in blocks of 32 (scan: its 2^blk-warp blocks with 4 bytes of
   local memory per warp, as baselines/vortex/simtix_apps/main.cpp). Returns the busy
   cycles of the kernel; the flush's go to run_flush. */
static uint32_t vx_launch(int app, uint32_t params, uint32_t n, uint32_t blk)
{
    uint32_t block = (app == VX_SCAN) ? (VX_THREADS << blk) : 32u;
    if (app == VX_SCAN) while (n % block) block >>= 1;
    else if (n < block) block = n;              /* the last block may be part-full: kernel_main skips t >= n */
    volatile uint32_t *arg = (volatile uint32_t *)(uintptr_t)VX_ARGS_DDR;
    arg[0] = (uint32_t)app; arg[1] = params; arg[2] = n;
    Xil_DCacheFlushRange((INTPTR)VX_ARGS_DDR, 64);
    vx_dcr(0x010, vx_img_base); vx_dcr(0x011, 0);          /* KMU_STARTUP_ADDR0/1 */
    vx_dcr(0x012, vx_main_pc);  vx_dcr(0x013, 0);          /* KMU_KERNEL_ENTRY0/1 */
    vx_dcr(0x014, VX_ARGS_VA);  vx_dcr(0x015, 0);          /* KMU_STARTUP_ARG0/1 */
    vx_dcr(0x016, block); vx_dcr(0x017, 1); vx_dcr(0x018, 1);       /* BLOCK_DIM */
    vx_dcr(0x019, (n + block - 1) / block); vx_dcr(0x01A, 1); vx_dcr(0x01B, 1);   /* GRID_DIM */
    vx_dcr(0x01C, app == VX_SCAN ? (block / VX_THREADS) * 4u : 0u); /* LMEM_SIZE */
    vx_dcr(0x01D, block);                                           /* BLOCK_SIZE */
    vx_dcr(0x01E, VX_THREADS % block); vx_dcr(0x01F, 0); vx_dcr(0x020, 0);  /* WARP_STEP */
    vx_dcr(0x021, 1); vx_dcr(0x022, 1); vx_dcr(0x023, 1);          /* CLUSTER_DIM */
    uint64_t b0 = vx_busycyc();
    wr(VX_START, 1);
    while (rd(VX_STATUS) & 1u)
        if (pmode) pw_sample();
    uint64_t b1 = vx_busycyc();
    wr(VX_DCRA, 0x000); wr(VX_DCRR, 0);                    /* CACHE_FLUSH, core 0 */
    while ((rd(VX_STATUS) & 3u) != 2u) ;
    uint64_t b2 = vx_busycyc();
    run_flush += (uint32_t)(b2 - b1);
    return (uint32_t)(b1 - b0);
}
#endif

static void launch(uint32_t pc, const uint32_t *params, uint32_t n, uint32_t blk)
{
#ifdef SIMTIX_A53_ONLY
    (void)pc; (void)params; (void)n; (void)blk;
    return;
#endif
#ifdef SIMTIX_VORTEX
    int app = vx_app_of(pc);
    if (app < 0) { vx_skip = 1; return; }
    run_cycles += vx_launch(app, addr(params), n, blk);
    return;
#endif
    wr(REG_KERNEL_PC, pc);
    wr(REG_BASE_A, addr(params));
    wr(REG_N, n);
    wr(REG_BLOCK, blk);
    wr(REG_CTRL, 1);
    while (!(rd(REG_STATUS) & 1u))
        if (pmode) pw_sample();
    run_cycles += rd(REG_CYCLES);
    run_hits   += rd(REG_L1_HITS);
    run_miss   += rd(REG_L1_MISSES);
}

static uint32_t *params(unsigned n) { return alloc_u32(n); }

static void load(uint32_t pc, const uint32_t *w, unsigned n);

static void report(const char *app, uint32_t size, double acc_us, double cpu_us, unsigned errs)
{
#ifdef SIMTIX_VORTEX
    if (pmode) { if (!vx_skip) pw_report(app, size, ph_reps, ph_ms); return; }
#else
    if (pmode) { pw_report(app, size, ph_reps, ph_ms); return; }
#endif
#ifdef SIMTIX_A53_ONLY
    /* No accelerator output to check. The FNV-1a hash of the arena (inputs and
       the A53 results) shows that two builds compute the same results. */
    (void)acc_us; (void)errs;
    uint32_t h = 2166136261u;
    for (const volatile uint32_t *q = (const uint32_t *)(uintptr_t)ARENA_BASE;
         (uintptr_t)q < top; q++)
        h = (h ^ *q) * 16777619u;
    unsigned u10 = (unsigned)(cpu_us * 10.0 + 0.5);
    xil_printf("A53,%s,%u,%u.%u,%08x\r\n", app, size, u10 / 10, u10 % 10, h);
    return;
#endif
    unsigned long long a10 = (unsigned long long)(acc_us * 10.0 + 0.5);
    unsigned long long c10 = (unsigned long long)(cpu_us * 10.0 + 0.5);
#ifdef SIMTIX_VORTEX
    /* VXB,<app>,<size>,<kernel cycles>,<accel us (incl. flushes)>,<a53 us>,<flush cycles>,0,<errors> */
    if (vx_skip) { xil_printf("VXB,%s,%u,skip\r\n", app, size); return; }
    xil_printf("VXB,%s,%u,%llu,%llu.%llu,%llu.%llu,%u,0,%u\r\n", app, size, (unsigned long long)run_cycles,
               a10 / 10, a10 % 10, c10 / 10, c10 % 10, run_flush, errs);
    return;
#endif
    xil_printf("BOARD,%s,%u,%llu,%llu.%llu,%llu.%llu,%u,%u,%u\r\n", app, size, (unsigned long long)run_cycles,
               a10 / 10, a10 % 10, c10 / 10, c10 % 10, run_hits, run_miss, errs);
}

static unsigned diff(const uint32_t *a, const uint32_t *b, size_t n)
{
    unsigned e = 0;
    for (size_t i = 0; i < n; i++) e += (a[i] != b[i]);
    return e;
}

/* ── GEMM: C = A * B, FP32, n x n ───────────────────────────────────────────── */
/* blocked: gemm_rb.S (v3), a 4x4 block of C per thread; same FMA order over k, so
   the same reference applies bit for bit. */
static unsigned app_gemm(uint32_t n, int blocked)
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
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        launch(blocked ? PC_GEMM_RB : PC_GEMM, p, blocked ? n * n / 16u : n * n, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
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
    report(blocked ? "gemmrb" : "gemm", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── SpMV: y = M x, CSR, FP32 ───────────────────────────────────────────────── */
static unsigned app_spmv(uint32_t rows, uint32_t maxnnz, int zba)
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
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        launch(zba ? PC_SPMV_Z : PC_SPMV, p, rows, 0);   /* zba: spmv_z.S */
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
        for (uint32_t r = 0; r < rows; r++) {
            float acc = 0.0f;
            for (uint32_t j = rowptr[r]; j < rowptr[r + 1]; j++) acc = fmaf(val[j], x[col[j]], acc);
            ref[r] = acc;
        }
    XTime_GetTime(&t3);
    unsigned e = diff((uint32_t *)y, (uint32_t *)ref, rows);
    report(zba ? "spmvz" : "spmv", rows, us(t0, t1), us(t2, t3), e);
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

static unsigned app_stencil(uint32_t n, uint32_t sweeps, uint32_t rows)
{
    XTime t0, t1, t2, t3;
    uint32_t s = n + 16, words = (n + 2) * s, lg = 0;
    while ((1u << lg) < n) lg++;
    float *g[2] = { alloc(4u * words), alloc(4u * words) };
    float *r[2] = { alloc(4u * words), alloc(4u * words) };
    const float c0 = 0.5f, c1 = 0.125f;
    if (rows) load(PC_STENCIL_RB, k_stencil_rb, sizeof k_stencil_rb / 4u);   /* overlay window */
    for (uint32_t i = 0; i < words; i++) g[0][i] = g[1][i] = r[0][i] = r[1][i] = rnd_f32();
    uint32_t *p[16];
    for (uint32_t t = 0; t < sweeps && t < 16; t++) {
        p[t] = params(7);
        p[t][0] = addr(g[t % 2]); p[t][1] = addr(g[(t + 1) % 2]);
        p[t][2] = lg; p[t][3] = s; p[t][4] = f2u(c0); p[t][5] = f2u(c1); p[t][6] = rows;
    }
    clean_all();
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        for (uint32_t t = 0; t < sweeps && t < 16; t++)   /* rows: stencil_rb.S, a strip per thread */
            launch(rows ? PC_STENCIL_RB : PC_STENCIL, p[t], rows ? n / rows * n : n * n, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
        for (uint32_t t = 0; t < sweeps && t < 16; t++)
            stencil_ref(r[t % 2], r[(t + 1) % 2], n, s, c0, c1);
    XTime_GetTime(&t3);
    unsigned e = diff((uint32_t *)g[sweeps % 2], (uint32_t *)r[sweeps % 2], words);
    report(rows ? "stencilrb" : "stencil", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── k-means: assignment + accumulation, integer 2-D points ─────────────────── */
static unsigned app_kmeans(uint32_t npts, uint32_t k, uint32_t two)
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
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        launch(two ? PC_KMEANS_U : PC_KMEANS, p, two ? npts / 2u : npts, 0);   /* two: kmeans_u.S */
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); ) {
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
    }
    XTime_GetTime(&t3);
    unsigned e = diff(as, ras, npts) + diff(sx, rsx, k) + diff(sy, rsy, k) + diff(cn, rcn, k);
    report(two ? "kmeansu" : "kmeans", npts, us(t0, t1), us(t2, t3), e);
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
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        for (uint32_t L = 0; L < 64; L++) {
            launch(PC_BFS, p[L], nv, 0);
            Xil_DCacheInvalidateRange((INTPTR)flag[L], 32);
            if (!flag[L][0]) break;
        }
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); ) {
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

/* v3 segmented scan (scan_seg.S + scan_segadd.S): one warp scans a segment of
   r*LANES words, r = 64 rows at most; the segment totals are scanned the same way,
   then added. As sim/gen_apps.py scanseg(). */
static uint32_t *seg_level(const uint32_t *src, uint32_t m)
{
    uint32_t r = (m / LANES < 64u) ? m / LANES : 64u;
    while (m % (r * LANES)) r /= 2u;
    uint32_t nseg = m / (r * LANES), ntp = (nseg + LANES - 1u) / LANES * LANES;
    uint32_t *out = alloc_u32(m), *tot = alloc_u32(ntp);
    for (uint32_t i = 0; i < ntp; i++) tot[i] = 0;
    uint32_t *p = params(4);
    p[0] = addr(src); p[1] = addr(out); p[2] = addr(tot); p[3] = r;
    plan[nplan++] = (struct step){ PC_SCAN_SEG, LANES * nseg, 0, p };
    if (nseg > 1) {
        uint32_t *tsc = seg_level(tot, ntp);
        uint32_t *q = params(3);
        q[0] = addr(out); q[1] = addr(tsc); q[2] = r;
        plan[nplan++] = (struct step){ PC_SCAN_SEGADD, LANES * nseg, 0, q };
    }
    return out;
}

static unsigned app_scan(uint32_t n, int seg)
{
    XTime t0, t1, t2, t3;
    uint32_t *in = alloc_u32(n), *ref = alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) in[i] = rnd() & 0xFFFFu;
    nplan = 0;
    uint32_t *out = seg ? seg_level(in, n) : scan_level(in, n);
    clean_all();
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        for (unsigned s = 0; s < nplan; s++) launch(plan[s].pc, plan[s].p, plan[s].n, plan[s].blk);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); ) {
        uint32_t acc = 0;
        for (uint32_t i = 0; i < n; i++) { acc += in[i]; ref[i] = acc; }
    }
    XTime_GetTime(&t3);
    unsigned e = diff(out, ref, n);
    report(seg ? "scanseg" : "scan", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── MLP: INT8 fully connected layers, ReLU between, INT32 logits ───────────── */
/* Layer l: acc = x . W (pdot8 on the accelerator); hidden layers requantize to
   rne(clamp(fmaf((float)acc, scale, zp), 0, 127)), rounding half to even. Columns
   are padded to Npad, a power of two of at least 8; each image's activations are
   Npad bytes. */
static uint8_t rne_u8(float v)          /* 0 <= v <= 127 */
{
    int32_t i = (int32_t)v;
    float   f = v - (float)i;           /* exact */
    if (f > 0.5f || (f == 0.5f && (i & 1))) i++;
    return (uint8_t)i;
}

static unsigned app_mlp(uint32_t batch)
{
    static const uint32_t dims[] = { 784, 256, 128, 10 };
    const unsigned nl = sizeof dims / sizeof dims[0] - 1;
    const float scale = 1.0f / 1024.0f, zp = 3.0f;
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
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        for (unsigned l = 0; l < nl; l++) launch(PC_MLP, p[l], batch * npad[l], 0);
    XTime_GetTime(&t1);
    invalidate_all();

    /* A53: the same layers, one image at a time */
    uint8_t *act = alloc(batch * 256), *nxt = alloc(batch * 256);
    int32_t *logit = alloc(4u * batch * npad[nl - 1]);
    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); ) {
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
                        nxt[b * npad[l] + n] = rne_u8(v);
                    }
                }
            if (!last) {
                for (uint32_t i = 0; i < batch * npad[l]; i++) act[i] = nxt[i];
                src = act;
            }
        }
    }
    XTime_GetTime(&t3);
    unsigned e = diff((uint32_t *)out[nl - 1], (uint32_t *)logit, batch * npad[nl - 1]);
    report("mlp", batch, us(t0, t1), us(t2, t3), e);

    /* A second A53 reference with the weights the usual CPU way, one contiguous row
       of k bytes per output (wT[n][k]), so the dot product is a contiguous INT8 loop
       that GCC vectorizes at -O3. Printed as A53T,mlp,<batch>,<us>,<errors>. */
    if (!pmode) {
        int8_t *wT[3];
        for (unsigned l = 0; l < nl; l++) {
            wT[l] = alloc(k[l] * npad[l]);
            for (uint32_t n = 0; n < npad[l]; n++)
                for (uint32_t kk = 0; kk < k[l]; kk++)
                    wT[l][n * k[l] + kk] = w[l][((kk / 4) * npad[l] + n) * 4 + kk % 4];
        }
        int32_t *logit2 = alloc(4u * batch * npad[nl - 1]);
        XTime t4, t5;
        XTime_GetTime(&t4);
        const uint8_t *src = x0;
        for (unsigned l = 0; l < nl; l++) {
            int last = (l == nl - 1);
            for (uint32_t b = 0; b < batch; b++) {
                const int8_t *xb = (const int8_t *)src + b * k[l];
                for (uint32_t n = 0; n < npad[l]; n++) {
                    const int8_t *wr_ = wT[l] + n * k[l];
                    int32_t acc = 0;
                    for (uint32_t kk = 0; kk < k[l]; kk++) acc += (int32_t)xb[kk] * wr_[kk];
                    if (last) {
                        logit2[b * npad[l] + n] = acc;
                    } else {
                        float v = fmaf((float)acc, scale, zp);
                        v = v > 127.0f ? 127.0f : (v < 0.0f ? 0.0f : v);
                        nxt[b * npad[l] + n] = rne_u8(v);
                    }
                }
            }
            if (!last) {
                for (uint32_t i = 0; i < batch * npad[l]; i++) act[i] = nxt[i];
                src = act;
            }
        }
        XTime_GetTime(&t5);
        unsigned e2 = diff((uint32_t *)logit2, (uint32_t *)logit, batch * npad[nl - 1]);
        unsigned u10 = (unsigned)(us(t4, t5) * 10.0 + 0.5);
        xil_printf("A53T,mlp,%u,%u.%u,%u\r\n", batch, u10 / 10, u10 % 10, e2);
        e += e2;
    }
    return e;
}

/* ── CNN: INT8 3x3 convolution layers 16 -> 32 -> 32 channels, n x n image ────── */
/* conv8.S: zero padding 1, stride 1, requantization with ReLU as the MLP. The
   accelerator's activations are [row][channel/4][column] words (padded); the A53
   uses the usual CPU layout, NHWC bytes with OHWI weights, so its inner loop runs
   over contiguous channels and GCC vectorizes it at -O3. Both are filled with the
   same values and every output byte is compared. */
static unsigned app_conv(uint32_t n)
{
    static const uint32_t ch[] = { 16, 32, 32 };
    enum { NL = 2 };
    const float scale = 1.0f / 1024.0f, zp = 3.0f;
    const uint32_t wp = n + 2, rows = n + 2;
    XTime t0, t1, t2, t3;
    uint32_t lgq = 0;
    while ((4u << lgq) < n) lgq++;
    load(PC_OVL, k_conv8, sizeof k_conv8 / 4u);
    uint32_t *xa[NL + 1];                     /* accelerator activations */
    int8_t   *xc[NL + 1], *wt[NL];            /* A53 activations (NHWC), weights (OHWI) */
    uint32_t *wk[NL], *p[NL];
    for (unsigned l = 0; l <= NL; l++) {
        xa[l] = alloc_u32(rows * (ch[l] / 4u) * wp);
        xc[l] = alloc(rows * wp * ch[l]);
        for (uint32_t i = 0; i < rows * (ch[l] / 4u) * wp; i++) xa[l][i] = 0;
        for (uint32_t i = 0; i < rows * wp * ch[l]; i++) xc[l][i] = 0;
    }
    for (uint32_t r = 1; r <= n; r++)
        for (uint32_t x = 1; x <= n; x++)
            for (uint32_t c = 0; c < ch[0]; c++) {
                uint8_t v = rnd() & 0x7Fu;
                xc[0][(r * wp + x) * ch[0] + c] = (int8_t)v;
                ((uint8_t *)xa[0])[4u * ((r * (ch[0] / 4u) + c / 4u) * wp + x) + c % 4u] = v;
            }
    for (unsigned l = 0; l < NL; l++) {
        uint32_t ci = ch[l], co = ch[l + 1], lgo = 0;
        while ((1u << lgo) < co) lgo++;
        wt[l] = alloc(co * 9u * ci);
        wk[l] = alloc_u32(9u * (ci / 4u) * co);
        for (uint32_t i = 0; i < co * 9u * ci; i++) wt[l][i] = (int8_t)((int32_t)(rnd() % 128u) - 64);
        for (uint32_t ky = 0; ky < 3; ky++)       /* Wt[ky][c][kx][o], 4 input channels per word */
            for (uint32_t c = 0; c < ci / 4u; c++)
                for (uint32_t kx = 0; kx < 3; kx++)
                    for (uint32_t o = 0; o < co; o++)
                        for (uint32_t i = 0; i < 4; i++)
                            ((uint8_t *)wk[l])[4u * (((ky * (ci / 4u) + c) * 3u + kx) * co + o) + i] =
                                (uint8_t)wt[l][((o * 3u + ky) * 3u + kx) * ci + 4u * c + i];
        p[l] = params(9);
        p[l][0] = addr(xa[l]); p[l][1] = addr(wk[l]); p[l][2] = addr(xa[l + 1]);
        p[l][3] = ci / 4u; p[l][4] = lgo; p[l][5] = lgq;
        p[l][6] = f2u(scale); p[l][7] = f2u(zp); p[l][8] = wp;
    }
    clean_all();
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        for (unsigned l = 0; l < NL; l++) launch(PC_OVL, p[l], n * (n / 4u) * ch[l + 1], 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
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
    unsigned e = 0;
    for (unsigned l = 1; l <= NL; l++)            /* every byte of both layers' outputs */
        for (uint32_t r = 0; r < rows; r++)
            for (uint32_t x = 0; x < wp; x++)
                for (uint32_t c = 0; c < ch[l]; c++)
                    e += ((uint8_t *)xa[l])[4u * ((r * (ch[l] / 4u) + c / 4u) * wp + x) + c % 4u] !=
                         (uint8_t)xc[l][(r * wp + x) * ch[l] + c];
    report("conv8", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Embedding bag: out[b] = sum of K rows of T (recommendation inference) ───── */
/* embag.S: D = 32 floats per row, the K rows of a bag summed in order from +0. The
   A53 adds each row into the bag's D sums (contiguous; vectorized at -O3), which
   is the same order per element. */
static unsigned app_embag(uint32_t nrows, uint32_t bags, uint32_t k)
{
    enum { D = 32, LGD = 5 };
    XTime t0, t1, t2, t3;
    load(PC_OVL, k_embag, sizeof k_embag / 4u);
    float *t = alloc(4u * nrows * D);
    uint32_t *idx = alloc_u32(bags * k);
    float *out = alloc(4u * bags * D), *ref = alloc(4u * bags * D);
    for (uint32_t i = 0; i < nrows * D; i++) t[i] = rnd_f32();
    for (uint32_t i = 0; i < bags * k; i++) idx[i] = rnd() % nrows;
    uint32_t *p = params(5);
    p[0] = addr(t); p[1] = addr(idx); p[2] = addr(out); p[3] = k; p[4] = LGD;
    clean_all();
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        launch(PC_OVL, p, bags * D, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
        for (uint32_t b = 0; b < bags; b++) {
            float *o = ref + b * D;
            for (uint32_t d = 0; d < D; d++) o[d] = 0.0f;
            for (uint32_t j = 0; j < k; j++) {
                const float *row = t + idx[b * k + j] * D;
                for (uint32_t d = 0; d < D; d++) o[d] += row[d];
            }
        }
    XTime_GetTime(&t3);
    unsigned e = diff((uint32_t *)out, (uint32_t *)ref, bags * D);
    report("embag", bags, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Hash join: probe a linear-probing table of 2^s slots (database) ────────── */
/* hashj.S: slots {key, value}, key 0 = empty, half full; half of the probe keys
   are in the table. The A53 builds the table (not timed) and probes it with the
   same loop. */
static unsigned app_hashj(uint32_t s, uint32_t nprobe)
{
    const uint32_t nslot = 1u << s, mask = nslot - 1u, nins = nslot / 2u;
    XTime t0, t1, t2, t3;
    load(PC_OVL, k_hashj, sizeof k_hashj / 4u);
    uint32_t *slot = alloc_u32(2u * nslot), *ins = alloc_u32(nins);
    uint32_t *key = alloc_u32(nprobe), *out = alloc_u32(nprobe), *ref = alloc_u32(nprobe);
    for (uint32_t i = 0; i < 2u * nslot; i++) slot[i] = 0;
    for (uint32_t i = 0; i < nins; ) {
        uint32_t kk = rnd(), h = (kk * 0x9E3779B1u) >> (32u - s);
        if (kk == 0) continue;
        while (slot[2u * h] && slot[2u * h] != kk) h = (h + 1u) & mask;
        if (slot[2u * h] == kk) continue;           /* keys are distinct */
        slot[2u * h] = kk;
        slot[2u * h + 1u] = rnd() >> 1;
        ins[i++] = kk;
    }
    for (uint32_t i = 0; i < nprobe; i++) {
        uint32_t r = rnd();
        key[i] = (r & 1u) ? ins[(r >> 1) % nins] : (rnd() | 1u);
    }
    uint32_t *p = params(5);
    p[0] = addr(slot); p[1] = addr(key); p[2] = addr(out); p[3] = 32u - s; p[4] = mask;
    clean_all();
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        launch(PC_OVL, p, nprobe, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
        for (uint32_t i = 0; i < nprobe; i++) {
            uint32_t kk = key[i], h = (kk * 0x9E3779B1u) >> (32u - s);
            while (slot[2u * h] != kk && slot[2u * h] != 0) h = (h + 1u) & mask;
            ref[i] = (slot[2u * h] == kk) ? slot[2u * h + 1u] : 0xFFFFFFFFu;
        }
    XTime_GetTime(&t3);
    unsigned e = diff(out, ref, nprobe);
    report("hashj", s, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Mandelbrot: escape-time counts, n x n image of [-2, 0.5] x [-1.25, 1.25] ── */
/* mandel.S: the same FP32 operations in the same order (one rounding each), so
   every count is compared exactly. */
static unsigned app_mandel(uint32_t n, uint32_t m)
{
    XTime t0, t1, t2, t3;
    uint32_t lg = 0;
    while ((1u << lg) < n) lg++;
    load(PC_OVL, k_mandel, sizeof k_mandel / 4u);
    const float x0 = -2.0f, y0 = -1.25f, d = 2.5f / (float)n;
    uint32_t *out = alloc_u32(n * n), *ref = alloc_u32(n * n);
    uint32_t *p = params(7);
    p[0] = addr(out); p[1] = lg; p[2] = f2u(x0); p[3] = f2u(y0); p[4] = f2u(d); p[5] = f2u(d);
    p[6] = m;
    clean_all();
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        launch(PC_OVL, p, n * n, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
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
    unsigned e = diff(out, ref, n * n);
    report("mandel", n, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Smith-Waterman: local alignment scores of DNA pairs, affine gaps ───────── */
/* swat.S: match +2, mismatch -1, gap open 3, extend 1; one pair per thread, query
   in strips of 4 rows. The A53 runs the usual one-row Gotoh loop per pair over byte
   sequences. Every score is compared. */
#define SW_NEG (-16384)
static unsigned app_swat(uint32_t pairs, uint32_t lq, uint32_t lt)
{
    XTime t0, t1, t2, t3;
    load(PC_OVL, k_swat, sizeof k_swat / 4u);
    uint8_t  *qs = alloc(pairs * lq), *ts = alloc(pairs * lt);   /* A53: pair-major bytes */
    uint32_t *tw = alloc_u32(lt * pairs), *qw = alloc_u32(lq / 4u * pairs);
    uint32_t *bnd = alloc_u32(lt * pairs), *out = alloc_u32(pairs), *ref = alloc_u32(pairs);
    for (uint32_t i = 0; i < pairs * lq; i++) qs[i] = rnd() & 3u;
    for (uint32_t i = 0; i < pairs * lt; i++) ts[i] = rnd() & 3u;
    for (uint32_t j = 0; j < lt; j++)
        for (uint32_t pp = 0; pp < pairs; pp++) tw[j * pairs + pp] = ts[pp * lt + j] * 0x55u;
    for (uint32_t s = 0; s < lq / 4u; s++)
        for (uint32_t pp = 0; pp < pairs; pp++) {
            uint32_t w = 0;
            for (uint32_t i = 0; i < 4; i++) w |= (uint32_t)qs[pp * lq + 4u * s + i] << (2u * i);
            qw[s * pairs + pp] = w;
        }
    uint32_t *p = params(7);
    p[0] = addr(tw); p[1] = addr(qw); p[2] = addr(bnd); p[3] = addr(out); p[4] = lt;
    p[5] = lq / 4u; p[6] = 4u * pairs;
    int32_t hrow[64], erow[64];
    clean_all();
    idle_phase();
    XTime_GetTime(&t0);
    for (ph_begin(PW_ACCEL); ph_again(); )
        launch(PC_OVL, p, pairs, 0);
    XTime_GetTime(&t1);
    invalidate_all();

    XTime_GetTime(&t2);
    for (ph_begin(PW_A53); ph_again(); )
        for (uint32_t pp = 0; pp < pairs; pp++) {
            const uint8_t *q = qs + pp * lq, *t = ts + pp * lt;
            int32_t best = 0;
            for (uint32_t i = 0; i < lq; i++) { hrow[i] = 0; erow[i] = SW_NEG; }
            for (uint32_t j = 0; j < lt; j++) {
                int32_t hup = 0, f = SW_NEG, diag = 0;
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
    unsigned e = diff(out, ref, pairs);
    report("swat", pairs, us(t0, t1), us(t2, t3), e);
    return e;
}

/* ── Suite ──────────────────────────────────────────────────────────────────── */
static void load(uint32_t pc, const uint32_t *w, unsigned n)
{
#ifdef SIMTIX_A53_ONLY
    (void)pc; (void)w; (void)n;
    return;
#endif
#ifdef SIMTIX_VORTEX
    /* Vortex's image holds every kernel: only note which application the overlay
       window now stands for. */
    (void)n;
    if (pc == PC_OVL)
        vx_ovl_app = (w == k_conv8) ? VX_CONV8 : (w == k_embag) ? VX_EMBAG :
                     (w == k_hashj) ? VX_HASHJ : (w == k_mandel) ? VX_MANDEL :
                     (w == k_swat) ? VX_SWAT : -1;
    return;
#endif
    for (unsigned i = 0; i < n; i++) wr(IRAM + pc + 4u * i, w[i]);
}

#ifdef SIMTIX_VORTEX
/* a run without a Vortex port (vx_skip) checks outputs nobody wrote: not an error */
#define RUN(call) do { arena_reset(); run_cycles = run_hits = run_miss = run_flush = 0; vx_skip = 0;                        unsigned e_ = (call); errs += vx_skip ? 0u : e_; vx_skip = 0; } while (0)
#define PRUN(call) do { arena_reset(); run_cycles = run_hits = run_miss = run_flush = 0; vx_skip = 0;                         (void)(call); vx_skip = 0; } while (0)
#define VARIANT(x) x                       /* run (inputs stay in step), POWER rows dropped */
#else
#define RUN(call) do { arena_reset(); run_cycles = run_hits = run_miss = 0; errs += (call); } while (0)
#define PRUN(call) do { arena_reset(); run_cycles = run_hits = run_miss = 0; (void)(call); } while (0)
#define VARIANT(x) x
#endif

static unsigned run_suite2(void);   /* suite2.inc, at the end of this file */
static unsigned run_rodinia(void);  /* rodinia.inc, at the end of this file */

unsigned run_apps(void)
{
    unsigned errs = 0;
#ifdef RD_ONLY                          /* the Rodinia suite alone (docs/rodinia_plan.md) */
    errs += run_rodinia();
    return errs;
#endif
    load(PC_GEMM,     k_gemm,     sizeof k_gemm / 4u);
    load(PC_SPMV,     k_spmv,     sizeof k_spmv / 4u);
    load(PC_STENCIL,  k_stencil,  sizeof k_stencil / 4u);
    load(PC_KMEANS,   k_kmeans,   sizeof k_kmeans / 4u);
    load(PC_BFS,      k_bfs,      sizeof k_bfs / 4u);
    load(PC_SCAN,     k_scan,     sizeof k_scan / 4u);
    load(PC_SCAN_ADD, k_scan_add, sizeof k_scan_add / 4u);
    load(PC_MLP,      k_mlp,      sizeof k_mlp / 4u);
    load(PC_GEMM_RB,     k_gemm_rb,     sizeof k_gemm_rb / 4u);
    load(PC_SCAN_SEG,    k_scan_seg,    sizeof k_scan_seg / 4u);
    load(PC_SCAN_SEGADD, k_scan_segadd, sizeof k_scan_segadd / 4u);
    _Static_assert(sizeof k_stencil_rb <= 0x100u, "stencil_rb overflows 0x100-0x1FF");
    _Static_assert(sizeof k_kmeans_u <= 0x200u, "kmeans_u overflows 0xE00-0xFFF");
    load(PC_STENCIL_RB,  k_stencil_rb,  sizeof k_stencil_rb / 4u);
    load(PC_KMEANS_U,    k_kmeans_u,    sizeof k_kmeans_u / 4u);
    _Static_assert(sizeof k_spmv <= 0x80u && sizeof k_spmv_z <= 0x80u, "spmv / spmv_z overflow 0x300-0x3FF");
    load(PC_SPMV_Z,      k_spmv_z,      sizeof k_spmv_z / 4u);
    _Static_assert(sizeof k_conv8 <= 0x200u && sizeof k_embag <= 0x200u &&
                   sizeof k_hashj <= 0x200u && sizeof k_stencil_rb <= 0x200u &&
                   sizeof k_mandel <= 0x200u && sizeof k_swat <= 0x200u,
                   "an overlay kernel exceeds 0x000-0x1FF");

    RUN(app_gemm(64, 0));       RUN(app_gemm(256, 0));
    RUN(app_spmv(4096, 16, 0)); RUN(app_spmv(65536, 16, 0));
    RUN(app_stencil(128, 4, 0));   RUN(app_stencil(512, 4, 0));
    RUN(app_kmeans(16384, 16, 0)); RUN(app_kmeans(262144, 16, 0));
    RUN(app_bfs(16384, 8));     RUN(app_bfs(262144, 8));
    RUN(app_scan(65536, 0));    RUN(app_scan(1u << 20, 0));
    RUN(app_mlp(16));           RUN(app_mlp(256));
    /* v3 kernels last, so the inputs of the cases above are those of the earlier runs */
    RUN(app_gemm(64, 1));       RUN(app_gemm(256, 1));
    RUN(app_scan(65536, 1));    RUN(app_scan(1u << 20, 1));
    RUN(app_stencil(128, 4, 16));  RUN(app_stencil(512, 4, 16));
    RUN(app_kmeans(16384, 16, 1)); RUN(app_kmeans(262144, 16, 1));
    RUN(app_spmv(4096, 16, 1)); RUN(app_spmv(65536, 16, 1));
    /* real-application kernels (v3): CNN layers, embedding bag, hash-join probe */
    RUN(app_conv(32));          RUN(app_conv(128));
    RUN(app_embag(16384, 256, 16)); RUN(app_embag(1u << 18, 4096, 32));
    RUN(app_hashj(16, 16384));  RUN(app_hashj(22, 1u << 20));
    /* standard GPU benchmarks */
    RUN(app_mandel(256, 256));  RUN(app_mandel(1024, 256));
    RUN(app_swat(2048, 32, 128)); RUN(app_swat(16384, 32, 128));

    /* Power pass on the DRAM-sized inputs */
    if (pw_init() > 0) {
        xil_printf("POWER,app,size,phase,rail,mV,mW,samples,reps,ms\r\n");
        pmode = 1;
        PRUN(app_gemm(256, 0));
        PRUN(app_spmv(65536, 16, 0));
        PRUN(app_stencil(512, 4, 0));
        PRUN(app_kmeans(262144, 16, 0));
        PRUN(app_bfs(262144, 8));
        PRUN(app_scan(1u << 20, 0));
        PRUN(app_mlp(256));
        VARIANT(PRUN(app_gemm(256, 1)));
        VARIANT(PRUN(app_scan(1u << 20, 1)));
        VARIANT(PRUN(app_stencil(512, 4, 16)));
        VARIANT(PRUN(app_kmeans(262144, 16, 1)));
        VARIANT(PRUN(app_spmv(65536, 16, 1)));
        PRUN(app_conv(128));
        PRUN(app_embag(1u << 18, 4096, 32));
        PRUN(app_hashj(22, 1u << 20));
        PRUN(app_mandel(1024, 256));
        PRUN(app_swat(16384, 32, 128));
        pmode = 0;
    }
#ifndef SIMTIX_VORTEX                   /* suite 2 has no Vortex ports yet */
    errs += run_suite2();
#endif
    return errs;
}

/* ── Suite 2 (docs/suite2_plan.md): its kernels replace suite 1's in the instruction
   RAM, so it runs last ─────────────────────────────────────────────────────────── */
#define S2_RUN(call) RUN(call)
/* No SIMTiX instruction RAM on the A53-only and Vortex builds. On Vortex the IRAM
   offsets (0x1000 + ...) reach its control block, which decodes only the low 8 address
   bits: the kernel words landed on CTRL.reset, START and the DCR registers, and the
   first launch then waited for a flush that never came (board, 2026-11-10). */
#if defined(SIMTIX_A53_ONLY) || defined(SIMTIX_VORTEX)
#define s2_load_all() ((void)0)
#define S2_NO_LOAD
#endif
#include "suite2.inc"

/* ── The Rodinia suite (docs/rodinia_plan.md): suite 2's kernels plus kernels/rodinia
   in the instruction RAM; built with RD_ONLY it is the whole run ──────────────── */
#include "rodinia.inc"
#ifdef SIMTIX_VORTEX
static int vx_app_of_rd(uint32_t pc)
{
    switch (pc) {
    case PC_S2_PATHFINDER: return VX_PATHFINDER;
    case PC_S2_BP_FORWARD: return VX_BP_FORWARD;
    case PC_S2_BP_ADJUST:  return VX_BP_ADJUST;
    case PC_RD_BFS:        return VX_BFS;
    case PC_RD_HOTSPOT_RD: return VX_HOTSPOT_RD;
    case PC_RD_NN:         return VX_NN;
    case PC_RD_HOTSPOT3D:  return VX_HOTSPOT3D;
    case PC_RD_GAUSS_FAN1: return VX_GAUSS_FAN1;
    case PC_RD_GAUSS_FAN2: return VX_GAUSS_FAN2;
    case PC_RD_KMEANS_RD:  return VX_KMEANS_RD;
    default: return -1;                /* no Vortex port yet */
    }
}
#endif
