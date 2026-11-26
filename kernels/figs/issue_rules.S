# issue_rules.S  -  FPU dependency chains between independent integer instructions
#
# Run on four warps by tests/tb_figtrace.sv (KERN 2; docs/figs/arch_v2_tikz/fig_trace.py, run
# rules4): its issue trace validates the issue-rule model of the latency figure
# (lat_sched.py, check_lat_sched.py). No memory instruction, so every latency is fixed.
.section .text
.globl _start
_start:
    fmadd.s f1, f1, f1, f1      # 0
    add     t0, a0, a0          # 1  independent
    fmadd.s f2, f1, f1, f1      # 2  waits for 0
    add     t1, t0, t0          # 3
    fmul.s  f3, f2, f2          # 4  waits for 2
    fadd.s  f4, f0, f0          # 5  independent FPU op
    fadd.s  f5, f3, f4          # 6  waits for 4 and 5 (5's write wakes it first)
    ecall                       #    waits for every pending result
