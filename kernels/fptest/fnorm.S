# fnorm.S  -  M14.4 single-precision element-wise normalize (SFU-heavy).
#   C[i] = A[i] / sqrt(B[i])
#   A vector-normalize / inverse-scale step (as in batch-norm or RMS scaling),
#   exercising BOTH multi-cycle SFU ops per element (fsqrt then fdiv). B is
#   positive. a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli    t0, a0, 2          # i*4
    add     t1, a1, t0
    flw     f1, 0(t1)          # f1 = A[i]
    add     t2, a2, t0
    flw     f2, 0(t2)          # f2 = B[i]
    fsqrt.s f3, f2             # f3 = sqrt(B[i])      (SFU)
    fdiv.s  f4, f1, f3         # f4 = A[i] / sqrt(B)  (SFU)
    add     t3, a3, t0
    fsw     f4, 0(t3)          # C[i] = f4
    ecall
