# divergence.S  -  a one-sided if and a loop whose trip count differs per lane
#
#   a0 = tid   a3 = &C        C[tid] = (tid >= 3 ? 2 tid + 1 : 0) + (tid mod 4) + 1
#
# Traced on one warp by tests/tb_figtrace.sv (docs/figs/arch_v2_tikz/fig_trace.py):
#  - the forward branch diverges: the not-taken lanes 3-7 run the body under a pushed
#    frame whose RPC is the branch target, and pop there;
#  - the backward branch keeps the lanes with iterations left in the loop: lane l leaves
#    after (l mod 4) + 1 iterations, so each iteration pushes one more frame (four
#    frames for four trip counts) and the frames pop in turn at the exit.
.section .text
.globl _start
_start:
    slti    t0, a0, 3           # t0 = (tid < 3)
    bnez    t0, 1f              # forward branch: lanes 0-2 skip the body
    slli    a5, a0, 1           #   x = 2 tid
    addi    a5, a5, 1           #   x = 2 tid + 1
1:  andi    t1, a0, 3           # iterations left - 1
2:  addi    a5, a5, 1           # loop body: x += 1
    addi    t1, t1, -1
    bgez    t1, 2b              # backward branch: lanes with iterations left stay
    slli    t2, a0, 2
    add     t2, a3, t2
    sw      a5, 0(t2)           # C[tid] = x
    ecall
