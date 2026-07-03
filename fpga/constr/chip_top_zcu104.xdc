# chip_top_zcu104.xdc  -  full pin-constrained implementation XDC for the M10 chip
#
# Target: ZCU104 (Zynq UltraScale+ MPSoC xczu7ev-ffvc1156-2-e).
#
# Pin strategy (Part A, 2nd attempt): the first attempt packed all 35 ports into
# HP bank 64, which over-constrained the congested placer and regressed timing by
# ~2 ns. These LOCs are instead EXTRACTED FROM THE PLACER'S OWN CHOICES in the
# timing-closed unconstrained run (reports_fp_chip_fast/post_route_io.rpt of the
# 107.3 MHz F/X-pipeline build): result[31:0] in HP bank 68, clk/rst/done in HD
# bank 88 with clk on a clock-capable HDGC pin (IO_L8P_HDGC_88) — so the dedicated
# clock route is legal with NO CLOCK_DEDICATED_ROUTE override, and pinning changes
# nothing the placer wasn't already doing. All banks run LVCMOS18 (VCCO 1.8 V).
#
# NO DRC severity downgrades and NO routing hacks: with every port LOC'd and
# IOSTANDARD'd, the NSTD-1 / UCIO-1 checks pass on their own.

create_clock -name clk -period 10.000 [get_ports clk]

# Reset is asynchronous to the clock.
set_false_path -from [get_ports rst]

# write_bitstream on UltraScale+ requires these configuration-bank properties.
set_property CFGBVS GND          [current_design]
set_property CONFIG_VOLTAGE 1.8  [current_design]

# ── Clock / control (HD bank 88; clk on the HDGC clock-capable pin) ──────────────
set_property -dict {PACKAGE_PIN E4  IOSTANDARD LVCMOS18} [get_ports clk]
set_property -dict {PACKAGE_PIN E5  IOSTANDARD LVCMOS18} [get_ports rst]
set_property -dict {PACKAGE_PIN F6  IOSTANDARD LVCMOS18} [get_ports done]

# ── result[31:0] (HP bank 68) ─────────────────────────────────────────────────────
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS18} [get_ports {result[0]}]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS18} [get_ports {result[1]}]
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS18} [get_ports {result[2]}]
set_property -dict {PACKAGE_PIN A7  IOSTANDARD LVCMOS18} [get_ports {result[3]}]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS18} [get_ports {result[4]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS18} [get_ports {result[5]}]
set_property -dict {PACKAGE_PIN B6  IOSTANDARD LVCMOS18} [get_ports {result[6]}]
set_property -dict {PACKAGE_PIN A6  IOSTANDARD LVCMOS18} [get_ports {result[7]}]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS18} [get_ports {result[8]}]
set_property -dict {PACKAGE_PIN B8  IOSTANDARD LVCMOS18} [get_ports {result[9]}]
set_property -dict {PACKAGE_PIN C7  IOSTANDARD LVCMOS18} [get_ports {result[10]}]
set_property -dict {PACKAGE_PIN C6  IOSTANDARD LVCMOS18} [get_ports {result[11]}]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS18} [get_ports {result[12]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS18} [get_ports {result[13]}]
set_property -dict {PACKAGE_PIN F12 IOSTANDARD LVCMOS18} [get_ports {result[14]}]
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS18} [get_ports {result[15]}]
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS18} [get_ports {result[16]}]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS18} [get_ports {result[17]}]
set_property -dict {PACKAGE_PIN H13 IOSTANDARD LVCMOS18} [get_ports {result[18]}]
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS18} [get_ports {result[19]}]
set_property -dict {PACKAGE_PIN F11 IOSTANDARD LVCMOS18} [get_ports {result[20]}]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS18} [get_ports {result[21]}]
set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS18} [get_ports {result[22]}]
set_property -dict {PACKAGE_PIN G11 IOSTANDARD LVCMOS18} [get_ports {result[23]}]
set_property -dict {PACKAGE_PIN G10 IOSTANDARD LVCMOS18} [get_ports {result[24]}]
set_property -dict {PACKAGE_PIN F10 IOSTANDARD LVCMOS18} [get_ports {result[25]}]
set_property -dict {PACKAGE_PIN H9  IOSTANDARD LVCMOS18} [get_ports {result[26]}]
set_property -dict {PACKAGE_PIN G9  IOSTANDARD LVCMOS18} [get_ports {result[27]}]
set_property -dict {PACKAGE_PIN E9  IOSTANDARD LVCMOS18} [get_ports {result[28]}]
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS18} [get_ports {result[29]}]
set_property -dict {PACKAGE_PIN F8  IOSTANDARD LVCMOS18} [get_ports {result[30]}]
set_property -dict {PACKAGE_PIN E8  IOSTANDARD LVCMOS18} [get_ports {result[31]}]
