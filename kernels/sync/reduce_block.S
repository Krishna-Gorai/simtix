# reduce_block.S  -  thread-block sum through the block-shared scratchpad
#
#   C[b] = sum of the 2^a2 elements of block b      (a2 = log2 threads per block)
#
# Launch with REG_BLOCK = a2 - 3 (warps per block = 2^(a2-3)). Each warp reduces
# with a shuffle butterfly and lane 0 writes its sum to shared[warp in block];
# after the barrier the block's thread 0 adds the per-warp partial sums.
#   a0 = tid   a1 = &A   a2 = log2(threads per block)   a3 = &C   a4 = N
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
    li    s0, 1
    sll   s0, s0, a2
    addi  s0, s0, -1       # threads-per-block mask
    and   s1, a0, s0       # local thread id
    srli  s2, s1, 3        # warp within block
    slli  s2, s2, 2
    lui   s3, 0x60000      # SHARED_BASE
    add   s2, s3, s2       # &shared[warp within block]
    andi  t5, a0, 7
    bnez  t5, 1f
    sw    t2, 0(s2)        # lane 0: shared[wib] = warp sum
1:
    bar
    bnez  s1, 3f           # only the block's thread 0 continues
    srli  s4, s0, 3
    addi  s4, s4, 1        # warps per block
    sub   t0, a4, a0       # threads left from this block's base (a0 = base here)
    addi  t0, t0, 7
    srli  t0, t0, 3        # warps present in a partial last block
    bgeu  t0, s4, 4f
    mv    s4, t0           # sum only the warps that exist
4:
    li    t6, 0            # acc
2:
    lw    t1, 0(s3)
    add   t6, t6, t1
    addi  s3, s3, 4
    addi  s4, s4, -1
    bnez  s4, 2b
    srl   t5, a0, a2       # block index
    slli  t5, t5, 2
    add   t5, a3, t5
    sw    t6, 0(t5)        # C[block] = block sum
3:
    ecall
