# impl_mem_engine.tcl  -  v2: out-of-context synthesis + place & route of the
# memory engine, with and without line-aggregated AMOs.
#
# Target: xczu7ev-ffvc1156-2-e (ZCU104), 100 MHz. Reports area and placed-and-
# routed timing for mem_engine alone (register-to-register paths; its ports are
# not timed). Run from fpga/:
#
#   vivado -mode batch -source impl_mem_engine.tcl -tclargs <AGG 0|1>

set_param general.maxThreads 2

set agg     [lindex $argv 0]
set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
set out_dir [file normalize ./reports_mem_engine/agg$agg]
file mkdir $out_dir

read_verilog -sv [list $rtl_dir/simtix_pkg.sv $rtl_dir/mem_engine.sv]

synth_design -top mem_engine -part $part -mode out_of_context -flatten_hierarchy none \
    -generic AGG=$agg
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file $out_dir/post_synth_util.rpt

opt_design
place_design
route_design

report_utilization    -file $out_dir/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out_dir/post_route_timing.rpt

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns   [get_property SLACK $paths]
puts [format "========== mem_engine AGG=%s: WNS %+.3f ns at 100 MHz ==========" $agg $wns]
