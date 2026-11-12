# bp_forward.S  -  Rodinia backprop, GPU kernel 1: partial sums of the forward pass
#
#   ps[b][j] = fma(w[16b+15][j], in[16b+15], ... fma(w[16b][j], in[16b], +0))
#   Thread t: j = t & 15 (hidden unit), b = t >> 4 (block of 16 inputs); w is
#   N x 16 row-major. The host adds the blocks and applies the sigmoid (Rodinia's
#   CPU part). The in[i] loads are broadcasts; a warp reads half a line of w per i.
#
#   a0 = tid   a1 = &P   a4 = N
#   P[0] = &in  P[1] = &w  P[2] = &ps
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # in
    lw      s1, 4(a1)          # w
    lw      s2, 8(a1)          # ps
    andi    t0, a0, 15         # j
    srli    t1, a0, 4          # b
    slli    t2, t1, 6          # 16b * 4 bytes
    add     s0, s0, t2         # &in[16b]
    slli    t2, t1, 10         # 16b * 16 * 4 bytes
    add     s1, s1, t2
    sh2add  s1, t0, s1         # &w[16b][j]
    addi    t6, s0, 64         # &in[16b+16]
    fmv.w.x f0, x0             # +0
1:  flw     f1, 0(s1)          # w[i][j]
    flw     f2, 0(s0)          # in[i]
    flw     f3, 64(s1)         # w[i+1][j]
    flw     f4, 4(s0)          # in[i+1]
    fmadd.s f0, f1, f2, f0
    fmadd.s f0, f3, f4, f0
    addi    s1, s1, 128
    addi    s0, s0, 8
    bne     s0, t6, 1b
    sh2add  t0, a0, s2
    fsw     f0, 0(t0)          # ps[b][j] (= ps[t])
    ecall
