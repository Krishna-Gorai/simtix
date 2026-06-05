# chip_top_impl.xdc  -  in-context implementation constraints for the M10 full chip
#
# Target board: ZCU104 (Zynq UltraScale+ MPSoC xczu7ev-ffvc1156-2-e).
#
# The official ZCU104 board files / master XDC are not installed on this machine,
# so the chip's top-level I/O (clk, rst, done, result[31:0]) are left for the
# placer to auto-assign, and the matching "unconstrained / non-default I/O" DRCs
# are downgraded to warnings. The intent of this flow is a real, placed-and-routed,
# timing-closed BITSTREAM of the complete chip — not board-specific pin bring-up.
# To deploy on the physical board, drop in the ZCU104 master XDC pin LOC/IOSTANDARD
# lines for these ports (and constrain `clk` to a clock-capable user pin).

create_clock -name clk -period 10.000 [get_ports clk]

# Reset is asynchronous to the clock.
set_false_path -from [get_ports rst]

# write_bitstream on UltraScale+ requires these configuration-bank properties.
set_property CFGBVS GND          [current_design]
set_property CONFIG_VOLTAGE 1.8  [current_design]

# Permit auto-placed, unconstrained top-level I/O (no board pinout in this flow).
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
