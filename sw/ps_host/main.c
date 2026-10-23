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
 * Results are printed on the UART as CSV:
 *   BOARD,<kernel>,<N>,<accel cycles>,<accel us>,<a53 us>,<L1 hits>,<L1 misses>,<errors>
 *
 * Register map: rtl/soc/simt_ps_top.sv; window at 0xA000_0000 (create_bd_ps.tcl).
 */
#include <stdint.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"      /* XTime, XTime_GetTime, COUNTS_PER_SECOND */
#include "kernels.h"

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
#define PC_HIST        0x100u

#define NMAX           (1u << 18)      /* 262144 elements */

/* Buffers in DDR4 (the program is linked in DDR, below 0x4000_0000). */
static uint32_t A[NMAX]          __attribute__((aligned(64)));
static uint32_t C[NMAX / 8 + 64] __attribute__((aligned(64)));
static uint32_t REF[NMAX / 8 + 64];

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
static uint32_t launch(uint32_t pc, uint32_t n, double *t_us)
{
    XTime t0, t1;
    wr(REG_KERNEL_PC, pc);
    wr(REG_BASE_A, (uint32_t)(uintptr_t)A);
    wr(REG_BASE_C, (uint32_t)(uintptr_t)C);
    wr(REG_N, n);
    wr(REG_BLOCK, 0);
    XTime_GetTime(&t0);
    wr(REG_CTRL, 1);
    while (!(rd(REG_STATUS) & 1u)) ;
    XTime_GetTime(&t1);
    *t_us = us(t0, t1);
    return rd(REG_CYCLES);
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

int main(void)
{
    static const uint32_t sizes[] = { 1024u, 16384u, NMAX };
    unsigned errs = 0;

    xil_printf("\r\nSIMTiX v2 on ZCU104: A53 host, DDR4 through L1 + AXI4 (HP0)\r\n");
    load_kernel(PC_REDUCE, k_reduce_shfl, sizeof k_reduce_shfl / 4u);
    load_kernel(PC_HIST,   k_histogram,   sizeof k_histogram / 4u);
    for (unsigned i = 0; i < sizeof k_reduce_shfl / 4u; i++)
        errs += (rd(IRAM + PC_REDUCE + 4u * i) != k_reduce_shfl[i]);
    xil_printf("instruction RAM read-back: %s\r\n", errs ? "MISMATCH" : "ok");

    xil_printf("BOARD,kernel,N,accel_cycles,accel_us,a53_us,l1_hits,l1_misses,errors\r\n");
    for (unsigned s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        errs += run_reduce(sizes[s]);
        errs += run_hist(sizes[s]);
    }
    if (rd(REG_AXI_ERR) & 1u) { xil_printf("AXI error response seen\r\n"); errs++; }
    xil_printf("RESULT: %s (%u errors)\r\n", errs ? "FAIL" : "PASS", errs);
    return 0;
}
