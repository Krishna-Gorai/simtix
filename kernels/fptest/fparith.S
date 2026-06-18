# fparith.S  -  M14.1 FP arithmetic verification kernel.
#   Each thread computes a fused-style expression through the per-lane FPU:
#       C[i] = A[i] * B[i] + B[i]
#   exercising flw (two FP loads), fmul.s, fadd.s, and fsw end-to-end. The result
#   is checked bit-exact in the testbench against a DPI IEEE-754 float reference.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli   t0, a0, 2          # i*4
    add    t1, a1, t0         # &A[i]
    flw    f1, 0(t1)          # f1 = A[i]
    add    t2, a2, t0         # &B[i]
    flw    f2, 0(t2)          # f2 = B[i]
    fmul.s f3, f1, f2         # f3 = A[i] * B[i]
    fadd.s f3, f3, f2         # f3 = A[i] * B[i] + B[i]
    add    t3, a3, t0         # &C[i]
    fsw    f3, 0(t3)          # C[i] = f3
    ecall
