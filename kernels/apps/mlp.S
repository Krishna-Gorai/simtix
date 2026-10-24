# mlp.S  -  one INT8 fully connected layer for a batch, with requantization
#
#   Thread t computes output n = t & (Npad-1) of image b = t >> log2Npad:
#       acc = sum over kk < Kp of pdot8(x_b[kk], W[kk][n])      (4 MACs per word)
#   x_b is image b's input, Kp words of packed INT8 at x + 4*Kp*b; W is pre-packed
#   [Kp][Npad] words (W[kk][n] packs rows 4kk..4kk+3 of column n). Then
#       mode 0:  out32[b*Npad + n] = acc                         (logits)
#       mode 1:  out8 [b*Npad + n] = rne(clamp(fmadd(float(acc), scale, zp), 0, 127))
#   Mode 1 is requantization with a fused ReLU, rounding half to even; its INT8
#   bytes, Npad per image, are the next layer's packed input with Kp = Npad/4.
#
#   a0 = tid   a1 = &P   a4 = batch*Npad
#   P[0] = &x  P[1] = &W  P[2] = &out  P[3] = Kp  P[4] = log2Npad
#   P[5] = scale (f32)  P[6] = zp (f32)  P[7] = mode
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # x
    lw      s1, 4(a1)          # W
    lw      s2, 8(a1)          # out
    lw      s3, 12(a1)         # Kp
    lw      s4, 16(a1)         # log2Npad
    srl     t0, a0, s4         # b
    li      t1, 1
    sll     t1, t1, s4
    addi    t1, t1, -1
    and     t1, a0, t1         # n
    mul     t2, t0, s3
    slli    t2, t2, 2
    add     t2, s0, t2         # &x_b[0]
    slli    t3, t1, 2
    add     t3, s1, t3         # &W[0][n]
    li      t4, 4
    sll     t4, t4, s4         # W row stride (bytes)
    li      t5, 0              # acc
    mv      t6, s3             # kk counter
1:  lw      s5, 0(t2)          # x_b[kk]   (broadcast)
    lw      s6, 0(t3)          # W[kk][n]  (coalesced)
    .insn r 0x0B, 0, 0, s7, s5, s6   # pdot8 s7 = sum of the four INT8 products
    add     t5, t5, s7
    addi    t2, t2, 4
    add     t3, t3, t4
    addi    t6, t6, -1
    bnez    t6, 1b
    lw      t2, 28(a1)         # mode
    bnez    t2, 2f
    slli    t3, a0, 2          # mode 0: out32[t] = acc  (t = b*Npad + n)
    add     t3, s2, t3
    sw      t5, 0(t3)
    ecall
2:  flw     f1, 20(a1)         # scale
    flw     f2, 24(a1)         # zp
    fcvt.s.w f3, t5
    fmadd.s f3, f3, f1, f2     # acc*scale + zp
    lui     t3, 0x42fe0        # 127.0f
    fmv.w.x f4, t3
    fmv.w.x f5, x0
    fmin.s  f3, f3, f4
    fmax.s  f3, f3, f5         # ReLU
    fcvt.w.s t4, f3, rne
    add     t3, s2, a0
    sb      t4, 0(t3)          # out8[t]
    ecall
