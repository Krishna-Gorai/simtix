# blackscholes.S  -  RiVEC / PARSEC Black-Scholes (BlkSchlsEqEuroNoDiv), FP32, one option per thread
#
#   sq = sqrt(T);  lt = log(S / K);  pw = (v*v) * 0.5
#   d1 = ((r + pw) * T + lt) / (v*sq);   d2 = d1 - v*sq
#   N1 = CNDF(d1);  N2 = CNDF(d2);  fv = K * exp(-(r*T))
#   call = S*N1 - fv*N2;   put = fv*(1 - N2) - S*(1 - N1)
# every operation rounded once, in this order (no contraction outside the fma below).
#
#   exp(x): k = rne(x * log2e);  kf = -(float)k
#           f = fma(kf, ln2hi, x);  f = fma(kf, ln2lo, f)
#           p = fma(f, E6, E5);  p = fma(f, p, E4) ... fma(f, p, E0)     (Ei = 1/i!)
#           result bits = bits(p) + (k << 23)   (results normal for the inputs used)
#   log(x): e = exponent(x) - 127;  m = mantissa(x) in [1, 2);  if m > sqrt2: m *= 0.5, e += 1
#           f = m - 1;  s = f / (f + 2);  z = s*s
#           R = fma(z, C4, C3);  R = fma(z, R, C2);  R = fma(z, R, C1);  R = R*z
#           result = fma((float)e, ln2, fma(s, R, s + s))          (Ci = 2/(2i+1))
#   CNDF(x) (PARSEC): xa = |x|;  n = exp(-((xa*xa) * 0.5)) * (1/sqrt(2 pi))
#           k2 = 1 / (1 + 0.2316419*xa);  k2^2..k2^5 by successive products
#           l = k2*a1 + ((((k2^2*a2) + k2^3*a3) + k2^4*a4) + k2^5*a5)
#           loc = 1 - l*n;  if x < 0: loc = 1 - loc
#   Constants: table C (sim/gen_suite2.py BS_C), indices in the comments.
#
#   a0 = tid   a1 = &P   a4 = n
#   P[0..4] = &S &K &r &v &T   P[5] = &call  P[6] = &put  P[7] = &C
.section .text
.globl _start

.macro EXP fd, fx                      # temps f20-f23, t0 t1
    flw     f20, 12(s7)                # log2e
    fmul.s  f20, \fx, f20
    fcvt.w.s t0, f20, rne              # k
    fcvt.s.w f21, t0
    fneg.s  f21, f21                   # kf = -k
    flw     f22, 16(s7)                # ln2 hi
    fmadd.s f22, f21, f22, \fx
    flw     f23, 20(s7)                # ln2 lo
    fmadd.s f22, f21, f23, f22         # f
    flw     f23, 48(s7)                # E6
    flw     f21, 44(s7)                # E5
    fmadd.s f23, f22, f23, f21
    flw     f21, 40(s7)                # E4
    fmadd.s f23, f22, f23, f21
    flw     f21, 36(s7)                # E3
    fmadd.s f23, f22, f23, f21
    flw     f21, 32(s7)                # E2
    fmadd.s f23, f22, f23, f21
    flw     f21, 28(s7)                # E1
    fmadd.s f23, f22, f23, f21
    flw     f21, 24(s7)                # E0
    fmadd.s f23, f22, f23, f21         # p
    fmv.x.w t1, f23
    slli    t0, t0, 23
    add     t1, t1, t0
    fmv.w.x \fd, t1
.endm

.macro LOG fd, fx                      # temps f20-f24, t0-t2
    fmv.x.w t0, \fx
    srli    t1, t0, 23
    andi    t1, t1, 0xFF
    addi    t1, t1, -127               # e
    li      t2, 0x7FFFFF
    and     t0, t0, t2
    li      t2, 0x3F800000
    or      t0, t0, t2
    fmv.w.x f20, t0                    # m in [1, 2)
    flw     f21, 72(s7)                # sqrt2
    flt.s   t2, f21, f20
    beqz    t2, 1f
    flw     f21, 0(s7)                 # 0.5
    fmul.s  f20, f20, f21
    addi    t1, t1, 1
1:  flw     f21, 4(s7)                 # 1
    fsub.s  f20, f20, f21              # f
    flw     f21, 8(s7)                 # 2
    fadd.s  f21, f20, f21
    fdiv.s  f20, f20, f21              # s
    fmul.s  f21, f20, f20              # z
    flw     f22, 68(s7)                # C4
    flw     f23, 64(s7)                # C3
    fmadd.s f22, f21, f22, f23
    flw     f23, 60(s7)                # C2
    fmadd.s f22, f21, f22, f23
    flw     f23, 56(s7)                # C1
    fmadd.s f22, f21, f22, f23
    fmul.s  f22, f22, f21              # R
    fadd.s  f23, f20, f20              # s + s
    fmadd.s f22, f20, f22, f23         # log1p part
    fcvt.s.w f23, t1
    flw     f24, 52(s7)                # ln2
    fmadd.s \fd, f23, f24, f22
.endm

.macro CNDF fd, fx                     # temps f24-f31, t3 (and EXP's)
    fmv.x.w t3, \fx
    srli    t3, t3, 31                 # sign
    fabs.s  f25, \fx                   # xa
    fmul.s  f26, f25, f25
    flw     f27, 0(s7)                 # 0.5
    fmul.s  f26, f26, f27
    fneg.s  f26, f26
    EXP     f26, f26
    flw     f27, 76(s7)                # 1/sqrt(2 pi)
    fmul.s  f26, f26, f27              # n
    flw     f27, 80(s7)                # 0.2316419
    fmul.s  f27, f27, f25
    flw     f28, 4(s7)                 # 1
    fadd.s  f27, f28, f27
    fdiv.s  f27, f28, f27              # k2
    fmul.s  f28, f27, f27              # k2^2
    fmul.s  f29, f28, f27              # k2^3
    fmul.s  f30, f29, f27              # k2^4
    fmul.s  f31, f30, f27              # k2^5
    flw     f24, 84(s7)                # a1
    fmul.s  f27, f27, f24
    flw     f24, 88(s7)                # a2
    fmul.s  f28, f28, f24
    flw     f24, 92(s7)                # a3
    fmul.s  f29, f29, f24
    fadd.s  f28, f28, f29
    flw     f24, 96(s7)                # a4
    fmul.s  f30, f30, f24
    fadd.s  f28, f28, f30
    flw     f24, 100(s7)               # a5
    fmul.s  f31, f31, f24
    fadd.s  f28, f28, f31
    fadd.s  f27, f27, f28              # l
    fmul.s  f27, f27, f26
    flw     f24, 4(s7)                 # 1
    fsub.s  \fd, f24, f27              # loc
    beqz    t3, 2f
    fsub.s  \fd, f24, \fd
2:
.endm

_start:
    lw      s0, 0(a1)                  # S
    lw      s1, 4(a1)                  # K
    lw      s2, 8(a1)                  # r
    lw      s3, 12(a1)                 # v
    lw      s4, 16(a1)                 # T
    lw      s5, 20(a1)                 # call
    lw      s6, 24(a1)                 # put
    lw      s7, 28(a1)                 # C
    slli    t4, a0, 2
    add     t5, s0, t4
    flw     f0, 0(t5)                  # S
    add     t5, s1, t4
    flw     f1, 0(t5)                  # K
    add     t5, s2, t4
    flw     f2, 0(t5)                  # r
    add     t5, s3, t4
    flw     f3, 0(t5)                  # v
    add     t5, s4, t4
    flw     f4, 0(t5)                  # T
    fsqrt.s f5, f4                     # sq
    fdiv.s  f6, f0, f1                 # S / K
    LOG     f6, f6                     # lt
    fmul.s  f7, f3, f3
    flw     f8, 0(s7)                  # 0.5
    fmul.s  f7, f7, f8                 # pw
    fadd.s  f8, f2, f7
    fmul.s  f8, f8, f4
    fadd.s  f8, f8, f6
    fmul.s  f9, f3, f5                 # den
    fdiv.s  f8, f8, f9                 # d1
    fsub.s  f9, f8, f9                 # d2
    CNDF    f10, f8                    # N1
    CNDF    f11, f9                    # N2
    fmul.s  f12, f2, f4
    fneg.s  f12, f12
    EXP     f12, f12
    fmul.s  f12, f1, f12               # fv
    fmul.s  f13, f0, f10
    fmul.s  f14, f12, f11
    fsub.s  f13, f13, f14              # call
    flw     f15, 4(s7)                 # 1
    fsub.s  f14, f15, f11
    fmul.s  f14, f12, f14
    fsub.s  f16, f15, f10
    fmul.s  f16, f0, f16
    fsub.s  f14, f14, f16              # put
    add     t5, s5, t4
    fsw     f13, 0(t5)
    add     t5, s6, t4
    fsw     f14, 0(t5)
    ecall
