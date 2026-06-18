# fpvadd.S  -  M14 FP32 streaming add kernel (benchmark).
#   C[i] = A[i] + B[i]  in single precision (flw, fadd.s, fsw).
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli   t0, a0, 2
    add    t1, a1, t0
    flw    f1, 0(t1)
    add    t2, a2, t0
    flw    f2, 0(t2)
    fadd.s f3, f1, f2
    add    t3, a3, t0
    fsw    f3, 0(t3)
    ecall
