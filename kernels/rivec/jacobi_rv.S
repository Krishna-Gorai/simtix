# jacobi_rv.S  -  RiVEC jacobi-2d (docs/rivec_plan.md): one sweep, FP32
#
#   A and B are n x n row-major (n a power of two), the border fixed. Thread t is point
#   i = t >> log2n, j = t & (n-1); border points do nothing. An interior point computes,
#   in RiVEC's vector order (kernel_jacobi_2d_vector, read per element):
#       B[i][j] = (((A[i][j] + A[i][j-1]) + A[i][j+1]) + (A[i+1][j] + A[i-1][j])) * 0.2f
#   The host alternates A -> B and B -> A.
#
#   a0 = tid   a1 = &P
#   P[0] = &A (source)  P[1] = &B (destination)  P[2] = log2n  P[3] = 0.2f
.section .text
.globl _start
_start:
    lw      t2, 8(a1)          # log2n
    li      t3, 1
    sll     t3, t3, t2         # n
    srl     t4, a0, t2         # i
    addi    t5, t3, -1
    and     t5, a0, t5         # j
    addi    t6, t3, -2         # n - 2
    addi    a2, t4, -1
    bgeu    a2, t6, 1f         # i - 1 >= n - 2 (unsigned): border row
    addi    a2, t5, -1
    bgeu    a2, t6, 1f         # border column
    lw      t0, 0(a1)          # A
    lw      t1, 4(a1)          # B
    flw     f6, 12(a1)         # 0.2f
    sh2add  a3, a0, t0         # &A[i][j]
    sh2add  a4, t3, a3         # &A[i+1][j]
    sub     a5, a3, t3
    sub     a5, a5, t3
    sub     a5, a5, t3
    sub     a5, a5, t3         # &A[i-1][j] (4n bytes back)
    flw     f0, 0(a3)          # c
    flw     f1, -4(a3)         # left
    flw     f2, 4(a3)          # right
    flw     f3, 0(a4)          # bottom
    flw     f4, 0(a5)          # top
    fadd.s  f0, f0, f1
    fadd.s  f0, f0, f2
    fadd.s  f3, f3, f4
    fadd.s  f0, f0, f3
    fmul.s  f0, f0, f6
    sh2add  a6, a0, t1
    fsw     f0, 0(a6)          # B[i][j]
1:  ecall
