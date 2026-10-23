# impl_l1.tcl  -  v2: out-of-context synthesis + place & route of the L1 data cache
#
# Target: xczu7ev-ffvc1156-2-e (ZCU104), 100 MHz. Reports area (LUT/FF/BRAM),
# placed-and-routed timing and power for l1_dcache alone. Run from fpga/:
#
#   vivado -mode batch -source impl_l1.tcl

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
set out_dir [file normalize ./reports_l1]
file mkdir $out_dir

read_verilog -sv [list $rtl_dir/simtix_pkg.sv $rtl_dir/l1_dcache.sv]

synth_design -top l1_dcache -part $part -mode out_of_context -flatten_hierarchy none
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file $out_dir/post_synth_util.rpt

opt_design
place_design
route_design

report_utilization    -file $out_dir/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out_dir/post_route_timing.rpt
report_power          -file $out_dir/post_route_power.rpt

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns   [get_property SLACK $paths]
puts "========== L1 DATA CACHE (xczu7ev, OOC, routed) =========="
puts [format "  Setup WNS   : %+.3f ns at 10.000 ns" $wns]
puts [format "  Fmax        : %.1f MHz" [expr {1000.0 / (10.0 - $wns)}]]
