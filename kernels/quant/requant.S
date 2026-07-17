# =============================================================================
# requant.S — INT32→INT8 requantization (AI Tier-2; FP-reuse, no new hardware)
#
# The bridge between quantized layers: a GEMM/conv layer accumulates INT8×INT8
# products into an INT32 accumulator; before the next INT8 layer that value must
# be rescaled and re-clamped to a signed byte:
#     out = clamp( round( acc * scale + zero_point ), -128, 127 )
# SIMTiX already has an FPU, so this is a short branchless FP sequence — no
# dedicated fixed-point requantize datapath is needed (unlike FPU-less INT8
# engines). One thread per element; the signed-byte stores (sb, stride 1) pack
# four outputs per word, which is exactly qgemm's packed-INT8 input layout.
#
#   ABI:  a0 = tid   a1 = &Acc (int32[])   a2 = &params   a3 = &Out (int8[])
#         params[0] = scale (f32)   params[1] = zero_point (f32)
#   Constants: 127.0f = 0x42FE0000, -128.0f = 0xC3000000 (lui loads bits[31:12]).
#
# Assemble (F for the FP ops, M unused here but keeps the shared list uniform):
#   riscv64-unknown-elf-gcc -march=rv32imf -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o requant.elf requant.S
# =============================================================================
    .text
    .globl _start
_start:
    slli     t0, a0, 2         # tid*4
    add      t1, a1, t0        # &Acc[tid]
    lw       t2, 0(t1)         # acc  (int32)
    flw      f1, 0(a2)         # scale       (broadcast, same for all lanes)
    flw      f2, 4(a2)         # zero_point  (broadcast)
    fcvt.s.w f3, t2            # f3 = (float)acc
    fmadd.s  f3, f3, f1, f2    # f3 = acc*scale + zero_point   (fused, 1 rounding)
    lui      t3, 0x42fe0       # 127.0f
    fmv.w.x  f4, t3
    lui      t3, 0xc3000       # -128.0f
    fmv.w.x  f5, t3
    fmin.s   f3, f3, f4        # clamp high: min(f3, 127)
    fmax.s   f3, f3, f5        # clamp low:  max(f3, -128)
    fcvt.w.s t4, f3, rne       # round to nearest even → int32 in [-128,127]
    add      t5, a3, a0        # &Out[tid]   (int8, stride 1 byte)
    sb       t4, 0(t5)         # store the signed byte (packs 4/word)
    ecall
