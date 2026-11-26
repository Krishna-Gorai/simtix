# synth_fgpu_ooc.tcl - FGPU out of context for the ZCU102 (docs/fgpu_plan.md, phase 0 step 3),
# with the flow and strategy of the SIMTiX/Vortex out-of-context study
# (C:/work/vortex_syn/dut/project.tcl, OPT_LEVEL 3): Flow_PerfOptimized_High synthesis with
# retiming, Performance_ExtraTimingOpt implementation, AggressiveExplore phys_opt before and
# after routing; vectorless power at a 12.5% toggle rate.
# Configuration (on a copy of FGPU's GPL v3 RTL, outside the repository): 1 CU of 8 PEs
# (N_CU_W = 0), FLOAT_IMPLEMENT = 1 (fadd/fsub, fmul, fdiv, fsqrt, uitofp, fslt; no frsqrt),
# ATOMIC_IMPLEMENT = 1, N_TAG_MANAGERS_W = N_CU_W+1 (FGPU's assertion), FP cores from
# gen_fp_ip.tcl.
#   vivado -mode batch -source baselines/fgpu/synth_fgpu_ooc.tcl -tclargs [MHz] [name]
set mhz  [lindex $argv 0]; if {$mhz eq ""} { set mhz 100 }
set name [lindex $argv 1]; if {$name eq ""} { set name fgpu_1cu_${mhz}mhz }
set SRC C:/work/fgpu_src/FGPU/RTL
set BLD C:/work/fgpu_build
set dir $BLD/syn/$name
file delete -force $dir
file mkdir $dir/rtl
set_param general.maxThreads 2

foreach f [glob $SRC/*.vhd $SRC/*.mif] { file copy $f $dir/rtl/ }
proc subst_file {path re repl} {
    set fh [open $path r]; set t [read $fh]; close $fh
    set n [regsub -all -line $re $t $repl t]
    if {$n == 0} { error "no match for $re in $path" }
    set fh [open $path w]; fconfigure $fh -translation lf; puts -nonewline $fh $t; close $fh
}
set D $dir/rtl/FGPU_definitions.vhd
subst_file $D {(constant N_TAG_MANAGERS_W\s*: natural := N_CU_W)\+0;} {\1+1;}
subst_file $D {(constant FLOAT_IMPLEMENT\s*: natural := )\d+;} {\11;}
subst_file $D {(constant ATOMIC_IMPLEMENT\s*: natural := )\d+;} {\11;}
# the code and kernel-descriptor RAMs read their .mif at elaboration: absolute paths
subst_file $dir/rtl/FGPU.vhd {init_krnl_ram\("krnl_ram.mif"\)} "init_krnl_ram(\"$dir/rtl/krnl_ram.mif\")"
subst_file $dir/rtl/FGPU.vhd {init_CRAM\("cram.mif", } "init_CRAM(\"$dir/rtl/cram.mif\", "

create_project fgpu_syn $dir/prj -part xczu9eg-ffvb1156-2-e -force
set_property target_language VHDL [current_project]
set rtl {}
foreach f [glob $dir/rtl/*.vhd] {
    if {[regexp {FGPU_tb|global_mem|FGPU_simulation_pkg} $f]} continue
    lappend rtl $f
}
add_files -norecurse $rtl
set_property file_type {VHDL 2008} [get_files $rtl]
foreach x [glob $BLD/ip/*/*.xci] {
    if {[string match *frsqrt* $x]} continue
    add_files -norecurse $x
}
set_property top FGPU [current_fileset]
set xdc $dir/fgpu.xdc
set fh [open $xdc w]
puts $fh "create_clock -name clk -period [format %.3f [expr {1000.0 / $mhz}]] \[get_ports clk\]"
close $fh
add_files -fileset constrs_1 -norecurse $xdc
update_compile_order -fileset sources_1

set_property strategy Flow_PerfOptimized_High [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]
set_property strategy Performance_ExtraTimingOpt [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
open_run synth_1
report_utilization -file $dir/post_synth_util.rpt
close_design
launch_runs impl_1 -jobs 2
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }
open_run impl_1
report_utilization -file $dir/post_impl_util.rpt
report_utilization -hierarchical -file $dir/post_impl_util_hier.rpt
report_timing_summary -max_paths 10 -file $dir/timing.rpt
reset_switching_activity -all
set_switching_activity -default_toggle_rate 0.125 -default_static_probability 0.5
set_switching_activity -deassert_resets
report_power -file $dir/power_vectorless.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set T [expr {1000.0 / $mhz}]
set fh [open $dir/summary.txt w]
puts $fh "period_ns $T"
puts $fh "wns_ns $wns"
puts $fh "fmax_mhz [format %.1f [expr {1000.0 / ($T - $wns)}]]"
close $fh
puts "SYNTHDONE $name WNS $wns"
