# spmv_z.S  -  y = A x, CSR, one row per thread, with Zba addressing (v3)
#
#   Same results as spmv.S (the row's products are accumulated in the same order
#   with fmadd). The column and value arrays are walked with pointers and the
#   gather address x + 4*col[j] is one sh2add: 8 instructions per nonzero (11).
#   a0 = tid   a1 = &P   a4 = rows
#   P[0] = &rowptr  P[1] = &col  P[2] = &val  P[3] = &x  P[4] = &y
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # rowptr
    lw      s1, 4(a1)          # col
    lw      s2, 8(a1)          # val
    lw      s3, 12(a1)         # x
    lw      s4, 16(a1)         # y
    sh2add  t0, a0, s0
    lw      t1, 0(t0)          # j = rowptr[r]
    lw      t2, 4(t0)          # end = rowptr[r+1]
    fmv.w.x f0, x0             # acc = +0.0
    bge     t1, t2, 2f
    sh2add  t3, t1, s1         # -> col[j]
    sh2add  t4, t1, s2         # -> val[j]
    sh2add  t6, t2, s1         # -> col[end]
1:  lw      t5, 0(t3)          # col[j]
    flw     f1, 0(t4)          # val[j]
    sh2add  t5, t5, s3
    flw     f2, 0(t5)          # x[col[j]]
    fmadd.s f0, f1, f2, f0
    addi    t3, t3, 4
    addi    t4, t4, 4
    bne     t3, t6, 1b
2:  sh2add  t0, a0, s4
    fsw     f0, 0(t0)          # y[r]
    ecall
