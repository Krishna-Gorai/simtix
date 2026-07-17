# =============================================================================
# requant_relu.S — requantize + fused ReLU (AI-4). Identical to requant.S but the
# low clamp is 0 instead of -128, so it does INT32 -> INT8 requantization AND the
# ReLU activation in one pass:  out = clamp(round(acc*scale + zp), 0, 127).
# Used between MLP layers (qgemv -> requant_relu -> qgemv). Signed-byte stores at
# stride 1 pack 4/word = the next qgemv's packed-INT8 x-vector layout.
#   ABI: a0=tid  a1=&Acc(int32[])  a2=&params(f32:[0]scale,[1]zp)  a3=&Out(int8[])
# =============================================================================
    .text
    .globl _start
_start:
    slli     t0, a0, 2
    add      t1, a1, t0
    lw       t2, 0(t1)         # acc (int32)
    flw      f1, 0(a2)         # scale
    flw      f2, 4(a2)         # zero_point
    fcvt.s.w f3, t2            # (float)acc
    fmadd.s  f3, f3, f1, f2    # acc*scale + zp
    lui      t3, 0x42fe0       # 127.0f
    fmv.w.x  f4, t3
    fmv.w.x  f5, x0            # 0.0f  (ReLU low clamp)
    fmin.s   f3, f3, f4        # min(f3, 127)
    fmax.s   f3, f3, f5        # max(f3, 0)     ← ReLU
    fcvt.w.s t4, f3, rne       # round to nearest even → int in [0,127]
    add      t5, a3, a0        # &Out[tid]  (int8, stride 1)
    sb       t4, 0(t5)
    ecall
