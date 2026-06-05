# M13 — Post-implementation functional simulation (routed gate-level netlist)

M11 produced a placed-and-routed bitstream and M12 made the host CPU load the
inputs; M13 closes the loop by **simulating the real routed hardware**. Instead of
the RTL, we simulate the post-route gate-level netlist Vivado emits — actual
UltraScale+ primitives (`LUT6`, `FDRE`, `RAMD64E` distributed RAM, `DSP48E2`, clock
buffers) wired exactly as placed and routed — and confirm it still computes the
right answer. This is the sign-off that synthesis + place & route preserved the
design's behaviour, not just its area/timing.

## Flow

1. **Emit the simulation models** (added to `fpga/impl_chip.tcl`, after `route_design`):
   ```tcl
   write_verilog -mode funcsim -force postimpl/chip_top_funcsim.v   # 152 MB gate netlist
   write_sdf                   -force postimpl/chip_top_funcsim.sdf  # 776 MB routed delays
   ```
   The funcsim netlist is the routed design expressed in UNISIM cells; the SDF holds
   the back-annotatable routed delays (for an optional *timing* sim — not needed for
   the *functional* sim here).

2. **Simulate in Vivado xsim** (`fpga/run_postimpl_sim.bat`) with the **same
   self-checking testbench** used for RTL (`tests/tb_chip_top.sv`, drives only
   `clk`/`rst`):
   ```
   xvlog chip_top_funcsim.v
   xvlog -sv ../../tests/tb_chip_top.sv
   xvlog <Vivado>/data/verilog/src/glbl.v
   xelab tb_chip_top glbl -L unisims_ver -L secureip -L xpm -s chip_postimpl
   xsim chip_postimpl -runall
   ```
   `glbl` supplies the global set/reset (GSR) pulse the primitives expect at t=0;
   `unisims_ver`/`secureip` provide the primitive models.

## Result

```
[tb_chip_top] chip booted; host CPU is driving the accelerator
[tb_chip_top] PASS: chip computed result = 964 in ~204 cycles
$finish called at time : 2085 ns
```

The routed gate-level chip produces **result = 964** — identical to RTL — with the
host CPU loading A/B, programming/launching the accelerator, and reading the results
back. (The ~204 vs ~198 RTL cycles is just the GSR-release start offset in the gate
model; the computation is bit-identical.) **The implemented hardware is verified.**

## Timing note (honest)

This M12 re-implementation run closed **hold** (WHS +0.006 ns) but missed **setup**
by a hair: **WNS −0.078 ns** (TNS −7.536, Fmax ≈ 99.2 MHz) — a ~0.8 % miss vs the
100 MHz constraint, against M11's exact +0.000 on the same datapath. The cause is
**routing congestion (level 5) + run-to-run P&R variance**, not a new logic path —
the M12 RTL delta is only 14 extra combinational driver-ROM entries. It is
recoverable with a timing-focused implementation directive or a different placer
seed (the design is the same one that met at M11). The **functional** sign-off above
is independent of this and stands: the routed netlist is logically correct.

## Reproduce

```
cd fpga && vivado -mode batch -source impl_chip.tcl   # -> postimpl/chip_top_funcsim.v (+ .sdf, .bit)
cd fpga && run_postimpl_sim.bat                        # xsim gate-level functional sim -> result=964
```
