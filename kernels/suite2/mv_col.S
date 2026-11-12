# mv_col.S  -  transposed matrix-vector product, FP32 (PolyBench atax: y = A^T tmp;
#              bicg: s = A^T r)
#
#   y[j] = fma(A[n-1][j], x[n-1], ... fma(A[0][j], x[0], +0))     (in i order)
#   Thread t computes column j = t; a warp reads one line of A per row (coalesced)
#   and x[i] is a broadcast. Two rows per iteration.
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
    sh2add  s0, a0, s0         # &A[0][j]
    slli    t1, s3, 2          # row stride (bytes)
    slli    t2, s3, 3          # two rows
    sh2add  t6, s3, s1         # &x[n]
    fmv.w.x f0, x0             # +0
1:  add     t3, s0, t1
    flw     f1, 0(s0)          # A[i][j]
    flw     f2, 0(s1)          # x[i]
    flw     f3, 0(t3)          # A[i+1][j]
    flw     f4, 4(s1)          # x[i+1]
    fmadd.s f0, f1, f2, f0
    fmadd.s f0, f3, f4, f0
    add     s0, s0, t2
    addi    s1, s1, 8
    bne     s1, t6, 1b
    sh2add  t0, a0, s2
    fsw     f0, 0(t0)          # y[j]
    ecall
