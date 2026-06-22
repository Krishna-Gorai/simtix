# fpdivsqrt.S  -  M14.3 divide + square-root verification kernel.
#   Each thread computes C[i] = sqrt(A[i] / B[i]), exercising BOTH multi-cycle SFU
#   ops back-to-back (fdiv then fsqrt, with a data dependency f3->f4) so the stall
#   scoreboard must park/resume the warp twice. A,B are positive; checked bit-exact
#   against sqrt(div(A,B)) in the testbench.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli    t0, a0, 2
    add     t1, a1, t0
    flw     f1, 0(t1)          # f1 = A[i]
    add     t2, a2, t0
    flw     f2, 0(t2)          # f2 = B[i]
    fdiv.s  f3, f1, f2         # f3 = A[i] / B[i]   (SFU)
    fsqrt.s f4, f3             # f4 = sqrt(f3)      (SFU)
    add     t3, a3, t0
    fsw     f4, 0(t3)          # C[i] = f4
    ecall
