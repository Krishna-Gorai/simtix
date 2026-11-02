# scan_segadd.S  -  second pass of the segmented scan (v3 phase A)
#
#   out[w] += tscan[g - 1] for every word w of segment g > 0 (segments of R*LANES
#   words, one warp each, as in scan_seg.S), where tscan is the inclusive scan of
#   the segment totals scan_seg.S wrote. Launch with the threads of scan_seg.S.
#
#   a0 = tid   a1 = &P
#   P[0] = &out   P[1] = &tscan   P[2] = R (rows per segment)
#include "lanes.h"
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # out
    lw      s1, 4(a1)          # tscan
    lw      s3, 8(a1)          # R
    srli    s6, a0, LOG2L      # segment g
    beqz    s6, 2f             # segment 0 has nothing before it
    addi    t0, s6, -1
    slli    t0, t0, 2
    add     t0, s1, t0
    lw      t6, 0(t0)          # total of the segments before this one
    andi    s5, a0, LANES-1    # lane
    mul     t0, s6, s3
    slli    t0, t0, LOG2L+2
    slli    t1, s5, 2
    add     t0, t0, t1
    add     s0, s0, t0
1:  lw      t2, 0(s0)
    add     t2, t2, t6
    sw      t2, 0(s0)
    addi    s0, s0, LANES*4
    addi    s3, s3, -1
    bnez    s3, 1b
2:  ecall
