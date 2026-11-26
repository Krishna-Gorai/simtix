# reduce_shfl.S  -  per-warp segmented sum with a warp shuffle butterfly
#
#   C[w] = sum_{l=0..LANES-1} A[LANES*w + l]      (same output as kernels/reduce/reduce.S)
#
# log2(LANES) shfl_xor + add steps leave the full warp sum in every lane, so all
# lanes store the same word to C[w]: one coalesced store, no divergence and no
# scratchpad round trip (reduce.S serialises the collapse on lane 0).
#   a0 = tid   a1 = &A   a3 = &C
#include "lanes.h"
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
    add   t2, t2, t4       # quads (the whole warp at 4 lanes)
#if LANES >= 8
    li    t3, 4
    shfl_xor t4, t2, t3
    add   t2, t2, t4       # eights (the whole warp at 8 lanes)
#endif
#if LANES >= 16
    li    t3, 8
    shfl_xor t4, t2, t3
    add   t2, t2, t4       # the whole warp at 16 lanes
#endif
    srli  t5, a0, LOG2L    # warp = tid >> log2(LANES)
    slli  t5, t5, 2
    add   t5, a3, t5
    sw    t2, 0(t5)        # C[warp] = sum (every lane, same value)
    ecall
