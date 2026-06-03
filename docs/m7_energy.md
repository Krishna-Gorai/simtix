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

## Next: M7b — FPGA / PPA

Out of scope for this pass (deferred): an out-of-context Vivado synthesis of
`simt_accel` for real area (LUT/FF), Fmax, and a vendor power estimate, with the
clock-gating enabled so the ICGs are inserted and the modelled saving can be
cross-checked against the tool's switching-activity power report.

## Prior art

Lane/thread clock-gating under divergence is known in GPU micro-architecture;
this study reproduces the effect in a compact open SIMT core and quantifies it on
RISC-V kernels. Position against Vortex, Ventus, Nyuzi/Cyclone, and Simty.
