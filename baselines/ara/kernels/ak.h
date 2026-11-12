/*
 * ak.h - Ara/CVA6 benchmark kernels: interface shared by the RISC-V program and the
 * A53 host (baselines/ara/host/apps_ara.c).
 *
 * The A53 builds the inputs of an application in DDR4 exactly as sw/ps_host/apps.c
 * does for SIMTiX (same generator, same order of draws), writes a mailbox, starts
 * CVA6 and waits for the exit. The RISC-V program (ak_main.c) runs one kernel per
 * start: mode 0 is the scalar version on CVA6 (the A53's reference loop, compiled
 * for RV64GC, no vector unit), mode 1 the RVV version on Ara. Both are compared
 * with the A53 reference word for word.
 *
 * Addresses: Ara sees the host's DDR window 0x4000_0000-0x4FFF_FFFF at
 * 0x8000_0000-0x8FFF_FFFF (rtl/ara_ps_top.sv). Arguments carry the HOST address
 * (32 bits); the kernels add AK_OFS.
 *
 *   host 0x4000_0000  program image (at most AK_IMG_MAX bytes)
 *   host 0x41FF_0000  mailbox (struct ak_mb)
 *   host 0x4200_0000  data arena, 192 MB
 *   host 0x4E00_0000-0x5000_0000  CVA6 stack (sp = DRAM end = Ara 0x9000_0000)
 */
#ifndef AK_H
#define AK_H
#include <stdint.h>

#define AK_OFS       0x40000000u           /* Ara address = host address + AK_OFS */
#define AK_IMG_HOST  0x40000000u
#define AK_IMG_MAX   0x01FF0000u
#define AK_MB_HOST   0x41FF0000u
#define AK_ARENA     0x42000000u
#define AK_ARENA_SZ  0x0C000000u
#define AK_MAGIC     0xA7A7C0DEu

enum ak_app {
    AK_GEMM = 1, AK_SPMV, AK_STENCIL, AK_KMEANS, AK_BFS, AK_SCAN, AK_MLP,
    AK_CONV, AK_EMBAG, AK_HASHJ, AK_MANDEL, AK_SWAT,
    /* suite 2 (docs/suite2_plan.md; layouts of sim/gen_suite2.py, kernels/suite2/s2_ref.h) */
    AK_PATHFINDER, AK_HOTSPOT, AK_JACOBI2D, AK_ATAX, AK_BICG, AK_PAGERANK, AK_CC,
    AK_BACKPROP, AK_SORT, AK_BLACKSCHOLES,
    /* Rodinia (docs/rodinia_plan.md; layouts of sim/gen_rodinia.py, kernels/rodinia/rd_ref.h) */
    AK_RD_HOTSPOT, AK_RD_NN, AK_RD_HOTSPOT3D, AK_RD_GAUSSIAN, AK_RD_KMEANS,
    /* RiVEC batch 1 (docs/rivec_plan.md): Ara runs RiVEC's own vector code
       (ak_vector_rv.inc), CVA6 kernels/rivec/rv_ref.h */
    AK_RV_AXPY, AK_RV_MATMUL, AK_RV_SPMV, AK_RV_JACOBI, AK_RV_PATHFINDER, AK_RV_BS, AK_RV_LAVAMD,
    AK_NAPPS
};

/* Arguments (u32 each; "p" = host address of an array):
 *  GEMM    p A, p B, p C, n                              C = A B, FP32, n x n, i-k-j fmaf
 *  SPMV    p rowptr, p col, p val, p x, p y, rows        CSR, per-row fmaf chain from +0
 *  STENCIL p g0, p g1, n, s, c0, c1, sweeps              5-point Jacobi, g0 -> g1 -> g0 ...
 *  KMEANS  p px, p py, p cx, p cy, k, p as, p sx, p sy, p cn, npts
 *  BFS     p rowptr, p col, p lev, nv, p queue           levels from vertex 0 (queue: scalar)
 *  SCAN    p in, p out, n                                inclusive u32 prefix sum
 *  MLP     p x0, batch, nl, p dims, p w0, p w1, p w2, p act, p nxt, p logit, scale, zp
 *          dims[l] = k[l], dims[4 + l] = npad[l]; scalar: w = wT[n][k] (A53 layout);
 *          vector: w = W[k][npad] int8 (output index fastest)
 *  CONV    p x0, p x1, p x2, p w0, p w1, n, c0, c1, c2, scale, zp
 *          scalar: x = NHWC bytes (A53 layout), vector: x = [row][channel][column]
 *          bytes; both padded to (n + 2) x (n + 2); w = OHWI int8 (both)
 *  EMBAG   p t, p idx, p out, bags, k                    D = 32 floats per row
 *  HASHJ   p slot, p key, p out, nprobe, s
 *  MANDEL  p out, n, x0, y0, d, m                        (FP32 bit patterns)
 *  SWAT    p q, p t, p out, pairs, lq, lt, p scratch
 *          scalar: q, t pair-major bytes (A53 layout); vector: q[i][pair], t[j][pair]
 *          bytes, scratch 2 * lq * 256 int16 (H and E rows of a strip of 256 pairs)
 * Suite 2 (one start runs the whole application, all its steps):
 *  PATHFINDER   p wall, p buf0, p buf1, rows, cols    rows padded with INT_MAX; result buf[(rows-1)&1]
 *  HOTSPOT      p t0, p t1, p power, n, s, rx1, ry1, rz1, amb, sdc, steps    result t[steps&1]
 *  JACOBI2D     p a, p b, n, s, 0.2f, tsteps            result a
 *  ATAX         p A, p x, p tmp, p y, n
 *  BICG         p A, p p, p r, p q, p s, n
 *  PAGERANK     p rowptr, p col, p invdeg, p c, p pr0, p pr1, nv, d, base, iters   result pr[iters&1]
 *  CC           p rowptr, p col, p lab0, p lab1, nv, p rounds (out)   result lab[rounds&1]
 *  BACKPROP     p in, p w, p ow, p ed, p ps, n, m       forward partial sums, then the update
 *  SORT         p k0, p v0, p k1, p v1, n, p scratch, W   result in k0, v0; scratch (vector
 *               version) 33 * W words: hist and off (16 x W each) and tot
 *  BLACKSCHOLES p S, p K, p r, p v, p T, p call, p put, p C, n
 * RiVEC batch 1 (one start runs the whole application):
 *  RV_AXPY        p dx, p dy, a, n                     dy = fma(a, dx, dy)
 *  RV_MATMUL      p A, p B, p C, m, n, p               C (m x n) = A (m x p) B (p x n)
 *  RV_SPMV        p ia, p ja, p val, p x, p y, nrows   CSR (32-bit indices)
 *  RV_JACOBI      p A, p B, n, tsteps                  n x n, tsteps x (A -> B, B -> A)
 *  RV_PATHFINDER  p wall, p dst, p tmp, rows, cols, runs    result in dst (tmp: scalar only)
 *  RV_BS          p S, p K, p r, p v, p T, p type, p price, n, runs
 *  RV_LAVAMD      p rv, p qv, p fv, p nn, p nei, a2, nbox    fv accumulated
 */
#define AK_NARGS 24

struct ak_mb {
    uint32_t magic;          /* AK_MAGIC: written by the host */
    uint32_t app;            /* enum ak_app */
    uint32_t mode;           /* 0 scalar (CVA6), 1 vector (Ara) */
    uint32_t done;           /* set to 1 by the kernel program */
    uint64_t cycles;         /* cycle CSR around the kernel (after fences) */
    uint32_t args[AK_NARGS];
};

#define AK_SW_NEG (-16384)
#define AK_EMBAG_D 32u

#ifdef __riscv
#include <stddef.h>
#define AKP(T, a) ((T *)(uintptr_t)((uint64_t)(uint32_t)(a) + AK_OFS))
static inline float ak_f(uint32_t u) { union { uint32_t u; float f; } v = { .u = u }; return v.f; }
typedef void (*ak_fn)(const uint32_t *a);
extern const ak_fn ak_scalar[AK_NAPPS];
extern const ak_fn ak_vector[AK_NAPPS];
#endif

#endif
