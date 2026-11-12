# gauss_fan2.S  -  Rodinia gaussian, kernel Fan2: elimination step t
#
#   The augmented matrix a is n x (n+1) (b is column n, so Rodinia's b update is the
#   last column). Thread u owns column j = t + u (j = t .. n) and walks the rows below
#   the pivot:   for i = t+1 .. n-1:  a[i][j] = fma(-m[i][t], a[t][j], a[i][j])
#   (one rounding: Rodinia's a[i][j] -= m[i][t] * a[t][j], fused). The row loop is the
#   same for every thread, so a warp never diverges; m[i][t] is a broadcast load.
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
    addi    t4, t2, 1          # n + 1 (row stride of a, in words)
    slli    a5, t4, 2          # row stride of a, bytes
    slli    a6, t2, 2          # row stride of m, bytes
    add     t5, t3, a0         # j
    mul     t6, t3, t4
    add     t6, t6, t5
    sh2add  t6, t6, t0
    flw     f1, 0(t6)          # a[t][j]
    add     t6, t6, a5         # &a[t+1][j]
    addi    a2, t3, 1
    mul     a3, a2, t2
    add     a3, a3, t3
    sh2add  a3, a3, t1         # &m[t+1][t]
    beq     a2, t2, 2f         # t = n-1: no rows below
1:  flw     f2, 0(a3)          # m[i][t]
    flw     f0, 0(t6)          # a[i][j]
    fnmsub.s f0, f2, f1, f0    # a[i][j] - m[i][t]*a[t][j], one rounding
    fsw     f0, 0(t6)
    add     t6, t6, a5
    add     a3, a3, a6
    addi    a2, a2, 1
    bne     a2, t2, 1b
2:  ecall
