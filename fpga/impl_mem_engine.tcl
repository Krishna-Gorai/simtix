# impl_mem_engine.tcl  -  v2: out-of-context synthesis + place & route of the
# memory engine in its AMO variants.
#
# Target: xczu7ev-ffvc1156-2-e (ZCU104), 100 MHz. Reports area and placed-and-
# routed timing for mem_engine alone (register-to-register paths; its ports are
# not timed). Run from fpga/:
#
#   vivado -mode batch -source impl_mem_engine.tcl -tclargs <variant> [lanes<n>] [byp<0|1>] [<mem_engine.sv>]
#
#   base   AGG = 0             one read-modify-write per lane
#   ser    AGG = 1, APAR = 0   one per line, one lane per cycle
#   par    AGG = 1, APAR = 1   one per line, lanes on distinct words in parallel
#   old    the given source file (an engine without these parameters)
# lanes<n> sets SIMTIX_NUM_LANES (default 8); byp0 builds the engine as the board
# top does (BYP = 0, the default is 1). Reports go to reports_mem_engine/<variant>/,
# with _l<n> and _byp0 appended when those options are given.

set_param general.maxThreads 2

set var     [lindex $argv 0]
set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
set src     $rtl_dir/mem_engine.sv
set lanes   8
set byp     {}
foreach a [lrange $argv 1 end] {
  if {[regexp {^lanes=?(\d+)$} $a -> n]} { set lanes $n
  } elseif {[regexp {^byp=?([01])$} $a -> b]} { set byp $b
  } else { set src [file normalize $a] }
}
set tag $var
if {$lanes != 8} { append tag _l$lanes }
if {$byp ne {}}  { append tag _byp$byp }
set out_dir [file normalize ./reports_mem_engine/$tag]
file mkdir $out_dir

array set gens {base {AGG=0 APAR=0} ser {AGG=1 APAR=0} par {AGG=1 APAR=1} old {}}
set gen {}
foreach g $gens($var) { lappend gen -generic $g }
if {$byp ne {}} { lappend gen -generic BYP=$byp }

read_verilog -sv [list $rtl_dir/simtix_pkg.sv $src]

synth_design -top mem_engine -part $part -mode out_of_context -flatten_hierarchy none \
    -verilog_define SIMTIX_NUM_LANES=$lanes {*}$gen
create_clock -name clk -period 10.000 [get_ports clk]
report_utilization -file $out_dir/post_synth_util.rpt

opt_design
place_design
route_design

report_utilization    -file $out_dir/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out_dir/post_route_timing.rpt

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns   [get_property SLACK $paths]
puts [format "========== mem_engine %s: WNS %+.3f ns at 100 MHz ==========" $tag $wns]
