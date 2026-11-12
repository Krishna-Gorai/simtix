# conv8.S  -  one INT8 3x3 convolution layer (stride 1, zero padding 1), requantized
#
#   Activations are INT8 (0..127) in a padded row layout, four channels per word:
#       word (r, c, x) at X + 4*((r*Cw + c)*Wp + x),   r < H+2, c < Cw, x < Wp = W+2
#   holds channels 4c..4c+3 of padded pixel (r, x); the border is zero.
#   Weights Wt[ky][c][kx][o]: one word per (ky, c, kx, o) holding the four input
#   channels 4c..4c+3 of output channel o.
#   Thread t computes output channel o = t & (Cout-1) for the four pixels
#   (y, x..x+3), q = t >> log2Cout, x = 4*(q & (W/4-1)), y = q >> log2(W/4):
#       acc_j = sum over ky, c, kx of pdot8(X(y+ky, c, x+j+kx), Wt[ky][c][kx][o])
#   so every weight word serves four pixels and every input word up to three
#   weights (12 pdot8 for 9 loads). A warp is 8 output channels of one pixel group:
#   the input loads are broadcasts and the weight loads one line each.
#   Output: out8 = rne(clamp(fmadd(float(acc), scale, zp), 0, 127)) (requantization
#   with a fused ReLU, as mlp.S) into the same padded layout with Cout/4 words per
#   pixel, so a layer's output is the next layer's input.
#
#   a0 = tid   a1 = &P   a4 = H*W/4*Cout
#   P[0] = &X  P[1] = &Wt  P[2] = &Out  P[3] = Cw  P[4] = log2Cout  P[5] = log2(W/4)
#   P[6] = scale (f32)  P[7] = zp (f32)  P[8] = Wp
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # X
    lw      s1, 4(a1)          # Wt
    lw      a7, 12(a1)         # Cw
    lw      t0, 16(a1)         # log2Cout
    lw      t1, 20(a1)         # log2(W/4)
    lw      t2, 32(a1)         # Wp
    li      t3, 1
    sll     t3, t3, t0         # Cout
    addi    t4, t3, -1
    and     a2, a0, t4         # o
    srl     a3, a0, t0         # q
    li      t4, 1
    sll     t4, t4, t1
    addi    t4, t4, -1
    and     a5, a3, t4
    slli    a5, a5, 2          # x
    srl     a6, a3, t1         # y
    slli    s2, t3, 2          # kx stride of Wt (bytes)
    slli    s3, t2, 2          # row stride of X (bytes)
    mul     t5, a6, a7
    mul     t5, t5, t2
    add     t5, t5, a5
    sh2add  s0, t5, s0         # &X(y, 0, x)
    sh2add  s1, a2, s1         # &Wt[0][0][0][o]
    slli    s4, a7, 1
    add     s4, s4, a7         # 3*Cw passes (ky, c)
    lw      t4, 8(a1)          # Out
    srli    t5, t3, 2          # Cout/4
    addi    t6, a6, 1
    mul     t6, t6, t5         # (y+1) * Cout/4
    srli    t5, a2, 2
    add     t6, t6, t5         # + o/4
    mul     t6, t6, t2         # * Wp
    add     t6, t6, a5
    addi    t6, t6, 1          # + x + 1
    sh2add  t6, t6, t4
    andi    t5, a2, 3
    add     a7, t6, t5         # byte of channel o at output pixel (y, x)
    li      s5, 0
    li      s6, 0
    li      s7, 0
    li      s8, 0
1:  lw      t0, 0(s0)          # X(.., x .. x+5)    (broadcast)
    lw      t1, 4(s0)
    lw      t2, 8(s0)
    lw      t3, 12(s0)
    lw      t4, 16(s0)
    lw      t5, 20(s0)
    lw      s9, 0(s1)          # Wt[..][kx = 0][o] (coalesced)
    add     t6, s1, s2
    lw      s10, 0(t6)         # kx = 1
    add     t6, t6, s2
    lw      s11, 0(t6)         # kx = 2
    add     s1, t6, s2
    .insn r 0x0B, 0, 0, a2, t0, s9
    .insn r 0x0B, 0, 0, a3, t1, s9
    .insn r 0x0B, 0, 0, a5, t2, s9
    .insn r 0x0B, 0, 0, a6, t3, s9
    add     s5, s5, a2
    add     s6, s6, a3
    add     s7, s7, a5
    add     s8, s8, a6
    .insn r 0x0B, 0, 0, a2, t1, s10
    .insn r 0x0B, 0, 0, a3, t2, s10
    .insn r 0x0B, 0, 0, a5, t3, s10
    .insn r 0x0B, 0, 0, a6, t4, s10
    add     s5, s5, a2
    add     s6, s6, a3
    add     s7, s7, a5
    add     s8, s8, a6
    .insn r 0x0B, 0, 0, a2, t2, s11
    .insn r 0x0B, 0, 0, a3, t3, s11
    .insn r 0x0B, 0, 0, a5, t4, s11
    .insn r 0x0B, 0, 0, a6, t5, s11
    add     s5, s5, a2
    add     s6, s6, a3
    add     s7, s7, a5
    add     s8, s8, a6
    add     s0, s0, s3         # next (ky, c) row of X
    addi    s4, s4, -1
    bnez    s4, 1b
    flw     f1, 24(a1)         # scale
    flw     f2, 28(a1)         # zp
    lui     t3, 0x42fe0        # 127.0f
    fmv.w.x f4, t3
    fmv.w.x f5, x0
    .macro rq acc, off
    fcvt.s.w f3, \acc
    fmadd.s f3, f3, f1, f2     # acc*scale + zp
    fmin.s  f3, f3, f4
    fmax.s  f3, f3, f5         # ReLU
    fcvt.w.s t0, f3, rne
    sb      t0, \off(a7)
    .endm
    rq      s5, 0
    rq      s6, 4
    rq      s7, 8
    rq      s8, 12
    ecall
