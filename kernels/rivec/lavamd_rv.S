# lavamd_rv.S  -  RiVEC lavaMD (docs/rivec_plan.md), FP32, one particle per thread
#
#   Boxes of 96 particles; rv holds (v, x, y, z) per particle, qv the charges, fv the
#   forces (the host sets them to 0). Thread t is particle i = t mod 96 of home box
#   l = t / 96. It visits the home box and then its nn[l] neighbours nei[l*26 + 0..],
#   RiVEC's order, and in each box the 96 particles j in order (rv_ref.h rv_lavamd):
#     r2 = (B.v + A.v) - fma(A.z, B.z, fma(A.y, B.y, B.x*A.x));  u2 = r2*a2
#     vij = exp(-u2) (RiVEC's Cephes exp);  fs = 2*vij;  f = fs*(A - B)
#     fA.v = fma(q, vij, fA.v);  fA.x/y/z = fma(q, f.x/y/z, fA.x/y/z)
#
#   a0 = tid   a1 = &P
#   P[0] = &rv  P[1] = &qv  P[2] = &fv  P[3] = &nn  P[4] = &nei (26 words per box, plus one
#   spare word at the end)  P[5] = a2 (f32)
#   P[6] = &C (the exp constants: rv_ref.h rv_bs_consts)
.section .text
.globl _start

.macro EXP fd, fx                      # Cephes exp, as bs_rv.S; temps f16-f20, t0 t1
    fmv.s   f16, \fx
    flw     f17, 8(s7)                 # [2] hi
    fmin.s  f16, f16, f17
    flw     f17, 12(s7)                # [3] lo
    fmax.s  f16, f16, f17
    flw     f17, 16(s7)                # [4] log2e
    flw     f18, 0(s7)                 # [0] 0.5
    fmadd.s f17, f17, f16, f18
    fcvt.w.s t0, f17, rne
    fcvt.s.w f18, t0
    flt.s   t1, f17, f18
    fcvt.s.w f19, t1
    fsub.s  f17, f18, f19
    flw     f18, 20(s7)                # [5] C1
    fmul.s  f18, f17, f18
    flw     f19, 24(s7)                # [6] C2
    fmul.s  f19, f17, f19
    fsub.s  f16, f16, f18
    fsub.s  f16, f16, f19
    fmul.s  f19, f16, f16
    flw     f18, 28(s7)                # [7] p0
    flw     f20, 32(s7)
    fmadd.s f18, f18, f16, f20
    flw     f20, 36(s7)
    fmadd.s f18, f18, f16, f20
    flw     f20, 40(s7)
    fmadd.s f18, f18, f16, f20
    flw     f20, 44(s7)
    fmadd.s f18, f18, f16, f20
    flw     f20, 48(s7)                # [12] p5
    fmadd.s f18, f18, f16, f20
    fmadd.s f18, f18, f19, f16
    flw     f20, 4(s7)                 # [1] 1
    fadd.s  f18, f18, f20
    fcvt.w.s t0, f17, rne
    addi    t0, t0, 127
    slli    t0, t0, 23
    fmv.w.x f20, t0
    fmul.s  \fd, f18, f20
.endm

_start:
    lw      s0, 0(a1)                  # rv
    lw      s1, 4(a1)                  # qv
    lw      s2, 8(a1)                  # fv
    lw      s3, 12(a1)                 # nn
    lw      s4, 16(a1)                 # nei
    flw     f8, 20(a1)                 # a2
    lw      s7, 24(a1)                 # C
    flw     f9, 4(s7)
    fadd.s  f9, f9, f9                 # 2.0
    li      t2, 43691                  # ceil(2^22 / 96): no divide instruction
    mul     s5, a0, t2
    srli    s5, s5, 22                 # l = t / 96, exact for t < 98,304 (boxes1d <= 10)
    slli    t3, a0, 4                  # 16 bytes per particle
    add     t4, s0, t3
    flw     f0, 0(t4)                  # A.v
    flw     f1, 4(t4)                  # A.x
    flw     f2, 8(t4)                  # A.y
    flw     f3, 12(t4)                 # A.z
    add     s6, s2, t3                 # &fA
    flw     f4, 0(s6)
    flw     f5, 4(s6)
    flw     f6, 8(s6)
    flw     f7, 12(s6)
    sh2add  t4, s5, s3
    lw      s8, 0(t4)                  # nn[l]: neighbour boxes left after the home box
    li      t4, 104                    # 26 words per box
    mul     t4, s5, t4
    add     s9, s4, t4                 # &nei[l*26]
    mv      s10, s5                    # pb = l (home box first)
1:  li      t4, 1536                   # 96 * 16 bytes per box
    mul     a3, s10, t4
    add     a3, s0, a3                 # &rB[0]
    li      t4, 384                    # 96 * 4
    mul     a4, s10, t4
    add     a4, s1, a4                 # &qB[0]
    li      s11, 96
2:  flw     f10, 0(a3)                 # B.v
    flw     f11, 4(a3)                 # B.x
    flw     f12, 8(a3)                 # B.y
    flw     f13, 12(a3)                # B.z
    fadd.s  f14, f10, f0               # B.v + A.v
    fmul.s  f15, f11, f1               # B.x*A.x
    fmadd.s f15, f2, f12, f15          # + A.y*B.y
    fmadd.s f15, f3, f13, f15          # + A.z*B.z
    fsub.s  f14, f14, f15              # r2
    fmul.s  f14, f14, f8               # u2
    fneg.s  f14, f14
    EXP     f14, f14                   # vij
    fmul.s  f15, f9, f14               # fs
    fsub.s  f10, f1, f11               # dx
    fsub.s  f11, f2, f12               # dy
    fsub.s  f12, f3, f13               # dz
    fmul.s  f10, f15, f10              # fxij
    fmul.s  f11, f15, f11              # fyij
    fmul.s  f12, f15, f12              # fzij
    flw     f13, 0(a4)                 # q
    fmadd.s f4, f13, f14, f4
    fmadd.s f5, f13, f10, f5
    fmadd.s f6, f13, f11, f6
    fmadd.s f7, f13, f12, f7
    addi    a3, a3, 16
    addi    a4, a4, 4
    addi    s11, s11, -1
    bnez    s11, 2b
    lw      s10, 0(s9)                 # next neighbour (after the last: one word past
    addi    s9, s9, 4                  #   this box's list, not used; nei has a spare word)
    addi    s8, s8, -1
    bgez    s8, 1b                     # nn[l] + 1 boxes in all
    fsw     f4, 0(s6)
    fsw     f5, 4(s6)
    fsw     f6, 8(s6)
    fsw     f7, 12(s6)
    ecall
