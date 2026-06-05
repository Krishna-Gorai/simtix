# M9 — Scratchpad in distributed RAM (LUTRAM) + timing-driven synthesis

After M8 moved the vector register file into LUTRAM, the per-warp **scratchpad**
was the single largest remaining bank of flip-flops: `NUM_WARPS × SCRATCH_WORDS ×
32 = 4 × 64 × 32 = 8,192 FFs`, about **62 %** of the design's registers. M9 moves
it into **distributed RAM** as well, and — because the netlist is now small enough
— turns Vivado's **timing-driven optimization** back on (M7b/M8 had used
`-no_timing_driven` as a workaround for a 4-hour, 4.25 GB RAM thrash on this 8 GB
host).

## The problem: a shared scratchpad is multi-ported

Unlike the VRF (which M8 split into per-lane banks, one bank per lane), the
scratchpad is **shared across a warp's lanes** — lane 0's store must be visible to
lane 3's load (that is the whole point of on-chip shared memory; the matmul
regression stages a reused `A` row in it). The old design served *every* pending
lane in a single cycle, so it was an **8-read / 8-write** structure — which is
exactly why it had to be flip-flops. No LUTRAM or BRAM primitive offers 8
independent write ports to one coherent memory.

## What changed (`rtl/accel/warp_pool.sv`)

1. **One flat single-port RAM.** The array became a single
   `(* ram_style = "distributed" *) logic [31:0] scratch [0:NW*SCRATCH_WORDS-1]`
   addressed by `{warp, sidx}` (8-bit address, 256 words). One synchronous write
   port, one asynchronous read port — the canonical LUTRAM pattern.

2. **The memory engine serializes one lane per cycle.** A scratch op now drains
   like the global coalescing engine already did: each cycle it picks `lead`, the
   lowest still-pending lane, reads (load) or writes (store) *that* lane's word,
   and clears it from `mem_pending`; when the last lane drains, the warp resumes.
   This is the only behavioural change — a scratch instruction that touches *k*
   active lanes now takes *k* cycles instead of 1.

3. **Single-lane writeback.** A scratch load drives the VRF write arbiter for the
   `lead` lane only (sourced from the one RAM read port `sc_rd`), instead of all
   lanes at once.

Semantics are preserved **exactly**: within one SIMT memory instruction every lane
does the same op (all-load or all-store), so there is no intra-instruction
lane-to-lane forwarding to lose by serializing. Store/store address collisions
still resolve last-writer-wins (highest lane index), identical to the old
non-blocking for-loop. The functional regression is bit-for-bit unchanged — the
matmul results match, the scratchpad is still used, and it still cuts global line
traffic 17 → 11. (The scratch-transaction *counter* now ticks once per lane, e.g.
the staged matmul reads 72 = 9 ops × 8 lanes; the regression only checks it is
non-zero.)

## Result — OOC synthesis on xczu7ev (ZCU104), Vivado 2025.1

| Metric | M7b (FF VRF) | M8 (LUTRAM VRF) | **M9 (LUTRAM VRF + scratch)** |
|---|---:|---:|---:|
| Synthesis flow | `-no_timing_driven` | `-no_timing_driven` | **timing-driven** |
| Target clock | 5.0 ns / 200 MHz | 10.0 ns / 100 MHz | 10.0 ns / 100 MHz |
| CLB LUTs | 170,868 (74.16%) | 77,025 (33.43%) | **30,088 (13.06%)** |
| &nbsp;&nbsp;└ LUT as distributed RAM | 20 | 1,300 | **1,428** (VRF + scratch) |
| CLB registers (FF) | 44,112 (9.57%) | 13,322 (2.89%) | **4,590 (1.00%)** |
| DSP48E2 | 24 | 24 | 24 |
| Block RAM / URAM | 0 / 0 | 0 / 0 | 0 / 0 |
| Setup WNS | −3.213 (violated) | +2.719 (MET) | **+2.254 (MET)** |
| Critical-path delay | 8.213 ns | 7.281 ns | 7.746 ns |
| Max Fmax | 121.8 MHz | 137.3 MHz | **129.1 MHz** |
| Total on-chip power | 1.673 W @200 MHz | 0.841 W @100 MHz | **0.811 W @100 MHz** |

Per-hierarchy (M9): `u_pool` (warp_pool) 29,948 LUT / 4,363 FF / 1,428 LUTRAM /
24 DSP; `u_regs` (mmio_regs) 109 LUT / 161 FF; top-level glue 31 LUT / 66 FF.

### Reading the table honestly

M9 bundles two changes, so the deltas split cleanly by resource:

- **Flip-flops (13,322 → 4,590, −8.7 k): the scratchpad.** Removing the 8,192
  scratch FFs is the dominant term; the rest is optimization trimming. This is the
  milestone's real contribution.
- **LUTs (77,025 → 30,088): mostly the timing-driven optimization phase.** M8's
  77 k was a `-no_timing_driven` figure carrying Vivado's *"final LUT count after
  physical optimization is typically lower"* warning. With the VRF and scratchpad
  both in LUTRAM the netlist is finally small enough that the timing-optimization
  phase fits the host's RAM (peak ~2.95 GB vs the old 4.25 GB), so it runs and
  collapses the redundant logic. The scratchpad move enables this; it does not by
  itself account for the full LUT drop.

### Timing

The design **meets at 100 MHz with +2.254 ns** and the printed WNS-vs-period sweep
shows it also meets at **8 ns / 125 MHz** (+0.254 ns); the 7.746 ns critical path
puts the ceiling near 129 MHz. The path remains the irreducible single-cycle
LUTRAM-read → 32-bit ALU (DSP multiply) → writeback. Power is a vectorless estimate
(0.218 W dynamic + 0.593 W static); dynamic power scales with clock, so cross-clock
comparisons are not exact.

## What's left in flip-flops

The dominant FF user is now the **SIMT reconvergence stacks**
(`stk_npc/stk_rpc/stk_mask`, NW × SDEPTH frames) together with the `reg_written`
valid bits (1,024) and the memory-engine latches. These are small and
not on the critical path; the big-bank LUTRAM conversions (VRF, scratchpad) are
done.

## Reproduce

```
make -C sim test                                      # functional suite (green, behaviour identical)
cd fpga && vivado -mode batch -source synth_ooc.tcl   # timing-driven OOC PPA on xczu7ev
```
