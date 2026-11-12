# embag.S  -  embedding-bag lookup (recommendation-model inference), FP32 sum
#
#   out[b][d] = T[idx[b][0]][d] + T[idx[b][1]][d] + ... + T[idx[b][K-1]][d]
#   summed in order k = 0..K-1 from +0. T has D floats per row (D a power of two,
#   at least 8); idx holds K row numbers per bag (K even).
#   Thread t computes d = t & (D-1) of bag b = t >> log2D, so a warp reads one line
#   of each row it gathers, and the K index loads of a bag are broadcasts. Two
#   gathers are issued before their adds, so each warp keeps two misses in flight.
#
#   a0 = tid   a1 = &P   a4 = B*D
#   P[0] = &T  P[1] = &idx  P[2] = &out  P[3] = K  P[4] = log2D
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # T
    lw      s1, 4(a1)          # idx
    lw      s2, 8(a1)          # out
    lw      s3, 12(a1)         # K
    lw      s4, 16(a1)         # log2D
    li      t0, 1
    sll     t0, t0, s4
    addi    t0, t0, -1
    and     t1, a0, t0         # d
    srl     t2, a0, s4         # b
    mul     t3, t2, s3
    sh2add  s1, t3, s1         # &idx[b][0]
    sh2add  s0, t1, s0         # &T[0][d]
    addi    s5, s4, 2          # log2 of the row size in bytes
    sh2add  t6, s3, s1         # &idx[b][K]
    fmv.w.x f0, x0             # +0
1:  lw      t3, 0(s1)          # idx[b][k]     (broadcast)
    lw      t4, 4(s1)          # idx[b][k+1]
    sll     t3, t3, s5
    sll     t4, t4, s5
    add     t3, t3, s0
    add     t4, t4, s0
    flw     f1, 0(t3)          # T[idx[b][k]][d]
    flw     f2, 0(t4)
    fadd.s  f0, f0, f1
    fadd.s  f0, f0, f2
    addi    s1, s1, 8
    bne     s1, t6, 1b
    sh2add  t0, a0, s2
    fsw     f0, 0(t0)          # out[b][d]
    ecall
