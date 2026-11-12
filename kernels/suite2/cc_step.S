# cc_step.S  -  GAP connected components, one round of label propagation
#
#   lab'[v] = min(lab[v], lab[u] for u in v's neighbours)     (unsigned)
#   between two arrays, so a round's result does not depend on the order of the
#   threads; a vertex whose label changed sets the round's flag (amoor). The host
#   repeats rounds until a flag stays 0.
#
#   a0 = tid   a1 = &P   a4 = N
#   P[0] = &rowptr  P[1] = &col  P[2] = &lab  P[3] = &lab'  P[4] = &flag
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # rowptr
    lw      s1, 4(a1)          # col
    lw      s2, 8(a1)          # lab
    lw      s3, 12(a1)         # lab'
    sh2add  t0, a0, s0
    lw      t1, 0(t0)          # rowptr[v]
    lw      t2, 4(t0)          # rowptr[v+1]
    sh2add  t4, a0, s2
    lw      t5, 0(t4)          # lab[v]
    mv      t6, t5             # m
    sh2add  t1, t1, s1         # &col[first]
    sh2add  t2, t2, s1         # &col[end]
    beq     t1, t2, 2f
1:  lw      t3, 0(t1)          # u
    sh2add  t3, t3, s2
    lw      t3, 0(t3)          # lab[u]
    minu    t6, t6, t3
    addi    t1, t1, 4
    bne     t1, t2, 1b
2:  sh2add  t0, a0, s3
    sw      t6, 0(t0)          # lab'[v]
    beq     t6, t5, 3f
    lw      t3, 16(a1)         # flag
    li      t4, 1
    amoor.w x0, t4, (t3)
3:  ecall
