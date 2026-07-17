# AI-3 — INT32→INT8 requantization (`requant`)

This is the deep-dive for the third AI step: **requantization**, the bridge that
lets quantized layers be chained. It is a software kernel (`requant.S`) that reuses
the existing FPU — no new hardware — and it completes the operator set needed for
an end-to-end quantized MLP (`qgemm` → `requant` → ReLU → `qgemm` → …).

Builds on [AI-1 `pdot8`](ai1_pdot8.md) and [AI-2 `qgemm`](ai2_qgemm.md).

---

## 1. Why requantization is needed

A quantized layer multiplies INT8 activations by INT8 weights and accumulates into
an **INT32** accumulator (that is exactly what `qgemm` produces). But the *next*
INT8 layer needs INT8 **inputs**. Requantization rescales the wide accumulator back
down to a signed byte:

```
out = clamp( round( acc × scale + zero_point ), -128, 127 )
```

where `scale = (S_in · S_weight) / S_out` is the composed quantization scale (a real
number, usually < 1) and `zero_point` shifts the output range for asymmetric
quantization (0 for symmetric). Without this step the layers cannot be composed.

## 2. Design decision — FP-reuse, not a dedicated datapath

**SIMTiX already has a full FP32 pipeline** (`fcvt`, `fmadd`, `fmin`/`fmax`), so
requantization is a short *branchless* FP sequence and needs **no new hardware**.

This is a deliberate, honest trade. A production FPU-less INT8 accelerator would
implement requantize as a fixed-point integer datapath (gemmlowp's
`SaturatingRoundingDoublingHighMul` + rounding shift), specifically to *avoid*
paying for an FPU. SIMTiX already pays for one (it is a general SIMT core with FP
kernels), so the marginal-cost-optimal choice is to reuse it. The dedicated integer
`requant` instruction remains available as future work and would make a clean PPA /
energy comparison (see §6).

## 3. The kernel

One thread per element; `acc[tid]` → one output byte. Because the outputs are
stored with **`sb` at stride 1**, four consecutive lanes' bytes pack into one word —
which is precisely `qgemm`'s packed-INT8 **input** layout, so requant feeds the next
layer directly with no repacking.

```asm
_start:                       # a0=tid a1=&Acc(int32) a2=&params(f32) a3=&Out(int8)
    slli     t0, a0, 2
    add      t1, a1, t0
    lw       t2, 0(t1)        # acc (int32)
    flw      f1, 0(a2)        # scale       (broadcast)
    flw      f2, 4(a2)        # zero_point  (broadcast)
    fcvt.s.w f3, t2           # (float)acc
    fmadd.s  f3, f3, f1, f2   # acc*scale + zero_point   (fused → single rounding)
    lui      t3, 0x42fe0; fmv.w.x f4, t3   #  127.0f
    lui      t3, 0xc3000; fmv.w.x f5, t3   # -128.0f
    fmin.s   f3, f3, f4       # clamp high
    fmax.s   f3, f3, f5       # clamp low
    fcvt.w.s t4, f3, rne      # round to nearest even → int32 in [-128,127]
    add      t5, a3, a0
    sb       t4, 0(t5)        # signed byte (packs 4/word for the next qgemm)
    ecall
```

Notes:
* The clamp is done **in float, before the int conversion** — `fmin`/`fmax` are
  branchless, so there is no SIMT divergence (unlike a compare-and-branch clamp).
* `fcvt.w.s … rne` uses round-to-nearest-even, the standard rounding for
  requantization.
* `fmadd.s` fuses `acc*scale + zp` with a single rounding.
* The 127/−128 float constants are built with `lui` (which loads bits [31:12]);
  `0x42FE0000 = 127.0f`, `0xC3000000 = −128.0f`.

## 4. Precision note

`fcvt.s.w` converts INT32→FP32, which is *exact* only for `|acc| < 2²⁴`. For the
`qgemm` tile (K=16, `|acc| ≲ 2.6·10⁵`) and for an MNIST MLP (784 inputs,
`|acc| ≲ 1.3·10⁷ < 2²⁴`) the accumulator is within the exact range, so no precision
is lost in the int→float step. For much longer reductions the conversion would
round — inherent to any FP-based requantize and acceptable for inference. A
dedicated integer datapath would avoid this entirely.

## 5. Verification

`tests/tb_requant.sv` runs the kernel on eight accumulators spanning the sign range,
**both clamp saturations**, near-zero, and the +127 edge, with `scale = 0.05`,
`zero_point = 2.0`. Each output byte is checked against a software reference:

```
out = clamp( round_nearest( acc·scale + zp ), -128, 127 )
```

Test values are chosen away from `.5` rounding boundaries so the integer result is
unambiguous and the check is **exact**. Result:

```
SIMTiX INT32->INT8 requantize golden test  (LANES=8 WARPS=4)
  [PASS] all 8 requantized bytes bit-exact
RESULT: PASS
```

Run with `make -C sim test-requant`. No RTL is added, so the full regression stays
green.

> **Verification aside (worth recording for the thesis).** The first run "failed"
> — but the *reference* was wrong, not the kernel. SystemVerilog's `int'(real)`
> cast **already rounds to nearest**; the reference additionally added `0.5` before
> the cast, double-rounding `52.0 → 52.5 → 53`. The hardware's `52` was correct.
> Fix: `r = int'(y)` with no manual `+0.5`. A good reminder that a golden model is
> only as trustworthy as its own arithmetic.

## 6. Future work

* **Dedicated integer `requant` instruction** — gemmlowp-style
  `clamp(round((acc · M0) >> shift), -128, 127)` on a DSP-pipelined engine
  (mirroring `pdot8`'s `W_DOT`). Enables FPU-less INT8 inference and a direct
  PPA/energy comparison against this FP-reuse kernel.
* **Per-channel scale** — load a per-lane `scale`/`zp` (weights are commonly
  quantized per output channel) instead of a broadcast per-tensor scalar.

## 7. Toward the MNIST demo (next)

With `qgemm` (INT8 GEMM), `requant` (this), and ReLU, the full quantized-MLP
forward pass is now expressible:

```
x(int8) → qgemm → acc(int32) → requant → h(int8) → relu → qgemm → … → argmax
```

Next: a pre-quantized 784→128→10 MLP driven by the host CPU on `chip_top`, reading
back the predicted digit — the end-to-end proof point (accuracy + images/s).

## 8. Files

| File | Change |
|------|--------|
| `kernels/quant/requant.S` | INT32→INT8 requantize kernel (FP-reuse) |
| `tests/tb_requant.sv` | golden testbench (exact byte check) |
| `sim/Makefile` | `test-requant` target (+ added to `test`) |
| `kernels/build_kernels.sh` | `quant/requant` in the FP build list |
| `docs/ai3_requant.md` | this document |
