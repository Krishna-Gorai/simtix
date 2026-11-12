# jacobi2d.S  -  PolyBench jacobi-2d: one sweep, FP32
#
#   The n x n interior in stencil.S's padded layout (row stride S, (i, j) at word
#   (i+1)*S + LANES + j; the padding is the fixed border). Thread t computes
#   i = t >> log2n, j = t & (n-1):
#       B[i][j] = 0.2f * ((((A[i][j] + A[i][j-1]) + A[i][j+1]) + A[i+1][j]) + A[i-1][j])
#   PolyBench's order of the additions. The host alternates A -> B and B -> A.
#
#   a0 = tid   a1 = &P   a4 = n*n
#   P[0] = &A  P[1] = &B  P[2] = log2n  P[3] = S  P[4] = 0.2f
#include "lanes.h"
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # A
    lw      s1, 4(a1)          # B
    lw      t5, 8(a1)          # log2n
    lw      s3, 12(a1)         # S
    flw     f10, 16(a1)        # 0.2f
    srl     t0, a0, t5         # i
    li      t1, 1
    sll     t1, t1, t5
    addi    t1, t1, -1
    and     t1, a0, t1         # j
    addi    t0, t0, 1
    mul     t0, t0, s3
    add     t0, t0, t1
    addi    t0, t0, LANES      # word index of (i, j)
    slli    t0, t0, 2
    slli    t2, s3, 2          # row stride (bytes)
    add     t3, s0, t0         # &A(i, j)
    flw     f0, 0(t3)          # A[i][j]
    flw     f1, -4(t3)         # A[i][j-1]
    flw     f2, 4(t3)          # A[i][j+1]
    add     t4, t3, t2
    flw     f3, 0(t4)          # A[i+1][j]
    sub     t4, t3, t2
    flw     f4, 0(t4)          # A[i-1][j]
    fadd.s  f0, f0, f1
    fadd.s  f0, f0, f2
    fadd.s  f0, f0, f3
    fadd.s  f0, f0, f4
    fmul.s  f0, f10, f0        # 0.2f * sum
    add     t3, s1, t0
    fsw     f0, 0(t3)          # B[i][j]
    ecall
