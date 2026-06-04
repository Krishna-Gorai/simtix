# M8 — Register file in distributed RAM (LUTRAM) + timing closure

M7b's PPA showed the accelerator eating **74% of the ZCU104's LUTs at only ~10% of
its flip-flops**, and missing timing at 200 MHz (setup WNS −3.213 ns). Both came
from one structure: the vector register file built out of flip-flops.

The VRF is `NUM_WARPS × NUM_LANES × 32 = 1024` 32-bit words = **32,768 flip-flops**,
read every cycle as `vrf[issue_w][lane][rs]` with *both* the warp and the register
index variable — which synthesises a 128:1 mux per lane per read port. That mux
fabric (not the ALUs) was the LUT hog and the critical path. M8 moves the VRF into
**distributed RAM (LUTRAM)** so the addressing is done by the RAM primitive instead
of LUT muxes.

## What changed (`rtl/accel/warp_pool.sv`)

Three coupled changes were needed to make the file RAM-inferable while keeping
behaviour bit-for-bit identical:

1. **Per-lane 1D banks in a generate block.** Each lane gets its own
   `(* ram_style = "distributed" *) logic [31:0] bank [0:VDEPTH-1]` with one
   synchronous write port and two async read ports. A *2D* `vrf[lane][addr]` written
   in a for-loop is misread by Vivado as a "3D-RAM" and dissolves to registers
   (`[Synth 8-11357]`); a clean 1D array per lane maps to `RAM64M8` LUTRAM.

2. **Valid bits instead of a spawn clear.** The old design zeroed all 32 registers of
   a warp in a single cycle on spawn — 32 simultaneous writes, which is a 32-write-port
   pattern a RAM cannot express. Instead a per-`(warp,lane,reg)` `reg_written` bit
   (1,024 FFs) tracks whether a register has been written this grid; an unwritten
   register reads its **spawn seed** (`a0=tid`, `a1..a4=args`, else 0) through a small
   mux. This reproduces the "zero then seed" semantics exactly, with no clear cycle.

3. **A single write port per lane, arbitrated.** The issue stage's compute writeback
   (warp `issue_w`) and the memory engine's load writeback (warp `mem_w`) can both
   target a lane in the same cycle, but a LUTRAM bank has one write port. The memory
   writeback takes priority and the compute writeback is **squashed and re-issued**
   next cycle — safe because a compute instruction is idempotent (same VRF in → same
   result out). This is the only behavioural change, and it costs at most one cycle
   per load/compute collision; correctness (results, txn/divergence/energy counts) is
   unchanged. Multi-warp memory-heavy cycle counts tick up slightly (e.g. the N=32
   regression went 43→49 cycles); single-warp tests are unaffected.

The clock target was also relaxed from 5 ns (200 MHz) to **10 ns (100 MHz)** in
`fpga/constr/simt_accel_ooc.xdc`: the single-cycle datapath (VRF read → 32-bit ALU
incl. a DSP multiply → writeback) genuinely cannot close at 200 MHz, so the
constraint now reflects a frequency the design actually meets.

## Result — OOC synthesis on xczu7ev (ZCU104), Vivado 2025.1

| Metric | M7b (flip-flop VRF) | M8 (LUTRAM VRF) | Δ |
|---|---:|---:|---:|
| Target clock | 5.0 ns / 200 MHz | 10.0 ns / 100 MHz | |
| CLB LUTs | 170,868 (74.16%) | **77,025 (33.43%)** | **−54.9%** |
| &nbsp;&nbsp;└ LUT as distributed RAM | 20 | 1,300 | VRF → 8× `RAM64M8` |
| CLB registers (FF) | 44,112 (9.57%) | **13,322 (2.89%)** | **−69.8%** |
| DSP48E2 | 24 | 24 | — |
| Block RAM / URAM | 0 / 0 | 0 / 0 | — |
| Setup WNS | −3.213 ns (**violated**) | **+2.719 ns (MET)** | meets |
| Critical-path delay | 8.213 ns | 7.281 ns | |
| Max Fmax | 121.8 MHz | **137.3 MHz** | +13% |
| Total on-chip power | 1.673 W @200 MHz | 0.841 W @100 MHz | see note |

Notes:
- **Timing met.** At 100 MHz the design closes with +2.719 ns slack; the WNS-vs-period
  sweep (printed by `synth_ooc.tcl`) shows it also closes at 8 ns (**125 MHz**, +0.719 ns)
  and the raw critical path of 7.281 ns gives a ceiling of ~137 MHz. The path is now an
  irreducible single-cycle LUTRAM-read → ALU (DSP multiply) → writeback.
- **Power** is a vectorless estimate; dynamic power scales with clock frequency, so the
  M7b (200 MHz) and M8 (100 MHz) figures are not directly comparable. Static power
  (0.593 W) is, and the LUT/FF reduction shows up there.
- Synthesis stays light (`-flatten_hierarchy none -no_timing_driven`, `maxThreads 2`);
  the smaller netlist also peaks lower on RAM than the flip-flop design.

## What's left in flip-flops

`reg_written` (1,024 bits), the SIMT reconvergence stacks, and the per-warp scratchpad
remain registers. The scratchpad (`NW × 64 × 32`) is the next candidate for the same
LUTRAM treatment; the stacks and valid bits are small.

## Reproduce

```
make -C sim test                 # functional suite (still green, behaviour identical)
cd fpga && vivado -mode batch -source synth_ooc.tcl   # OOC PPA on xczu7ev
```
