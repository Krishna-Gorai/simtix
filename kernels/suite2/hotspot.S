# hotspot.S  -  Rodinia hotspot: one step of the thermal simulation, FP32
#
#   The n x n interior (n a power of two) sits in a padded array as stencil.S's: row
#   stride S, interior (i, j) at word (i+1)*S + LANES + j; the padding is the fixed
#   (ghost) border. Thread t computes i = t >> log2n, j = t & (n-1):
#       a = (tN + tS) - (t + t)      b = (tE + tW) - (t + t)      c = amb - t
#       s = fma(a, ry1, p)   s = fma(b, rx1, s)   s = fma(c, rz1, s)
#       out = fma(sdc, s, t)
#   tN = T(i-1, j), tS = T(i+1, j), tE = T(i, j+1), tW = T(i, j-1); the power p uses
#   the same layout. Rodinia's constants (rx1 = 1/Rx, ...) come from the host.
#
#   a0 = tid   a1 = &P   a4 = n*n
#   P[0] = &Tin  P[1] = &Tout  P[2] = &Pw  P[3] = log2n  P[4] = S
#   P[5] = rx1  P[6] = ry1  P[7] = rz1  P[8] = amb  P[9] = sdc   (f32)
#include "lanes.h"
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # Tin
    lw      s1, 4(a1)          # Tout
    lw      s2, 8(a1)          # Pw
    lw      t5, 12(a1)         # log2n
    lw      s3, 16(a1)         # S
    flw     f10, 20(a1)        # rx1
    flw     f11, 24(a1)        # ry1
    flw     f12, 28(a1)        # rz1
    flw     f13, 32(a1)        # amb
    flw     f14, 36(a1)        # sdc
    srl     t0, a0, t5         # i
    li      t1, 1
    sll     t1, t1, t5
    addi    t1, t1, -1
    and     t1, a0, t1         # j
    addi    t0, t0, 1
    mul     t0, t0, s3         # (i+1)*S
    add     t0, t0, t1
    addi    t0, t0, LANES      # word index of (i, j)
    slli    t0, t0, 2          # byte offset
    slli    t2, s3, 2          # row stride (bytes)
    add     t3, s0, t0         # &T(i, j)
    flw     f0, 0(t3)          # t
    flw     f4, 4(t3)          # tE
    flw     f5, -4(t3)         # tW
    sub     t4, t3, t2
    flw     f2, 0(t4)          # tN
    add     t4, t3, t2
    flw     f3, 0(t4)          # tS
    add     t4, s2, t0
    flw     f6, 0(t4)          # p
    fadd.s  f1, f0, f0         # t + t
    fadd.s  f2, f2, f3         # tN + tS
    fadd.s  f4, f4, f5         # tE + tW
    fsub.s  f2, f2, f1         # a
    fsub.s  f4, f4, f1         # b
    fsub.s  f7, f13, f0        # c = amb - t
    fmadd.s f6, f2, f11, f6    # s = fma(a, ry1, p)
    fmadd.s f6, f4, f10, f6    # s = fma(b, rx1, s)
    fmadd.s f6, f7, f12, f6    # s = fma(c, rz1, s)
    fmadd.s f0, f14, f6, f0    # out = fma(sdc, s, t)
    add     t3, s1, t0
    fsw     f0, 0(t3)          # Tout(i, j)
    ecall
