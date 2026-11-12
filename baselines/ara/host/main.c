/*
 * main.c - bare-metal A53 host for Ara + CVA6 on the ZCU102 (baselines/ara)
 *
 * For each program in ara_progs.h (RV64 images linked at 0x8000_0000, which the
 * wrapper maps to DDR 0x4000_0000):
 *   1. holds the core in reset (CTRL.run = 0), copies the image to DDR and cleans
 *      the data cache (S_AXI_HP0 is not coherent with the A53 caches),
 *   2. releases the core (CTRL.run = 1) and polls STATUS.done,
 *   3. prints the program's console text (the wrapper's UART buffer) and
 *      ARA,<program>,<exit>,<cycles>,<hwcnt cycles>,<us at the PL clock>
 * The program named "ak" (kernels/ak_main.c) is not run this way: it is the kernel
 * program of the benchmark suite, apps_ara.c, which runs it once per kernel.
 * Register map: rtl/ara_ps_top.sv; window at 0xA000_0000 (create_bd_ara.tcl).
 * The console also goes to DDR for run_board_ara.tcl, as in sw/ps_host/main.c.
 */
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "ara_progs.h"

unsigned run_ara_apps(const uint32_t *img, uint32_t words, double mhz);   /* apps_ara.c */

#define ARA_BASE     0xA0000000u
#define R_CTRL       0x00u
#define R_STATUS     0x04u
#define R_EXIT       0x08u
#define R_CYC_LO     0x0Cu
#define R_CYC_HI     0x10u
#define R_HW_LO      0x14u
#define R_HW_HI      0x18u
#define R_UARTCNT    0x1Cu
#define R_INFO       0x20u
#define R_WROUT      0x24u
#define R_NAR        0x28u
#define R_NAW        0x2Cu
#define R_NR         0x30u
#define R_NB         0x34u
#define R_UBUF       0x1000u
#define DDR_WIN      0x40000000u
#define WIN_BYTES    0x10000000u

#define OUTBUF   0x0E000000u
#define OUTMAX   0x00F00000u
#define MB       ((volatile uint32_t *)0x0EF00000u)
#define MB_DONE  0x444F4E45u               /* "DONE" */
static uint32_t outlen, flushed;

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

static inline uint32_t rd(uint32_t off) { return Xil_In32(ARA_BASE + off); }
static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(ARA_BASE + off, v); }

static unsigned run_prog(const struct ara_prog *p, double pl_mhz)
{
    wr(R_CTRL, 0);
    memcpy((void *)(uintptr_t)DDR_WIN, p->img, 4u * p->words);
    Xil_DCacheFlushRange((INTPTR)DDR_WIN, 4u * p->words);
    XTime t0, t1;
    XTime_GetTime(&t0);
    wr(R_CTRL, 1);
    uint32_t st = 0;
    for (;;) {
        st = rd(R_STATUS);
        if (st & 1u) break;
        XTime_GetTime(&t1);
        if ((t1 - t0) > 120ull * COUNTS_PER_SECOND) break;    /* 2 min */
    }
    if (!(st & 1u)) {
        con_printf("ARA,%s,TIMEOUT status=%x wrout=%u ar=%u aw=%u r=%u b=%u uart=%u\r\n",
                   p->name, (unsigned)st, (unsigned)rd(R_WROUT), (unsigned)rd(R_NAR),
                   (unsigned)rd(R_NAW), (unsigned)rd(R_NR), (unsigned)rd(R_NB),
                   (unsigned)rd(R_UARTCNT));
    }
    uint32_t n = rd(R_UARTCNT);
    if (n > 2048u) n = 2048u;
    char line[256];
    unsigned k = 0;
    for (uint32_t i = 0; i < n; i += 4u) {
        uint32_t w = rd(R_UBUF + i);
        for (unsigned b = 0; b < 4u && i + b < n; b++) {
            char c = (char)(w >> (8u * b));
            if (c == '\n' || k == sizeof line - 3u) {
                line[k] = 0; con_printf("  | %s\r\n", line); k = 0;
                if (c == '\n') continue;
            }
            if (c != '\r') line[k++] = c;
        }
    }
    if (k) { line[k] = 0; con_printf("  | %s\r\n", line); }
    uint64_t cyc = ((uint64_t)rd(R_CYC_HI) << 32) | rd(R_CYC_LO);
    uint64_t hw  = ((uint64_t)rd(R_HW_HI) << 32) | rd(R_HW_LO);
    uint32_t ex  = rd(R_EXIT);
    con_printf("ARA,%s,%u,%llu,%llu,%.1f\r\n", p->name, (unsigned)ex,
               (unsigned long long)cyc, (unsigned long long)hw, (double)cyc / pl_mhz);
    wr(R_CTRL, 0);
    return (st & 1u) && ex == 0 ? 0u : 1u;
}

int main(void)
{
    MB[1] = 0;
    MB[2] = 0;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    /* PL clock 0 = 1.5 GHz / (div0 * div1) of CRL_APB.PL0_REF_CTRL (create_bd_ara.tcl) */
    uint32_t pl0 = Xil_In32(0xFF5E00C0u);
    double pl_mhz = 1500.0 / (double)(((pl0 >> 8) & 0x3Fu) * ((pl0 >> 16) & 0x3Fu));
    uint32_t info = rd(R_INFO);
    con_printf("\r\nAra + CVA6 on ZCU102: %u lanes, VLEN %u, PL clock %.2f MHz\r\n",
               (unsigned)((info >> 16) & 0xFFu), (unsigned)(info & 0xFFFFu), pl_mhz);
    if ((info >> 24) != 0xA7u) con_printf("unexpected INFO register %08x\r\n", (unsigned)info);
    con_printf("ARA,program,exit,cycles,hwcnt_cycles,us\r\n");
    unsigned errs = 0;
    const struct ara_prog *ak = 0;
    for (unsigned i = 0; i < sizeof ara_progs / sizeof ara_progs[0]; i++) {
        if (!strcmp(ara_progs[i].name, "ak")) { ak = &ara_progs[i]; continue; }
        errs += run_prog(&ara_progs[i], pl_mhz);
    }
    if (ak) errs += run_ara_apps(ak->img, ak->words, pl_mhz);
    con_printf("RESULT: %s (%u errors)\r\n", errs ? "FAIL" : "PASS", errs);
    MB[2] = MB_DONE;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    return 0;
}
