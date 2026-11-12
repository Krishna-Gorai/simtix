/*
 * main_vortex.c - bare-metal A53 host for Vortex 3.0 on the ZCU102 (vortex_ps_top at
 * 0xA000_0000, create_bd_vortex.tcl).
 *
 * Loads the kernel image (vx_image.h, the Vortex ports of the SIMTiX kernels) at its
 * Vortex address 0x8000_0000 = DDR 0x5000_0000, resets Vortex, and runs SIMTiX's
 * application suite (sw/ps_host/apps.c built with -DSIMTIX_VORTEX): the same inputs,
 * A53 references and checks as the SIMTiX board run, one row per run:
 *   VXB,<app>,<size>,<kernel cycles>,<us incl. flushes>,<a53 us>,<flush cycles>,0,<errors>
 * The console also goes to DDR (OUTBUF, mailbox MB) for run_board_vortex.tcl, as in
 * sw/ps_host/main.c; every file is compiled with -Dxil_printf=con_printf.
 */
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "vx_image.h"

unsigned run_apps(void);                                   /* apps.c */
void vx_set_image(uint32_t base, uint32_t main_pc);        /* apps.c */

#define VX_BASE     0xA0000000u
#define VX_CTRL     0x00u
#define VX_STATUS   0x08u
#define VX_INFO     0x24u
#define VX_NAR      0x28u
#define VX_NAW      0x2Cu
#define VX_ERRADDR  0x38u
#define IMG_DDR     0x50000000u            /* Vortex 0x8000_0000 (vortex_ps_top windows) */

static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(VX_BASE + off, v); }
static inline uint32_t rd(uint32_t off)         { return Xil_In32(VX_BASE + off); }

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
    unsigned errs = 0;
    MB[1] = 0;
    MB[2] = 0;
    Xil_DCacheFlushRange((INTPTR)MB, 64);

    wr(VX_CTRL, 1);                                        /* hold Vortex in reset */
    uint32_t info = rd(VX_INFO);
    xil_printf("\r\nVortex 3.0 on ZCU102: %u core, %u warps x %u threads; A53 host, DDR4 (HP0)\r\n",
               info & 0xFFu, (info >> 16) & 0xFFu, (info >> 8) & 0xFFu);
    if ((info >> 24) != 0xB7u) { xil_printf("no Vortex at 0x%08x (INFO %08x)\r\n", VX_BASE, info); return 1; }

    volatile uint32_t *img = (volatile uint32_t *)(uintptr_t)IMG_DDR;
    for (unsigned i = 0; i < sizeof vx_image / 4u; i++) img[i] = vx_image[i];
    Xil_DCacheFlushRange((INTPTR)IMG_DDR, sizeof vx_image);
    for (unsigned i = 0; i < sizeof vx_image / 4u; i++) errs += (img[i] != vx_image[i]);
    xil_printf("kernel image: %u bytes at Vortex 0x%08x, main 0x%08x%s\r\n", (unsigned)sizeof vx_image,
               VX_IMG_BASE, VX_MAIN_PC, errs ? " (READ-BACK MISMATCH)" : "");
    vx_set_image(VX_IMG_BASE, VX_MAIN_PC);
    for (volatile int d = 0; d < 1000; d++) ;
    wr(VX_CTRL, 0);                                        /* release Vortex */

    xil_printf("VXB,app,size,kernel_cycles,accel_us,a53_us,flush_cycles,unused,errors\r\n");
    errs += run_apps();
    uint32_t st = rd(VX_STATUS);
    if (st & 4u) { xil_printf("Vortex address outside the DDR windows: 0x%08x\r\n", rd(VX_ERRADDR)); errs++; }
    xil_printf("AXI handshakes AR %u AW %u\r\n", rd(VX_NAR), rd(VX_NAW));
    xil_printf("COUNTS_PER_SECOND,%u\r\n", (unsigned)COUNTS_PER_SECOND);
    xil_printf("RESULT: %s (%u errors)\r\n", errs ? "FAIL" : "PASS", errs);
    MB[2] = MB_DONE;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    return 0;
}
