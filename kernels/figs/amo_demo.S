# amo_demo.S  -  the AMO example of the paper: eight lanes add 1 to words of one line
#
#   a0 = tid   a1 = &idx (the word of each lane: 3, 3, 5, 0, 3, 5, 7, 1)   a2 = &r   a3 = &C
#   r[tid] = C[idx[tid]]++ with amoadd.w; afterwards C[w] = the number of lanes on word w, and
#   r[tid] = the number of lower lanes on the same word (the value serial execution returns)
#
# Traced by tests/tb_figtrace.sv (KERN 3; docs/figs/arch_v2_tikz/fig_trace.py, runs amo_ser,
# amo_par and amo_lane) for the AMO figure: lanes 0, 1 and 4 share word 3, lanes 2 and 5
# word 5, so the serial unit takes eight apply cycles and the parallel one three rounds.
.section .text
.globl _start
_start:
    slli     t0, a0, 2
    add      t1, a1, t0          # &idx[tid]
    lw       t2, 0(t1)           # this lane's word
    slli     t2, t2, 2
    add      t3, a3, t2          # &C[word]
    li       t4, 1
    amoadd.w t5, t4, (t3)        # one AMO instruction for the warp
    add      t6, a2, t0
    sw       t5, 0(t6)           # the old value it returned
    ecall
