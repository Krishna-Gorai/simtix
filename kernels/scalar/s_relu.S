# s_relu.S  -  scalar RV32I baseline for relu:  C[i] = max(0, A[i])
#
# A natural scalar branch (no SIMT masking): a taken branch costs the pipeline's
# 2-cycle flush, which is exactly the single-core cost we want to measure.
#   A @ 0x2000   C @ 0x6000   N @ 0x1000

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
    bge   t3, x0, .Lpos    # if A[i] >= 0 keep it
    li    t3, 0            # else clamp to 0
.Lpos:
    add   t2, a3, t1
    sw    t3, 0(t2)
    addi  t0, t0, 1
    blt   t0, a4, .Lloop
    lui   t1, 0x90000
    sw    t0, 0(t1)
.Lhalt:
    j     .Lhalt
