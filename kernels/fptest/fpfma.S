# fpfma.S  -  M14.1b FP32 fused multiply-add verification kernel.
#   Each thread computes, with a SINGLE rounding, C[i] = A[i]*B[i] + C[i]
#   exercising flw (three FP loads), fmadd.s, and fsw. The result is checked
#   bit-exact in the testbench against a single-rounded fmaf reference.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C  (C is read AND written)
.section .text
.globl _start
_start:
    slli    t0, a0, 2          # i*4
    add     t1, a1, t0         # &A[i]
    flw     f1, 0(t1)          # f1 = A[i]
    add     t2, a2, t0         # &B[i]
    flw     f2, 0(t2)          # f2 = B[i]
    add     t3, a3, t0         # &C[i]
    flw     f3, 0(t3)          # f3 = C[i]
    fmadd.s f4, f1, f2, f3     # f4 = A[i]*B[i] + C[i]  (one rounding)
    fsw     f4, 0(t3)          # C[i] = f4
    ecall
