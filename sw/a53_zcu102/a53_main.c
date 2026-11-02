/*
 * a53_main.c  -  the A53 references of the application suite on a ZCU102
 *
 * The ZCU102's XCZU9EG cannot be implemented with Vivado ML Standard, so this
 * board runs no accelerator: the A53 runs the same sequential references as the
 * board host (sw/ps_host/apps.c, built with SIMTIX_A53_ONLY) on the same
 * DRAM-sized inputs, and reads the PS power monitors (power.c, ZCU102 table).
 * build_init.py / run_init.tcl bring up the PS first; run_a53.tcl loads this
 * program over JTAG. The console is a text buffer in DDR that the JTAG script
 * reads back (the board's only USB cable is on JTAG).
 *
 * Mailbox at MB (DDR): [0] system-counter frequency in Hz, measured by the JTAG
 * script against the host clock and written before the program starts; [1]
 * bytes of console text; [2] 0x444F4E45 ("DONE") when the run has finished.
 */
#include <stdint.h>
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "power.h"

#define OUTBUF  0x0E000000u
#define OUTMAX  0x00F00000u
#define MB      ((volatile uint32_t *)0x0EF00000u)
#define DONE    0x444F4E45u
#define CPS_DEFAULT 93843752u       /* psu_init's IOU_SCNTRS base frequency */
#define ARENA_BASE  0x10000000u     /* as in apps.c */
#define ARENA_SIZE  0x10000000u

#ifndef A53_BUILD
#define A53_BUILD "unspecified"
#endif

unsigned run_apps(void);            /* sw/ps_host/apps.c */
double a53_counts_per_second;

static uint32_t outlen, flushed;

static void sync_out(void)
{
    if (outlen > flushed) Xil_DCacheFlushRange((INTPTR)(OUTBUF + flushed), outlen - flushed);
    flushed = outlen;
    MB[1] = outlen;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
}

/* Linked with --wrap=outbyte: xil_printf's output comes here, not to UART0. */
void __wrap_outbyte(char c);
void __wrap_outbyte(char c)
{
    if (outlen >= OUTMAX) return;
    *(volatile char *)(uintptr_t)(OUTBUF + outlen++) = c;
    if (c == '\n') sync_out();
}

/* A53 clock from the PMU cycle counter against the system counter. */
static uint32_t a53_khz(void)
{
    uint64_t pmcr, c0, c1;
    XTime t0, t1;
    __asm__ volatile("mrs %0, pmcr_el0" : "=r"(pmcr));
    /* E = 1, D = 0: count every cycle, not every 64th */
    __asm__ volatile("msr pmcr_el0, %0" :: "r"((pmcr | 1u) & ~(uint64_t)8u));
    __asm__ volatile("msr pmcntenset_el0, %0" :: "r"((uint64_t)1 << 31));
    __asm__ volatile("isb");
    XTime_GetTime(&t0);
    __asm__ volatile("mrs %0, pmccntr_el0" : "=r"(c0));
    do { XTime_GetTime(&t1); } while ((double)(t1 - t0) < 0.2 * a53_counts_per_second);
    __asm__ volatile("mrs %0, pmccntr_el0" : "=r"(c1));
    return (uint32_t)((double)(c1 - c0) * a53_counts_per_second / (double)(t1 - t0) / 1000.0);
}

int main(void)
{
    Xil_DCacheInvalidateRange((INTPTR)MB, 64);
    uint32_t cps = MB[0];
    int measured = cps > 10000000u && cps < 1000000000u;
    if (!measured) cps = CPS_DEFAULT;
    a53_counts_per_second = (double)cps;
    pw_iic_clock_hz = cps;          /* I2C0 and the system counter: IOPLL / 16 */
    MB[2] = 0;

    xil_printf("\r\nSIMTiX v2 A53 references on the ZCU102 (no accelerator)\r\n");
    xil_printf("system counter: %u Hz (%s)\r\n", cps, measured ? "measured over JTAG" : "default");
    uint32_t khz = a53_khz();
    xil_printf("A53 clock: %u.%u MHz (cycle counter)\r\n", khz / 1000, (khz % 1000) / 100);
    /* Clear the arena: the buffers the accelerator would write are never
       written here, and from a cleared start the arena hashes of two builds
       agree exactly when their results do. */
    for (volatile uint64_t *q = (uint64_t *)(uintptr_t)ARENA_BASE;
         (uintptr_t)q < ARENA_BASE + ARENA_SIZE; q++)
        *q = 0;
    Xil_DCacheFlush();
    xil_printf("build: %s\r\n", A53_BUILD);
    xil_printf("A53,app,size,a53_us,arena_fnv1a\r\n");
    run_apps();
    xil_printf("A53 RUN DONE\r\n");
    sync_out();
    MB[2] = DONE;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    for (;;) ;
}
