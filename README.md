# SIMTiX — a GPU-inspired SIMT accelerator for RISC-V

[![CI](https://github.com/Krishna-Gorai/simtix/actions/workflows/ci.yml/badge.svg)](https://github.com/Krishna-Gorai/simtix/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![RTL: SystemVerilog](https://img.shields.io/badge/RTL-SystemVerilog-orange.svg)
![Sim: Verilator](https://img.shields.io/badge/Sim-Verilator%205.030-green.svg)
![FPGA: ZCU104 / xczu7ev](https://img.shields.io/badge/FPGA-ZCU104%20xczu7ev-purple.svg)

**SIMTiX** is an open-source, GPU-inspired **SIMT** (Single-Instruction,
Multiple-Threads) accelerator written from scratch in SystemVerilog and attached
to a 5-stage pipelined RISC-V host CPU. The host offloads data-parallel kernels —
vector add, matrix multiply, divergent control kernels — to the accelerator over a
memory-mapped command interface, exactly the way a discrete GPU is driven by its
host.

The goal of the project is to build, and to make legible, every moving part of a
modern throughput machine: **warps**, a **warp scheduler that hides memory
latency**, eight **SIMT lanes** over a **banked vector register file**, true
**control divergence** with a per-warp **reconvergence stack**, an **address-
coalescing memory engine**, and an on-chip **shared-memory scratchpad** — then to
take the whole thing through **FPGA synthesis** on a Zynq UltraScale+ and report
real area / timing / power, plus a small **micro-architectural energy study**.

> **Status: complete.** Milestones **M0 → M9** are all implemented, verified, and
> pushed; CI (lint + simulation regression) is green on every push. See the
> [roadmap](docs/roadmap.md).

---

## Table of contents

1. [Highlights](#highlights)
2. [What makes it SIMT (and not just a vector unit)](#what-makes-it-simt-and-not-just-a-vector-unit)
3. [System architecture](#system-architecture)
4. [Microarchitecture: the `warp_pool` engine](#microarchitecture-the-warp_pool-engine)
5. [How it works, end to end](#how-it-works-end-to-end)
6. [Programming model & kernel ISA](#programming-model--kernel-isa)
7. [Build & test](#build--test)
8. [Results](#results)
9. [Engineering highlights](#engineering-highlights)
10. [Repository layout](#repository-layout)
11. [Roadmap / milestones](#roadmap--milestones)
12. [Limitations & future work](#limitations--future-work)
13. [Prior art](#prior-art)
14. [License](#license)

---

## Highlights

- **True SIMT, not SIMD.** Per-thread control flow is handled in hardware with a
  per-lane active mask and a per-warp **reconvergence stack** — data-dependent
  `if`/loops work without a compiler.
- **Latency hiding by warp interleaving.** A round-robin scheduler issues one warp
  per cycle while a **background memory engine** services another warp's loads/
  stores — the classic GPU trick, measured working in simulation.
- **Memory coalescing.** Eight per-lane accesses that fall on one 32-byte line are
  merged into a **single** line transaction; a contiguous warp access costs 1
  transfer instead of 8 (**8× fewer** in the regression).
- **On-chip shared memory.** A per-warp scratchpad aperture serves a warp's lanes
  without touching the global port — staging reused data there cuts global traffic.
- **Taken to silicon-cost.** Out-of-context synthesis on the **ZCU104 (xczu7ev)**
  with full area / timing / power, *and* optimization passes that bank both the
  register file (M8) and the scratchpad (M9) into distributed RAM: from 170.9k LUT /
  44.1k FF down to **30.1k LUT (13%) / 4.6k FF (1%)**, **timing met at 100 MHz**
  (also meets 125 MHz), 0.81 W.
- **A real research angle.** A divergence-aware **lane clock-gating energy study**
  quantifies **0% → 22.5%** lane-datapath energy saved as divergence rises.
- **Reproducible & open.** 100% open-source flow (Verilator); kernels assemble with
  stock `riscv32` GCC and their machine code is embedded in the testbenches so CI
  stays toolchain-free.

**Default configuration** (`rtl/accel/simtix_pkg.sv`):

| Parameter | Value | Meaning |
|---|---|---|
| `NUM_LANES` | 8 | physical SIMT lanes (threads executed in lockstep / cycle) |
| `WARP_SIZE` | 8 | threads per warp |
| `NUM_WARPS` | 4 | hardware-resident warp slots |
| `XLEN` | 32 | data width (RV32) |
| VRF | 4 × 8 × 32 × 32b | warps × lanes × regs × bits = **32,768 bits** of register state |
| `SDEPTH` | 8 | reconvergence-stack depth (branch nesting limit) |
| `LINE_WORDS` | 8 | words per coalesced cache line (a **256-bit / 32-byte** line) |
| `SCRATCH_WORDS` | 64 | 32-bit words of scratchpad per warp |
| `MMIO_BASE` | `0x8000_0000` | accelerator command-register aperture |
| `SCRATCH_BASE` | `0x4000_0000` | scratchpad address aperture |

---

## What makes it SIMT (and not just a vector unit)

A SIMD/vector unit applies one operation to a vector of data; it has no notion of
per-element control flow. **SIMT keeps the illusion that each thread (lane) has its
own program counter.** When a branch sends lanes in different directions, the
hardware must execute both sides with the correct subset of lanes active and then
*reconverge* them. SIMTiX implements that machinery explicitly:

```c
if (tid & 1)            // odd lanes take the branch, even lanes don't  -> DIVERGENCE
    x += 1000;          // executed with only the odd lanes active
// ... both groups rejoin here                                          -> RECONVERGENCE
```

This is the line that separates SIMTiX from a RISC-V Vector (RVV) core, and it is
the heart of milestone **M5**.

---

## System architecture

The host is a conventional 5-stage pipelined RISC-V core (`rtl/cpu/`, reused and
unmodified). The accelerator hangs off the CPU's **data bus**; a one-line address
decode in `rtl/soc/soc_top.sv` routes accesses in the MMIO aperture to the
accelerator and everything else to the CPU's local RAM. A normal RISC-V program
therefore launches a kernel purely with `sw`/`lw` instructions — no custom opcodes.

```
        ┌──────────────────────────┐
        │   5-stage RISC-V host CPU │   driver program:
        │   IF  ID  EX  MEM  WB     │     sw  kernel_pc/base_a/b/c/n  -> MMIO
        └─────────────┬────────────┘     sw  1 -> CTRL.GO ; poll STATUS.DONE
                      │ data bus (ALUResultM / WriteDataM / ReadDataM)
            ┌─────────▼─────────┐
            │  address decode   │   addr >= 0x8000_0000 ? accelerator : data RAM
            └────┬─────────┬────┘
        (< MMIO) │         │ (>= MMIO)
        ┌────────▼──┐  ┌───▼─────────────────────────────────────────────────┐
        │ data RAM  │  │                 simt_accel  (accelerator top)         │
        └───────────┘  │  ┌────────────┐   ┌───────────────────────────────┐  │
                       │  │ mmio_regs  │──▶│ dispatcher FSM (GO→run→done)  │  │
                       │  └────────────┘   └──────────────┬────────────────┘  │
                       │                   ┌──────────────▼────────────────┐  │
                       │                   │            warp_pool          │  │
                       │                   │  the entire SIMT engine       │  │
                       │                   └──────────────┬────────────────┘  │
                       └──────────────────────────────────┼───────────────────┘
                                       imem (kernel code) ◀┴▶ dmem (256-bit line)
                                                    shared memory
```

- **`mmio_regs`** — the command/status registers the host writes/reads.
- **`simt_accel`** — wraps the registers, a small dispatcher FSM, and the engine.
  The dispatcher pulses `start` on `GO`, then counts cycles until the grid retires
  (exposed as the `CYCLES` performance register).
- **`warp_pool`** — *the project*: scheduler, lanes, register file, divergence
  stack, memory engine and scratchpad, all in one tightly-integrated module.

### MMIO register map (`MMIO_BASE = 0x8000_0000`)

| Offset | Name | R/W | Description |
|---|---|---|---|
| `0x00` | `KERNEL_PC` | W | byte address of the kernel's first instruction |
| `0x04` | `BASE_A` | W | argument 0 base pointer |
| `0x08` | `BASE_B` | W | argument 1 base pointer |
| `0x0C` | `BASE_C` | W | argument 2 base pointer |
| `0x10` | `N` | W | number of threads (grid size) to launch |
| `0x14` | `CTRL` | W | bit0 = `GO` (write 1 to launch) |
| `0x18` | `STATUS` | R | bit0 = `DONE`, bit1 = `BUSY` |
| `0x1C` | `CYCLES` | R | cycle count of the last kernel (performance) |

---

## Microarchitecture: the `warp_pool` engine

`warp_pool` holds **`NUM_WARPS` (4)** warp slots resident at once. Each slot owns
its own architectural state; all slots **share a single fetch/decode/ALU datapath
and a single data port**. A round-robin scheduler issues one warp per cycle, and a
background memory engine advances one coalesced transaction per cycle — so a warp's
memory latency is overlapped with *other* warps' compute.

```
                       ┌───────────────────────────────────────────────┐
   round-robin  ─────▶ │  pick one READY warp  (rr_ptr)                 │
   scheduler           └───────────────────┬───────────────────────────┘
                                           │ cur_pc, cur_mask  (top of that warp's stack)
                       ┌───────────────────▼───────────────────────────┐
   shared fetch ─────▶ │  fetch @cur_pc  →  decode (RV32I + mul + csrr) │
   & decode            └───────────────────┬───────────────────────────┘
                                           │ one decoded instruction, broadcast to all lanes
        ┌──────────────────────────────────▼─────────────────────────────────┐
        │  lane0   lane1   lane2   lane3   lane4   lane5   lane6   lane7        │  ← "single
        │   ALU     ALU     ALU     ALU     ALU     ALU     ALU     ALU         │   instruction,
        │  [cur_mask[l] gates writeback + clock-enable per lane]               │   multiple
        └──────────────────────────────────┬─────────────────────────────────┘   threads"
                                           │  results
        ┌──────────────────────────────────▼─────────────────────────────────┐
        │  Vector Register File  —  8 per-lane DISTRIBUTED-RAM banks (LUTRAM)  │
        │  vrf[lane][{warp,reg}] :  1 write port + 2 async read ports / bank   │
        └──────────────────────────────────────────────────────────────────────┘

        ┌─────────────────────────────────────────────────────────────────────┐
        │  Background memory engine (runs in parallel with the scheduler):      │
        │    • coalesces a warp's 8 lane addresses by 32-byte line              │
        │    • 1 line transaction / cycle on the 256-bit data port              │
        │    • scratchpad accesses bypass the global port (1 cycle / warp)      │
        └─────────────────────────────────────────────────────────────────────┘
```

### Per-warp state

- **Reconvergence stack** — `stk_npc / stk_rpc / stk_mask` with stack pointer `sp`.
  The top-of-stack frame defines the warp's live PC and **active mask**.
- **Vector register file** — 32 RV32 registers per lane, per warp.
- **Scratchpad** — `SCRATCH_WORDS` words of on-chip shared memory.
- **`warp_base`** — the warp's base thread id (for the `tid` CSR / `a0`).

A `wstate` field tracks each slot: `W_EMPTY → W_RUN ⇄ W_MEM → W_DONE`. The spawner
drops grid warps `0,1,2,…` into free/retired slots and recycles a slot the moment
its warp retires, so a grid with more warps than slots still runs.

### Control divergence (the SIMT core idea, M5)

Each warp carries a small **reconvergence stack**. A branch is resolved *per lane*:

- **Uniform** (all active lanes agree) → just retarget the current PC; no divergence.
- **Divergent** (lanes disagree) → push a "continue" frame so the two lane groups
  run in turn, then **pop** and reconverge at the join PC (`RPC`) recorded in the
  frame. Nesting works up to `SDEPTH`.

The supported, compiler-free convention is single-sided `if (cond) { … }` and
divergent loops (one side falls through to the join). `dbg_divergences` counts
divergent-branch events for verification.

### Address coalescing (M4)

The data port is a whole **256-bit line** (8 words). Each cycle the memory engine
picks the line of the lowest still-pending lane and gathers **every** pending lane
that shares that line into one transaction. A contiguous warp access (`A[tid]`)
collapses to **1** line transfer; a fully scattered access costs up to 8.
`dbg_mem_txns` counts global line transactions.

### Shared-memory scratchpad (M6, LUTRAM in M9)

Accesses whose effective address lands in the `SCRATCH_BASE` aperture are served
from a per-warp on-chip scratchpad and never reach the global port. Staging reused
data (e.g. a broadcast matrix row) there cuts global traffic; `dbg_scratch_txns`
counts scratchpad transactions. The scratchpad is **shared across a warp's lanes**
(lane 0's store is visible to lane 3's load), so M9 implements it as a single
**distributed-RAM (LUTRAM)** bank with the memory engine **serializing one lane per
cycle** — the same coalescing-style drain the global port uses — which removes 8.2k
flip-flops while keeping shared-memory semantics exact.

### Register file in distributed RAM (M8)

The VRF is 32,768 bits of state read as `vrf[issue_w][lane][rs]` with *both* the
warp and register index variable — which, if built from flip-flops, synthesizes
into a 128:1 multiplexer per lane per read port (the dominant area and critical
path on FPGA). M8 banks it into **8 independent per-lane distributed-RAM (LUTRAM)
banks** — one synchronous write port and two async read ports each — so the
addressing is done by the RAM primitive instead of LUT muxes. Two supporting
mechanisms keep behaviour bit-identical:

- **Valid bits** replace the one-cycle 32-register spawn clear (a 32-write-port
  pattern a RAM can't express): an unwritten register reads its **spawn seed**
  (`a0=tid`, `a1..a4=args`, else 0).
- **A single arbitrated write port** per lane: the issue stage's compute writeback
  and the memory engine's load writeback can collide, so the memory write wins and
  the compute writeback is **squashed and re-issued** next cycle (idempotent, so
  results are unchanged).

The win: **LUTs 170.9k → 77.0k, FFs 44.1k → 13.3k**, and the design now meets
timing — see [Results](#results) and [docs/m8_lutram.md](docs/m8_lutram.md). M9
then moves the scratchpad to LUTRAM the same way and re-enables timing-driven
synthesis, landing at **30.1k LUT / 4.6k FF** — see
[docs/m9_scratchpad.md](docs/m9_scratchpad.md).

---

## How it works, end to end

A complete launch of a vector-add grid (`C[tid] = A[tid] + B[tid]`):

1. **Command.** The host writes `KERNEL_PC, BASE_A/B/C, N` to the MMIO page, then
   writes `CTRL.GO = 1`.
2. **Dispatch.** `simt_accel`'s FSM pulses `start`; `warp_pool` latches the grid
   and computes `total_warps = ceil(N / WARP_SIZE)`.
3. **Spawn.** Free slots are filled with warps. Each lane is seeded by convention
   (`a0 = tid`, `a1..a4 = args`) — for free, via the M8 valid-bit seed mux.
4. **Issue.** Every cycle the round-robin scheduler picks one `W_RUN` warp, fetches
   at its top-of-stack PC, decodes once, and executes across all 8 lanes; only
   `cur_mask` lanes write back.
5. **Memory.** A `lw`/`sw` hands the warp's active-lane addresses to the background
   engine (warp → `W_MEM`) and **keeps issuing other warps**. The engine coalesces
   and drains the access over one-or-more line transactions, writes results back to
   the VRF, and returns the warp to `W_RUN`.
6. **Divergence.** A branch where lanes disagree pushes a stack frame; the groups
   run in turn and pop/reconverge at the join PC.
7. **Retire.** `ecall` retires a warp (slot → `W_DONE`, recyclable). When nothing is
   left to spawn or run, the pool pulses `done`; the dispatcher latches `CYCLES` and
   sets `STATUS.DONE`. The host's poll loop falls through and reads results from
   memory.

---

## Programming model & kernel ISA

Kernels are written in the **RV32I subset** (plus `mul` and a `tid` CSR) that the
lanes implement, so they assemble with the standard
`riscv32-unknown-elf-gcc -march=rv32im`. At launch each thread is seeded by register
convention:

| Register | Contents at kernel entry |
|---|---|
| `a0` (x10) | thread id (`tid`) |
| `a1` (x11) | base pointer A |
| `a2` (x12) | base pointer B |
| `a3` (x13) | base pointer C |
| `a4` (x14) | thread count `N` |

Thread identity is also available from CSR `TID` (`0xCC0`). A thread terminates with
`ecall`.

**Supported instruction classes:** ALU reg/imm (`add sub and or xor sll srl sra slt
sltu` + immediates), `lui`/`auipc`, `mul` (RV32M, low 32 bits), loads/stores
(`lb lh lw lbu lhu`, `sb sh sw`), branches (`beq bne blt bge bltu bgeu`), jumps
(`jal jalr`), `csrr rd, tid`, and `ecall`. Full details in
[docs/isa.md](docs/isa.md).

**Example — vector add (`kernels`/testbench):**

```asm
vadd_kernel:
    slli  t0, a0, 2          # t0 = tid * 4 (byte offset)
    add   t1, a1, t0         # &A[tid]
    add   t2, a2, t0         # &B[tid]
    add   t3, a3, t0         # &C[tid]
    lw    t4, 0(t1)          # A[tid]
    lw    t5, 0(t2)          # B[tid]
    add   t6, t4, t5
    sw    t6, 0(t3)          # C[tid]
    ecall                    # thread retires
```

Host side (pseudocode):

```c
ACCEL->kernel_pc = vadd_kernel;
ACCEL->base_a = A; ACCEL->base_b = B; ACCEL->base_c = C;
ACCEL->n = 1024;
ACCEL->ctrl = GO;
while (!(ACCEL->status & DONE)) {}
```

The repo ships divergence (`kernels/divergence/`) and matmul (`kernels/matmul/`,
naïve vs. scratchpad-staged) kernels used by the regression.

---

## Build & test

Everything runs under [Verilator](https://www.veripool.org/verilator/) (5.030) —
the exact flow CI uses, so a green badge means the regression passed. No vendor
license required.

```bash
make lint     # strict lint of the accelerator + SoC + reference cores (6 targets)
make test     # build & run the self-checking SystemVerilog regression (5 testbenches)
```

The regression covers the single-thread reference lane, the single-warp reference,
the full multi-warp pool (coalescing, divergence, scratchpad, the energy study),
the accelerator with its MMIO handshake, and the complete SoC where the **host CPU
launches a kernel over MMIO** end to end. Kernel machine code is embedded in the
testbenches, so CI needs no RISC-V toolchain.

**FPGA PPA (optional, needs Vivado):**

```bash
cd fpga
vivado -mode batch -source synth_ooc.tcl   # OOC synth of simt_accel on xczu7ev
# -> fpga/reports/post_synth_{util,timing,power}.rpt
```

---

## Results

### 1. Functional verification (Verilator regression — all green)

| Testbench | What it proves | Result |
|---|---|---|
| `tb_lane` | single-thread RV32I core (M1 reference) | ✅ PASS |
| `tb_warp` | 8-lane lockstep warp + banked VRF (M2 reference) | ✅ PASS |
| `tb_warp_pool` | multi-warp scheduler, coalescing, divergence, scratchpad, energy study | ✅ PASS |
| `tb_simt_accel` | accelerator + MMIO launch handshake; vadd `C[tid]=A+B` correct | ✅ PASS |
| `tb_soc_top` | **host CPU launches the accelerator over MMIO**, end to end | ✅ PASS |

Key measured behaviours (from `tb_warp_pool`):

- **Coalescing:** a contiguous warp access costs **3** line transactions vs **24**
  for a fully scattered one — **8× fewer**.
- **Latency hiding:** 4 warps finish in **49** cycles vs **60** if serialized
  (4 × 15) — **~81%** of the serial memory cost hidden behind other warps' compute.
- **Divergence:** a single-sided `if(tid&1)` kernel records exactly **2** divergent
  events (one per warp) and every lane's result is correct after reconvergence.
- **Scratchpad:** staging a reused matrix row on-chip cuts global line transactions
  from **17 → 11**.

### 2. Energy study — divergence-aware lane clock-gating (M7a)

The SIMT active mask is *also* the natural per-lane clock-enable: lanes masked off
by divergence do no useful work, so a real chip would clock-gate them. The engine
counts committed lane-instructions vs. active lanes and reports the dynamic energy a
gated design would save. Across kernels of rising divergence intensity:

| Kernel | Divergence | Lane utilisation | **Lane-datapath energy saved** |
|---|---|---:|---:|
| convergent (vadd) | none | 100.0% | **0.0%** |
| light (`if(tid&1)`) | mild | 95.8% | **4.2%** |
| heavy (3× nested `if`) | strong | 77.5% | **22.5%** |

The monotonic relationship is asserted in CI. Details:
[docs/m7_energy.md](docs/m7_energy.md).

### 3. FPGA PPA — ZCU104 (xczu7ev-ffvc1156-2-e), Vivado 2025.1

Out-of-context synthesis of `simt_accel`, evolved over three builds. M7b used a
flip-flop register file and showed it dominating area and timing; M8 banked the VRF
into distributed RAM; M9 did the same for the shared scratchpad and — the netlist
now being small enough — re-enabled **timing-driven** optimization:

| Metric | M7b (FF VRF) | M8 (LUTRAM VRF) | **M9 (+ LUTRAM scratch)** |
|---|---:|---:|---:|
| Synthesis flow | `-no_timing_driven` | `-no_timing_driven` | **timing-driven** |
| Target clock | 5.0 ns / 200 MHz | 10.0 ns / 100 MHz | 10.0 ns / 100 MHz |
| CLB LUTs | 170,868 (74.2%) | 77,025 (33.4%) | **30,088 (13.1%)** |
| &nbsp;&nbsp;└ as distributed RAM | 20 | 1,300 | **1,428** (VRF + scratch) |
| CLB registers (FF) | 44,112 (9.6%) | 13,322 (2.9%) | **4,590 (1.0%)** |
| DSP48E2 | 24 | 24 | 24 |
| Block RAM / URAM | 0 / 0 | 0 / 0 | 0 / 0 |
| Setup WNS | −3.213 (**violated**) | +2.719 (MET) | **+2.254 (MET)** |
| Critical-path delay | 8.213 ns | 7.281 ns | 7.746 ns |
| Max Fmax | 121.8 MHz | 137.3 MHz | **129.1 MHz** |
| On-chip power (vectorless) | 1.673 W @200 MHz | 0.841 W @100 MHz | **0.811 W @100 MHz** |

The M9 design **meets timing at 100 MHz with +2.25 ns slack** and the WNS-vs-period
sweep shows it also closes at **125 MHz**; the path is an irreducible single-cycle
LUTRAM-read → 32-bit ALU (incl. a DSP multiply) → writeback. Read the M8→M9 table
honestly: the **flip-flop drop (13.3k → 4.6k) is the scratchpad** (8.2k FFs removed),
while the **LUT drop (77k → 30k) is mostly the timing-driven optimization phase**
finally fitting in the host's RAM once both big banks are LUTRAM. (Power is a
vectorless estimate; dynamic power scales with frequency, so cross-clock figures are
not directly comparable.) Full analysis: [docs/m8_lutram.md](docs/m8_lutram.md),
[docs/m9_scratchpad.md](docs/m9_scratchpad.md).

> **Host note.** These runs were done on an 8 GB laptop. The flow is tuned for that
> (`-flatten_hierarchy none`, capped threads); M7b/M8 also needed `-no_timing_driven`
> to dodge a 4 GB RAM thrash, a workaround M9's smaller netlist no longer requires.
> The writeups document the RAM-pressure pitfalls and the working recipe.

---

## Engineering highlights

A few problems worth calling out, because solving them is most of the work:

- **Latched memory-replay context.** The shared decode always tracks the
  *currently-issued* warp, but the background engine is replaying a *different*
  warp's access — so the access context (per-lane address, store data, `funct3`,
  `rd`, mask) is latched at issue. Missing this is a subtle multi-warp bug.
- **The reconvergence-stack convention.** Forward branches (`if`) and backward
  branches (loops) push frames with different join-PC and mask choices so a single
  mechanism handles both, with the base frame guarding the bottom of the stack.
- **Making the register file inferable as RAM.** A 2-D `vrf[lane][addr]` written in
  a `for` loop is misread by Vivado as a "3-D RAM" and dissolves to flip-flops;
  splitting it into one **1-D array per lane in a `generate` block** with
  `ram_style="distributed"` is what actually maps to LUTRAM. The one-cycle spawn
  clear and the dual-writer both had to be redesigned (valid bits; arbitrated write
  port with idempotent re-issue) to keep a single write port — *without changing a
  single test result*.
- **CI stays toolchain-free.** Kernels are assembled offline with `riscv32` GCC and
  their hex is embedded in the testbenches, so GitHub Actions only needs Verilator.

---

## Repository layout

```
rtl/accel/          SIMT accelerator RTL (the project)
  simtix_pkg.sv       parameters, MMIO map, ISA/ALU constants
  mmio_regs.sv        host command/status registers
  warp_pool.sv        the SIMT engine: scheduler, lanes, VRF (LUTRAM), divergence
                      stack, coalescing memory engine, scratchpad
  simt_accel.sv       accelerator top: MMIO + dispatcher FSM + warp_pool
  lane.sv             M1 single-thread reference core (kept, still linted/tested)
  warp.sv             M2 single-warp reference (kept, still linted/tested)
rtl/cpu/            reused 5-stage pipelined RISC-V host core (Verilog)
rtl/soc/            soc_top.sv — CPU + accelerator + data RAM + MMIO decode
sim/                Verilator build/lint Makefile (delegated to from the root)
tests/              self-checking SystemVerilog testbenches
kernels/            data-parallel kernels (divergence, matmul naïve vs. scratchpad)
fpga/               OOC synthesis: synth_ooc.tcl, constraints, PPA reports
docs/               architecture, ISA, roadmap, energy study, LUTRAM writeup
```

---

## Roadmap / milestones

Each milestone is a self-contained, demoable, green-in-CI step.

| # | Milestone | Proves | Status |
|---|---|---|---|
| M0 | Scaffold + CI + host builds in Verilator | tooling works end to end | ✅ |
| M1 | MMIO launch handshake + single-lane kernel execution | offload + one thread runs a real kernel | ✅ |
| M2 | 8 SIMT lanes + banked vector register file | lockstep data-parallel execution | ✅ |
| M3 | Multiple warps + round-robin scheduler | latency hiding by warp switching | ✅ |
| M4 | LSU + loads/stores + address coalescing | realistic memory behaviour | ✅ |
| M5 | Control divergence: active mask + reconvergence stack | **true SIMT** | ✅ |
| M6 | Shared-memory scratchpad + matmul reuse benchmark | on-chip reuse story | ✅ |
| M7a | Divergence-aware lane clock-gating **energy study** | the research contribution (0→22.5%) | ✅ |
| M7b | FPGA / PPA: OOC synth on ZCU104 | real silicon-cost numbers | ✅ |
| M8 | Register file in distributed RAM + timing closure | LUTs −55%, FFs −70%, timing met | ✅ |
| M9 | Scratchpad in distributed RAM + timing-driven synth | 30.1k LUT / 4.6k FF, timing met (meets 125 MHz) | ✅ |

Full detail in [docs/roadmap.md](docs/roadmap.md).

---

## Limitations & future work

- **Scope of divergence.** General two-sided `if/else` where both arms are non-empty
  before the join is out of scope; write it as two single-sided `if`s. The
  convention is compiler-free by design.
- **One memory access in flight.** A single data port serves the whole engine; a
  warp wanting memory while the port is busy waits its turn (no starvation — the
  scheduler keeps advancing).
- **Small, fixed grid geometry.** `WARP_SIZE == NUM_LANES == 8`, `NUM_WARPS == 4` by
  default; all are parameters.
- **Next optimizations.** The big register banks (VRF M8, scratchpad M9) are now in
  LUTRAM; remaining ideas: move the SIMT reconvergence stacks (now the dominant FF
  user) into RAM, tighten the FPGA clock to the 125 MHz the design already meets, and
  cross-check the modelled clock-gating energy against a switching-activity power run.

---

## Prior art

SIMTiX is a compact, legible take on ideas explored by larger open projects, useful
to position against: **Vortex** (Georgia Tech full RISC-V GPGPU), **Ventus**
(RVV-based GPGPU), **Nyuzi / Cyclone** (open SIMT GPGPU with an excellent divergence
writeup), **Simty** (minimal SIMT RISC-V, closest in spirit), and the **GPGPU-Sim**
/ **MIAOW** ecosystem. SIMTiX's niche is being small enough to read end to end while
still implementing real divergence, coalescing, shared memory, and a measured FPGA
PPA + energy result.

---

## License

Apache-2.0 — see [LICENSE](LICENSE).
