# s_reduce.S  -  scalar RV32I baseline for reduce:  C[w] = sum_{l=0..7} A[8w+l]
#
# Outer loop over the N/8 segments, inner 8-element accumulation (unrolled).
#   A @ 0x2000   C @ 0x6000   N @ 0x1000

.section .text
.globl _start
_start:
    lui   a1, 0x2
    lui   a3, 0x6
    lui   t6, 0x1
    lw    a4, 0(t6)        # N
    srli  a5, a4, 3        # nwarps = N/8
    li    t0, 0            # w = 0
.Lloop:
    slli  t1, t0, 5        # w*32  (8 words)
    add   t2, a1, t1       # &A[8w]
    li    t3, 0            # acc
    lw    t4,  0(t2); add t3, t3, t4
    lw    t4,  4(t2); add t3, t3, t4
    lw    t4,  8(t2); add t3, t3, t4
    lw    t4, 12(t2); add t3, t3, t4
    lw    t4, 16(t2); add t3, t3, t4
    lw    t4, 20(t2); add t3, t3, t4
    lw    t4, 24(t2); add t3, t3, t4
    lw    t4, 28(t2); add t3, t3, t4
    slli  t5, t0, 2
    add   t6, a3, t5       # &C[w]
    sw    t3, 0(t6)
    addi  t0, t0, 1
    blt   t0, a5, .Lloop
    lui   t1, 0x90000
    sw    t0, 0(t1)
.Lhalt:
    j     .Lhalt
