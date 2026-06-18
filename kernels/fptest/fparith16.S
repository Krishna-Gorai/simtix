# fparith16.S  -  M14.2 half-precision (FP16) arithmetic verification kernel.
#   Each thread computes, in FP16, C[i] = A[i] * B[i] + B[i]  exercising flw (the
#   NaN-boxed half operands ride in 32-bit words), fmul.h, fadd.h, and fsw. The
#   result is checked bit-exact in the testbench against a DPI half reference.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C   (A/B/C hold NaN-boxed FP16 words)
.section .text
.globl _start
_start:
    slli   t0, a0, 2          # i*4 (one boxed half word per thread)
    add    t1, a1, t0         # &A[i]
    flw    f1, 0(t1)          # f1 = boxed A[i]
    add    t2, a2, t0         # &B[i]
    flw    f2, 0(t2)          # f2 = boxed B[i]
    fmul.h f3, f1, f2         # f3 = A[i] * B[i]   (half)
    fadd.h f3, f3, f2         # f3 = A[i] * B[i] + B[i]
    add    t3, a3, t0         # &C[i]
    fsw    f3, 0(t3)          # C[i] = f3   (boxed half)
    ecall
