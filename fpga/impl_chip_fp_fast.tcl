# impl_chip_fp_fast.tcl  -  FAST-iteration variant of impl_chip_fp.tcl.
#
# Identical full in-context flow (host RISC-V + pipelined FP32/FP16 SIMTiX accel +
# shared memory + driver ROM) on the ZCU104 (xczu7ev-ffvc1156-2-e), EXCEPT synth_design
# uses -directive RuntimeOptimized to skip the very expensive synth Timing-Optimization
# passes that ran >2.75 h on this 8 GB host for the whole-chip FP netlist. The metric we
# actually care about for 100 MHz closure is the PLACED WNS (synth-estimate timing is
# congestion-blind), so place_design + phys_opt_design + route_design are kept at full
# effort. Use this to get a fast directional read on Stage A1+A2; do a default-directive
# run for the publication-grade number once the direction looks right.
#
#   cd fpga && vivado -mode batch -source impl_chip_fp_fast.tcl
#
# Host guards (8 GB): maxThreads 2, flatten none, no write_checkpoint (silent-hang
# signature on this host). Deliverables: .rpt files in reports_fp_chip_fast/ + chip_top_fp.bit.

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set acc_dir [file normalize ../rtl/accel]
set soc_dir [file normalize ../rtl/soc]
set cpu_dir [file normalize ../rtl/cpu]
set out_dir [file normalize ./reports_fp_chip_fast]
file mkdir $out_dir

# -- RTL: SystemVerilog (package first, leaf-to-top), WITH the FP datapath ---------
read_verilog -sv [list \
    $acc_dir/simtix_pkg.sv \
    $acc_dir/mmio_regs.sv  \
    $acc_dir/simt_fpu.sv   \
    $acc_dir/fp_divsqrt.sv \
    $acc_dir/warp_pool.sv  \
    $acc_dir/simt_accel.sv \
    $soc_dir/shared_mem.sv \
    $soc_dir/cpu_driver_rom.sv \
    $soc_dir/chip_top.sv ]

read_verilog [list \
    $cpu_dir/alu.v \
    $cpu_dir/control_unit.v \
    $cpu_dir/extend.v \
    $cpu_dir/forwarding_unit.v \
    $cpu_dir/hazard_unit.v \
    $cpu_dir/register_file.v \
    $cpu_dir/riscv_pipeline.v ]

read_xdc [list [file normalize ./constr/chip_top_impl.xdc]]

# -- In-context synthesis, FAST directive (real IO buffers; NOT out_of_context) ----
synth_design -top chip_top -part $part -flatten_hierarchy none -directive RuntimeOptimized
report_utilization    -file $out_dir/post_synth_util.rpt
report_timing_summary -max_paths 10 -file $out_dir/post_synth_timing.rpt

# -- Logic optimization ------------------------------------------------------------
opt_design
report_drc -file $out_dir/opt_drc.rpt

# -- Placement (auto-places the unconstrained top-level I/O too) -------------------
place_design

# The input clock IO may land on a non-clock-capable pin (no board pinout here);
# allow the dedicated-clock-route check to pass so route_design can complete.
catch { set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hier -filter {NAME =~ *clk_IBUF}] }

phys_opt_design
report_utilization    -file $out_dir/post_place_util.rpt

# -- Routing -----------------------------------------------------------------------
route_design

# A final post-route physical-opt pass only if routing left negative slack.
set wns_pre [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns_pre < 0} {
    puts "post-route WNS ${wns_pre} ns < 0 -- running post-route phys_opt_design"
    phys_opt_design
}

# -- Post-route sign-off reports ---------------------------------------------------
report_utilization      -file $out_dir/post_route_util.rpt
report_timing_summary   -max_paths 20 -file $out_dir/post_route_timing.rpt
report_power            -file $out_dir/post_route_power.rpt
report_drc              -file $out_dir/post_route_drc.rpt
report_io               -file $out_dir/post_route_io.rpt

# -- Bitstream ---------------------------------------------------------------------
write_bitstream -force [file normalize ./chip_top_fp_fast.bit]

# -- Console summary (also captured in the log) ------------------------------------
set clk_period 10.000
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "============== FP FULL-CHIP (FAST) IMPLEMENTATION SUMMARY (xczu7ev / ZCU104) =============="
if {[llength $paths] > 0} {
    set wns  [get_property SLACK $paths]
    set raw  [expr {$clk_period - $wns}]
    set fmax [expr {1000.0 / $raw}]
    puts [format "  Constrained period   : %.3f ns (%.1f MHz)" $clk_period [expr {1000.0/$clk_period}]]
    puts [format "  Post-route setup WNS : %+.3f ns  (%s)" $wns [expr {$wns >= 0 ? "MET" : "VIOLATED"}]]
    puts [format "  Critical-path delay  : %.3f ns" $raw]
    puts [format "  Max Fmax             : %.1f MHz" $fmax]
} else {
    puts "  (no timing path returned -- see post_route_timing.rpt)"
}
set bit [file normalize ./chip_top_fp_fast.bit]
if {[file exists $bit]} { puts "  Bitstream            : $bit ([file size $bit] bytes)" }
puts "==========================================================================================="
