# reduce_all.S  -  whole-grid sum: warp shuffle butterfly + one atomic per warp
#
#   C[0] += sum_{tid < N} A[tid]        (host clears C[0] before launch)
#
#   a0 = tid   a1 = &A   a3 = &C
.include "simtix_v2.inc"
.section .text
.globl _start
_start:
    slli  t0, a0, 2
    add   t1, a1, t0
    lw    t2, 0(t1)        # v = A[tid]
    li    t3, 1
    shfl_xor t4, t2, t3
    add   t2, t2, t4
    li    t3, 2
    shfl_xor t4, t2, t3
    add   t2, t2, t4
    li    t3, 4
    shfl_xor t4, t2, t3
    add   t2, t2, t4       # warp sum in every lane
    andi  t5, a0, 7
    bnez  t5, 1f           # only lane 0 publishes the warp sum
    amoadd.w x0, t2, (a3)  # C[0] += warp sum
1:
    ecall
