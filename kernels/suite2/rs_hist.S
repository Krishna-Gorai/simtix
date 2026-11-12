# rs_hist.S  -  SHOC sort (LSD radix, 4 bits per pass), step 1: digit histograms
#
#   Worker w (one thread) owns the chunk keys[w*C .. w*C+C-1]:
#       hist[d][w] = number of keys in the chunk with (key >> shift) & 15 == d
#   hist is 16 x W (digit-major), so worker w counts in its own column.
#
#   a0 = tid (w)   a1 = &P   a4 = W
#   P[0] = &keys  P[1] = &hist  P[2] = C  P[3] = shift  P[4] = W
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # keys
    lw      s1, 4(a1)          # hist
    lw      s2, 8(a1)          # C
    lw      s3, 12(a1)         # shift
    lw      s4, 16(a1)         # W
    sh2add  s1, a0, s1         # &hist[0][w]
    slli    s5, s4, 2          # digit stride (bytes)
    mv      t0, s1
    li      t1, 16
1:  sw      x0, 0(t0)          # hist[d][w] = 0
    add     t0, t0, s5
    addi    t1, t1, -1
    bnez    t1, 1b
    mul     t0, a0, s2
    sh2add  s0, t0, s0         # &keys[w*C]
    sh2add  t6, s2, s0         # end of the chunk
2:  lw      t2, 0(s0)          # key
    srl     t2, t2, s3
    andi    t2, t2, 15         # d
    mul     t2, t2, s5
    add     t2, t2, s1         # &hist[d][w]
    lw      t3, 0(t2)
    addi    t3, t3, 1
    sw      t3, 0(t2)
    addi    s0, s0, 4
    bne     s0, t6, 2b
    ecall
