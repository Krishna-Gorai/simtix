# fsaxpy.S  -  M14.4 single-precision AXPY (the canonical FP streaming kernel).
#   C[i] = ALPHA * A[i] + B[i]          (ALPHA = 3.0, hardcoded)
#   One thread per element; fully contiguous so each warp coalesces. Uses a single
#   fused multiply-add (fmadd.s) per element. No divergence.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli    t0, a0, 2          # i*4
    lui     t5, 0x40400        # 0x40400000 = 3.0f
    fmv.w.x f5, t5             # f5 = 3.0
    add     t1, a1, t0
    flw     f1, 0(t1)          # f1 = A[i]
    add     t2, a2, t0
    flw     f2, 0(t2)          # f2 = B[i]
    fmadd.s f3, f5, f1, f2     # f3 = 3.0*A[i] + B[i]  (one rounding)
    add     t3, a3, t0
    fsw     f3, 0(t3)          # C[i] = f3
    ecall
