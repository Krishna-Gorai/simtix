# fsaxpy16.S  -  M14.4 half-precision AXPY (FP16 streaming with fused multiply-add).
#   C[i] = ALPHA * A[i] + B[i]          (ALPHA = 3.0h, hardcoded, NaN-boxed)
#   Operands ride through memory and the f-file as NaN-boxed FP16 words. Uses
#   fmadd.h per element. a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli    t0, a0, 2          # i*4 (one boxed half word per thread)
    lui     t5, 0xffff4        # NaN-box upper half + 0x4...
    addi    t5, t5, 0x200      # 0xffff4200 = NaN-boxed 3.0h (0x4200)
    fmv.w.x f5, t5             # f5 = boxed 3.0h
    add     t1, a1, t0
    flw     f1, 0(t1)          # f1 = boxed A[i]
    add     t2, a2, t0
    flw     f2, 0(t2)          # f2 = boxed B[i]
    fmadd.h f3, f5, f1, f2     # f3 = 3.0*A[i] + B[i]  (half, one rounding)
    add     t3, a3, t0
    fsw     f3, 0(t3)          # C[i] = f3
    ecall
