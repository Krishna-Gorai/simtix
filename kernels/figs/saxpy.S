# saxpy.S  -  y[tid] = a * x[tid] + y[tid], the kernel the paper's operation figures trace
#
#   a0 = tid   a1 = &x   a2 = &y   a3 = &a   a4 = N
#
# Traced by tests/tb_figtrace.sv (docs/figs/arch_v2_tikz/fig_trace.py). The three loads go
# through the coalescer as one line request each: x and y are contiguous, and a is one
# word that every lane reads.
.section .text
.globl _start
_start:
    bgeu    a0, a4, 1f          # if (tid >= N) return: a uniform branch (stage B)
    flw     f0, 0(a3)           # a, the same word in every lane
    slli    t0, a0, 2           # byte offset of element tid
    add     t1, a1, t0          # &x[tid]
    add     t2, a2, t0          # &y[tid]
    flw     f1, 0(t1)           # x[tid]
    flw     f2, 0(t2)           # y[tid]
    fmadd.s f2, f0, f1, f2      # a * x + y: waits for the three loads (scoreboard)
    fsw     f2, 0(t2)           # y[tid]: waits for the FMA result
1:  ecall
