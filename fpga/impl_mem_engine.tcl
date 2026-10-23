# impl_mem_engine.tcl  -  v2: out-of-context synthesis + place & route of the
# memory engine in its AMO variants.
#
# Target: xczu7ev-ffvc1156-2-e (ZCU104), 100 MHz. Reports area and placed-and-
# routed timing for mem_engine alone (register-to-register paths; its ports are
# not timed). Run from fpga/:
#
#   vivado -mode batch -source impl_mem_engine.tcl -tclargs <variant> [<mem_engine.sv>]
#
#   base   AGG = 0             one read-modify-write per lane
#   ser    AGG = 1, APAR = 0   one per line, one lane per cycle
#   par    AGG = 1, APAR = 1   one per line, lanes on distinct words in parallel
#   old    the given source file (an engine without these parameters)
# Reports go to reports_mem_engine/<variant>/.

set_param general.maxThreads 2

set var     [lindex $argv 0]
set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
set src     [expr {[llength $argv] > 1 ? [file normalize [lindex $argv 1]] : "$rtl_dir/mem_engine.sv"}]
set out_dir [file normalize ./reports_mem_engine/$var]
file mkdir $out_dir

array set gens {base {AGG=0 APAR=0} ser {AGG=1 APAR=0} par {AGG=1 APAR=1} old {}}
set gen {}
foreach g $gens($var) { lappend gen -generic $g }

read_verilog -sv [list $rtl_dir/simtix_pkg.sv $src]

synth_design -top mem_engine -part $part -mode out_of_context -flatten_hierarchy none {*}$gen
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file $out_dir/post_synth_util.rpt

opt_design
place_design
route_design

report_utilization    -file $out_dir/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out_dir/post_route_timing.rpt

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns   [get_property SLACK $paths]
puts [format "========== mem_engine %s: WNS %+.3f ns at 100 MHz ==========" $var $wns]
