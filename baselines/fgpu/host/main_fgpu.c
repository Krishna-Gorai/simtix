/*
 * main_fgpu.c - bare-metal A53 host for FGPU on the ZCU102 (fgpu_ps_wrap at 0xA000_0000,
 * create_bd_fgpu.tcl): docs/fgpu_plan.md, phase 0 step 4, the first board runs.
 *
 * FGPU's host protocol, as FGPU's own benchmark/<app>/src/kernel_descriptor.cpp and as
 * baselines/fgpu/tb/tb_fgpu_ps.sv (which passed in simulation before the board build):
 *   code into the code RAM (0x4000), the kernel descriptor (32 words at 0x0000), INITIATE and
 *   CLEAN_CACHE (0xFFFF), START = 1, poll STATUS until it is non-zero.
 * Kernels (fgpu_image.h, from FGPU's compiler as built here):
 *   vec_add         int    out[i] = in1[i] + in2[i]
 *   add_hard_float  FP32   out[i] = in1[i] + in2[i]   (FGPU's float units)
 * Each run at several sizes; every output is checked against the A53. One row per run:
 *   FGB,<kernel>,<n>,<fgpu_us>,<a53_us>,<errors>
 * Times from the A53's system counter (XTime), START to STATUS for FGPU (as FGPU's own
 * benchmarks), the plain loop for the A53. The console also goes to DDR (OUTBUF, mailbox MB)
 * for run_board_fgpu.tcl, as baselines/vortex/host/main_vortex.c.
 */
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "fgpu_image.h"

#define FG_BASE        0xA0000000u
#define FG_CRAM        0x4000u
#define FG_STATUS      0x8000u
#define FG_START       0x8004u
#define FG_CLEAN_CACHE 0x8008u
#define FG_INITIATE    0x800Cu
static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(FG_BASE + off, v); }
static inline uint32_t rd(uint32_t off)         { return Xil_In32(FG_BASE + off); }

/* buffers in DDR, below 4 GB (FGPU's addresses are 32-bit) */
#define BUF_IN1  0x20000000u
#define BUF_IN2  0x24000000u
#define BUF_OUT  0x28000000u
#define NMAX     (1u << 22)

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

static uint32_t us(XTime a, XTime b) { return (uint32_t)((b - a) * 1000000ull / COUNTS_PER_SECOND); }

static void download_code(const uint32_t *code, unsigned len)
{
    for (unsigned i = 0; i < len; i++) wr(FG_CRAM + 4u * i, code[i]);
}

/* kernel<T>::prepare_descriptor + compute_descriptor + download_descriptor, 1-D, 3 params */
static void download_descriptor(unsigned start, unsigned n)
{
    unsigned wg = n < 64 ? n : 64, nwg = n / wg, nwf = (wg + 63) / 64;
    for (unsigned i = 0; i < 32; i++) wr(4u * i, 0);
    wr(0x00, ((nwf - 1u) << 28) | start);
    wr(0x04, n);                         /* size0 */
    wr(0x1C, wg);                        /* nDim-1 = 0, wg_size0 */
    wr(0x20, nwg - 1u);                  /* n_wg0-1 */
    wr(0x24, 0xFFFFFFFFu);               /* n_wg1-1 (n_wg1 = 0) */
    wr(0x28, 0xFFFFFFFFu);               /* n_wg2-1 */
    wr(0x2C, (3u << 28) | wg);           /* nParams, wg_size */
    wr(0x40, BUF_IN1);
    wr(0x44, BUF_IN2);
    wr(0x48, BUF_OUT);
}

/* returns the number of wrong outputs; prints one FGB row */
static unsigned run(const char *name, const uint32_t *code, unsigned len, unsigned start,
                    unsigned n, int fp)
{
    volatile uint32_t *in1 = (volatile uint32_t *)(uintptr_t)BUF_IN1;
    volatile uint32_t *in2 = (volatile uint32_t *)(uintptr_t)BUF_IN2;
    volatile uint32_t *out = (volatile uint32_t *)(uintptr_t)BUF_OUT;
    static uint32_t ref[NMAX];
    XTime t0, t1, t2, t3;
    unsigned err = 0;

    for (unsigned i = 0; i < n; i++) {
        if (fp) {
            float a = (float)i, b = (float)(3u * i) + 0.25f;
            union { float f; uint32_t u; } ua = { a }, ub = { b };
            in1[i] = ua.u; in2[i] = ub.u;
        } else {
            in1[i] = i * 7u + 1u; in2[i] = 0xFFFF0000u + i;
        }
        out[i] = 0xDEADBEEFu;
    }
    Xil_DCacheFlushRange((INTPTR)BUF_IN1, 4u * n);
    Xil_DCacheFlushRange((INTPTR)BUF_IN2, 4u * n);
    Xil_DCacheFlushRange((INTPTR)BUF_OUT, 4u * n);

    download_code(code, len);
    download_descriptor(start, n);
    wr(FG_INITIATE, 0xFFFFu);
    wr(FG_CLEAN_CACHE, 0xFFFFu);
    XTime_GetTime(&t0);
    wr(FG_START, 1u);
    unsigned long polls = 0;
    while (rd(FG_STATUS) == 0u && ++polls < 2000000000ul) ;
    XTime_GetTime(&t1);
    Xil_DCacheInvalidateRange((INTPTR)BUF_OUT, 4u * n);

    XTime_GetTime(&t2);                                    /* the A53 reference, timed */
    for (unsigned i = 0; i < n; i++) {
        if (fp) {
            union { uint32_t u; float f; } a = { in1[i] }, b = { in2[i] }, s;
            s.f = a.f + b.f;
            ref[i] = s.u;
        } else ref[i] = in1[i] + in2[i];
    }
    XTime_GetTime(&t3);
    for (unsigned i = 0; i < n; i++)
        if (out[i] != ref[i]) {
            if (err < 5) xil_printf("  %s out[%u] = %08x, expected %08x\r\n", name, i, out[i], ref[i]);
            err++;
        }
    if (rd(FG_STATUS) == 0u) { xil_printf("  %s: FGPU did not finish\r\n", name); err++; }
    xil_printf("FGB,%s,%u,%u,%u,%u\r\n", name, n, us(t0, t1), us(t2, t3), err);
    return err;
}

#ifdef FG_SUITE
unsigned run_apps(void);                   /* sw/ps_host/apps.c built with -DSIMTIX_FGPU */
void fg_load_code(void);                   /* apps.c: fgpu_image.h's suite image -> code RAM */
#endif

int main(void)
{
    unsigned errs = 0;
    MB[1] = 0;
    MB[2] = 0;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    xil_printf("\r\nFGPU on ZCU102: 1 CU x 8 PEs, FP32 + atomics; A53 host, DDR4 (HP0)\r\n");
#ifdef FG_SUITE
    /* phase 1: the suites of the SIMTiX comparison through sw/ps_host/apps.c (FGB rows) */
    fg_load_code();
    xil_printf("FGB,app,size,cycles,accel_us,a53_us,0,0,errors\r\n");
    errs += run_apps();
    xil_printf("COUNTS_PER_SECOND,%u\r\n", (unsigned)COUNTS_PER_SECOND);
    xil_printf("RESULT: %s (%u errors)\r\n", errs ? "FAIL" : "PASS", errs);
    MB[2] = MB_DONE;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    return 0;
#endif
    xil_printf("FGB,kernel,n,fgpu_us,a53_us,errors\r\n");
    static const unsigned sizes[] = { 64, 1024, 16384, 262144, 1u << 20 };
    for (unsigned s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        errs += run("vec_add", fgpu_code_vec_add, FG_VEC_ADD_LEN, FG_VEC_ADD_VEC_ADD_POS, sizes[s], 0);
        errs += run("add_hard_float", fgpu_code_vec_add_hard_float, FG_VEC_ADD_HARD_FLOAT_LEN,
                    FG_VEC_ADD_HARD_FLOAT_ADD_HARD_FLOAT_POS, sizes[s], 1);
    }
    xil_printf("COUNTS_PER_SECOND,%u\r\n", (unsigned)COUNTS_PER_SECOND);
    xil_printf("RESULT: %s (%u errors)\r\n", errs ? "FAIL" : "PASS", errs);
    MB[2] = MB_DONE;
    Xil_DCacheFlushRange((INTPTR)MB, 64);
    return 0;
}
