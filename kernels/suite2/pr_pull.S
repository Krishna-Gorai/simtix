# pr_pull.S  -  GAP PageRank, second step of an iteration (pull over the in-edges)
#
#   acc = +0;  acc = acc + c[u]  for u = col[rowptr[v]] .. col[rowptr[v+1]-1]  (in order)
#   pr'[v] = fma(d, acc, base)
#   One thread per vertex v; the graph is symmetric, so the CSR rows are the in-edges.
#
#   a0 = tid   a1 = &P   a4 = N
#   P[0] = &rowptr  P[1] = &col  P[2] = &c  P[3] = &pr'  P[4] = d  P[5] = base  (f32)
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # rowptr
    lw      s1, 4(a1)          # col
    lw      s2, 8(a1)          # c
    lw      s3, 12(a1)         # pr'
    flw     f10, 16(a1)        # d
    flw     f11, 20(a1)        # base
    sh2add  t0, a0, s0
    lw      t1, 0(t0)          # rowptr[v]
    lw      t2, 4(t0)          # rowptr[v+1]
    sh2add  t1, t1, s1         # &col[first]
    sh2add  t2, t2, s1         # &col[end]
    fmv.w.x f0, x0             # +0
    beq     t1, t2, 2f
1:  lw      t3, 0(t1)          # u
    sh2add  t3, t3, s2
    flw     f1, 0(t3)          # c[u]
    fadd.s  f0, f0, f1
    addi    t1, t1, 4
    bne     t1, t2, 1b
2:  fmadd.s f0, f10, f0, f11   # fma(d, acc, base)
    sh2add  t0, a0, s3
    fsw     f0, 0(t0)          # pr'[v]
    ecall
