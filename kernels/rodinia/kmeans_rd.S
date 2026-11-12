# kmeans_rd.S  -  Rodinia kmeans, kernel kmeansPoint: the nearest centre of every point
#
#   Features are feature-major (Rodinia's inverted layout): feature j of point p at word
#   j*N + p, so a warp's loads of one feature are contiguous. Centres are K x F. Thread p:
#       for i = 0 .. K-1:  ans = +0;  for j = 0 .. F-1:  d = f[j][p] - c[i][j];
#                                                        ans = fma(d, d, ans)
#                          when ans < best: best = ans, idx = i      (first minimum wins)
#       membership[p] = idx
#   The selection has no branch: best = fmin(best, ans) and idx is picked with Zicond on
#   the strict comparison. The host then counts the changes and computes the new centres
#   (Rodinia's CPU part).
#
#   a0 = tid   a1 = &P
#   P[0] = &f  P[1] = &c  P[2] = &membership  P[3] = N  P[4] = K  P[5] = F
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # f
    lw      s1, 4(a1)          # c
    lw      s2, 8(a1)          # membership
    lw      s3, 12(a1)         # N
    lw      s4, 16(a1)         # K
    lw      s5, 20(a1)         # F
    slli    s3, s3, 2          # feature stride (bytes)
    sh2add  s0, a0, s0         # &f[0][p]
    lui     t0, 0x7f800
    addi    t0, t0, -1         # FLT_MAX bits 0x7f7fffff
    fmv.w.x f10, t0            # best
    li      a2, 0              # idx
    li      a3, 0              # i
    mv      a4, s1             # &c[i][0]
1:  fmv.w.x f0, x0             # ans = +0
    mv      t1, s0             # &f[0][p]
    mv      t2, a4             # &c[i][0]
    li      t3, 0              # j
2:  flw     f1, 0(t1)          # f[j][p]
    flw     f2, 0(t2)          # c[i][j]
    fsub.s  f1, f1, f2         # d
    fmadd.s f0, f1, f1, f0     # ans = fma(d, d, ans)
    add     t1, t1, s3
    addi    t2, t2, 4
    addi    t3, t3, 1
    bne     t3, s5, 2b
    flt.s   t4, f0, f10        # ans < best
    fmin.s  f10, f10, f0
    czero.eqz t5, a3, t4       # i if ans < best
    czero.nez a2, a2, t4       # idx if not
    or      a2, a2, t5
    mv      a4, t2             # &c[i+1][0]
    addi    a3, a3, 1
    bne     a3, s4, 1b
    sh2add  s2, a0, s2
    sw      a2, 0(s2)          # membership[p]
    ecall
