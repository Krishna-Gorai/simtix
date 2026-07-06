# fsoftmax.S  -  numerically-stable FP32 softmax over one warp (8 elements)  [DRAFT]
#
#   m      = max_i x[i]                 (cross-lane max reduction, fmax.s)
#   e[i]   = exp(x[i] - m)              (z = x-m <= 0, so exp in (0,1] : no overflow)
#   s      = sum_i e[i]                 (cross-lane sum reduction, fadd.s)
#   y[i]   = e[i] / s                   (fdiv.s)
#
# One warp = 8 lanes = 8 classes (extend to N by tiling / masking; MNIST-10 needs
# two warps or a masked 16-lane launch). The two reductions are SINGLE-SIDED ifs
# (only lane 0 works; lanes 1-7 skip to the join and the warp reconverges there),
# then every lane reads the broadcast slot from scratch and finishes in lockstep.
#
# SIMTiX has no exp instruction (SFU = div/sqrt only), so exp(z) is built from FMAs:
#     exp(z) = 2^(z*log2e) = 2^k * 2^f,  k = round(z*log2e),  f = z*log2e - k in [-.5,.5]
#     2^f  ~= (((( c4*f + c3)*f + c2)*f + c1)*f + 1   (degree-4 Horner, |err| ~1e-5)
#     2^k  = bit-built float: exponent field = k+127   (k<=0 here; huge -z -> 0, fine)
#
#   a0 = tid   a1 = &X (in, 8 words)   a3 = &Y (out, 8 words)
#   scratch[0..7] = per-lane staging   scratch[8] = max bcast   scratch[9] = sum bcast
#   SCRATCH_BASE = 0x4000_0000
#
# Assemble:
#   riscv64-unknown-elf-gcc -march=rv32imf -mabi=ilp32f -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o fsoftmax.elf fsoftmax.S
#   riscv64-unknown-elf-objcopy -O binary fsoftmax.elf fsoftmax.bin

.section .text
.globl _start
_start:
    andi    t0, a0, 7          # lane = tid & 7
    slli    t1, t0, 2          # lane*4
    lui     t2, 0x40000        # SCRATCH_BASE
    add     t2, t2, t1         # &scratch[lane]
    slli    t3, a0, 2          # tid*4
    add     t4, a1, t3         # &X[tid]
    flw     f1, 0(t4)          # x = X[tid]
    fsw     f1, 0(t2)          # scratch[lane] = x

    # ── reduction 1: m = max_i scratch[i]  (single-sided, lane 0 only) ────────────
    bne     t0, x0, .Ljoin_m
    lui     t5, 0x40000        # &scratch[0]
    flw     f10, 0(t5)         # m = scratch[0]
    flw     f4, 4(t5)
    fmax.s  f10, f10, f4       # max scratch[1]
    flw     f4, 8(t5)
    fmax.s  f10, f10, f4       # max scratch[2]
    flw     f4, 12(t5)
    fmax.s  f10, f10, f4       # max scratch[3]
    flw     f4, 16(t5)
    fmax.s  f10, f10, f4       # max scratch[4]
    flw     f4, 20(t5)
    fmax.s  f10, f10, f4       # max scratch[5]
    flw     f4, 24(t5)
    fmax.s  f10, f10, f4       # max scratch[6]
    flw     f4, 28(t5)
    fmax.s  f10, f10, f4       # max scratch[7]
    fsw     f10, 32(t5)        # scratch[8] = m   (broadcast)
.Ljoin_m:                      # <-- warp reconverges here (all 8 lanes active)
    lui     t5, 0x40000
    flw     f10, 32(t5)        # every lane: m = scratch[8]
    fsub.s  f1, f1, f10        # z = x - m     (<= 0)

    # ── e = exp(z) via 2^(z*log2e), built from FMAs ───────────────────────────────
    li      t6, 0x3FB8AA3B     # log2e = 1.44269502
    fmv.w.x f11, t6
    fmul.s  f2, f1, f11        # y = z*log2e   (<= 0)
    fcvt.w.s t6, f2, rne       # k = round(y)  (nearest, ties-even)
    fcvt.s.w f12, t6           # (float)k
    fsub.s  f3, f2, f12        # f = y - k     in [-0.5, 0.5]
    # 2^f  Horner:  acc = c4; acc = acc*f + c3; ... ; acc = acc*f + 1.0
    li      t3, 0x3C1D9B92     # c4 = 0.00961812
    fmv.w.x f13, t3
    li      t3, 0x3D6357CF     # c3 = 0.05550411
    fmv.w.x f14, t3
    fmadd.s f13, f13, f3, f14  # acc = c4*f + c3
    li      t3, 0x3E75FDF1     # c2 = 0.24022651
    fmv.w.x f14, t3
    fmadd.s f13, f13, f3, f14  # acc = acc*f + c2
    li      t3, 0x3F317218     # c1 = 0.69314718 (ln2)
    fmv.w.x f14, t3
    fmadd.s f13, f13, f3, f14  # acc = acc*f + c1
    li      t3, 0x3F800000     # c0 = 1.0
    fmv.w.x f14, t3
    fmadd.s f13, f13, f3, f14  # acc = acc*f + 1.0   == 2^f
    # 2^k : build float with exponent field (k+127); k<=0, underflow -> 0 (term->0)
    addi    t6, t6, 127        # biased exponent
    slli    t6, t6, 23         # into exponent position (mantissa 0)
    fmv.w.x f15, t6            # 2^k
    fmul.s  f5, f13, f15       # e = 2^f * 2^k = exp(z)
    fsw     f5, 0(t2)          # scratch[lane] = e   (overwrites staged x)

    # ── reduction 2: s = sum_i scratch[i]  (single-sided, lane 0 only) ────────────
    bne     t0, x0, .Ljoin_s
    lui     t5, 0x40000
    fmv.w.x f6, x0             # s = +0.0
    flw     f4, 0(t5)
    fadd.s  f6, f6, f4
    flw     f4, 4(t5)
    fadd.s  f6, f6, f4
    flw     f4, 8(t5)
    fadd.s  f6, f6, f4
    flw     f4, 12(t5)
    fadd.s  f6, f6, f4
    flw     f4, 16(t5)
    fadd.s  f6, f6, f4
    flw     f4, 20(t5)
    fadd.s  f6, f6, f4
    flw     f4, 24(t5)
    fadd.s  f6, f6, f4
    flw     f4, 28(t5)
    fadd.s  f6, f6, f4
    fsw     f6, 36(t5)         # scratch[9] = s   (broadcast)
.Ljoin_s:                      # <-- reconverge, all 8 lanes active
    lui     t5, 0x40000
    flw     f6, 36(t5)         # every lane: s = scratch[9]
    fdiv.s  f7, f5, f6         # y = e / s

    slli    t3, a0, 2          # tid*4
    add     t4, a3, t3         # &Y[tid]
    fsw     f7, 0(t4)          # Y[tid] = softmax
    ecall
