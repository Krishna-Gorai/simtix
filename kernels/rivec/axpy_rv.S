# axpy_rv.S  -  RiVEC axpy (docs/rivec_plan.md), FP32, one element per thread
#
#   dy[t] = fma(a, dx[t], dy[t])        (axpy_vector: vfmacc)
#
#   a0 = tid   a1 = &P
#   P[0] = &dx  P[1] = &dy  P[2] = a (f32)
.section .text
.globl _start
_start:
    lw      t0, 0(a1)          # dx
    lw      t1, 4(a1)          # dy
    flw     f2, 8(a1)          # a
    sh2add  t0, a0, t0
    sh2add  t1, a0, t1
    flw     f0, 0(t0)          # dx[t]
    flw     f1, 0(t1)          # dy[t]
    fmadd.s f1, f2, f0, f1     # a*dx + dy
    fsw     f1, 0(t1)
    ecall
