# AI-1 — INT8 packed dot-product (`pdot8`)

This is the implementation deep-dive for the first step of turning SIMTiX into an
**AI inference accelerator**: a custom **INT8 packed dot-product instruction**,
`pdot8`. It is written to be read alongside the source (`rtl/accel/warp_pool.sv`,
`rtl/accel/simtix_pkg.sv`) and is detailed enough to stand as a thesis chapter.

It follows the same house style as the other focused studies —
[m8_lutram.md](m8_lutram.md) (register file in distributed RAM),
[m7_energy.md](m7_energy.md) (lane clock-gating) — and the overall
[architecture.md](architecture.md).

---

## 1. Motivation — why this instruction, and why now

### 1.1 SIMTiX before AI-1

SIMTiX is a programmable SIMT (Single-Instruction, Multiple-Thread) accelerator:
`NUM_LANES = 8` lanes execute one warp's instruction in lockstep, and `NUM_WARPS
= 4` hardware warp slots are interleaved by a round-robin scheduler to hide
latency. It runs a subset of RV32IMF, so it can *already* express the core math of
a neural network — it has FP32/FP16 GEMM (`kernels/matmul/fgemm.S`), softmax
(`kernels/fptest/fsoftmax.S`), and ReLU. In that sense SIMTiX was already a
functional, if small, AI engine.

### 1.2 The gap AI-1 closes

The gap between *"can run neural-net math"* and *"is an efficient inference
accelerator"* is **arithmetic precision and density**. Modern inference does not
run in FP32 — it runs in **quantized INT8**, because:

* **4× the data movement efficiency** — four INT8 values pack into one 32-bit
  word, so a load moves four MACs' worth of operands.
* **4× the compute density** — four INT8 multiply-accumulates replace one FP32 MAC
  for the same register pressure.
* **Negligible accuracy loss** — post-training INT8 quantization holds within a
  fraction of a percent of FP32 accuracy on typical CNN/MLP inference.

A general SIMT core *can* do INT8 by masking and shifting bytes, but that costs
~8 instructions per 4 MACs. A **single fused dot-product instruction** collapses
that to one instruction and, crucially, maps the four multiplies onto the FPGA's
hard **DSP48E2** blocks instead of soft LUT fabric.

### 1.3 Where this sits in the resource picture

A prior audit ([memory: SIMTiX LUT audit]) established that SIMTiX on the ZCU104
(`xczu7ev`) uses ~30 % of LUTs, **2.3 % of DSPs, and 0 % of BRAM** — i.e. the FPGA
has enormous arithmetic headroom. `pdot8` spends a little of that DSP headroom
(+32 DSP, four per lane — see §4.2) to buy a 4× INT8 throughput multiplier, which
is exactly the right trade for an accelerator that is nowhere near DSP-bound (the
measured build sits at 72/1728 DSP = 4.2%).

---

## 2. Design decisions (and the rationale for each)

Every non-obvious choice is recorded here, because the *reasoning* is the part a
thesis needs.

### 2.1 Non-accumulating semantics

`pdot8 rd, rs1, rs2` computes a **pure 4-way dot product** into `rd`; it does
**not** read `rd` as a running accumulator (`rd += …`).

**Why:** the integer register file (VRF) has exactly **two asynchronous read
ports** (`vrf_rd1`/`vrf_rd2`, see `warp_pool.sv` `g_vrf`). A fused
`rd += dot(rs1,rs2)` form would need to read `rd` as a *third* source, forcing an
extra LUTRAM read port on every lane's bank. The non-accumulating form keeps the
two-port file untouched; the kernel accumulates in a separate register with a
single-cycle `add`, which overlaps freely with the next `pdot8` under the
scheduler. A fused accumulate is noted as future work (§8).

### 2.2 A background DSP engine, not a single-cycle ALU op

`pdot8` executes in a **park-and-resume background engine** (`W_DOT`), exactly
like RV32M `mul` (`W_MUL`) and FP compute (`W_FPC`) — **not** in the single-cycle
integer ALU.

**Why:** SIMTiX is a 2-stage F(etch)/X(ecute) pipeline whose critical path is
routing-dominated. Putting a DSP multiply directly in the single-cycle
fetch→execute→writeback cloud is precisely what hurt timing historically (the
reason `mul` was pulled out of the ALU into `W_MUL`). A DSP that is *pipelined and
parked* stays off the critical path. The warp parks on `W_DOT`; the scheduler
keeps issuing other warps while the DSP tree fills; the result is written back
when a VRF port is free. This reuses a proven, already-verified pattern.

### 2.3 Custom-0 opcode, encoded with `.insn`

`pdot8` uses the RISC-V **custom-0** major opcode (`7'b0001011`), which the ISA
reserves for non-standard extensions.

**Why:** it can never collide with the `rv32imf` instructions the toolchain emits,
so the extension is *inert* to every existing kernel and to the compiler. Because
gcc does not know the mnemonic, kernels encode it with the assembler's raw
`.insn r` directive — **no compiler patch is needed**, which keeps the whole
toolchain stock.

### 2.4 DSP microarchitecture — an honest note on "2 INT8 per DSP"

Xilinx's well-known INT8 trick (WP486) packs **two** INT8 MACs into one DSP48E2 —
but only when the two multiplies **share an operand** (one activation × two
weights, i.e. convolution output-channel reuse). In a general per-lane dot product
all eight bytes are independent, so that packing **does not apply** to `pdot8`; it
belongs to a future systolic/tensor engine where weight-sharing is structural.

For `pdot8` the correct, DSP-frugal design is **four independent signed 9×9
multiplies per lane reduced by a registered adder tree** — one DSP per product,
i.e. **4 DSP/lane if fully parallel**. In practice Vivado fits the small 9×9
products and the reduction efficiently; the design is pipelined so all inferred
DSPs pack cleanly (AREG/BREG + MREG + PREG, zero DRC advisories), the same
discipline used for the existing multiply engines.

---

## 3. ISA specification

### 3.1 Encoding (R-type, custom-0)

```
 31        25 24    20 19    15 14  12 11   7 6      0
| funct7=0   |  rs2   |  rs1   |funct3| rd  |0001011 |   OP_CUSTOM0
```

| field   | value            | meaning                                   |
|---------|------------------|-------------------------------------------|
| opcode  | `0001011` (0x0B) | custom-0 major opcode                     |
| funct7  | `0000000`        | selects the `pdot8` family (0)            |
| funct3  | variant          | signedness (below)                        |
| rd      | dest             | 32-bit dot-product result                 |
| rs1/rs2 | sources          | each holds four packed INT8 values        |

Package constants (`rtl/accel/simtix_pkg.sv`):

```systemverilog
parameter logic [6:0] OP_CUSTOM0 = 7'b0001011;  // custom-0: pdot8 family
parameter logic [2:0] DOT8_SS = 3'b000;   // rs1 signed   × rs2 signed
parameter logic [2:0] DOT8_UU = 3'b001;   // rs1 unsigned × rs2 unsigned
parameter logic [2:0] DOT8_SU = 3'b010;   // rs1 signed   × rs2 unsigned
```

### 3.2 Operation

For `rs1 = {a3,a2,a1,a0}` and `rs2 = {b3,b2,b1,b0}` (byte `i` = bits `[8i+7 : 8i]`):

```
rd = Σ(i=0..3) ext(a_i) × ext(b_i)
```

where `ext()` is sign-extension for a signed operand and zero-extension for an
unsigned one, selected per `funct3`:

| funct3 | mnemonic  | rs1 bytes | rs2 bytes | typical use                  |
|--------|-----------|-----------|-----------|------------------------------|
| `000`  | `pdot8`   | signed    | signed    | symmetric / weight×weight    |
| `001`  | `pdot8u`  | unsigned  | unsigned  | activation×activation        |
| `010`  | `pdot8su` | signed    | unsigned  | **weight × activation** (inference) |

The sum of four products lies in `[-260 100, +260 100]`, so it never overflows the
32-bit `rd` (it fits in 19 bits; 32 bits is comfortable).

### 3.3 Assembly form

Because gcc does not emit the mnemonic, encode with `.insn`:

```asm
# pdot8   rd, rs1, rs2   (signed × signed)
.insn r 0x0B, 0, 0, rd, rs1, rs2
# pdot8u  rd, rs1, rs2   (unsigned × unsigned)
.insn r 0x0B, 1, 0, rd, rs1, rs2
# pdot8su rd, rs1, rs2   (signed × unsigned — the inference case)
.insn r 0x0B, 2, 0, rd, rs1, rs2
```

---

## 4. Microarchitecture

All of the following lives in `rtl/accel/warp_pool.sv`. `pdot8` is a faithful
clone of the `W_MUL` integer-multiply engine; the table in §6 lists the exact
correspondence.

### 4.1 Decode

```systemverilog
assign is_dot   = (opcode == OP_CUSTOM0) && (instr[31:25] == 7'd0);
assign dot_mode = funct3;                       // DOT8_SS / _UU / _SU
```

Dispatch is gated so `pdot8` retires through `W_DOT` and never through the
single-cycle compute path:

```systemverilog
assign do_dot     = issue_valid && !do_pop && !is_ecall && !is_mem &&
                    !is_sfu_op && is_dot;
assign do_compute = ... && !do_fp && !do_mul && !do_dot;   // dot excluded
```

### 4.2 The per-lane DSP datapath

Operands are captured at issue (`q_dot_a`, `q_dot_b`) and **held constant** while
the warp is parked, so the datapath is a fixed-latency streaming pipeline whose
output settles and then stays stable (the scoreboard samples it a cycle later,
which makes the capture robust to off-by-one). Per lane (`generate g_idot`):

```
Stage 0  : sign/zero-extend the four byte-pairs to 9-bit signed (DSP A/B regs)
           sa = signed(rs1)?   [SS or SU]      sb = signed(rs2)?   [SS]
Stage 1  : four signed 9×9 products  m0..m3     (DSP MREG)   (* use_dsp="yes" *)
Stage 2  : product registers         p0..p3     (DSP PREG)
Stage 3  : partial sums  s01 = p0+p1,  s23 = p2+p3   (sign-extended to 32b)
Stage 4  : dsum = s01 + s23           → dot_res[lane]
```

A single **signed** 9×9 multiply serves every variant: an unsigned byte is
extended with a `0` sign bit (value `0..255`, always non-negative), a signed byte
is sign-extended (`-128..127`). This is why `sa`/`sb` fully capture SS/UU/SU with
one multiplier shape.

### 4.3 Latency and the scoreboard

`q`-capture (1) + A/B reg (1) + M (1) + P (1) + add (1) + add (1) = **6 cycles**
from issue to a settled result. The `W_DOT` scoreboard is a three-state FSM
mirroring `W_MUL`:

```
DOT_IDLE  → (issue) → DOT_RUN → (dot_cnt counts down) → DOT_WB → (port free) → DOT_IDLE
```

`DOT_CNT_INIT = 6` makes `DOT_RUN` capture `dot_res` at issue+7 — one safe cycle
after it settles. `DOT_WB` drives the per-lane results onto the integer VRF when
the port is free, then restores the parked warp's PC to `dot_resume_pc` and
returns it to `W_RUN`. Only **one** dot is in flight across all warps (single
slot); a second warp attempting a dot while the engine is busy simply waits and
retries — idempotent, since nothing was committed.

### 4.4 Writeback arbitration

`pdot8` is always integer-dest, so it shares the integer VRF write port. The port
priority is:

```
integer mem-load  >  FPC(int-dest)  >  MUL  >  DOT  >  single-cycle compute
```

`dot_wb_fire` asserts only when the port is not claimed by any higher-priority
producer; a colliding single-cycle compute is squashed (`squash_wb`) and re-issues
next cycle. This guarantees at most one writer per lane per cycle, preserving the
single-write-port LUTRAM invariant.

---

## 5. Worked throughput example (INT8 GEMM inner loop)

An INT8 matrix-multiply inner product over `K` elements, four at a time:

```asm
        li   acc, 0
.Lk:    lw   av, 0(pa)          # 4 activations (packed int8)
        lw   wv, 0(pw)          # 4 weights     (packed int8)
        .insn r 0x0B, 2, 0, t0, wv, av   # pdot8su t0 = Σ w_i·a_i  (4 MACs)
        add  acc, acc, t0       # accumulate (single-cycle, overlaps)
        addi pa, pa, 4
        addi pw, pw, 4
        addi k,  k,  -4
        bnez k, .Lk
```

Each iteration does **4 INT8 MACs** and issues one `pdot8` (+1 `add`). The scalar
equivalent needs 4 `mul` + 4 `add` (8 arithmetic ops) plus byte extraction — so
`pdot8` is roughly a **4× reduction in dynamic instruction count** on the MAC
path, and it moves the multiplies from LUT fabric onto DSP48E2.

---

## 6. Integration map (`W_MUL` → `W_DOT`)

Every `pdot8` signal mirrors an existing `mul` signal, which is why the change is
contained (~90 lines) and low-risk:

| Concern                 | `W_MUL` (existing)       | `W_DOT` (new)                       |
|-------------------------|--------------------------|-------------------------------------|
| warp state enum         | `W_MUL`                  | `W_DOT` (enum widened to 4 bits)    |
| decode                  | `is_mul`                 | `is_dot`, `dot_mode`                |
| dispatch flag           | `do_mul`                 | `do_dot` (+ excluded from `do_compute`) |
| operand hold regs       | `q_mul_a/b`              | `q_dot_a/b`, `q_dot_mode`           |
| datapath (generate)     | `g_imul` (16×16 tree)    | `g_idot` (4×(9×9) + adder tree)     |
| per-lane result         | `mul_res`                | `dot_res`                           |
| scoreboard FSM          | `MUL_IDLE/RUN/WB`        | `DOT_IDLE/RUN/WB`                   |
| scoreboard regs         | `mul_w/rd/we/cnt/data…`  | `dot_w/rd/we/cnt/data…`             |
| writeback-enable capture| `mwb_en`                 | `dwb_en`                            |
| writeback gate          | `mul_wb_fire`            | `dot_wb_fire` (one tier below MUL)  |
| VRF write branch        | `mul_wb_fire` arm        | `dot_wb_fire` arm                   |
| issue-time park         | `else if (do_mul)`       | `else if (do_dot)`                  |
| busy / energy guards    | `W_MUL`, `do_mul` terms  | `W_DOT`, `do_dot` terms             |
| reset / launch init     | `mul_state <= MUL_IDLE`  | `dot_state <= DOT_IDLE`             |

---

## 7. Verification

### 7.1 Method

`tests/tb_pdot8.sv` drives `warp_pool` directly through a behavioural line memory
(same harness as `tb_fpkernels`). It loads the assembled kernel
`kernels/dotprod/pdot8.S` (13 words, inlined), preloads eight lanes' worth of
distinct packed operands, launches one warp of `NUM_LANES` threads, and reads the
three per-lane results back from memory.

The kernel computes **all three variants** (`pdot8`, `pdot8u`, `pdot8su`) on the
same operands and stores them to three output regions, so a single run checks
every signedness path per lane. Test operands deliberately include the signed
edge values `0x80` (−128), `0x7F` (127) and `0xFF` (−1 / 255) so sign/zero
extension is exercised at the boundaries.

### 7.2 Reference model

Because `pdot8` is integer arithmetic, the reference is **exact** (no tolerance).
`tb_pdot8.sv` reimplements each variant in SystemVerilog:

```systemverilog
// signed × signed
for (i=0..3) s += int'(signed'(a[8i+:8])) * int'(signed'(b[8i+:8]));
// unsigned × unsigned
for (i=0..3) s += int'({24'b0,a[8i+:8]}) * int'({24'b0,b[8i+:8]});
// signed × unsigned
for (i=0..3) s += int'(signed'(a[8i+:8])) * int'({24'b0,b[8i+:8]});
```

Every lane's hardware result must match its reference `!==`-exactly.

### 7.3 Result

```
SIMTiX INT8 pdot8 golden test  (NUM_LANES=8  NUM_WARPS=4)
  [PASS] all 8 lanes × 3 variants bit-exact
RESULT: PASS
```

Run with `make -C sim test-pdot8`. The instruction is inert to prior kernels, so
the full regression (`make -C sim test`) stays green.

---

## 8. Future work

* **Fused accumulate** (`pdot8.acc rd += dot`) — needs a third VRF read port or an
  in-engine accumulator keyed by (warp, lane, rd); would remove the separate
  `add` from the inner loop.
* **Wider packing** — `pdot8` over two source registers (8 bytes) per instruction,
  streaming 8 products, for longer inner products per issue.
* **Requantization op** — INT32 accumulator → INT8 with scale + clamp, to close the
  quantized-inference loop in hardware.
* **Tensor / systolic engine** — the natural place for the WP486 "2 INT8 per DSP"
  weight-sharing packing and for output-stationary MAC arrays; this is where
  SIMTiX would fold in the separate INT8 systolic accelerator project.
---

## 8a. Measured FPGA PPA (ZCU104 / xczu7ev, placed OOC, 100 MHz)

Placed (synth → opt → place → phys_opt → route → power) via `fpga/impl_ai.tcl`;
reports in `fpga/reports_ai_pdot8/`. Compared to the pre-`pdot8` M17 baseline:

| Resource | AI-1/AI-2 build | M17 baseline | Δ |
|----------|----------------:|-------------:|----:|
| LUT | 70,779 (30.7%) | 69,987 | +792 (~1%) |
| FF | 17,411 | 14,954 | +2,457 |
| DSP | **72** (4.2%) | 40 | **+32** (4/lane × 8) |
| BRAM | 0 | 0 | 0 |
| Placed Fmax | **112.2 MHz** (WNS +1.089 ns @100 MHz) | 100.7 | +11.5 |
| Power (vectorless) | 0.969 W (0.376 dyn + 0.594 static) | ~1.53 | run-variance* |

The result confirms the design thesis: the INT8 engine costs **+32 DSP and ~1% LUT
and does NOT regress Fmax** (it is a pipelined DSP background engine, off the
fetch→execute path). *Note: `report_power` is a vectorless estimate at default
toggle rates and is run-sensitive, so the apparent power drop vs. M17 is not
claimed as a real reduction — 0.969 W is this build's measured value.*

**Efficiency (INT8, ops = 2×MAC).** An 8-lane core lands in the GOPS range, not TOPS:

| | @100 MHz (met) | @112.2 MHz (placed Fmax) |
|---|---|---|
| Measured (qgemm, 1.90 MAC/cyc) | 0.38 GOP/s → **0.39 GOP/s/W** | 0.43 → **0.44 GOP/s/W** |
| Datapath ceiling (32 MAC/cyc) | 6.4 GOP/s → **6.6 GOP/s/W** | 7.2 → **7.4 GOP/s/W** |

The measured-vs-ceiling gap is the single-slot `W_DOT` scoreboard plus the
memory/accumulate stalls in `qgemm` (see [ai2_qgemm.md](ai2_qgemm.md) §6); closing
it is the motivation for the Tier-3 tensor engine.

## 8b. Future work

* **Wider packing** — `pdot8` over two source registers (8 bytes) per instruction.
* **Requantization op** — INT32 accumulator → INT8 with scale + clamp.
* **Tensor / systolic engine** — the natural place for the WP486 "2 INT8 per DSP"
  weight-sharing packing and output-stationary MAC arrays; where SIMTiX folds in
  the separate INT8 systolic accelerator project.

---

## 9. Files touched

| File | Change |
|------|--------|
| `rtl/accel/simtix_pkg.sv` | `OP_CUSTOM0`, `DOT8_SS/UU/SU` constants |
| `rtl/accel/warp_pool.sv`  | `W_DOT` state, decode, `g_idot` DSP engine, scoreboard, writeback, park logic |
| `kernels/dotprod/pdot8.S` | self-test / demo kernel (all three variants) |
| `tests/tb_pdot8.sv`       | bit-exact golden testbench |
| `sim/Makefile`            | `test-pdot8` target (+ added to `test`) |
| `docs/ai1_pdot8.md`       | this document |
| `docs/isa.md`             | ISA-table entry for `pdot8` |
