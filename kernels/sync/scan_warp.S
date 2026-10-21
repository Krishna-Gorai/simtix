# scan_warp.S  -  inclusive prefix sum within each warp (shfl_up, branch-free)
#
#   C[tid] = sum_{j = 8*w .. tid} A[j]
#
# Step k adds the value k lanes below. shfl_up returns the lane's own value when
# lane < k, so that term is masked to zero with (lane >= k) ? -1 : 0.
#   a0 = tid   a1 = &A   a3 = &C
.include "simtix_v2.inc"
.section .text
.globl _start
_start:
    slli  t0, a0, 2
    add   t1, a1, t0
    lw    t2, 0(t1)        # v = A[tid]
    andi  s0, a0, 7        # lane
    li    t3, 1
    shfl_up t4, t2, t3
    sltu  t5, s0, t3       # lane < k
    addi  t5, t5, -1       # -1 if lane >= k, else 0
    and   t4, t4, t5
    add   t2, t2, t4
    li    t3, 2
    shfl_up t4, t2, t3
    sltu  t5, s0, t3
    addi  t5, t5, -1
    and   t4, t4, t5
    add   t2, t2, t4
    li    t3, 4
    shfl_up t4, t2, t3
    sltu  t5, s0, t3
    addi  t5, t5, -1
    and   t4, t4, t5
    add   t2, t2, t4
    add   t6, a3, t0
    sw    t2, 0(t6)
    ecall
