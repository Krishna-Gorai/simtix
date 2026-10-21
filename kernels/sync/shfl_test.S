# shfl_test.S  -  every shuffle mode on distinct per-lane values
#
#   v = A[tid]
#   C[  0 + tid] = shfl_idx (v, 3*lane + 1)      wraps mod 8
#   C[ 64 + tid] = shfl_up  (v, 2)
#   C[128 + tid] = shfl_down(v, 3)
#   C[192 + tid] = shfl_xor (v, 5)
#   a0 = tid   a1 = &A   a3 = &C
.include "simtix_v2.inc"
.section .text
.globl _start
_start:
    slli  t0, a0, 2        # tid*4
    add   t1, a1, t0
    lw    s0, 0(t1)        # v = A[tid]
    add   s1, a3, t0       # &C[tid]
    andi  t2, a0, 7        # lane
    slli  t3, t2, 1
    add   t3, t3, t2
    addi  t3, t3, 1        # 3*lane + 1
    shfl_idx  t4, s0, t3
    sw    t4, 0(s1)
    li    t3, 2
    shfl_up   t4, s0, t3
    sw    t4, 256(s1)
    li    t3, 3
    shfl_down t4, s0, t3
    sw    t4, 512(s1)
    li    t3, 5
    shfl_xor  t4, s0, t3
    sw    t4, 768(s1)
    ecall
