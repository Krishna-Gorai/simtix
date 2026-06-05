# synth_chip.tcl  -  M10: out-of-context, timing-driven synthesis + PPA of the
#                   COMPLETE chip (host CPU + accelerator + shared memory) on ZCU104
#
# Target: Zynq UltraScale+ MPSoC xczu7ev-ffvc1156-2-e (the ZCU104 eval board).
# Synthesizes the whole chip_top hierarchy — the 5-stage RISC-V pipeline, the
# SIMTiX SIMT accelerator, the on-chip shared memory, and the driver ROM — and
# reports area (LUT/FF/BRAM/DSP), a post-synth timing estimate (=> Fmax), and a
# vectorless power estimate. Run from the fpga/ directory:
#
#   vivado -mode batch -source synth_chip.tcl
#
# Same host-proven guards as the M9 accelerator flow (8 GB laptop): maxThreads 2 +
# flatten_hierarchy none keep peak RAM bounded; the LUTRAM register file (M8) and
# scratchpad (M9) plus the LUTRAM shared memory keep the flip-flop/mux fabric small
# enough that timing-driven optimization fits. No write_checkpoint (silent-hang
# signature on this host); the .rpt files carry every PPA number we need.

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set acc_dir [file normalize ../rtl/accel]
set soc_dir [file normalize ../rtl/soc]
set cpu_dir [file normalize ../rtl/cpu]
set out_dir [file normalize ./reports_chip]
file mkdir $out_dir

# ── RTL: SystemVerilog (package first, leaf-to-top), then the Verilog CPU ────────
read_verilog -sv [list \
    $acc_dir/simtix_pkg.sv \
    $acc_dir/mmio_regs.sv  \
    $acc_dir/warp_pool.sv  \
    $acc_dir/simt_accel.sv \
    $soc_dir/shared_mem.sv \
    $soc_dir/cpu_driver_rom.sv \
    $soc_dir/chip_top.sv ]

# Host CPU pipeline + leaf modules (Verilog-2001). The standalone CPU SoC wrapper,
# its ROM/SRAM, and the FPGA board top are excluded — chip_top supplies its own.
read_verilog [list \
    $cpu_dir/alu.v \
    $cpu_dir/control_unit.v \
    $cpu_dir/extend.v \
    $cpu_dir/forwarding_unit.v \
    $cpu_dir/hazard_unit.v \
    $cpu_dir/register_file.v \
    $cpu_dir/riscv_pipeline.v ]

# NB: wrap the path in [list ...] so read_xdc does not re-split on the space in the
# "Verilog Projects" parent directory.
read_xdc [list [file normalize ./constr/chip_top_ooc.xdc]]

# ── Out-of-context, timing-driven synthesis of the whole chip ───────────────────
synth_design -top chip_top -part $part -mode out_of_context \
    -flatten_hierarchy none

# ── Reports: area, timing (Fmax), power ─────────────────────────────────────────
report_utilization      -file $out_dir/post_synth_util.rpt
report_timing_summary   -max_paths 10 -file $out_dir/post_synth_timing.rpt
report_power            -file $out_dir/post_synth_power.rpt

# ── Console summary (also captured in the log) ──────────────────────────────────
set clk_period 10.000
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "============== M10 FULL-CHIP PPA SUMMARY (xczu7ev / ZCU104) =============="
if {[llength $paths] > 0} {
    set wns  [get_property SLACK $paths]
    set raw  [expr {$clk_period - $wns}]
    set fmax [expr {1000.0 / $raw}]
    puts [format "  Constrained period   : %.3f ns (%.1f MHz)" $clk_period [expr {1000.0/$clk_period}]]
    puts [format "  Setup WNS            : %+.3f ns  (%s)" $wns [expr {$wns >= 0 ? "MET" : "VIOLATED"}]]
    puts [format "  Critical-path delay  : %.3f ns" $raw]
    puts [format "  Max Fmax             : %.1f MHz" $fmax]
} else {
    puts "  (no timing path returned — see post_synth_timing.rpt)"
}
report_utilization -hierarchical -hierarchical_depth 2
puts "========================================================================="
