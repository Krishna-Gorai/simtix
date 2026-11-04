# kmeans_u.S  -  k-means assignment + accumulation, two points per thread (v3)
#
#   Same results as kmeans.S: for each point the nearest centroid (squared
#   distance, the lowest index on a tie), assign[p] = k, and sumx[k] += x,
#   sumy[k] += y, cnt[k] += 1 by global atomics. Thread t takes the points t and
#   t + T (T = npts/2 threads, so both loads of a warp are coalesced): every
#   centroid load serves two distance computations, and the centroid loop is
#   unrolled by two (K even). The nearest centroid is kept with Zbb min and
#   Zicond czero (slt, min, czero.eqz, czero.nez, or: 5 instructions, 8 without).
#
#   a0 = tid   a1 = &P   a4 = T = npts/2
#   P[0] = &px  P[1] = &py  P[2] = &cx  P[3] = &cy  P[4] = K
#   P[5] = &assign  P[6] = &sumx  P[7] = &sumy  P[8] = &cnt
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # px
    lw      s1, 4(a1)          # py
    lw      a2, 8(a1)          # -> cx[k]
    lw      a3, 12(a1)         # -> cy[k]
    lw      s4, 16(a1)         # K
    slli    t0, a0, 2          # byte offset of point t
    slli    a5, a4, 2          # byte offset of the second point
    add     t1, s0, t0
    lw      s5, 0(t1)          # x0
    add     t1, t1, a5
    lw      a6, 0(t1)          # x1
    add     t1, s1, t0
    lw      s6, 0(t1)          # y0
    add     t1, t1, a5
    lw      a7, 0(t1)          # y1
    li      s7, -1
    srli    s7, s7, 1          # best0 = 0x7fffffff
    mv      s9, s7             # best1
    li      s8, 0              # best k of point 0
    li      s10, 0             # best k of point 1
    li      t2, 0              # k
1:
    .irp off, 0, 4
    lw      t5, \off(a2)       # cx[k]
    lw      t6, \off(a3)       # cy[k]
    sub     t3, s5, t5         # the two points interleaved (t*: point 0, s0-s2: point 1)
    sub     s0, a6, t5
    sub     t4, s6, t6
    sub     s1, a7, t6
    mul     t3, t3, t3
    mul     s0, s0, s0
    mul     t4, t4, t4
    mul     s1, s1, s1
    add     t3, t3, t4         # d0
    add     s0, s0, s1         # d1
    slt     t4, t3, s7         # d0 < best0
    slt     s1, s0, s9         # d1 < best1
    min     s7, s7, t3         # best0
    min     s9, s9, s0         # best1
    czero.eqz t1, t2, t4       # k if closer
    czero.eqz s2, t2, s1
    czero.nez s8, s8, t4       # else the old best k
    czero.nez s10, s10, s1
    or      s8, s8, t1
    or      s10, s10, s2
    addi    t2, t2, 1
    .endr
    addi    a2, a2, 8
    addi    a3, a3, 8
    blt     t2, s4, 1b
    lw      t1, 20(a1)         # assign
    add     t1, t1, t0
    sw      s8, 0(t1)
    add     t1, t1, a5
    sw      s10, 0(t1)
    slli    t3, s8, 2
    slli    t4, s10, 2
    lw      s0, 24(a1)         # sumx
    lw      s1, 28(a1)         # sumy
    lw      s2, 32(a1)         # cnt
    li      t6, 1
    add     t1, s0, t3
    amoadd.w x0, s5, (t1)
    add     t1, s1, t3
    amoadd.w x0, s6, (t1)
    add     t1, s2, t3
    amoadd.w x0, t6, (t1)
    add     t1, s0, t4
    amoadd.w x0, a6, (t1)
    add     t1, s1, t4
    amoadd.w x0, a7, (t1)
    add     t1, s2, t4
    amoadd.w x0, t6, (t1)
    ecall
