# kmeans.S  -  k-means assignment and accumulation step, integer 2-D points
#
#   Thread p finds the nearest of K centroids (squared Euclidean distance, the
#   lowest index on a tie, branch-free), stores it and adds the point into its
#   cluster's sums with global AMOs (the host divides to get new centroids):
#       assign[p] = k;  sumx[k] += x;  sumy[k] += y;  cnt[k] += 1
#   Coordinates are below 2^14, so distances fit in 31 bits.
#
#   a0 = tid (point)   a1 = &P   a4 = points
#   P[0] = &px  P[1] = &py  P[2] = &cx  P[3] = &cy  P[4] = K
#   P[5] = &assign  P[6] = &sumx  P[7] = &sumy  P[8] = &cnt
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # px
    lw      s1, 4(a1)          # py
    lw      s2, 8(a1)          # cx
    lw      s3, 12(a1)         # cy
    lw      s4, 16(a1)         # K
    slli    t0, a0, 2
    add     t1, s0, t0
    lw      s5, 0(t1)          # x
    add     t1, s1, t0
    lw      s6, 0(t1)          # y
    li      s7, -1
    srli    s7, s7, 1          # best = 0x7fffffff
    li      s8, 0              # best k
    li      t2, 0              # k
1:  slli    t3, t2, 2
    add     t4, s2, t3
    lw      t5, 0(t4)          # cx[k]
    add     t4, s3, t3
    lw      t6, 0(t4)          # cy[k]
    sub     t5, s5, t5
    sub     t6, s6, t6
    mul     t5, t5, t5
    mul     t6, t6, t6
    add     t5, t5, t6         # d
    slt     t6, t5, s7         # d < best
    neg     t6, t6             # all ones if so
    xor     t4, s7, t5
    and     t4, t4, t6
    xor     s7, s7, t4         # best = min
    xor     t4, s8, t2
    and     t4, t4, t6
    xor     s8, s8, t4         # best k
    addi    t2, t2, 1
    blt     t2, s4, 1b
    lw      t1, 20(a1)         # assign
    add     t1, t1, t0
    sw      s8, 0(t1)
    slli    t3, s8, 2
    lw      t1, 24(a1)         # sumx
    add     t1, t1, t3
    amoadd.w x0, s5, (t1)
    lw      t1, 28(a1)         # sumy
    add     t1, t1, t3
    amoadd.w x0, s6, (t1)
    lw      t1, 32(a1)         # cnt
    add     t1, t1, t3
    li      t4, 1
    amoadd.w x0, t4, (t1)
    ecall
