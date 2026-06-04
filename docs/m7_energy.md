# M7 — Divergence-aware lane clock-gating: an energy study

This is SIMTiX's micro-architectural research contribution. It does **not** add a
new warp scheduler (that design space is over-studied); instead it fuses the M5
SIMT divergence machinery with a measurable energy result.

## The idea

In a SIMT warp, a divergent branch masks off some lanes: their results are
discarded (`wb_en` is gated). But in the baseline RTL the masked lanes' datapath
registers still toggle every cycle, burning dynamic power for nothing. A real
chip would **clock-gate** the inactive lanes — drive an integrated clock-gate
(ICG) on each lane's pipeline registers from the lane's active bit, so only the
lanes doing useful work are clocked.

The active mask the warp already carries (`cur_mask`, the top-of-stack frame of
the reconvergence stack) *is* the per-lane clock-enable. In `warp_pool.sv`:

```systemverilog
logic [NL-1:0] lane_ce;
assign lane_ce = cur_mask;        // one ICG enable per lane (synthesis maps to ICGs)
```

So gating costs essentially no new control logic — it reuses the divergence
mask that already exists.

## What we measure

For every committed datapath instruction the engine counts:

| counter | meaning |
|---|---|
| `dbg_issued_insns` | datapath instructions that committed (pops/port-stalls excluded) |
| `dbg_active_lanes` | Σ over those instructions of `popcount(cur_mask)` |

An **ungated** design clocks all `NUM_LANES` lanes for every instruction, so it
spends `NUM_LANES * issued_insns` lane-cycles. A **gated** design clocks only the
active lanes, i.e. `active_lanes`. Hence:

```
lane utilisation        = active_lanes / (NUM_LANES * issued_insns)
lane-datapath energy saved = 1 - lane utilisation
```

This is a dynamic-energy model at lane-instruction granularity. It assumes equal
energy per lane-instruction and ignores the (small, fixed) ICG insertion cost and
leakage; it also does not count whole-warp idle/memory-stall cycles, which are an
orthogonal, coarser gating opportunity.

## Results (`tb_warp_pool` phase 8, one full warp, NUM_LANES=8)

Three kernels of increasing divergence intensity:

| kernel | divergence | insns | active | lane util | **energy saved** |
|---|---|---:|---:|---:|---:|
| convergent (vadd) | none | 9 | 72 | 100.0% | **0.0%** |
| light (`if(tid&1)`, 1-instr body) | mild | 12 | 92 | 95.8% | **4.2%** |
| heavy (3× `if`, 3-instr bodies) | strong | 20 | 124 | 77.5% | **22.5%** |

The convergent kernel clocks every lane (nothing to gate). As divergence
intensity rises, lane utilisation falls monotonically and the energy a gated
design saves rises — up to **22.5%** of the lane-datapath dynamic energy on the
heavily-divergent kernel. The test asserts this monotonic relationship, so the
result is regression-checked in CI.

The lane datapath is only part of the accelerator (fetch/decode/scheduler and the
memory engine are shared and unaffected), so the accelerator-level saving is this
figure scaled by the lane datapath's share `α` of total dynamic power. With the
8-lane ALU array dominating the datapath, `α` is large, but the headline,
defensible number is the lane-datapath saving reported above.

## Reproduce

```
make -C sim test-pool      # phase 8 prints the table and asserts monotonicity
```

The kernels live in `kernels/divergence/` (assembled with rv32i GCC; the hex is
embedded in the testbench so CI stays toolchain-free).

## M7b — FPGA / PPA (silicon-cost numbers)

Out-of-context synthesis of `simt_accel` on the ZCU104's Zynq UltraScale+
**xczu7ev-ffvc1156-2-e** (Vivado 2025.1, 200 MHz / 5.0 ns target clock). The flow
and constraints live in `fpga/` (`synth_ooc.tcl`, `constr/simt_accel_ooc.xdc`);
the raw reports are `fpga/reports/post_synth_{util,timing,power}.rpt`.

| Metric | Value | Device share |
|---|---:|---:|
| CLB LUTs            | 170,868 (170,848 logic + 20 LUTRAM) | 74.16% of 230,400 |
| CLB registers (FF)  | 44,112                              |  9.57% of 460,800 |
| DSP48E2             | 24                                  |  1.39% of 1,728   |
| Block RAM / URAM    | 0 / 0                               | —                 |
| CARRY8 / F7 / F8    | 288 / 4,034 / 939                   | —                 |
| Setup WNS @ 5.0 ns  | −3.213 ns                           | → **Fmax ≈ 122 MHz** |
| Total on-chip power | 1.673 W (1.076 dyn + 0.597 static)  | Tj 26.6 °C, vectorless (Medium conf.) |

Almost the entire footprint is `u_pool` (the `warp_pool`): **170,728 LUTs /
43,885 FFs / 24 DSPs**. The lesson is the headline of the PPA story — the
per-lane vector register file is `NUM_WARPS × NUM_LANES × 32 = 1024` 32-bit words
= **32,768 flip-flops**, and because a kernel reads it as `vrf[issue_w][l][rs]`
(both warp and register index variable) it synthesises a 128:1 mux per lane per
read port. That mux fabric — not the ALUs — is why the design eats ~74% of the
device LUTs at only ~10% of its FFs, and why it tops out near 122 MHz (the
single-cycle path is *VRF-read mux → ALU → writeback*). DSP usage is just the
eight per-lane RV32M multipliers (3 DSP48E2 each). **Architectural takeaway:**
banking the VRF into distributed/block RAM instead of flip-flops is the obvious
next optimisation — it would collapse the mux trees, the LUT count, and the
critical path together. (Synthesis-only estimate; `opt_design`/place would lower
the final LUT count further, per Vivado's own note in the utilization report.)

### A note on the run itself

The xczu7ev part database + timing engine alone push synthesis to a ~4.25 GB peak,
which does not fit alongside the OS on this 8 GB host. A first timing-driven
attempt thrashed for 4 h in "Timing Optimization" and produced nothing. The
working recipe (in `synth_ooc.tcl`) is `-flatten_hierarchy none -no_timing_driven`
with `maxThreads 2`: it optimises module-by-module and skips the timing-opt phase
(the memory hog), completing in ~27 min. Because this design's critical path is an
irreducible single-cycle mux→ALU→writeback, the non-timing-driven WNS is a
realistic Fmax estimate rather than a pessimistic floor.

## Prior art

Lane/thread clock-gating under divergence is known in GPU micro-architecture;
this study reproduces the effect in a compact open SIMT core and quantifies it on
RISC-V kernels. Position against Vortex, Ventus, Nyuzi/Cyclone, and Simty.
