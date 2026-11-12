# bs_rv.S  -  RiVEC blackscholes (docs/rivec_plan.md), FP32, one option per thread
#
#   RiVEC's BlkSchlsEqEuroNoDiv_vector and CNDF_SIMD read per element, with RiVEC's
#   Cephes exp and log (common/__exp.h __exp_2xf32, __log.h __log_2xf32); the operations
#   and their order are those of kernels/rivec/rv_ref.h rv_blackscholes:
#     lt = log(S/K); sq = sqrt(T); fv = exp(-(r*T)); pw = (v*v)*0.5
#     d1 = fma(r + pw, T, lt) / (v*sq); d2 = d1 - v*sq
#     N1 = CNDF(d1); N2 = CNDF(d2); fv = fv*K; for a put N1 = 1 - N1, N2 = 1 - N2
#     price = |fv*N2 - S*N1|
#   Constants: the table of rv_ref.h rv_bs_consts (word index in the comments).
#
#   a0 = tid   a1 = &P
#   P[0..4] = &S &K &r &v &T   P[5] = &type (int32, 1 = put)   P[6] = &price   P[7] = &C
.section .text
.globl _start

.macro EXP fd, fx                      # Cephes exp; temps f16-f20, t0 t1
    fmv.s   f16, \fx
    flw     f17, 8(s7)                 # [2] hi
    fmin.s  f16, f16, f17
    flw     f17, 12(s7)                # [3] lo
    fmax.s  f16, f16, f17              # x
    flw     f17, 16(s7)                # [4] log2e
    flw     f18, 0(s7)                 # [0] 0.5
    fmadd.s f17, f17, f16, f18         # fx = log2e*x + 0.5
    fcvt.w.s t0, f17, rne
    fcvt.s.w f18, t0                   # tmp = rne(fx)
    flt.s   t1, f17, f18
    fcvt.s.w f19, t1                   # fx < tmp ? 1 : 0
    fsub.s  f17, f18, f19              # fx = tmp - that
    flw     f18, 20(s7)                # [5] C1
    fmul.s  f18, f17, f18
    flw     f19, 24(s7)                # [6] C2
    fmul.s  f19, f17, f19
    fsub.s  f16, f16, f18
    fsub.s  f16, f16, f19              # x
    fmul.s  f19, f16, f16              # z
    flw     f18, 28(s7)                # [7] p0
    flw     f20, 32(s7)                # [8] p1
    fmadd.s f18, f18, f16, f20
    flw     f20, 36(s7)                # [9] p2
    fmadd.s f18, f18, f16, f20
    flw     f20, 40(s7)                # [10] p3
    fmadd.s f18, f18, f16, f20
    flw     f20, 44(s7)                # [11] p4
    fmadd.s f18, f18, f16, f20
    flw     f20, 48(s7)                # [12] p5
    fmadd.s f18, f18, f16, f20
    fmadd.s f18, f18, f19, f16         # y = y*z + x
    flw     f20, 4(s7)                 # [1] 1
    fadd.s  f18, f18, f20
    fcvt.w.s t0, f17, rne              # fx (an integer)
    addi    t0, t0, 127
    slli    t0, t0, 23
    fmv.w.x f20, t0                    # 2^fx
    fmul.s  \fd, f18, f20
.endm

.macro LOG fd, fx                      # Cephes log (x > 0); temps f16-f22, t0-t2
    flw     f16, 132(s7)               # [33] smallest normal
    fmax.s  f16, \fx, f16
    fmv.x.w t0, f16
    srli    t1, t0, 23                 # imm0
    li      t2, 0x807FFFFF             # ~0x7f800000
    and     t0, t0, t2
    li      t2, 0x3F000000             # bits of 0.5
    or      t0, t0, t2
    fmv.w.x f16, t0                    # x in [0.5, 1)
    addi    t1, t1, -127
    fcvt.s.w f17, t1
    flw     f18, 4(s7)                 # [1] 1
    fadd.s  f17, f17, f18              # e
    flw     f19, 52(s7)                # [13] sqrt(1/2)
    flt.s   t2, f16, f19
    fcvt.s.w f19, t2                   # mask ? 1 : 0
    fmul.s  f20, f16, f19              # tmp = mask ? x : +0
    fsub.s  f16, f16, f18              # x - 1
    fsub.s  f17, f17, f19              # e - mask
    fadd.s  f16, f16, f20              # x
    fmul.s  f21, f16, f16              # z
    flw     f22, 56(s7)                # [14] p0
    flw     f20, 60(s7)                # [15] p1
    fmadd.s f22, f22, f16, f20
    flw     f20, 64(s7)                # [16] p2
    fmadd.s f22, f22, f16, f20
    flw     f20, 68(s7)                # [17] p3
    fmadd.s f22, f22, f16, f20
    flw     f20, 72(s7)                # [18] p4
    fmadd.s f22, f22, f16, f20
    flw     f20, 76(s7)                # [19] p5
    fmadd.s f22, f22, f16, f20
    flw     f20, 80(s7)                # [20] p6
    fmadd.s f22, f22, f16, f20
    flw     f20, 84(s7)                # [21] p7
    fmadd.s f22, f22, f16, f20
    flw     f20, 88(s7)                # [22] p8
    fmadd.s f22, f22, f16, f20
    fmul.s  f22, f22, f21              # y*z
    flw     f20, 92(s7)                # [23] q1
    fmadd.s f22, f17, f20, f22         # e*q1 + y
    flw     f20, 0(s7)                 # [0] 0.5
    fmul.s  f20, f21, f20
    fsub.s  f22, f22, f20              # y - z*0.5
    flw     f20, 96(s7)                # [24] q2
    fmul.s  f20, f17, f20              # e*q2
    fadd.s  f16, f16, f22
    fadd.s  \fd, f16, f20
.endm

.macro CNDF fd, fx                     # RiVEC's CNDF_SIMD; temps f24-f31, t3 (and EXP's)
    fmv.w.x f24, zero
    flt.s   t3, \fx, f24               # x < 0
    fabs.s  f25, \fx                   # xa
    fmul.s  f26, f25, f25
    flw     f27, 128(s7)               # [32] -0.5
    fmul.s  f26, f26, f27
    EXP     f26, f26
    flw     f27, 100(s7)               # [25] 1/sqrt(2 pi)
    fmul.s  f26, f26, f27              # n
    flw     f27, 104(s7)               # [26] 0.2316419
    flw     f28, 4(s7)                 # [1] 1
    fmadd.s f27, f27, f25, f28
    fdiv.s  f27, f28, f27              # k2
    fmul.s  f28, f27, f27              # k2^2
    fmul.s  f29, f28, f27              # k2^3
    fmul.s  f30, f29, f27              # k2^4
    fmul.s  f31, f30, f27              # k2^5
    flw     f24, 108(s7)               # [27] a1
    fmul.s  f27, f27, f24              # l1
    flw     f24, 112(s7)               # [28] a2
    fmul.s  f28, f28, f24              # l2
    flw     f24, 116(s7)               # [29] a3
    fmadd.s f28, f29, f24, f28
    flw     f24, 120(s7)               # [30] a4
    fmadd.s f28, f30, f24, f28
    flw     f24, 124(s7)               # [31] a5
    fmadd.s f28, f31, f24, f28
    fadd.s  f27, f28, f27              # l2 + l1
    fmul.s  f27, f27, f26
    flw     f24, 4(s7)                 # [1] 1
    fsub.s  \fd, f24, f27              # loc
    beqz    t3, 2f
    fsub.s  \fd, f24, \fd              # x < 0: 1 - loc
2:
.endm

_start:
    lw      s0, 0(a1)                  # S
    lw      s1, 4(a1)                  # K
    lw      s2, 8(a1)                  # r
    lw      s3, 12(a1)                 # v
    lw      s4, 16(a1)                 # T
    lw      s5, 20(a1)                 # type
    lw      s6, 24(a1)                 # price
    lw      s7, 28(a1)                 # C
    sh2add  t5, a0, s0
    flw     f0, 0(t5)                  # S
    sh2add  t5, a0, s1
    flw     f1, 0(t5)                  # K
    sh2add  t5, a0, s2
    flw     f2, 0(t5)                  # r
    sh2add  t5, a0, s3
    flw     f3, 0(t5)                  # v
    sh2add  t5, a0, s4
    flw     f4, 0(t5)                  # T
    fdiv.s  f6, f0, f1                 # S / K
    LOG     f6, f6                     # lt
    fsqrt.s f5, f4                     # sq
    fmul.s  f12, f2, f4
    fneg.s  f12, f12
    EXP     f12, f12                   # fv
    fmul.s  f7, f3, f3
    flw     f8, 0(s7)                  # [0] 0.5
    fmul.s  f7, f7, f8                 # pw
    fadd.s  f8, f2, f7                 # r + pw
    fmadd.s f8, f8, f4, f6             # (r + pw)*T + lt
    fmul.s  f9, f3, f5                 # den
    fdiv.s  f8, f8, f9                 # d1
    fsub.s  f9, f8, f9                 # d2
    CNDF    f10, f8                    # N1
    CNDF    f11, f9                    # N2
    fmul.s  f12, f12, f1               # fv * K
    sh2add  t5, a0, s5
    lw      t5, 0(t5)                  # type
    beqz    t5, 3f
    flw     f15, 4(s7)                 # [1] 1
    fsub.s  f10, f15, f10              # put: 1 - N1
    fsub.s  f11, f15, f11              #      1 - N2
3:  fmul.s  f13, f0, f10               # S*N1
    fmul.s  f14, f12, f11              # fv*N2
    fsub.s  f13, f14, f13
    fabs.s  f13, f13                   # price
    sh2add  t5, a0, s6
    fsw     f13, 0(t5)
    ecall
