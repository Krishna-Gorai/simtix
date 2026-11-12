# synth_ara_ooc.tcl - out-of-context implementation of Ara + CVA6 on the XCZU9EG-2
#
#   vivado -mode batch -nojournal -log ara_ooc_<n>l.log -source synth_ara_ooc.tcl -tclargs <n>
#   (from baselines/ara; <n> = 2 or 4 lanes)
#
# Sources: C:/work/ara/vivado_sources_<n>l.tcl, written by
#   bender script vivado -t rtl -t cv64a6_imafdcv_sv39 -t fpga -t xilinx -t synthesis
#     -t exclude_first_pass_decoder --define NR_LANES=<n> --define VLEN=<1024 n>
#     --define ARIANE_ACCELERATOR_PORT=1 --define COMMON_CELLS_ASSERTS_OFF
# with backslashes turned into slashes. Clock: 115.37 MHz (8.667 ns), the SIMTiX board
# clock; Fmax = 1/(T - WNS) of the routed design, as for SIMTiX.
set_param general.maxThreads 2
set lanes  [lindex $argv 0]
# optional second argument "hs": FP32/FP16 only (define ARA_FPU_HS, ara_ooc_top.sv)
set hs     [expr {[lsearch -exact $argv hs] >= 0}]
set tag    ${lanes}l[expr {$hs ? "_hs" : ""}]
set part   xczu9eg-ffvb1156-2-e
set here   [file dirname [file normalize [info script]]]
set out    [file join $here reports_ooc_$tag]
file mkdir $out

create_project -in_memory -part $part
source C:/work/ara/vivado_sources_${lanes}l.tcl
add_files -norecurse [file join $here ara_ooc_top.sv]
set defs [get_property verilog_define [current_fileset]]
if {$hs} { lappend defs ARA_FPU_HS }
set incs [get_property include_dirs   [current_fileset]]

synth_design -top ara_ooc_top -part $part -mode out_of_context \
    -verilog_define $defs -include_dirs $incs
create_clock -name clk -period 8.667 [get_ports clk_i]
report_utilization -file $out/post_synth_util.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/post_synth_util_hier.rpt
write_checkpoint -force $out/post_synth.dcp

opt_design
place_design
phys_opt_design
route_design
report_utilization -file $out/post_route_util.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/post_route_util_hier.rpt
report_timing_summary -max_paths 10 -file $out/post_route_timing.rpt
report_power -file $out/post_route_power.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / (8.667 - $wns)}]
puts [format "========== Ara %s: WNS %+.3f ns at 115.37 MHz, Fmax %.1f MHz ==========" \
      $tag $wns $fmax]
