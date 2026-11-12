# rs_scatter.S  -  SHOC sort, step 3: stable scatter of a worker's pairs
#
#   Worker w first adds the digit bases to its column of off:
#       off[d][w] += tot[0] + ... + tot[d-1]
#   then moves its chunk in order: for each key (and value) of the chunk,
#       d = (key >> shift) & 15;  pos = off[d][w]++;  kdst[pos] = key;  vdst[pos] = val
#   Chunks in worker order and each chunk in order: a stable pass.
#
#   a0 = tid (w)   a1 = &P   a4 = W
#   P[0] = &ksrc  P[1] = &vsrc  P[2] = &kdst  P[3] = &vdst  P[4] = &off  P[5] = &tot
#   P[6] = C  P[7] = shift  P[8] = W
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # ksrc
    lw      s1, 4(a1)          # vsrc
    lw      s2, 8(a1)          # kdst
    lw      s3, 12(a1)         # vdst
    lw      s4, 16(a1)         # off
    lw      s5, 20(a1)         # tot
    lw      s6, 24(a1)         # C
    lw      s7, 28(a1)         # shift
    lw      s8, 32(a1)         # W
    sh2add  s4, a0, s4         # &off[0][w]
    slli    s9, s8, 2          # digit stride (bytes)
    mv      t0, s4
    li      t1, 0              # base
    li      t2, 16
1:  lw      t3, 0(t0)
    add     t3, t3, t1
    sw      t3, 0(t0)          # off[d][w] += base[d]
    lw      t4, 0(s5)          # tot[d]
    add     t1, t1, t4
    addi    s5, s5, 4
    add     t0, t0, s9
    addi    t2, t2, -1
    bnez    t2, 1b
    mul     t0, a0, s6
    sh2add  s0, t0, s0         # &ksrc[w*C]
    sh2add  s1, t0, s1         # &vsrc[w*C]
    sh2add  t6, s6, s0         # end of the chunk
2:  lw      t2, 0(s0)          # key
    lw      t5, 0(s1)          # value
    srl     t3, t2, s7
    andi    t3, t3, 15         # d
    mul     t3, t3, s9
    add     t3, t3, s4         # &off[d][w]
    lw      t4, 0(t3)          # pos
    addi    t1, t4, 1
    sw      t1, 0(t3)
    sh2add  t1, t4, s2
    sw      t2, 0(t1)          # kdst[pos]
    sh2add  t1, t4, s3
    sw      t5, 0(t1)          # vdst[pos]
    addi    s0, s0, 4
    addi    s1, s1, 4
    bne     s0, t6, 2b
    ecall
