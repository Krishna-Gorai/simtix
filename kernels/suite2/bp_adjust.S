# bp_adjust.S  -  Rodinia backprop, GPU kernel 2: weight update with momentum
#
#   dw = fma(ed[j], in[i], m * ow[i][j]);  w[i][j] = w[i][j] + dw;  ow[i][j] = dw
#   Thread t: i = t >> 4, j = t & 15 (w and ow are N x 16 row-major, so element t);
#   ed[j] = eta * delta[j] comes from the host.
#
#   a0 = tid   a1 = &P   a4 = N*16
#   P[0] = &in  P[1] = &w  P[2] = &ow  P[3] = &ed  P[4] = m (f32)
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # in
    lw      s1, 4(a1)          # w
    lw      s2, 8(a1)          # ow
    lw      s3, 12(a1)         # ed
    flw     f10, 16(a1)        # m
    srli    t1, a0, 4          # i
    andi    t0, a0, 15         # j
    sh2add  t1, t1, s0
    flw     f1, 0(t1)          # in[i]
    sh2add  t0, t0, s3
    flw     f2, 0(t0)          # ed[j]
    sh2add  s1, a0, s1
    sh2add  s2, a0, s2
    flw     f3, 0(s2)          # ow
    flw     f4, 0(s1)          # w
    fmul.s  f3, f10, f3        # m * ow
    fmadd.s f3, f2, f1, f3     # dw = fma(ed[j], in[i], m * ow)
    fadd.s  f4, f4, f3         # w + dw
    fsw     f4, 0(s1)
    fsw     f3, 0(s2)          # ow = dw
    ecall
