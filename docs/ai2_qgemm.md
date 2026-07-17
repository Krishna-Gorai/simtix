# AI-2 — INT8 GEMM kernel (`qgemm`)

This is the deep-dive for the second AI step: a **quantized INT8 GEMM** kernel,
`qgemm.S`, built on the `pdot8` instruction from [AI-1](ai1_pdot8.md). GEMM
(general matrix-multiply) is the computational core of every neural-network layer
— fully-connected layers *are* GEMMs, and convolution becomes a GEMM after
`im2col` — so a correct, coalesced INT8 GEMM is the load-bearing kernel of the
whole inference story. It is the INT8 twin of the FP32 `fgemm.S`.

---

## 1. What it computes

A full 8×8 output tile of an INT8 matrix multiply with reduction length `K = 16`:

```
C[row][col] = Σ(k=0..K-1) A[row][k] × B[k][col]        (M=N=8, K=16, signed INT8)
```

`A` and `B` are signed INT8; `C` is INT32 (the accumulator never saturates for
these sizes). The reduction runs **four elements at a time** with `pdot8`, so the
inner loop issues one packed dot-product (4 MACs) per iteration instead of four
scalar multiply-adds.

## 2. SIMT mapping

One **warp per output row**, one **lane per output column** (the same shape as
`fgemm.S`). Launch with `N = M·N = 64` threads:

```
row = tid >> 3       (= warp id)
col = tid & 7        (= lane id)
```

So all 8 lanes of a warp share the same `row` of `A`, and each lane owns a
different `col` of `B`/`C`.

## 3. Data layouts — chosen so both loads coalesce

The layouts are the crux of the kernel; they make every memory access a single
coalesced line, which is confirmed by the measured transaction count (§6).

| Matrix | Layout | Why it coalesces |
|--------|--------|------------------|
| **A** | 8×16 INT8, **row-major**. `A[row][4·kk‥]` is one 32-bit word. | Every lane of a warp uses the *same* `row`, so the 8 lane-loads hit **one address** → a single **broadcast** line transaction. |
| **B** | **Pre-packed** `Bpacked[Kp=4][N=8]` words. `Bpacked[kk][col]` packs `B[4·kk+0‥3][col]` little-endian, stored at word `kk·N + col`. | For a fixed `kk` the eight columns (lanes) are **contiguous** → a single coalesced line. This is the standard inference **weight layout** (weights are packed offline). |
| **C** | 8×8 INT32, row-major. `C[tid]`. | The eight columns of a row are contiguous → one store line per warp. |

The little-endian byte packing matches `pdot8`'s operand format exactly:
`pdot8` reads `rs.byte[i] = bits[8i+:8]`, so byte `i` of the A word is `A[row][4kk+i]`
and byte `i` of the B word is `B[4kk+i][col]`; their product sum over `i` and `kk`
is precisely `Σ_k A[row][k]·B[k][col]`.

## 4. Kernel walk-through

```asm
_start:
    srli t0, a0, 3        # row = tid >> 3
    andi t1, a0, 7        # col = tid & 7
    slli t0, t0, 4        # row*16  (K bytes/row)   → &A[row][0] = a1 + row*16
    add  t0, a1, t0
    slli t1, t1, 2        # col*4                    → &Bpacked[0][col] = a2 + col*4
    add  t1, a2, t1
    li   t2, 0            # acc = 0
    li   t3, 0            # kk  = 0
    li   t4, 4            # Kp
.Lk:
    slli t5, t3, 2        # A word stride = 4  → &A[row][4kk]
    add  t5, t0, t5
    lw   t5, 0(t5)        #   broadcast load
    slli t6, t3, 5        # B word stride = 32 → &Bpacked[kk][col]
    add  t6, t1, t6
    lw   t6, 0(t6)        #   coalesced load
    .insn r 0x0B,0,0, s0, t5, t6   # pdot8 s0 = Σ_i A_i·B_i   (4 MACs, signed×signed)
    add  t2, t2, s0      # acc += partial dot
    addi t3, t3, 1       # kk++
    blt  t3, t4, .Lk     # uniform branch → no divergence
    slli t5, a0, 2       # C[tid] = acc
    add  t5, a3, t5
    sw   t2, 0(t5)
    ecall
```

The K loop branch is **uniform** (all lanes compute the same `kk`), so it never
diverges — it just retargets the warp PC, and the reconvergence stack is untouched.

## 5. Verification

`tests/tb_qgemm.sv` preloads `A` (8×16 INT8) and the packed weights `Bpacked`
(4×8 words), launches 64 threads, and checks all 64 INT32 outputs **`!==`-exactly**
against a signed-integer matmul reference:

```systemverilog
for (k=0..15) s += int'(signed'(a8(row,k))) * int'(signed'(b8(k,col)));
```

Test data spans the full signed byte range (via `8'(…)` wrap-around) so negative
weights/activations are exercised. Result:

```
SIMTiX INT8 GEMM (qgemm) golden test  M=8 N=8 K=16  (LANES=8 WARPS=4)
  [PASS] all 64 INT8 outputs bit-exact  (538 cycles, 72 gmem txns)
RESULT: PASS
```

Run with `make -C sim test-qgemm`. The kernel adds no RTL (it only uses `pdot8`,
already in the green regression), so the full suite stays green.

## 6. Performance analysis

| Metric | Value | Notes |
|--------|-------|-------|
| MACs | 1024 | `M·N·K = 8·8·16` |
| `pdot8` SIMT instructions | 32 | `M·Kp`; each spans `N` lanes × 4 = **32 MACs** |
| Cycles | 538 | measured |
| **Throughput** | **1.90 MAC/cycle** | ceiling = 32 MAC/cycle (8 lanes × 4) |
| Global-mem transactions | 72 | = `8 warps × (Kp·2 loads + 1 store)` = 8×9 |

**Coalescing works as designed** — the 72 transactions match the analytic model
exactly, versus `64 threads × (Kp·2 + 1) = 576` for a naïve per-lane engine (an
**8× reduction** in memory traffic).

**Energy efficiency (measured, ops = 2×MAC).** With the placed power of **0.969 W**
(ZCU104 / xczu7ev; see [ai1_pdot8.md](ai1_pdot8.md) §8a) the INT8 efficiency is:

| | @100 MHz (met) | @112.2 MHz (placed Fmax) |
|---|---|---|
| Measured (qgemm, 1.90 MAC/cyc) | 0.38 GOP/s → **0.39 GOP/s/W** | 0.43 → **0.44 GOP/s/W** |
| Datapath ceiling (32 MAC/cyc) | 6.4 GOP/s → **6.6 GOP/s/W** | 7.2 → **7.4 GOP/s/W** |

For an 8-lane academic core these land honestly in the **GOPS** range (≡ milli-TOPS),
not TOPS. The gap between measured and ceiling is the single-slot `W_DOT` + the
per-warp dependency stalls below — the lever for closing it is the Tier-3 tensor
engine, not more SIMT tuning.

**Throughput is functional, not yet tuned.** 1.90 of a 32 MAC/cycle ceiling
reflects two honest limits, both known and both future work:
1. **Single-slot `W_DOT`** — only one `pdot8` is in flight across all warps, and
   its ~7-cycle latency is only partially hidden (there are just 8 warps of work
   for 4 slots).
2. **Per-warp dependency chain** — within a warp, each iteration's `load → pdot8 →
   accumulate` is serialized by the `acc` recurrence, so the loads and dot latency
   do not overlap across `kk`.

The lever for real density is **not** more SIMT tuning but a **tensor/systolic
engine** (Tier-3): an output-stationary MAC array amortizes weight reuse and hits
many MACs/cycle, which is exactly where the Xilinx "2 INT8 per DSP" weight-sharing
packing applies. `qgemm` establishes the *correct*, coalesced baseline that a
tensor engine will be measured against.

## 7. Toward the MNIST demo (next)

`qgemm` is the building block for the end-to-end proof point:
* stack two `qgemm` layers (784→128→10) with a **ReLU** between and a **requantize**
  step (INT32 → INT8 with per-layer scale + clamp),
* run a **pre-quantized MLP on `chip_top`** with the host CPU streaming an MNIST
  digit and reading back the argmax,
* report **accuracy + images/s + TOPS/W** — the numbers that make SIMTiX
  demonstrably an AI accelerator.

Open items: a `requantize` op/kernel and a general `K` (currently hard-wired to 16
like `fgemm`'s hard-wired `NCOL=8`, to fit the 3-pointer launch ABI). The FPGA PPA
is now measured (§6 above; full breakdown in [ai1_pdot8.md](ai1_pdot8.md) §8a).

## 8. Files

| File | Change |
|------|--------|
| `kernels/matmul/qgemm.S` | INT8 GEMM tile kernel (uses `pdot8`) |
| `tests/tb_qgemm.sv` | bit-exact golden testbench vs. integer matmul |
| `sim/Makefile` | `test-qgemm` target (+ added to `test`) |
| `kernels/build_kernels.sh` | `matmul/qgemm` in the build list |
| `docs/ai2_qgemm.md` | this document |
