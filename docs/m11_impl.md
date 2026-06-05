# M11 — Full implementation + bitstream (place & route → `chip_top.bit`)

Through M10 the complete chip (`chip_top`) was only ever taken to **out-of-context
synthesis** — enough for area/Fmax/power estimates, but not a real device image. M11
runs the whole thing through the **actual implementation flow** on the ZCU104's
Zynq UltraScale+ part: in-context synthesis → `opt_design` → `place_design` →
`phys_opt_design` → `route_design` → `write_bitstream`. The output is a routed,
**timing-closed** netlist and a real `.bit` for the entire system-on-chip.

## Flow (`fpga/impl_chip.tcl`)

Same RTL set and host guards as `synth_chip.tcl` (maxThreads 2; the M8/M9/M10
LUTRAM register file, scratchpad, and shared memory keep the netlist small enough to
place & route on an 8 GB laptop — peak ~5.0 GB with the swap backstop), but instead
of stopping at OOC synthesis it drives the real device flow and writes a bitstream.
No `write_checkpoint` (silent-hang signature on this host); the `.rpt` sign-off
reports plus the `.bit` are the deliverables.

### Constraints (`fpga/constr/chip_top_impl.xdc`)

The official ZCU104 board files / master XDC are **not installed on this machine**,
so the chip's top-level I/O (`clk`, `rst`, `done`, `result[31:0]` — 35 ports) are
left for the placer to auto-assign and the matching unconstrained-I/O DRCs
(`NSTD-1`, `UCIO-1`) are downgraded to warnings. The goal of this milestone is a
real **placed-and-routed, timing-closed bitstream** of the complete chip — not
board peripheral bring-up. `CFGBVS`/`CONFIG_VOLTAGE` are set (required by
`write_bitstream` on UltraScale+), and because the auto-placed clock input may land
on a non-clock-capable pin, `CLOCK_DEDICATED_ROUTE` is relaxed on the clock net so
the router can complete. To deploy on the physical board, drop in the ZCU104 master
XDC pin LOC/IOSTANDARD lines for these ports (and pin `clk` to a clock-capable user
pin).

## Result — post-route sign-off, xczu7ev-ffvc1156-2-e, Vivado 2025.1

**Timing — all user-specified constraints met @ 100 MHz:**

| | WNS | TNS | Failing endpoints |
|---|---:|---:|---:|
| **Setup** | **+0.000 ns** | 0.000 ns | 0 / 37,516 |
| **Hold** | +0.005 ns | 0.000 ns | 0 / 37,516 |
| **Pulse width** | +4.468 ns | 0.000 ns | 0 / 9,499 |

`phys_opt_design` recovered the placement-stage estimate (WNS ≈ −1.26 ns, inflated
by the generic auto-placed clock route) all the way back to **exactly meeting**
100 MHz on the final routed netlist. **0 errors, 0 critical warnings.**

**Area (post-route):**

| Resource | Used | Avail | Util% |
|---|---:|---:|---:|
| CLB LUTs | 34,850 | 230,400 | 15.1% |
| — LUT as logic | 31,502 | 230,400 | 13.7% |
| — LUT as distributed RAM | 3,348 | 101,760 | 3.3% |
| CLB registers (FF) | 6,130 | 460,800 | 1.3% |
| DSP48 | 24 | 1,728 | 1.4% |
| Block RAM / URAM | 0 / 0 | — | 0% |
| Bonded IOB | 35 | 360 | 9.7% |

**By instance:** `u_accel` (simt_accel) 30,429 LUT / 4,574 FF / 24 DSP — the
`warp_pool` SIMT engine dominates; `cpu` (riscv_pipeline) 1,430 LUT / 1,523 FF (the
register file alone is 992 of those FFs); `u_mem` (shared_mem) 2,929 LUT / 1,920
LUTRAM / **0 FF**.

**Power (vectorless):** 1.086 W total = 0.492 W dynamic + 0.594 W static.

**Bitstream:** `fpga/chip_top.bit`, 19,311,257 bytes — `Bitgen Completed
Successfully`. (Git-ignored as a build artifact; regenerate with the flow below.)

## Reproduce

```
cd fpga && vivado -mode batch -source impl_chip.tcl   # synth→place→route→bitstream
# sign-off reports land in fpga/reports_impl/ ; image is fpga/chip_top.bit
```
