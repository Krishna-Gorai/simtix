# gemm_rb.S  -  FP32 matrix multiply, register-blocked: a 4x4 block of C per thread
#
#   C[M x N] = A[M x K] * B[K x N], all row-major; M a multiple of 4, N a power
#   of two and a multiple of 4L (L lanes). Warp w computes rows 4*rq .. 4*rq+3
#   and the 4L columns of column block cb, with NB = N / (4L) blocks per row:
#       rq = w / NB, cb = w % NB.
#   Lane l takes columns c_j = cb*4L + l + j*L (j = 0..3), so the B loads of a
#   warp are whole lines and the A loads broadcasts. For each of its 16 outputs
#   a thread runs  acc = +0.0; for k: acc = fmadd(A[r][k], B[k][c], acc)  in the
#   same order as gemm.S, so the results are the same.
#   Per k: 4 A loads, 4 B loads, 16 fmadd, 7 instructions of loop overhead.
#
#   a0 = tid   a1 = &P   threads = M*N/16
#   P[0] = &A   P[1] = &B   P[2] = &C   P[3] = K   P[4] = log2N
#include "lanes.h"
#define BO (4 * LANES)                 /* bytes between a lane's columns */
.section .text
.globl _start
_start:
    lw      s0, 0(a1)              # A
    lw      s1, 4(a1)              # B
    lw      s2, 8(a1)              # C
    lw      s3, 12(a1)             # K
    lw      s4, 16(a1)             # log2N
    andi    t0, a0, LANES-1        # lane
    srli    t1, a0, LOG2L          # warp index w
    addi    t2, s4, -(LOG2L+2)     # log2 NB
    srl     t3, t1, t2             # rq
    li      t4, 1
    sll     t4, t4, t2
    addi    t4, t4, -1
    and     t4, t1, t4             # cb
    slli    t4, t4, LOG2L+2
    add     t4, t4, t0             # c0 = cb*4L + lane
    slli    t3, t3, 2              # r0 = 4*rq
    slli    t5, s3, 2              # A row stride K*4
    mul     t6, t3, t5
    add     a2, s0, t6             # &A[r0][0]
    add     a3, a2, t5             # &A[r0+1][0]
    add     a4, a3, t5             # &A[r0+2][0]
    add     a5, a4, t5             # &A[r0+3][0]
    slli    t6, t4, 2
    add     a6, s1, t6             # &B[0][c0]
    li      a7, 4
    sll     a7, a7, s4             # B and C row stride N*4
    fmv.w.x f0, x0
    fmv.w.x f1, x0
    fmv.w.x f2, x0
    fmv.w.x f3, x0
    fmv.w.x f4, x0
    fmv.w.x f5, x0
    fmv.w.x f6, x0
    fmv.w.x f7, x0
    fmv.w.x f8, x0
    fmv.w.x f9, x0
    fmv.w.x f10, x0
    fmv.w.x f11, x0
    fmv.w.x f12, x0
    fmv.w.x f13, x0
    fmv.w.x f14, x0
    fmv.w.x f15, x0
    mv      s5, s3                 # k counter
1:  flw     f16, 0(a2)             # A[r0+i][k]
    flw     f17, 0(a3)
    flw     f18, 0(a4)
    flw     f19, 0(a5)
    flw     f20, 0(a6)             # B[k][c_j]
    flw     f21, BO(a6)
    flw     f22, 2*BO(a6)
    flw     f23, 3*BO(a6)
    fmadd.s f0, f16, f20, f0       # acc[i][j], i = row, j = column
    fmadd.s f1, f16, f21, f1
    fmadd.s f2, f16, f22, f2
    fmadd.s f3, f16, f23, f3
    fmadd.s f4, f17, f20, f4
    fmadd.s f5, f17, f21, f5
    fmadd.s f6, f17, f22, f6
    fmadd.s f7, f17, f23, f7
    fmadd.s f8, f18, f20, f8
    fmadd.s f9, f18, f21, f9
    fmadd.s f10, f18, f22, f10
    fmadd.s f11, f18, f23, f11
    fmadd.s f12, f19, f20, f12
    fmadd.s f13, f19, f21, f13
    fmadd.s f14, f19, f22, f14
    fmadd.s f15, f19, f23, f15
    addi    a2, a2, 4
    addi    a3, a3, 4
    addi    a4, a4, 4
    addi    a5, a5, 4
    add     a6, a6, a7
    addi    s5, s5, -1
    bnez    s5, 1b
    sll     t6, t3, s4             # r0*N
    add     t6, t6, t4             # + c0
    slli    t6, t6, 2
    add     t6, s2, t6             # &C[r0][c0]
    fsw     f0, 0(t6)
    fsw     f1, BO(t6)
    fsw     f2, 2*BO(t6)
    fsw     f3, 3*BO(t6)
    add     t6, t6, a7
    fsw     f4, 0(t6)
    fsw     f5, BO(t6)
    fsw     f6, 2*BO(t6)
    fsw     f7, 3*BO(t6)
    add     t6, t6, a7
    fsw     f8, 0(t6)
    fsw     f9, BO(t6)
    fsw     f10, 2*BO(t6)
    fsw     f11, 3*BO(t6)
    add     t6, t6, a7
    fsw     f12, 0(t6)
    fsw     f13, BO(t6)
    fsw     f14, 2*BO(t6)
    fsw     f15, 3*BO(t6)
    ecall
