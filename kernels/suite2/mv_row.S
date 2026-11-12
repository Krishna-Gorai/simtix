# mv_row.S  -  matrix-vector product by rows, FP32 (PolyBench atax: tmp = A x; bicg: q = A p)
#
#   y[i] = fma(A[i][n-1], x[n-1], ... fma(A[i][0], x[0], +0))     (in j order)
#   Thread t computes row i = t; A is n x n row-major. The x loads are broadcasts
#   within a warp; each thread walks its own row (two products per iteration).
#
#   a0 = tid   a1 = &P   a4 = n
#   P[0] = &A  P[1] = &x  P[2] = &y  P[3] = n (even)
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # A
    lw      s1, 4(a1)          # x
    lw      s2, 8(a1)          # y
    lw      s3, 12(a1)         # n
    mul     t0, a0, s3
    sh2add  s0, t0, s0         # &A[i][0]
    sh2add  t6, s3, s1         # &x[n]
    fmv.w.x f0, x0             # +0
1:  flw     f1, 0(s0)          # A[i][j]
    flw     f2, 0(s1)          # x[j]
    flw     f3, 4(s0)          # A[i][j+1]
    flw     f4, 4(s1)          # x[j+1]
    fmadd.s f0, f1, f2, f0
    fmadd.s f0, f3, f4, f0
    addi    s0, s0, 8
    addi    s1, s1, 8
    bne     s1, t6, 1b
    sh2add  t0, a0, s2
    fsw     f0, 0(t0)          # y[i]
    ecall
