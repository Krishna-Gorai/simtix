# hotspot_rd.S  -  Rodinia hotspot: one time step of the thermal simulation, FP32
#
#   Every cell of the n x n grid (n a power of two, row-major) is computed. A neighbour
#   outside the grid is replaced by the cell itself, as Rodinia's clamped indices do:
#   iN = max(i-1, 0), iS = min(i+1, n-1), jW = max(j-1, 0), jE = min(j+1, n-1).
#   Thread t computes i = t >> log2n, j = t & (n-1):
#       a = (tN + tS) - (t + t)      b = (tE + tW) - (t + t)      c = amb - t
#       s = fma(a, ry1, p)   s = fma(b, rx1, s)   s = fma(c, rz1, s)
#       out = fma(sdc, s, t)
#   Rodinia's constants (rx1 = 1/Rx, ..., sdc = step/Cap) come from the host.
#
#   a0 = tid   a1 = &P
#   P[0] = &Tin  P[1] = &Tout  P[2] = &Pw  P[3] = log2n
#   P[4] = rx1  P[5] = ry1  P[6] = rz1  P[7] = amb  P[8] = sdc   (f32)
#include "lanes.h"
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # Tin
    lw      s1, 4(a1)          # Tout
    lw      s2, 8(a1)          # Pw
    lw      t5, 12(a1)         # log2n
    flw     f10, 16(a1)        # rx1
    flw     f11, 20(a1)        # ry1
    flw     f12, 24(a1)        # rz1
    flw     f13, 28(a1)        # amb
    flw     f14, 32(a1)        # sdc
    li      t6, 1
    sll     t6, t6, t5
    addi    t6, t6, -1         # n - 1
    srl     t0, a0, t5         # i
    and     t1, a0, t6         # j
    addi    t2, t0, -1
    max     t2, t2, zero       # iN
    addi    t3, t0, 1
    minu    t3, t3, t6         # iS
    addi    t4, t1, -1
    max     t4, t4, zero       # jW
    addi    a2, t1, 1
    minu    a2, a2, t6         # jE
    sll     t0, t0, t5         # i * n
    sll     t2, t2, t5         # iN * n
    sll     t3, t3, t5         # iS * n
    add     a3, t0, t1         # q = i*n + j
    sh2add  a4, a3, s0
    flw     f0, 0(a4)          # t
    add     t2, t2, t1
    sh2add  t2, t2, s0
    flw     f2, 0(t2)          # tN
    add     t3, t3, t1
    sh2add  t3, t3, s0
    flw     f3, 0(t3)          # tS
    add     t4, t0, t4
    sh2add  t4, t4, s0
    flw     f4, 0(t4)          # tW
    add     a2, t0, a2
    sh2add  a2, a2, s0
    flw     f5, 0(a2)          # tE
    sh2add  a5, a3, s2
    flw     f6, 0(a5)          # p
    fadd.s  f1, f0, f0         # t + t
    fadd.s  f2, f2, f3         # tN + tS
    fadd.s  f4, f5, f4         # tE + tW
    fsub.s  f2, f2, f1         # a
    fsub.s  f4, f4, f1         # b
    fsub.s  f7, f13, f0        # c = amb - t
    fmadd.s f6, f2, f11, f6    # s = fma(a, ry1, p)
    fmadd.s f6, f4, f10, f6    # s = fma(b, rx1, s)
    fmadd.s f6, f7, f12, f6    # s = fma(c, rz1, s)
    fmadd.s f0, f14, f6, f0    # out = fma(sdc, s, t)
    sh2add  a3, a3, s1
    fsw     f0, 0(a3)          # Tout(i, j)
    ecall
