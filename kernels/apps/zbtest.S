# zbtest.S  -  the v3 integer extensions, one of each per thread (a test kernel)
#
#   R[9t + i] = op_i(A[t], B[t]) for the nine ops below (gen_apps.py zbtest).
#   a0 = tid   a1 = &P   P[0] = &A  P[1] = &B  P[2] = &R
.section .text
.globl _start
_start:
    lw      t0, 0(a1)
    lw      t1, 4(a1)
    lw      t2, 8(a1)
    sh2add  t0, a0, t0         # &A[t]
    sh2add  t1, a0, t1         # &B[t]
    lw      s0, 0(t0)          # a
    lw      s1, 0(t1)          # b
    li      t3, 36
    mul     t3, a0, t3
    add     t2, t2, t3         # &R[9t]
    sh1add  t4, s0, s1
    sw      t4, 0(t2)
    sh2add  t4, s0, s1
    sw      t4, 4(t2)
    sh3add  t4, s0, s1
    sw      t4, 8(t2)
    min     t4, s0, s1
    sw      t4, 12(t2)
    minu    t4, s0, s1
    sw      t4, 16(t2)
    max     t4, s0, s1
    sw      t4, 20(t2)
    maxu    t4, s0, s1
    sw      t4, 24(t2)
    andi    t5, s1, 1          # a selector that is zero for even b
    czero.eqz t4, s0, t5
    sw      t4, 28(t2)
    czero.nez t4, s0, t5
    sw      t4, 32(t2)
    ecall
