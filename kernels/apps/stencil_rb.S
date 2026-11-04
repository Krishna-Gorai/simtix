# stencil_rb.S  -  one sweep of the 5-point Jacobi stencil, R rows per thread (v3)
#
#   Same grid layout, arithmetic and rounding as stencil.S (bit-exact with it):
#       s   = (up + down) + (left + right)
#       out = fmadd(c1, s, c0 * centre)
#   Thread t updates the R points (i0 + r, j), r = 0..R-1, of one column:
#       j = t & (W-1),  i0 = (t >> log2W) * R
#   so a warp still works on LANES adjacent columns of one row at a time (one line
#   per load). Walking down the column, the centre becomes the next row's up and
#   the down value the next centre, so each point loads 3 words (down, left,
#   right) instead of 5, and the per-thread setup is paid once per R points.
#   R is even: each loop pass does two rows, their instructions interleaved.
#
#   a0 = tid   a1 = &P   a4 = (H/R)*W
#   P[0] = &IN  P[1] = &OUT  P[2] = log2W  P[3] = S  P[4] = c0  P[5] = c1  P[6] = R
#include "lanes.h"
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # IN
    lw      s1, 4(a1)          # OUT
    lw      s2, 8(a1)          # log2W
    lw      s3, 12(a1)         # S
    flw     f10, 16(a1)        # c0
    flw     f11, 20(a1)        # c1
    lw      s4, 24(a1)         # R
    srl     t0, a0, s2         # strip
    li      t1, 1
    sll     t1, t1, s2
    addi    t1, t1, -1
    and     t1, a0, t1         # j
    mul     t0, t0, s4         # i0
    addi    t0, t0, 1
    mul     t0, t0, s3         # (i0+1)*S
    add     t0, t0, t1
    addi    t0, t0, LANES      # word index of (i0, j)
    slli    t0, t0, 2
    slli    t2, s3, 2          # row stride (bytes)
    add     t3, s0, t0         # p = &IN(i, j)
    add     t4, s1, t0         # q = &OUT(i, j)
    mul     t5, s4, t2
    add     t5, t3, t5         # p after the last row
    sub     t6, t3, t2
    flw     f1, 0(t6)          # up
    flw     f0, 0(t3)          # centre
    add     t6, t3, t2         # q1 = &IN(i+1, j)
    slli    t1, t2, 1          # two rows (bytes)
1:  # rows A = i (up f1, centre f0) and B = i+1 (up f0, centre f2), interleaved so
    # that each warp has independent FP work while a result is pending
    flw     f2, 0(t6)          # down A = centre B
    add     t0, t6, t2
    flw     f7, 0(t0)          # down B
    flw     f3, -4(t3)         # left A
    flw     f4, 4(t3)          # right A
    flw     f8, -4(t6)         # left B
    flw     f9, 4(t6)          # right B
    fadd.s  f5, f1, f2         # A: up + down
    fadd.s  f3, f3, f4         # A: left + right
    fadd.s  f12, f0, f7        # B: up + down
    fadd.s  f8, f8, f9         # B: left + right
    fmul.s  f6, f10, f0        # A: c0 * centre
    fmul.s  f13, f10, f2       # B: c0 * centre
    fadd.s  f5, f5, f3         # A: s
    fadd.s  f12, f12, f8       # B: s
    fmadd.s f6, f11, f5, f6
    fmadd.s f13, f11, f12, f13
    fsw     f6, 0(t4)
    add     t0, t4, t2
    fsw     f13, 0(t0)
    add     t3, t3, t1
    add     t6, t6, t1
    add     t4, t4, t1
    # next pair: up = centre B (f2), centre = down B (f7)
    fmv.s   f0, f7
    fmv.s   f1, f2
    bne     t3, t5, 1b
    ecall
