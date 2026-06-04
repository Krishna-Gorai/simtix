# SIMTiX architecture

This is the implementation deep-dive. It describes the RTL as it actually exists
(milestones M0–M8), down to signal names, so it can be read alongside the source.
For the high-level tour see the [README](../README.md); for the two focused studies
see [docs/m7_energy.md](m7_energy.md) (lane clock-gating) and
[docs/m8_lutram.md](m8_lutram.md) (register file in distributed RAM).

The whole SIMT engine lives in **one module, `rtl/accel/warp_pool.sv`** — the
scheduler, lanes, register file, reconvergence stack, memory engine and scratchpad
are tightly co-designed and share a single decode datapath and a single data port,
so they are implemented together rather than as separate blocks.

---

## 1. System view

The host is the reused 5-stage RISC-V core (`rtl/cpu/`), unmodified. Its
data-memory interface is the only attach point the accelerator needs:

```
cpu.MemWriteM  cpu.Funct3M  cpu.ALUResultM(addr)  cpu.WriteDataM   ->  bus
cpu.ReadDataM  <-  bus
```

`rtl/soc/soc_top.sv` performs a one-line **address decode** on `ALUResultM`:

- `addr <  MMIO_BASE` → the CPU's local data SRAM (`rtl/cpu/data_mem.v`)
- `addr >= MMIO_BASE` → the SIMTiX accelerator (`is_mmio = (ALUResultM >= MMIO_BASE)`)

The read-data return is muxed back the same way
(`ReadDataM = is_mmio ? accel_rdata : dram_rd`). This is exactly how a discrete GPU
is mapped into a host's physical address space, and it means a stock RISC-V program
drives the accelerator with ordinary `sw`/`lw` — no custom instructions.

The SoC boundary also exposes the host instruction-fetch port and the accelerator's
**shared-memory master ports** (kernel code via `imem`, data arrays via the
line-wide `dmem`), so the testbench (and, later, a real loader) own the memory
images.

---

## 2. MMIO register map

Base `MMIO_BASE = 0x8000_0000` (one 4 KB page). Word offsets:

| Offset | Name | R/W | Description |
|---|---|---|---|
| `0x00` | `KERNEL_PC` | W | byte address of the kernel's first instruction |
| `0x04` | `BASE_A` | W | base pointer, argument 0 |
| `0x08` | `BASE_B` | W | base pointer, argument 1 |
| `0x0C` | `BASE_C` | W | base pointer, argument 2 |
| `0x10` | `N` | W | total thread count (grid size) to launch |
| `0x14` | `CTRL` | W | bit0 = `GO` (write 1 to launch) |
| `0x18` | `STATUS` | R | bit0 = `DONE`, bit1 = `BUSY` |
| `0x1C` | `CYCLES` | R | cycle count of the last kernel (performance) |

`mmio_regs.sv` holds these; the `GO` write produces a one-cycle `go_pulse`.

---

## 3. Accelerator top (`simt_accel.sv`)

`simt_accel` is thin: it instantiates the registers and the engine and sequences
them with a small dispatcher FSM.

```
simt_accel
├── mmio_regs   u_regs    command/status registers
├── warp_pool   u_pool    the entire SIMT engine (§4)
└── dispatcher FSM         D_IDLE → D_LAUNCH → D_RUN → D_DONE
```

On `go_pulse` the FSM moves to `D_LAUNCH` (or straight to `D_DONE` for an empty
grid, `n_threads == 0`). `D_LAUNCH` asserts `pool_start` for one cycle — the pool is
idle and latches the whole grid. `D_RUN` counts cycles until `pool_done`, then
latches the runtime into the `CYCLES` register. `busy`/`done` drive `STATUS`.

The pool spawns and recycles *every* warp of the grid internally, so the dispatcher
never deals with individual warps — it launches once and waits. The memory-master
interface (`imem_*`, line-wide `dmem_*`) and the MMIO contract are fixed; they did
not change as the engine grew from M1 to M8.

---

## 4. The SIMT engine (`warp_pool.sv`)

`NUM_WARPS` (4) warp slots are resident at once. Each owns private architectural
state; all slots share one fetch/decode/ALU datapath and one data port. A
round-robin scheduler issues one warp per cycle while a background memory engine
advances one coalesced transaction per cycle — so one warp's memory latency is
overlapped with other warps' compute.

### 4.1 Per-slot state

| State | Signal | Notes |
|---|---|---|
| lifecycle | `wstate[w]` | `W_EMPTY → W_RUN ⇄ W_MEM → W_DONE` |
| reconvergence stack | `stk_npc[w][d]`, `stk_rpc[w][d]`, `stk_mask[w][d]`, `sp[w]` | depth `SDEPTH` (8) |
| vector register file | per-lane LUTRAM banks (§4.6) | 32 RV32 regs × 8 lanes × 4 warps |
| valid bits | `reg_written[w][lane][reg]` | "written this grid?" (§4.6) |
| base thread id | `warp_base[w]` | seeds `tid` / `a0` |

### 4.2 Scheduling & spawning (combinational selection)

- **Issue select:** scan from `rr_ptr` for the first `W_RUN` slot → `issue_valid`,
  `issue_w`. After an issue, `rr_ptr <= issue_w + 1` (round-robin; `NUM_WARPS` is a
  power of two so the pointer wraps in its width).
- **Fill select:** scan for the first `W_EMPTY`/`W_DONE` slot → `fill_valid`,
  `fill_w`. Each cycle, if grid warps remain, one is dropped into that slot:
  `warp_base`, the base stack frame (`sp=0`, `npc=kernel_pc`, `mask=`tail mask,
  `rpc=RPC_BOTTOM`), and `wstate <= W_RUN`. Tail mask handles a partial final warp
  (`tid >= n_threads`). Slots are recycled the moment a warp retires, so grids with
  more warps than slots run fine.

The "anything still running?" condition (`any_busy`) is warps left to spawn OR any
slot in `W_RUN`/`W_MEM`; when it clears, the pool pulses `done`.

### 4.3 Live TOS view & fetch/decode

The top-of-stack frame of the issuing warp gives the cycle's live view:
`cur_sp = sp[issue_w]`, `cur_pc = stk_npc[issue_w][cur_sp]`,
`cur_mask = stk_mask[issue_w][cur_sp]`. The shared fetch follows it
(`imem_addr = cur_pc`). Decode is plain combinational RV32I: `opcode`, `rd`, `rs1`,
`rs2`, `funct3`, the immediate forms, and `is_load/is_store/is_mem/is_ecall/is_csr`.
`alu_ctrl` reuses the 4-bit encoding from the host core's `alu.v`, extended with
`ALU_MUL` (RV32M `mul`, decoded via `funct7b0`).

A pushed stack frame is "spent" when its PC reaches its reconvergence PC:
`do_pop = issue_valid && (cur_sp != 0) && (cur_pc == stk_rpc[issue_w][cur_sp])` —
that issue slot pops (`sp <= cur_sp - 1`) instead of executing.

### 4.4 Per-lane datapath

For the issuing warp, all 8 lanes evaluate in parallel each cycle. Per lane `l`:

1. read operands `rv1[l]`, `rv2[l]` (from the VRF, §4.6);
2. select ALU inputs by opcode (reg/imm/PC/upper-imm);
3. compute the ALU result `addr[l]` (used as both ALU result and effective address);
4. form `wb_val[l]` / `wb_en[l]`. Writeback is gated off for `rd == x0` **and** for
   lanes not in `cur_mask` — masked-off lanes do nothing.

Branch decision is per lane (`btaken[l]`), giving `taken_mask` and `ntaken_mask`.
Uniform decisions (decode-shared) like the `jalr` target and the scratch-vs-global
classification use the **lowest active lane** `first_l` as the leader.

### 4.5 Control divergence — the reconvergence stack (M5)

A `BRANCH` is resolved against the active mask:

- `taken_mask == cur_mask` → uniform taken: retarget `stk_npc[cur_sp]` to `br_target`.
- `taken_mask == 0` → uniform not-taken: retarget to `fallthru`.
- otherwise → **divergent** (`dbg_divergences++`): record the union mask at the join
  and push a "continue" frame so the two lane groups run in turn:
  - **forward branch** (`br_target > cur_pc`, a single-sided `if`): join `RPC =
    br_target`; the pushed frame runs the fall-through (not-taken) lanes first.
  - **backward branch** (a loop): join `RPC = fallthru` (loop exit); the pushed frame
    runs the taken (still-looping) lanes.

The pushed frame pops at `do_pop` (§4.3) and the warp reconverges into the frame
below, which already holds the union mask at `RPC`. The base frame's
`rpc = RPC_BOTTOM (0xFFFF_FFFF)` so it never pops. Nesting works to `SDEPTH`.
`JAL`/`JALR` retarget the TOS PC; non-control instructions fall through to `pc+4`.

> **Out of scope (by design):** general two-sided `if/else` where both arms are
> non-empty before the join — write it as two single-sided `if`s. The convention is
> compiler-free.

### 4.6 Vector register file — distributed RAM (M2 banking → M8 LUTRAM)

The VRF is `NUM_WARPS × NUM_LANES × 32` 32-bit words, addressed by
`{warp, reg}` (`VAW = WIDXW + 5` bits, `VDEPTH = 1<<VAW`). It is built as **8
independent per-lane banks** in a `generate` block, each:

```systemverilog
(* ram_style = "distributed" *) logic [31:0] bank [0:VDEPTH-1];
always_ff @(posedge clk) if (v_we[gl]) bank[v_wa[gl]] <= v_wd[gl];  // 1 sync write
assign vrf_rd1[gl] = bank[vaddr(issue_w, rs1)];                     // 2 async reads
assign vrf_rd2[gl] = bank[vaddr(issue_w, rs2)];
```

This is the pattern Vivado maps to LUTRAM (`RAM64M8`). Two mechanisms preserve the
old flip-flop behaviour exactly while keeping a single write port:

- **Seed-on-read instead of spawn-clear.** A per-`(warp,lane,reg)` `reg_written`
  bit tracks whether a register has been written this grid. An unwritten register
  reads its **spawn seed** via `seed_val` (`a0 = warp_base+lane = tid`,
  `a1..a4 = arg_a..arg_n`, else 0). This reproduces the old "zero the file on spawn,
  then seed `a0..a4`" semantics with no 32-write clear cycle. (`x0` reads 0 as a
  special case, independent of the RAM.)
- **Arbitrated single write port** (§4.8).

See [docs/m8_lutram.md](m8_lutram.md) for the before/after and the "3-D RAM"
inference pitfall this avoids.

### 4.7 Background memory engine + coalescing (M4)

At most one memory instruction is in flight (single data port). When an issuing
warp executes a `lw`/`sw` and the engine is free, the access **context is latched**
— per-lane effective address (`mem_addr_lane`), store data (`mem_sdata_lane`),
`mem_funct3`, `mem_rd`, the active mask (`mem_pending <= cur_mask`), and the resume
PC (`mem_next_pc`) — and the warp moves to `W_MEM`. Latching is essential: the live
decode keeps tracking the *currently-issued* warp, not the one being replayed.

The data port is a whole **256-bit line** (`LINE_WORDS = 8`, `LINE_OFF = 5`). Each
cycle the engine:

1. picks the line of the lowest still-pending lane (`lead`, `lead_tag`);
2. gathers **every** pending lane sharing that line into `grp` (one transaction);
3. for a load, extracts each lane's word/half/byte from the line read into
   `ld_data[l]`; for a store, merges each lane's bytes into `dmem_wdata`/`dmem_be`;
4. drains `mem_pending &= ~grp`; when empty, writes the resume PC back and returns
   the warp to `W_RUN`.

Cost = number of distinct lines touched: a contiguous warp access (`A[tid]`) → **1**
transaction; a fully scattered one → up to 8. `dbg_mem_txns` counts global line
transactions.

### 4.7.1 Shared-memory scratchpad (M6)

A memory op whose leader-lane address is in the `SCRATCH_BASE` aperture
(`addr[31:30] == 2'b01`) is flagged `mem_is_scratch` at issue. The engine then
serves the **whole warp from a per-warp on-chip SRAM (`scratch[w][...]`) in one
cycle**, bypassing the global port entirely (the `dmem` driver is gated by
`!mem_is_scratch`). Per-lane index `sidx = addr[SCRATCH_AW+1:2]`. `dbg_scratch_txns`
counts scratchpad transactions. Staging reused data here (e.g. a broadcast matrix
row) cuts global traffic.

### 4.8 The VRF write arbiter (M8)

Two producers can target the file in the same cycle: the issue stage's **compute
writeback** (warp `issue_w`) and the memory engine's **load writeback** (warp
`mem_w`). A LUTRAM bank has one write port, so per lane the engine computes a single
`{v_we, v_wa, v_wd}`:

- **memory writeback wins** (`mem_wb_lane[l]`): from a global load (`grp[l]`,
  data `ld_data[l]`) or a scratch load (`mem_pending[l]`, data `scratch[mem_w][sidx]`);
- else the **compute writeback** (`wb_en[l]`, data `wb_val[l]`), *unless* a memory
  write is happening this cycle (`mem_wb_act`).

When a memory write preempts a compute writeback, `squash_wb` defers the whole
compute commit — its PC does not advance, so the warp **re-issues next cycle**. This
is safe because a compute instruction is idempotent (same VRF in → same result out);
it costs at most one cycle per collision, and the energy counters only count an
instruction when it actually commits. Each committed write also sets the
`reg_written` valid bit.

### 4.9 Energy accounting — lane clock-gating model (M7a)

The TOS active mask *is* the natural per-lane clock-enable (`lane_ce = cur_mask`).
Two counters quantify the dynamic energy a gated design would save: per committed
datapath instruction, `dbg_issued_insns++` and `dbg_active_lanes +=
popcount(cur_mask)` (pops and port-stalled re-attempts excluded; squashed
writebacks not double-counted). Then `lane utilisation = active /
(NUM_LANES × issued)` and `energy saved = 1 − utilisation`. Full model and results:
[docs/m7_energy.md](m7_energy.md).

---

## 5. Execution timeline (why latency hiding works)

The issue engine and the memory engine advance in the **same cycle**:

```
cycle →     issue engine (1 warp / cyc)            memory engine (1 line / cyc)
  t0    warp A: lw  -> hand to mem, A→W_MEM         (idle)
  t1    warp B: add (compute)                       servicing A's line(s)…
  t2    warp C: add (compute)                       …A drains, A→W_RUN
  t3    warp A: add (resumes)                       (idle)
```

While warp A's load is serviced in the background, warps B and C keep the otherwise-
idle ALU datapath busy — the classic GPU trick. Measured in `tb_warp_pool`: 4 warps
finish in 49 cycles vs. 60 if serialized (~81% of the serial memory cost hidden).

---

## 6. Parameters (`simtix_pkg.sv`)

| Parameter | Default | Meaning |
|---|---|---|
| `XLEN` | 32 | data width (RV32) |
| `NUM_LANES` | 8 | physical SIMT lanes |
| `WARP_SIZE` | 8 | threads per warp |
| `NUM_WARPS` | 4 | resident warp slots (power of two) |
| `SDEPTH` | 8 | reconvergence-stack depth |
| `LINE_WORDS` | 8 | words per coalesced line (256-bit / 32-byte) |
| `SCRATCH_WORDS` | 64 | scratchpad words per warp |
| `MMIO_BASE` | `0x8000_0000` | command-register aperture |
| `SCRATCH_BASE` | `0x4000_0000` | scratchpad aperture |
| `CSR_TID` | `0xCC0` | read-only thread-id CSR |

Derived: `WIDXW = clog2(NUM_WARPS)`, `LIDXW = clog2(NUM_LANES)`,
`VAW = WIDXW + 5`, `VDEPTH = 1<<VAW`, `LINE_BITS = 256`, `LINE_OFF = 5`.

---

## 7. Observability (debug taps)

`warp_pool` exports counters that `simt_accel` ties off (observability only; the
testbenches read them):

| Signal | Meaning |
|---|---|
| `dbg_retire_a0` | last-retired warp's lane-0 `tid` |
| `dbg_mem_txns` | global line transactions since launch |
| `dbg_divergences` | divergent-branch events since launch |
| `dbg_scratch_txns` | scratchpad transactions since launch |
| `dbg_issued_insns` | committed datapath instructions (energy model) |
| `dbg_active_lanes` | Σ active lanes per committed instruction (energy model) |

---

## 8. Reference cores

Two earlier, standalone cores are kept in the tree (still linted and tested) as
readable references for how the engine grew:

- **`lane.sv`** (M1) — a single-thread RV32I execute core.
- **`warp.sv`** (M2) — one 8-lane lockstep warp over a banked VRF, with per-lane
  loads/stores serialized onto a single data port (pre-coalescing).

The production path is `lane`/`warp` → **`warp_pool`** (M3+), which is what
`simt_accel` instantiates.
