# stencil.S  -  one sweep of a 5-point Jacobi stencil on an FP32 grid
#
#   The H x W interior (W a power of two) sits in a padded array: row stride S
#   words, interior row i at row i+1, column j at word 8+j (8 words of padding on
#   each side keep a warp's centre row line-aligned). Thread t updates interior
#   point (i, j) = (t >> log2W, t & (W-1)) from IN into OUT (same layout):
#       s   = (up + down) + (left + right)
#       out = fmadd(c1, s, c0 * centre)
#   The padding is never written, so sweeps alternate IN and OUT.
#
#   a0 = tid   a1 = &P   a4 = H*W
#   P[0] = &IN   P[1] = &OUT   P[2] = log2W   P[3] = S   P[4] = c0   P[5] = c1
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # IN
    lw      s1, 4(a1)          # OUT
    lw      s2, 8(a1)          # log2W
    lw      s3, 12(a1)         # S
    flw     f10, 16(a1)        # c0
    flw     f11, 20(a1)        # c1
    srl     t0, a0, s2         # i
    li      t1, 1
    sll     t1, t1, s2
    addi    t1, t1, -1
    and     t1, a0, t1         # j
    addi    t0, t0, 1
    mul     t0, t0, s3         # (i+1)*S
    add     t0, t0, t1
    addi    t0, t0, 8          # word index of (i, j)
    slli    t0, t0, 2          # byte offset
    slli    t2, s3, 2          # row stride (bytes)
    add     t3, s0, t0         # &IN(i, j)
    flw     f0, 0(t3)          # centre
    flw     f4, -4(t3)         # left
    flw     f5, 4(t3)          # right
    sub     t4, t3, t2
    flw     f2, 0(t4)          # up
    add     t4, t3, t2
    flw     f3, 0(t4)          # down
    fadd.s  f2, f2, f3         # up + down
    fadd.s  f4, f4, f5         # left + right
    fadd.s  f2, f2, f4         # s
    fmul.s  f0, f10, f0        # c0 * centre
    fmadd.s f0, f11, f2, f0    # c1 * s + c0 * centre
    add     t3, s1, t0
    fsw     f0, 0(t3)          # OUT(i, j)
    ecall
