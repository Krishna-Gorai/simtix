# synth_lanes.tcl - phase 5 of docs/lanes16_plan.md: out-of-context synthesis of the board
# top (simt_ps_top: accelerator + L1 + AXI4 line master, the logic that goes into the ZCU102
# design) at a lane/warp count, in the v3 board configuration (64 KB L1, 16 MSHRs, 16 tags,
# AMO aggregation on), on the ZCU102 part. Run from fpga/:
#
#   vivado -mode batch -source synth_lanes.tcl -tclargs 16 8 [retime]
#   vivado -mode batch -source synth_lanes.tcl -tclargs 16 4 [retime]
#   ... -tclargs 16 8 l1kb128 lowmem
# l1kb<n>: L1 size in KB (default 64). lowmem: -flatten_hierarchy none and the
# RuntimeOptimized directive, for a host that cannot hold the flattened timing-driven run
# (16Lx8W stalled in Timing Optimization for 2 h 40 min at 5.25 GB on the 7.8 GB laptop).
# The divide/sqrt core count follows simtix_pkg (one per 8 lanes) unless sfu<n> is given.
#
# Reports land in reports_lanes/L<lanes>_W<warps>[_rt]/; one line to grep:
#   LANESPPA,lanes,warps,retime,LUT,LUTRAM,FF,DSP,BRAM,WNS_ns,Fmax_est_MHz,synth_peak_MB
# Fmax_est is from the post-synthesis timing estimate at a 10 ns clock (routing adds delay:
# the routed design is usually 10-20% slower). synth_peak_MB is Vivado's own peak-memory
# figure for synth_design (the number that decides whether the 7.8 GB laptop can build it).
# Host guards (8 GB laptop): general.maxThreads 2, synth.maxThreads 1 (its helper processes
# take ~2 GB each), no checkpoint.

if {[llength $argv] < 2} { puts "usage: -tclargs <lanes> <warps> \[retime\]"; exit 1 }
set lanes  [lindex $argv 0]
set warps  [lindex $argv 1]
set retime [expr {[lsearch -exact $argv retime] >= 0}]
set lowmem [expr {[lsearch -exact $argv lowmem] >= 0}]
set l1kb   64
set sfu    {}
foreach a $argv {
    if {[regexp {^l1kb(\d+)$} $a -> n]} { set l1kb $n }
    if {[regexp {^sfu(\d+)$} $a -> n]}  { set sfu $n }
}

set_param general.maxThreads 2
set_param synth.maxThreads 1

set part    xczu9eg-ffvb1156-2-e
set rtl     [file normalize ../rtl]
set tag     L${lanes}_W${warps}[expr {$l1kb != 64 ? "_k$l1kb" : ""}][expr {$sfu ne {} ? "_s$sfu" : ""}][expr {$retime ? "_rt" : ""}][expr {$lowmem ? "_lm" : ""}]
set out_dir [file normalize ./reports_lanes/$tag]
file mkdir $out_dir

read_verilog -sv [list \
    $rtl/accel/simtix_pkg.sv $rtl/accel/mmio_regs.sv \
    $rtl/accel/simt_fpu.sv $rtl/accel/fp_divsqrt.sv \
    $rtl/accel/mem_engine.sv $rtl/accel/warp_pool.sv $rtl/accel/simt_accel.sv \
    $rtl/accel/l1_dcache.sv $rtl/accel/axi_line_master.sv \
    $rtl/soc/simt_ps_top.sv ]

set xdc $out_dir/ooc.xdc
set f [open $xdc w]
puts $f "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $f
read_xdc -mode out_of_context $xdc

set defs [list SIMTIX_NUM_LANES=$lanes SIMTIX_NUM_WARPS=$warps SIMTIX_L1_KB=$l1kb \
               SIMTIX_L1_MSHR=16 SIMTIX_MEM_TAGS=16]
if {$sfu ne {}} { lappend defs SIMTIX_SFU_CORES=$sfu }
set args [list -top simt_ps_top -part $part -mode out_of_context               -flatten_hierarchy [expr {$lowmem ? "none" : "rebuilt"}]]
if {$lowmem} { lappend args -directive RuntimeOptimized }
foreach d $defs { lappend args -verilog_define $d }
if {$retime} { lappend args -retiming }
puts "synth_design $args"
synth_design {*}$args

report_utilization -file $out_dir/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $out_dir/util_hier.rpt
report_timing_summary -max_paths 20 -file $out_dir/timing.rpt

set lut    [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set lutram [llength [get_cells -hier -filter {REF_NAME =~ RAM*}]]
set ff     [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set dsp    [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]
set bram   [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
set wns    [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set fmax   [format %.1f [expr {1000.0 / (10.0 - $wns)}]]
puts "LANESPPA,$tag,$lanes,$warps,$retime,$lut,$lutram,$ff,$dsp,$bram,$wns,$fmax,see_log"
set f [open $out_dir/ppa.csv w]
puts $f "lanes,warps,retime,LUT_cells,LUTRAM_cells,FF,DSP,BRAM,WNS_ns,Fmax_est_MHz"
puts $f "$lanes,$warps,$retime,$lut,$lutram,$ff,$dsp,$bram,$wns,$fmax"
close $f
