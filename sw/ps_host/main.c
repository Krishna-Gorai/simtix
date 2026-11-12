/*
 * main.c  -  SIMTiX v2 bare-metal host for the ZCU104 board build
 *
 * Runs on one Cortex-A53 (standalone BSP). For each kernel and size it
 *   1. writes the kernel into the accelerator's instruction RAM,
 *   2. places the input in DDR4 and cleans the data cache (the S_AXI_HP0 port
 *      is not coherent with the A53 caches),
 *   3. writes the command registers, sets CTRL.GO and polls STATUS.DONE,
 *   4. invalidates the data cache, checks every result against a reference
 *      computed on the A53, and
 *   5. times the same computation on the A53 (the CPU baseline).
 * It then runs the application suite (apps.c). Results are printed on the UART
 * as CSV:
 *   BOARD,<kernel>,<N>,<accel cycles>,<accel us>,<a53 us>,<L1 hits>,<L1 misses>,<errors>
 *
 * Register map: rtl/soc/simt_ps_top.sv; window at 0xA000_0000 (create_bd_ps.tcl).
 */
#include <stdint.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"      /* XTime, XTime_GetTime, COUNTS_PER_SECOND */
#include <stdarg.h>
#include <stdio.h>
#include "kernels.h"

unsigned run_apps(void);   /* apps.c */

#define SIMT_BASE      0xA0000000u
#define REG_KERNEL_PC  0x00u
#define REG_BASE_A     0x04u
#define REG_BASE_B     0x08u
#define REG_BASE_C     0x0Cu
#define REG_N          0x10u
#define REG_CTRL       0x14u
#define REG_STATUS     0x18u
#define REG_CYCLES     0x1Cu
#define REG_BLOCK      0x20u
#define REG_L1_HITS    0x100u
#define REG_L1_MISSES  0x104u
#define REG_AXI_ERR    0x108u
#define IRAM           0x1000u

#define PC_REDUCE      0x000u          /* instruction-RAM byte offsets */
#define PC_HIST        0x080u          /* 0x100-0x1FF: stencil_rb (apps.c) */
#define PC_CONTEND     0x280u          /* after gemm (apps.c, 0x200-0x277) */
#define PC_HSHARED     0x840u          /* after scan_add (apps.c, 0x800-0x837) */

#define NMAX           (1u << 18)      /* 262144 elements */

/* Buffers in DDR4 (the program is linked in DDR, below 0x4000_0000). */
static uint32_t A[NMAX]          __attribute__((aligned(64)));
static uint32_t C[NMAX / 8 + 64] __attribute__((aligned(64)));
static uint32_t REF[NMAX / 8 + 64];
static uint32_t KB[2u * NMAX]    __attribute__((aligned(64)));   /* amo_contend: 16 words per warp */
static uint32_t CC[4u * NMAX]    __attribute__((aligned(64)));   /* amo_contend: 4 results per thread */
static uint32_t KREF[2u * NMAX], CREF[4u * NMAX];

static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(SIMT_BASE + off, v); }
static inline uint32_t rd(uint32_t off)         { return Xil_In32(SIMT_BASE + off); }

static double us(XTime t0, XTime t1)
{
    return (double)(t1 - t0) * 1e6 / (double)COUNTS_PER_SECOND;
}

static void load_kernel(uint32_t pc, const uint32_t *w, unsigned n)
{
    for (unsigned i = 0; i < n; i++) wr(IRAM + pc + 4u * i, w[i]);
}

/* Launch one kernel and wait; returns accelerator cycles, fills wall time. */
static uint32_t launch_ab(uint32_t pc, uint32_t n, const void *a, const void *b, const void *c,
                          uint32_t block, double *t_us)
{
    XTime t0, t1;
    wr(REG_KERNEL_PC, pc);
    wr(REG_BASE_A, (uint32_t)(uintptr_t)a);
    wr(REG_BASE_B, (uint32_t)(uintptr_t)b);
    wr(REG_BASE_C, (uint32_t)(uintptr_t)c);
    wr(REG_N, n);
    wr(REG_BLOCK, block);
    XTime_GetTime(&t0);
    wr(REG_CTRL, 1);
    while (!(rd(REG_STATUS) & 1u)) ;
    XTime_GetTime(&t1);
    *t_us = us(t0, t1);
    return rd(REG_CYCLES);
}

static uint32_t launch(uint32_t pc, uint32_t n, double *t_us)
{
    return launch_ab(pc, n, A, 0, C, 0, t_us);
}

static uint32_t hash(uint32_t i) { return ((i * 2654435761u) >> 12) & 0xFFFu; }

static void report(const char *k, uint32_t n, uint32_t cyc, double acc_us, double cpu_us,
                   unsigned errs)
{
    /* xil_printf has no %f: print microseconds with one decimal */
    unsigned a10 = (unsigned)(acc_us * 10.0 + 0.5), c10 = (unsigned)(cpu_us * 10.0 + 0.5);
    xil_printf("BOARD,%s,%u,%u,%u.%u,%u.%u,%u,%u,%u\r\n", k, n, cyc, a10 / 10, a10 % 10,
               c10 / 10, c10 % 10, rd(REG_L1_HITS), rd(REG_L1_MISSES), errs);
}

/* reduce_shfl: C[w] = sum of A[8w .. 8w+7] */
static unsigned run_reduce(uint32_t n)
{
    XTime t0, t1;
    double acc_us;
    unsigned errs = 0;
    for (uint32_t i = 0; i < n; i++) A[i] = hash(i);
    Xil_DCacheFlushRange((INTPTR)A, n * 4u);
    Xil_DCacheFlushRange((INTPTR)C, (n / 8u) * 4u);

    uint32_t cyc = launch(PC_REDUCE, n, &acc_us);
    Xil_DCacheInvalidateRange((INTPTR)C, (n / 8u) * 4u);

    XTime_GetTime(&t0);
    for (uint32_t w = 0; w < n / 8u; w++) {
        uint32_t s = 0;
        for (uint32_t l = 0; l < 8u; l++) s += A[8u * w + l];
        REF[w] = s;
    }
    XTime_GetTime(&t1);
    for (uint32_t w = 0; w < n / 8u; w++) errs += (C[w] != REF[w]);
    report("reduce_shfl", n, cyc, acc_us, us(t0, t1), errs);
    return errs;
}

/* histogram: C[b] = #{i : A[i] mod 16 = b}, with global atomics */
static unsigned run_hist(uint32_t n)
{
    XTime t0, t1;
    double acc_us;
    unsigned errs = 0;
    for (uint32_t i = 0; i < n; i++) A[i] = hash(i);
    for (uint32_t b = 0; b < 16u; b++) C[b] = 0;
    Xil_DCacheFlushRange((INTPTR)A, n * 4u);
    Xil_DCacheFlushRange((INTPTR)C, 64u);

    uint32_t cyc = launch(PC_HIST, n, &acc_us);
    Xil_DCacheInvalidateRange((INTPTR)C, 64u);

    XTime_GetTime(&t0);
    for (uint32_t b = 0; b < 16u; b++) REF[b] = 0;
    for (uint32_t i = 0; i < n; i++) REF[A[i] & 15u]++;
    XTime_GetTime(&t1);
    for (uint32_t b = 0; b < 16u; b++) errs += (C[b] != REF[b]);
    report("histogram", n, cyc, acc_us, us(t0, t1), errs);
    return errs;
}

/* hist_shared: the histogram privatised in block-shared memory (32-thread blocks,
   one global AMO per bin and block) */
static unsigned run_hist_shared(uint32_t n)
{
    XTime t0, t1;
    double acc_us;
    unsigned errs = 0;
    for (uint32_t i = 0; i < n; i++) A[i] = hash(i);
    for (uint32_t b = 0; b < 16u; b++) C[b] = 0;
    Xil_DCacheFlushRange((INTPTR)A, n * 4u);
    Xil_DCacheFlushRange((INTPTR)C, 64u);

    uint32_t cyc = launch_ab(PC_HSHARED, n, A, 0, C, 2u, &acc_us);
    Xil_DCacheInvalidateRange((INTPTR)C, 64u);

    XTime_GetTime(&t0);
    for (uint32_t b = 0; b < 16u; b++) REF[b] = 0;
    for (uint32_t i = 0; i < n; i++) REF[A[i] & 15u]++;
    XTime_GetTime(&t1);
    for (uint32_t b = 0; b < 16u; b++) errs += (C[b] != REF[b]);
    report("hist_shared", n, cyc, acc_us, us(t0, t1), errs);
    return errs;
}

/* amo_contend: amoadd / amomax / amoswap that collide within a warp. Every
   returned value and the final words are checked against the lanes executed one
   at a time in ascending order (amo_contend.S). Warps own disjoint words, so the
   serial order over all threads is ascending tid. */
static unsigned run_contend(uint32_t n)
{
    XTime t0, t1;
    double acc_us;
    unsigned errs = 0;
    for (uint32_t i = 0; i < n; i++)          /* odd threads negative, for amomax */
        A[i] = hash(i) ^ ((i & 1u) ? 0x80000000u : 0u);
    for (uint32_t i = 0; i < 2u * n; i++) KB[i] = KREF[i] = hash(i + 7u) - 0x800u;
    for (uint32_t i = 0; i < 4u * n; i++) CC[i] = CREF[i] = 0xDEADBEEFu;
    Xil_DCacheFlushRange((INTPTR)A, n * 4u);
    Xil_DCacheFlushRange((INTPTR)KB, 2u * n * 4u);
    Xil_DCacheFlushRange((INTPTR)CC, 4u * n * 4u);

    uint32_t cyc = launch_ab(PC_CONTEND, n, A, KB, CC, 0, &acc_us);
    Xil_DCacheInvalidateRange((INTPTR)KB, 2u * n * 4u);
    Xil_DCacheInvalidateRange((INTPTR)CC, 4u * n * 4u);

    XTime_GetTime(&t0);
    for (uint32_t t = 0; t < n; t++) {
        uint32_t v = A[t], b = v & 3u, *k = KREF + 16u * (t / 8u);
        CREF[4u * t + 0] = k[b];     k[b] += v;
        CREF[4u * t + 1] = k[4 + b]; if ((int32_t)v > (int32_t)k[4 + b]) k[4 + b] = v;
        CREF[4u * t + 2] = k[8 + b]; k[8 + b] = t;
    }
    XTime_GetTime(&t1);
    for (uint32_t i = 0; i < 2u * n; i++) errs += (KB[i] != KREF[i]);
    for (uint32_t i = 0; i < 4u * n; i++) errs += (CC[i] != CREF[i]);
    report("amo_contend", n, cyc, acc_us, us(t0, t1), errs);
    return errs;
}

/* ── Console copy in DDR ────────────────────────────────────────────────────────
   With only the JTAG cable on the board there is no UART to read. build_vitis.py
   compiles every host file with -Dxil_printf=con_printf: the text still goes to
   UART0 and is also appended to OUTBUF in DDR; the mailbox MB holds its length
   ([1]) and DONE ([2]) when the run has finished. run_board.tcl reads it back over
   JTAG. MB[0] is left to the debugger. */
#define OUTBUF   0x0E000000u
#define OUTMAX   0x00F00000u
#define MB       ((volatile uint32_t *)0x0EF00000u)
#define MB_DONE  0x444F4E45u               /* "DONE" */
static uint32_t outlen, flushed;

#undef xil_printf
void xil_printf(const char8 *ctrl1, ...);   /* the BSP's, to UART0 */

void con_printf(const char8 *fmt, ...)
{
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    xil_printf("%s", buf);
    for (int i = 0; i < n && outlen < OUTMAX; i++)
        *(volatile char *)(uintptr_t)(OUTBUF + outlen++) = buf[i];
    if (outlen > flushed) Xil_DCacheFlushRange((INTPTR)(OUTBUF + flushed), outlen - flushed);
    flushed = outlen;
    MB[1] = outlen;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
}
#define xil_printf con_printf

int main(void)
{
    static const uint32_t sizes[] = { 1024u, 16384u, NMAX };
    unsigned errs = 0;

    MB[1] = 0;
    MB[2] = 0;
    Xil_DCacheFlushRange((INTPTR)MB, 64);

#ifdef SIMTIX_BOARD_ZCU104
    xil_printf("\r\nSIMTiX v2 on ZCU104: A53 host, DDR4 through L1 + AXI4 (HP0)\r\n");
#else
    xil_printf("\r\nSIMTiX v2 on ZCU102: A53 host, DDR4 through L1 + AXI4 (HP0)\r\n");
#endif
    load_kernel(PC_REDUCE, k_reduce_shfl, sizeof k_reduce_shfl / 4u);
    load_kernel(PC_HIST,   k_histogram,   sizeof k_histogram / 4u);
    _Static_assert(sizeof k_amo_contend <= 0x80u, "amo_contend overflows 0x280-0x2FF");
    _Static_assert(sizeof k_hist_shared <= 0xC0u, "hist_shared overflows 0x840-0x8FF");
    load_kernel(PC_CONTEND, k_amo_contend, sizeof k_amo_contend / 4u);
    load_kernel(PC_HSHARED, k_hist_shared, sizeof k_hist_shared / 4u);
    for (unsigned i = 0; i < sizeof k_reduce_shfl / 4u; i++)
        errs += (rd(IRAM + PC_REDUCE + 4u * i) != k_reduce_shfl[i]);
    xil_printf("instruction RAM read-back: %s\r\n", errs ? "MISMATCH" : "ok");

    xil_printf("BOARD,kernel,N,accel_cycles,accel_us,a53_us,l1_hits,l1_misses,errors\r\n");
    for (unsigned s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        errs += run_reduce(sizes[s]);
        errs += run_hist(sizes[s]);
        errs += run_hist_shared(sizes[s]);
        errs += run_contend(sizes[s]);
    }
    errs += run_apps();
    if (rd(REG_AXI_ERR) & 1u) { xil_printf("AXI error response seen\r\n"); errs++; }
    xil_printf("COUNTS_PER_SECOND,%u\r\n", (unsigned)COUNTS_PER_SECOND);
    xil_printf("RESULT: %s (%u errors)\r\n", errs ? "FAIL" : "PASS", errs);
    MB[2] = MB_DONE;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    return 0;
}
