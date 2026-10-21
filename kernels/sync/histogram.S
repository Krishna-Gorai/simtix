# histogram.S  -  16-bin histogram with global atomics
#
#   C[A[tid] & 15] += 1            (host clears C[0..15])
#   a0 = tid   a1 = &A   a3 = &C
.section .text
.globl _start
_start:
    slli  t0, a0, 2
    add   t1, a1, t0
    lw    t2, 0(t1)
    andi  t2, t2, 15
    slli  t2, t2, 2
    add   t2, a3, t2       # &C[bin]
    li    t3, 1
    amoadd.w x0, t3, (t2)
    ecall
