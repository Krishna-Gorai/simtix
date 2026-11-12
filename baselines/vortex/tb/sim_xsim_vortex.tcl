# sim_xsim_vortex.tcl - behavioural xsim of the board build's exact configuration
# (vortex_ps_wrap, the staged Vortex sources with FPU_TYPE=DSP, the Xilinx floating-point
# IPs: vortex_sources.tcl, as create_bd_vortex.tcl) with tb_vortex_xsim.sv, one case per
# run (gen_xsim_case.py). Run from baselines/vortex/tb (Vivado from PowerShell,
# NoDefaultCurrentDirectoryInExePath cleared):
#
#   vivado -mode batch -nojournal -log sim_<case>.log -source sim_xsim_vortex.tcl \
#          -tclargs <case dir> [src<staged dir>]
set casedir [file normalize [lindex $argv 0]]
set stage C:/work/vortex_syn/zcu102_1c8w8t
foreach a $argv { if {[regexp {^src(.+)$} $a -> d]} { set stage $d } }
set_param general.maxThreads 2
set tbdir    [file dirname [file normalize [info script]]]
set here     [file dirname $tbdir]
set proj_dir [file join $tbdir xsim_proj_[file tail $casedir]]

create_project vx_xsim $proj_dir -part xczu9eg-ffvb1156-2-e -force
source [file join $here vortex_sources.tcl]
set_property top vortex_ps_wrap [current_fileset]

add_files -fileset sim_1 -norecurse [file join $tbdir tb_vortex_xsim.sv]
set_property top tb_vortex_xsim [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property verilog_define [get_property verilog_define [current_fileset]] [get_filesets sim_1]
set_property include_dirs [get_property include_dirs [current_fileset]] [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} -value "-testplusarg CASE=$casedir" -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.debug_level} -value {off} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
puts "========== XSIM DONE: $casedir =========="
