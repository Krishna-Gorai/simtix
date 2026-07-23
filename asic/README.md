# SIMTiX → SkyWater 130 nm (sky130) ASIC synthesis

Yosys synthesis of the SIMTiX accelerator to `sky130_fd_sc_hd`, typical corner.
**Status: work in progress — no completed result yet.** See "Where this stands".

## Running

From WSL (the Docker daemon must be up: `sudo service docker start`):

```bash
cd /mnt/d/Verilog\ Projects/simtix/asic

TOP=simt_fpu FLATTEN=1 ./run_synth_sky130.sh   # one lane's FP unit (small, fast)
TOP=simt_accel          ./run_synth_sky130.sh   # whole accelerator, hierarchical
PERIOD_NS=20 TOP=simt_fpu ./run_synth_sky130.sh # sweep the clock target
```

Outputs land in `reports/stat_<top>.txt`, `reports/yosys.log`,
`results/<top>_sky130.v`.

## Toolchain notes (each of these cost a debug cycle)

1. **Yosys cannot parse this RTL directly.** The sources use a package import in
   the module header (`module mmio_regs\n import simtix_pkg::*;\n(...)`), which
   the OpenLane image's yosys 0.30 rejects — its own help says `-sv` covers
   "only a small subset of SystemVerilog". Neither OpenLane image ships `sv2v`
   or the slang plugin. Fix: `sv2v` v0.0.13, installed to `~/tools/sv2v-Linux/`
   (single static binary, no root). The runner regenerates
   `gen/simt_accel_flat.v` every run, so the RTL stays the single source of
   truth — do not hand-edit the generated file.
2. **`sv2v -E Always` is required.** Without it, sv2v lowers `always_comb` to a
   Verilog-2005 `always @(...)` whose sensitivity list names unpacked arrays
   (`rv1`, `rv2`, `frv1`…); yosys rejects that with `Invalid array access`.
   `-E Always` keeps `always_comb`/`always_ff`, which yosys handles natively.
3. **`always_comb` is then rewritten to `always @*`** by the runner. Yosys
   enforces the no-latch rule on `always_comb` and it fires on the loop index
   sv2v declares inside each block (`Latch inferred for \sv2v_autoblock_18.l`).
   That index is a conversion artifact, not design state. **Caveat: this rewrite
   would also mask a genuine latch, so the resulting netlist should be checked
   for latch cells before any result is trusted.**
4. **Do not flatten `simt_accel` on an 8 GB host.** `synth -flatten` handed abc a
   483,642-gate / 574,380-wire network with 90,735 inputs and the process was
   killed for memory after ~1 hour. Hierarchical synthesis (the default here)
   keeps abc's cones per-module. Flattening is fine for small tops.

## The architectural finding so far

Every register-file and buffer array reports
`Warning: Replacing memory ... with list of registers`. This is expected and
important: **sky130 has no distributed RAM, so the LUTRAM optimization that is
the headline FPGA result (5.7× LUT reduction) has no ASIC equivalent.** The
arrays become flip-flop banks — the integer VRF, the FP register file, and the
scratchpad together are roughly 74 k bits, and abc saw ~90 k combinational
inputs, which is essentially that flop count plus primary inputs.

A straight lift of the FPGA RTL therefore yields a very large, flop-dominated
130 nm block. Any real ASIC port needs SRAM macros or a restructured register
file — but the VRF is 1W/2R and the FP file 1W/3R, and multi-port SRAM is
exactly what sky130/OpenRAM does not provide easily. **ASIC area here is not
comparable like-for-like with the FPGA LUT numbers.**

## Where this stands

- Toolchain working end to end up to abc; three parse/lowering blockers fixed.
- No `stat` report and no netlist produced yet: the only full-accelerator
  attempt was flattened and was killed in abc.
- Next: run `TOP=simt_fpu FLATTEN=1` for a clean per-lane datapath area, then
  `TOP=simt_accel` hierarchically for the whole block. Then check the netlist
  for latch cells (see note 3) before quoting any number.
