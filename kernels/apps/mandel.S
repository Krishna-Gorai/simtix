# mandel.S  -  Mandelbrot escape-time image, FP32
#
#   Pixel (px, py) of a W x H image, px = t & (W-1), py = t >> log2W:
#       cr = fmadd(px, dx, x0)   ci = fmadd(py, dy, y0)   zr = zi = +0   n = 0
#       do { zr2 = zr*zr;  zi2 = zi*zi;  esc = (zr2 + zi2 > 4)
#            zi = fmadd(zr*zi, 2, ci);  zr = (zr2 - zi2) + cr;  n++ }
#       while (!esc && n < M)
#       out[t] = n
#   Every operation is rounded once (FP32, nearest even). The loop exit is data
#   dependent, so the lanes of a warp diverge; the loop has one backward branch.
#
#   a0 = tid   a1 = &P   a4 = W*H
#   P[0] = &out  P[1] = log2W  P[2] = x0  P[3] = y0  P[4] = dx  P[5] = dy  P[6] = M
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # out
    lw      s1, 4(a1)          # log2W
    flw     f10, 8(a1)         # x0
    flw     f11, 12(a1)        # y0
    flw     f12, 16(a1)        # dx
    flw     f13, 20(a1)        # dy
    lw      s2, 24(a1)         # M
    li      t0, 1
    sll     t0, t0, s1
    addi    t0, t0, -1
    and     t1, a0, t0         # px
    srl     t2, a0, s1         # py
    fcvt.s.w f1, t1
    fmadd.s f1, f1, f12, f10   # cr
    fcvt.s.w f2, t2
    fmadd.s f2, f2, f13, f11   # ci
    fmv.w.x f3, x0             # zr
    fmv.w.x f4, x0             # zi
    lui     t3, 0x40800        # 4.0f
    fmv.w.x f5, t3
    lui     t3, 0x40000        # 2.0f
    fmv.w.x f6, t3
    li      t4, 0              # n
1:  fmul.s  f7, f3, f3         # zr2
    fmul.s  f8, f4, f4         # zi2
    fadd.s  f9, f7, f8
    flt.s   t5, f5, f9         # escaped: 4 < zr2 + zi2
    fmul.s  f0, f3, f4
    fmadd.s f4, f0, f6, f2     # zi = 2 zr zi + ci
    fsub.s  f7, f7, f8
    fadd.s  f3, f7, f1         # zr = zr2 - zi2 + cr
    addi    t4, t4, 1
    slt     t6, t4, s2         # n < M
    czero.nez t6, t6, t5       # ... and not escaped
    bnez    t6, 1b
    sh2add  t0, a0, s0
    sw      t4, 0(t0)
    ecall
