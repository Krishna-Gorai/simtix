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

## 7. On-chip demo (step 4) — done

The tb above stands in for the host; step 4 moves the *whole* inference onto the
integrated `chip_top`, driven by the on-chip host RISC-V CPU exactly as the
"result = 964" bring-up demo is. The weights no longer arrive from a testbench —
they live in a **256 KB on-chip block-RAM store** (`weight_rom`, region `0xA`), and
the host CPU **streams** each weight tile from BRAM into the 16 KB LUTRAM working
memory, launches `qgemv`/`requant_relu` per tile via the accelerator MMIO, runs the
argmax, and self-checks each prediction against the golden — **the accelerator core
is untouched**.

* **Driver** — `kernels/mnist/mnist_driver.S`, a 182-instruction rv32i program
  assembled into `driver_rom` (`DRIVER="mnist"`). It boots by copying the two
  kernels + params from BRAM to working memory, then per image `i=0..63` copies the
  image, streams the layer-1 weights in 8 tiles (`Nt=16`, repacked to the tile
  stride), launches `qgemv`→`requant_relu`, streams layer-2, launches the final
  `qgemv`, takes the argmax, and self-checks against the golden byte. A two-phase
  poll (wait `BUSY`, then `DONE`) survives the dispatcher's held-`DONE` between
  launches.
* **BRAM latency** — a weight read stalls the CPU one cycle (`mem_ready`), so the
  1-cycle block-RAM read is absorbed transparently; no accelerator change.
* **Result** — `tests/tb_chip_mnist.sv`, `make -C sim test-chip-mnist`: the chip
  publishes the correct-count to `0x90000000` and the tb checks it is **64/64
  bit-exact** with the golden — full end-to-end MNIST inference on the integrated
  chip, host-driven, out of on-chip BRAM.

## 8. On-chip PPA — BRAM-inclusive (xczu7ev / ZCU104)

This is the first SIMTiX build with a **non-zero BRAM footprint**: the 256 KB
weight/data store is inferred as block RAM. Out-of-context, timing-driven synthesis
of the complete MNIST chip (`chip_top_mnist` = `chip_top` fixed to `DRIVER="mnist"`
+ 65536-word store), `fpga/synth_chip_mnist.tcl`:

| Resource | Used | Avail | Util % |
|----------|------|-------|--------|
| CLB LUTs | 83,475 | 230,400 | 36.2 |
| — LUT as logic | 69,247 | 230,400 | 30.1 |
| — LUT as memory (LUTRAM) | 14,228 | 101,760 | 14.0 |
| CLB registers (FF) | 18,939 | 460,800 | 4.1 |
| **Block RAM (RAMB36E2)** | **64** | 312 | **20.5** |
| — RAMB18 | 0 | 624 | 0.0 |
| DSP | 72 | 1,728 | 4.2 |

* **Timing (100 MHz target):** setup WNS **+1.707 ns → MET**, critical-path delay
  8.293 ns, synth Fmax 120.6 MHz.
* **Power:** 1.358 W total (0.762 dynamic + 0.596 static).

**Reading the numbers.**
* **64 RAMB36 (20.5 %)** — the `weight_rom` store (65536 × 32 = 2 Mbit) maps to 64
  RAMB36 tiles: 65536 deep ÷ 1024 words/tile, stacked depth-wise. The raw-bit floor
  is ~57 tiles; 64 is the real count once Vivado maps the fixed 1K×36 primitive
  geometry. Initialised bit-exact from `mnist_store.hex`, so the power estimate is
  faithful. This is the first non-zero BRAM in the project — every earlier build put
  the register file, scratchpad and shared memory in LUTRAM.
* **72 DSP** — the FP fabric's 40 plus the `pdot8` `W_DOT` INT8 dot engine's 32,
  matching the accelerator-level AI PPA ([ai1_pdot8.md](ai1_pdot8.md) §8a) now
  confirmed at chip level with the BRAM store attached.
* **Caveat — this is OOC synthesis**, so Fmax (120.6 MHz) is congestion-blind and
  optimistic; a placed-and-routed run would come down (cf. the FP timing arc: synth
  88 → placed 78 → 100 MHz after the 3-stage FMA). The **area figures (LUT/FF/BRAM/
  DSP) are accurate at synthesis**; a full `impl` run is the next step for a placed
  Fmax + a `.bit`.

## 9. Files

| File | Change |
|------|--------|
| `ml/mnist_quant.py` | train + quantize + float32 golden + hex export (incl. `mnist_store.hex`) |
| `ml/data/mnist_int8.npz` | weights/scales/golden (tracked) |
| `ml/data/*.hex` | tb/chip-loadable packed data (generated, gitignored) |
| `tests/tb_mnist.sv` | accelerator end-to-end orchestration + golden check |
| `tests/tb_chip_mnist.sv` | on-chip (chip_top) end-to-end, 64/64 self-check |
| `kernels/mnist/mnist_driver.S` | on-chip host driver (rv32i, streams BRAM weights) |
| `rtl/soc/weight_rom.sv` | 256 KB block-RAM weight/data store |
| `rtl/soc/driver_rom.sv` | generic `$readmemh` host instruction ROM |
| `rtl/soc/chip_top.sv` | parameterized `DRIVER`/`WSTORE_*`; BRAM read + `mem_ready` stall |
| `rtl/soc/chip_top_mnist.sv` | synthesis/impl top: chip fixed to the MNIST config |
| `fpga/synth_chip_mnist.tcl` | OOC synth + BRAM-inclusive PPA of the MNIST chip |
| `fpga/create_project_mnist.tcl` | managed GUI project (elaborated-schematic browsing) |
| `sim/Makefile` | `test-mnist`, `test-chip-mnist`, `mnist-driver` targets |
| `docs/ai4_mnist.md` | this document |
