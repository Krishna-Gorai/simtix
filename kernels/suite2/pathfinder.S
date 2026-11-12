# pathfinder.S  -  Rodinia pathfinder: one row of the dynamic program per launch
#
#   dst[c] = wall[c] + min(src[c-1], src[c], src[c+1])     (int32)
#   The src and dst rows are padded with one INT_MAX word on each side (element c at
#   word c+1), so the edge columns need no test. Thread t computes column c = t; the
#   three neighbour loads of a warp fall in one or two lines.
#
#   a0 = tid   a1 = &P   a4 = cols
#   P[0] = &src (padded)  P[1] = &dst (padded)  P[2] = &wall row  P[3] = cols
.section .text
.globl _start
_start:
    lw      t0, 0(a1)          # src
    lw      t1, 4(a1)          # dst
    lw      t2, 8(a1)          # wall row
    sh2add  t3, a0, t0         # &src[c-1] (padded index c)
    lw      t4, 0(t3)          # src[c-1]
    lw      t5, 4(t3)          # src[c]
    lw      t6, 8(t3)          # src[c+1]
    min     t4, t4, t5
    min     t4, t4, t6
    sh2add  t2, a0, t2
    lw      t5, 0(t2)          # wall[c]
    add     t4, t4, t5
    sh2add  t1, a0, t1
    sw      t4, 4(t1)          # dst[c] (padded index c+1)
    ecall
