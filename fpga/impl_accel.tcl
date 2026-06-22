# impl_accel.tcl  -  M15: placed (OOC) timing sign-off of the FP-enabled accelerator
#
# The post-synth Fmax is an UNPLACED estimate whose routing is padded (the 2-stage
# FP pipeline leaves logic at ~4.9 ns but the synth route estimate is ~6.4 ns).
# This runs the real placement + routing so the reported Fmax reflects placed
# routing, the legitimate measure of whether the design closes 100 MHz.
#
#   vivado -mode batch -source impl_accel.tcl
#
# Host guards (8 GB): maxThreads 2, flatten none, no write_checkpoint. Peak RAM is
# higher than synth (place+route); free RAM to ~3 GB first.

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
set out_dir [file normalize ./reports_fp_impl]
file mkdir $out_dir

read_verilog -sv [list \
    $rtl_dir/simtix_pkg.sv \
    $rtl_dir/mmio_regs.sv  \
    $rtl_dir/simt_fpu.sv   \
    $rtl_dir/fp_divsqrt.sv \
    $rtl_dir/warp_pool.sv  \
    $rtl_dir/simt_accel.sv ]
read_xdc [list [file normalize ./constr/simt_accel_ooc.xdc]]

synth_design -top simt_accel -part $part -mode out_of_context \
    -flatten_hierarchy none -retiming

opt_design
place_design
phys_opt_design
route_design

report_utilization    -file $out_dir/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out_dir/post_route_timing.rpt
report_power          -file $out_dir/post_route_power.rpt

set clk_period 10.000
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "============ M15 FP-ENABLED PLACED PPA (xczu7ev / ZCU104) ==========="
if {[llength $paths] > 0} {
    set wns  [get_property SLACK $paths]
    set raw  [expr {$clk_period - $wns}]
    set fmax [expr {1000.0 / $raw}]
    puts [format "  Constrained period  : %.3f ns (%.1f MHz)" $clk_period [expr {1000.0/$clk_period}]]
    puts [format "  Setup WNS           : %+.3f ns  (%s)" $wns [expr {$wns >= 0 ? "MET" : "VIOLATED"}]]
    puts [format "  Critical-path delay : %.3f ns" $raw]
    puts [format "  Max Fmax            : %.1f MHz" $fmax]
} else {
    puts "  (no timing path — see post_route_timing.rpt)"
}
puts "===================================================================="
