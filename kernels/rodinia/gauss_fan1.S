# gauss_fan1.S  -  Rodinia gaussian, kernel Fan1: the multipliers of elimination step t
#
#   The augmented matrix a is n x (n+1) (row stride n+1: b is column n). Thread u
#   computes row i = t + 1 + u:   m[i][t] = a[i][t] / a[t][t]   (m is n x n).
#
#   a0 = tid   a1 = &P
#   P[0] = &a  P[1] = &m  P[2] = n  P[3] = t
.section .text
.globl _start
_start:
    lw      t0, 0(a1)          # a
    lw      t1, 4(a1)          # m
    lw      t2, 8(a1)          # n
    lw      t3, 12(a1)         # t
    addi    t4, t2, 1          # n + 1
    mul     t5, t3, t4
    add     t5, t5, t3         # t*(n+1) + t
    sh2add  t5, t5, t0
    flw     f1, 0(t5)          # a[t][t]
    add     t6, t3, a0
    addi    t6, t6, 1          # i
    mul     a2, t6, t4
    add     a2, a2, t3         # i*(n+1) + t
    sh2add  a2, a2, t0
    flw     f0, 0(a2)          # a[i][t]
    fdiv.s  f0, f0, f1
    mul     a3, t6, t2
    add     a3, a3, t3         # i*n + t
    sh2add  a3, a3, t1
    fsw     f0, 0(a3)          # m[i][t]
    ecall
