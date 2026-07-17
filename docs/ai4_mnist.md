# AI-4 — end-to-end quantized MNIST inference

This is the deep-dive for the **capstone demo**: a complete INT8-quantized MLP
running MNIST digit inference on the SIMTiX accelerator, using only the operators
built in AI-1…AI-3. It is the proof point that SIMTiX is not just a SIMT core that
*can* do neural-net math, but one that runs a **real, trained, quantized network
end-to-end and gets the right answers**.

Builds on [`pdot8`](ai1_pdot8.md), [`qgemm`](ai2_qgemm.md), and
[`requant`](ai3_requant.md).

---

## 1. What it does

A pre-trained INT8 MLP (`784 → 128 → 10`) classifies MNIST digits. The entire
forward pass executes on the accelerator's kernels; the host (a testbench here,
the CPU driver on-chip) only sets base pointers and launches each kernel:

```
x(int8[784]) ─qgemv─► acc1(int32[128]) ─requant_relu─► h(int8[128])
             ─qgemv─► acc2(int32[10]) ─argmax─► predicted digit
```

## 2. The model and quantization (`ml/mnist_quant.py`)

* **Training** — a 784→128→10 ReLU MLP trained in pure numpy (SGD, 8 epochs):
  **FP32 test accuracy 96.82%**.
* **Quantization** — symmetric per-tensor INT8: activations and weights scaled to
  `[-127,127]`. **INT8 test accuracy 96.53%** — only a 0.29% drop.
* **Layer-1 requant multiplier** `M1 = (Sx·Sw1)/Sh = 0.000696921` (f32 bits
  `0x3A36B197`).
* **Golden** — an integer-exact inference the accelerator must reproduce. The
  requant step is computed in **float32** (`np.rint(np.float32(acc1)*M1f)` clamped
  to `[0,127]`) so it matches the hardware FPU bit-for-bit, not float64.

The script exports weights/images/golden as hex (packed 4×INT8/word) for the tb.

## 3. Kernels used

| Kernel | Role | Doc |
|--------|------|-----|
| `qgemv.S` | INT8 GEMV `out[n]=Σ x[k]·W[k][n]`, one lane per output, parameterized K/N | [ai_qgemv] |
| `requant_relu.S` | `clamp(round(acc·M1),0,127)` — requant + ReLU in one pass | [ai3] |
| (argmax) | 10-way max over the final logits — trivial, done host-side | — |

`qgemv` reads `Kp = K/4` from a config word (byte `0x100`) and `N` from the seeded
thread count `a4`, so the *same* kernel runs both layers (K=784 then K=128) just by
changing the config word and the base pointers.

## 4. Data flow and layouts

The layouts are chosen so every load coalesces and so each stage's output is
already in the next stage's input format — no repacking between layers:

* **x / h** — INT8 packed 4/word. `requant_relu` stores results with `sb` at
  stride 1, so the 128 hidden bytes land as 32 packed words = exactly `qgemv`'s
  packed x-vector layout for layer 2.
* **W1, W2** — pre-packed `Wpacked[Kp][N]` (weights packed offline, the standard
  inference layout): contiguous columns per warp ⇒ coalesced weight loads.

### Memory map (tb, 256 KB)

| Region | Addr | Size |
|--------|------|------|
| qgemv kernel | `0x0000` | 20 w |
| requant_relu kernel | `0x0060` | 16 w |
| config (`Kp`) | `0x0100` | 1 w |
| requant params (`M1`,`zp`) | `0x0140` | 2 w |
| layer-1 acc (int32[128]) | `0x0200` | 128 w |
| hidden h (int8[128]) | `0x0400` | 32 w |
| layer-2 acc (int32[10]) | `0x0480` | 10 w |
| W2packed `[32][10]` | `0x0800` | 320 w |
| images `[64][196]` | `0x1000` | 12544 w |
| W1packed `[196][128]` | `0x1_0000` | 25088 w |

## 5. Orchestration (per image)

```
mem[cfg] = 196;  launch qgemv (n=128, x=IMG[i], W=W1, out=ACC1)   # layer 1
           launch requant_relu (n=128, ACC1, params=M1, out=H)    # requant + ReLU
mem[cfg] = 32;   launch qgemv (n=10,  x=H,      W=W2, out=ACC2)   # layer 2
argmax(ACC2[0..9]) -> prediction
```

## 6. Result

`tests/tb_mnist.sv`, `make -C sim test-mnist`:

```
SIMTiX end-to-end MNIST inference  (784->128->10 INT8)  64 images
  accelerator vs golden : 64 / 64 match
  accuracy vs labels    : 63 / 64 = 98.4%
RESULT: PASS (accelerator reproduces the golden bit-exact)
```

* **64/64 bit-exact vs the integer golden** — the accelerator's INT8 GEMV +
  FP-reuse requant reproduce the reference inference exactly, digit for digit.
* **98.4% accuracy** on the 64-image subset, matching the golden — i.e. SIMTiX
  performs real MNIST classification, not a toy computation.

Combined with the measured PPA ([ai1_pdot8.md](ai1_pdot8.md) §8a: 72 DSP, 112 MHz,
0.969 W), this is a complete, honest story: a programmable RISC-V SIMT core that
runs a real quantized network end-to-end on measured hardware.

## 7. Next: on-chip demo (step 4)

The tb stands in for the host. The final step wires the same sequence into
`chip_top`'s **CPU driver** (the host RISC-V core sets the MMIO base/`Kp`/go
registers and reads back the argmax), so the whole inference runs on the
integrated chip exactly as the "result = 964" bring-up demo does — the deployable
end-to-end MNIST accelerator.

## 8. Files

| File | Change |
|------|--------|
| `ml/mnist_quant.py` | train + quantize + float32 golden + hex export |
| `ml/data/mnist_int8.npz` | weights/scales/golden (tracked) |
| `ml/data/*.hex` | tb-loadable packed data (generated, gitignored) |
| `tests/tb_mnist.sv` | end-to-end orchestration + golden check |
| `sim/Makefile` | `test-mnist` target |
| `docs/ai4_mnist.md` | this document |
