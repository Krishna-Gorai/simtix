# scan_seg.S  -  inclusive prefix sum of segments of R*LANES words, one warp per
#                segment (v3 phase A; scan.S is the v2 kernel)
#
#   Warp g scans in[g*R*LANES .. (g+1)*R*LANES) one row of LANES words at a time:
#   lane l of row j holds in[g*R*LANES + j*LANES + l] (coalesced). A shuffle scan of
#   the row plus the total of the rows before it gives out[]; the warp's total goes
#   to tot[g]. The lane masks and shuffle distances are set up once, so a row costs
#   16 warp instructions. scan_segadd.S then adds the scanned segment totals.
#   Launch with LANES * (n / (R*LANES)) threads.
#
#   a0 = tid   a1 = &P
#   P[0] = &in   P[1] = &out   P[2] = &tot   P[3] = R (rows per segment)
#include "lanes.h"
.include "simtix_v2.inc"

# v += (lane >= k) ? shfl_up(v, k) : 0, with v in t2, k in \kr and the mask in \mr
.macro SEG_STEP kr, mr
    shfl_up t4, t2, \kr
    and     t4, t4, \mr
    add     t2, t2, t4
.endm

.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # in
    lw      s1, 4(a1)          # out
    lw      s2, 8(a1)          # tot
    lw      s3, 12(a1)         # R
    andi    s5, a0, LANES-1    # lane
    srli    s6, a0, LOG2L      # segment g
    mul     t0, s6, s3         # g*R rows before this segment
    slli    t0, t0, LOG2L+2
    slli    t1, s5, 2
    add     t0, t0, t1         # byte offset of this lane in row 0
    add     s0, s0, t0
    add     s1, s1, t0
    li      a2, 1              # shuffle distances
    li      a3, 2
    li      a4, 4
    sltu    t5, s5, a2         # masks: -1 if lane >= k, else 0
    addi    s7, t5, -1
    sltu    t5, s5, a3
    addi    s8, t5, -1
    sltu    t5, s5, a4
    addi    s9, t5, -1
#if LANES > 8
    li      a6, 8
    sltu    t5, s5, a6
    addi    s10, t5, -1
#endif
    li      a5, LANES-1        # last lane
    li      t6, 0              # total of the rows before
1:  lw      t2, 0(s0)
    SEG_STEP a2, s7
    SEG_STEP a3, s8
#if LANES > 4
    SEG_STEP a4, s9
#endif
#if LANES > 8
    SEG_STEP a6, s10
#endif
    add     t2, t2, t6
    sw      t2, 0(s1)
    shfl_idx t6, t2, a5        # running total = last lane's value
    addi    s0, s0, LANES*4
    addi    s1, s1, LANES*4
    addi    s3, s3, -1
    bnez    s3, 1b
    bnez    s5, 2f             # lane 0 writes the segment total
    slli    t0, s6, 2
    add     t0, s2, t0
    sw      t6, 0(t0)
2:  ecall
