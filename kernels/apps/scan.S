# scan.S  -  inclusive prefix sum of each 32-thread block, and the block totals
#
#   out[t] = sum of in[32*b .. t] for t in block b;   bsum[b] = out[32*b + 31]
#   Launch with REG_BLOCK = 2 (4 warps per block) and a multiple of 32 threads.
#   Each warp scans with shfl_up; lane 7 puts its warp's total in shared[w], and
#   after the barrier every thread adds the totals of the lower warps of its
#   block. scan_add.S then adds the scanned block totals (a multi-block scan
#   applies scan to bsum recursively first).
#
#   a0 = tid   a1 = &P   a4 = threads
#   P[0] = &in   P[1] = &out   P[2] = &bsum
.include "simtix_v2.inc"
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # in
    lw      s1, 4(a1)          # out
    lw      s2, 8(a1)          # bsum
    slli    t0, a0, 2
    add     t1, s0, t0
    lw      t2, 0(t1)          # v
    andi    s5, a0, 7          # lane
    li      t3, 1
    shfl_up t4, t2, t3
    sltu    t5, s5, t3         # lane < k
    addi    t5, t5, -1         # -1 if lane >= k
    and     t4, t4, t5
    add     t2, t2, t4
    li      t3, 2
    shfl_up t4, t2, t3
    sltu    t5, s5, t3
    addi    t5, t5, -1
    and     t4, t4, t5
    add     t2, t2, t4
    li      t3, 4
    shfl_up t4, t2, t3
    sltu    t5, s5, t3
    addi    t5, t5, -1
    and     t4, t4, t5
    add     t2, t2, t4         # inclusive scan within the warp
    andi    s6, a0, 31
    srli    s6, s6, 3          # warp within the block
    lui     s3, 0x60000        # SHARED_BASE
    li      t3, 7
    bne     s5, t3, 1f
    slli    t4, s6, 2
    add     t4, s3, t4
    sw      t2, 0(t4)          # shared[w] = warp total
1:  bar
    beqz    s6, 3f             # warp 0 has nothing below it
    mv      t5, s6
    mv      t4, s3
2:  lw      t6, 0(t4)
    add     t2, t2, t6         # + total of a lower warp
    addi    t4, t4, 4
    addi    t5, t5, -1
    bnez    t5, 2b
3:  add     t1, s1, t0
    sw      t2, 0(t1)          # out[t]
    andi    t3, a0, 31
    li      t4, 31
    bne     t3, t4, 4f
    srli    t5, a0, 5
    slli    t5, t5, 2
    add     t5, s2, t5
    sw      t2, 0(t5)          # bsum[b] = block total
4:  ecall
