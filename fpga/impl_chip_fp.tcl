# impl_chip_fp.tcl  -  FULL IN-CONTEXT IMPLEMENTATION + BITSTREAM of the complete
#                     FP-enabled chip (host RISC-V pipeline + pipelined FP32/FP16
#                     SIMTiX accelerator + shared memory + driver ROM) on the
#                     ZCU104 (Zynq UltraScale+ xczu7ev-ffvc1156-2-e).
#
# This is the FP counterpart of impl_chip.tcl: the ONLY difference is that it adds
# the two floating-point sources -- simt_fpu.sv (the M17 three-stage pipelined FP
# unit) and fp_divsqrt.sv (the shared iterative divide/square-root core) -- that the
# current warp_pool.sv instantiates per-lane / shared. Same top (chip_top), same
# constraints (chip_top_impl.xdc), same host guards. It implements exactly the RTL
# that fgpa/vivado_project_fp/simtix_chip_fp.xpr contains, but as a single in-process
# batch run so peak RAM is bounded (maxThreads 2) on the 8 GB host -- the proven
# recipe from M11/M16/M17 -- instead of project-run child processes we cannot bound.
#
#   cd fpga && vivado -mode batch -source impl_chip_fp.tcl
#
# Host guards (8 GB): maxThreads 2, flatten none, no write_checkpoint (silent-hang
# signature on this host). Deliverables are the .rpt files and chip_top_fp.bit.

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set acc_dir [file normalize ../rtl/accel]
set soc_dir [file normalize ../rtl/soc]
set cpu_dir [file normalize ../rtl/cpu]
set out_dir [file normalize ./reports_fp_chip]
file mkdir $out_dir

# -- RTL: SystemVerilog (package first, leaf-to-top), WITH the FP datapath ---------
#    simt_fpu.sv + fp_divsqrt.sv are the only additions vs the integer impl_chip.tcl.
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

# -- In-context synthesis (real IO buffers; NOT out_of_context) --------------------
synth_design -top chip_top -part $part -flatten_hierarchy none
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

# -- Post-implementation simulation models (functional netlist + SDF) --------------
set sim_dir [file normalize ./postimpl_fp]
file mkdir $sim_dir
write_verilog -mode funcsim -force $sim_dir/chip_top_fp_funcsim.v
write_sdf                   -force $sim_dir/chip_top_fp_funcsim.sdf

# -- Bitstream ---------------------------------------------------------------------
write_bitstream -force [file normalize ./chip_top_fp.bit]

# -- Console summary (also captured in the log) ------------------------------------
set clk_period 10.000
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "============== FP FULL-CHIP IMPLEMENTATION SUMMARY (xczu7ev / ZCU104) =============="
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
set bit [file normalize ./chip_top_fp.bit]
if {[file exists $bit]} { puts "  Bitstream            : $bit ([file size $bit] bytes)" }
report_utilization -hierarchical -hierarchical_depth 2
puts "===================================================================================="
