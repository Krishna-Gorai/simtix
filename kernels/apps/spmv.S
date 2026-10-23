# spmv.S  -  FP32 sparse matrix-vector product, CSR, one thread per row
#
#   y[r] = sum over j in [rowptr[r], rowptr[r+1]) of val[j] * x[col[j]]
#   accumulated in order with fmadd from +0.0. Rows differ in length, so the
#   loop diverges; x[col[j]] is a gather.
#
#   a0 = tid (row)   a1 = &P   a4 = rows
#   P[0] = &rowptr   P[1] = &col   P[2] = &val   P[3] = &x   P[4] = &y
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # rowptr
    lw      s1, 4(a1)          # col
    lw      s2, 8(a1)          # val
    lw      s3, 12(a1)         # x
    lw      s4, 16(a1)         # y
    slli    t0, a0, 2
    add     t0, s0, t0
    lw      t1, 0(t0)          # j = rowptr[r]
    lw      t2, 4(t0)          # end = rowptr[r+1]
    fmv.w.x f0, x0             # acc = +0.0
    bge     t1, t2, 2f
1:  slli    t3, t1, 2
    add     t4, s1, t3
    lw      t5, 0(t4)          # col[j]
    add     t4, s2, t3
    flw     f1, 0(t4)          # val[j]
    slli    t5, t5, 2
    add     t5, s3, t5
    flw     f2, 0(t5)          # x[col[j]]
    fmadd.s f0, f1, f2, f0
    addi    t1, t1, 1
    blt     t1, t2, 1b
2:  slli    t0, a0, 2
    add     t0, s4, t0
    fsw     f0, 0(t0)          # y[r]
    ecall
