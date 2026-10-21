# reduce_shfl.S  -  per-warp segmented sum with a warp shuffle butterfly
#
#   C[w] = sum_{l=0..7} A[8*w + l]      (same output as kernels/reduce/reduce.S)
#
# Three shfl_xor + add steps leave the full warp sum in every lane, so all eight
# lanes store the same word to C[w]: one coalesced store, no divergence and no
# scratchpad round trip (reduce.S serialises the collapse on lane 0).
#   a0 = tid   a1 = &A   a3 = &C
.include "simtix_v2.inc"
.section .text
.globl _start
_start:
    slli  t0, a0, 2        # tid*4
    add   t1, a1, t0
    lw    t2, 0(t1)        # v = A[tid]
    li    t3, 1
    shfl_xor t4, t2, t3
    add   t2, t2, t4       # pairs
    li    t3, 2
    shfl_xor t4, t2, t3
    add   t2, t2, t4       # quads
    li    t3, 4
    shfl_xor t4, t2, t3
    add   t2, t2, t4       # whole warp
    srli  t5, a0, 3        # warp = tid >> 3
    slli  t5, t5, 2
    add   t5, a3, t5
    sw    t2, 0(t5)        # C[warp] = sum (every lane, same value)
    ecall
