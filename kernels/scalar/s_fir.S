# s_fir.S  -  scalar RV32I baseline for fir:  C[i] = A[i] + 2*A[i+1] + A[i+2]
#
# 2*A[i+1] via a shift (no `mul` on RV32I).  A carries a 2-element halo.
#   A @ 0x2000 (len N+2)   C @ 0x6000   N @ 0x1000

.section .text
.globl _start
_start:
    lui   a1, 0x2
    lui   a3, 0x6
    lui   t6, 0x1
    lw    a4, 0(t6)        # N
    li    t0, 0
.Lloop:
    slli  t1, t0, 2
    add   t2, a1, t1
    lw    t3, 0(t2)        # A[i]
    lw    t4, 4(t2)        # A[i+1]
    lw    t5, 8(t2)        # A[i+2]
    slli  t4, t4, 1        # 2*A[i+1]
    add   t3, t3, t4
    add   t3, t3, t5
    add   t2, a3, t1
    sw    t3, 0(t2)
    addi  t0, t0, 1
    blt   t0, a4, .Lloop
    lui   t1, 0x90000
    sw    t0, 0(t1)
.Lhalt:
    j     .Lhalt
