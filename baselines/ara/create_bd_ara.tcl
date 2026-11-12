# create_bd_ara.tcl - Ara + CVA6 (2 lanes, VLEN 2048, FP64/32/16) as a ZCU102 PS peripheral
#
#   ARM A53 --M_AXI_HPM0_FPD--> SmartConnect --AXI4-Lite--> ara_ps_wrap.s_axi (0xA000_0000)
#   ara_ps_wrap.m_axi (64-bit AXI4, 5-bit ID) --> S_AXI_HP0_FPD --> DDR4 (window 0x4000_0000)
#
# Same block design as SIMTiX's fpga/create_bd_ps.tcl. Run from baselines/ara (Vivado
# launched from PowerShell, NoDefaultCurrentDirectoryInExePath cleared):
#
#   vivado -mode batch -nojournal -log create_bd_ara.log -source create_bd_ara.tcl \
#          -tclargs [build] [mhz<n>] [tag<name>]
#
# Sources: C:/work/ara/vivado_sources_2l.tcl (Bender, see synth_ara_ooc.tcl), which also
# sets the include directories and defines (NR_LANES=2 VLEN=2048 ...) of the fileset.
# PL clock: the PS divides 1.5 GHz by an integer; Ara's out-of-context Fmax is 80.7 MHz,
# so mhz79 (1.5 GHz / 19 = 78.95 MHz) is the default.

set build [expr {[lsearch -exact $argv build] >= 0}]
set mhz 79
foreach a $argv { if {[regexp {^mhz(\d+)$} $a -> n]} { set mhz $n } }
set sfx ""
foreach a $argv { if {[regexp {^tag(\w+)$} $a -> t]} { append sfx "_$t" } }
set part  xczu9eg-ffvb1156-2-e
set bpart xilinx.com:zcu102:part0:3.4

set_param general.maxThreads 2
set here     [file dirname [file normalize [info script]]]
set proj_dir [file join $here ara_ps_zcu102$sfx]

create_project ara_ps $proj_dir -part $part -force
set_property board_part $bpart [current_project]

source C:/work/ara/vivado_sources_2l.tcl
add_files -norecurse [list [file join $here rtl ara_ps_top.sv] [file join $here rtl ara_ps_wrap.v]]
# A module-reference cell needs every included header in the project as a file, not
# only on the include path: add the .svh/.vh under the fileset's include directories.
proc find_hdrs {dir} {
    set hits [glob -nocomplain -directory $dir -types f *.svh *.vh]
    foreach d [glob -nocomplain -directory $dir -types d *] { set hits [concat $hits [find_hdrs $d]] }
    return $hits
}
set hdrs {}
foreach d [get_property include_dirs [current_fileset]] { set hdrs [concat $hdrs [find_hdrs $d]] }
set hdrs [lsort -unique $hdrs]
set have [get_files -quiet $hdrs]
set new {}
foreach h $hdrs { if {[lsearch -exact $have [file normalize $h]] < 0} { lappend new $h } }
if {[llength $new]} { add_files -norecurse $new }
set_property file_type {Verilog Header} [get_files $hdrs]
puts "headers in the project: [llength $hdrs]"
set_property top ara_ps_wrap [current_fileset]
update_compile_order -fileset sources_1
puts "Verilog defines: [get_property verilog_define [current_fileset]]"

# ── Block design ─────────────────────────────────────────────────────────────────
create_bd_design system

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {64} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $mhz \
] $ps

set ara [create_bd_cell -type module -reference ara_ps_wrap ara_0]
set fhz [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]]
puts "PL clock 0: $fhz Hz (requested $mhz MHz)"
set sc   [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
set rstc [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl0]

set clk [get_bd_pins $ps/pl_clk0]
connect_bd_net $clk [get_bd_pins $ps/maxihpm0_fpd_aclk] [get_bd_pins $ps/saxihp0_fpd_aclk] \
    [get_bd_pins $sc/aclk] [get_bd_pins $ara/clk] [get_bd_pins $rstc/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rstc/ext_reset_in]
connect_bd_net [get_bd_pins $rstc/peripheral_aresetn] [get_bd_pins $sc/aresetn] \
    [get_bd_pins $ara/aresetn]

connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $ara/s_axi]
connect_bd_intf_net [get_bd_intf_pins $ara/m_axi] [get_bd_intf_pins $ps/S_AXI_HP0_FPD]

assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data] -filter {NAME =~ "*ara_0*"}]
set_property offset 0xA0000000 $seg
set_property range 64K $seg

validate_bd_design
foreach {p w} {m_axi_awid 5 m_axi_bid 5 m_axi_arid 5 m_axi_rid 5 m_axi_wdata 64 m_axi_rdata 64} {
    set got [expr {[get_property LEFT [get_bd_pins $ara/$p]] + 1}]
    if {$got != $w} { error "ara_0/$p is $got bits, expected $w" }
}
save_bd_design
puts "========== ADDRESS MAP =========="
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces]] {
    puts [format "  %-60s %s %s" [get_property NAME $s] [get_property OFFSET $s] [get_property RANGE $s]]
}

# The Bender defines must reach the module-reference cell: synthesise the block design
# inside synth_1 (global), not as out-of-context IP runs.
set_property synth_checkpoint_mode None [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file normalize $proj_dir/ara_ps.gen/sources_1/bd/system/hdl/system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {!$build} { puts "BD created (no build requested)"; return }

# ── Build ────────────────────────────────────────────────────────────────────────
set pre [file join $proj_dir synth_pre.tcl]
set f [open $pre w]
puts $f "set_param synth.maxThreads 1"
puts $f "set_param general.maxThreads 2"
close $f
set_property STEPS.SYNTH_DESIGN.TCL.PRE $pre [get_runs synth_1]
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }

open_run impl_1
set out [file join $here reports_ps_zcu102$sfx]
file mkdir $out
report_utilization    -file $out/post_route_util.rpt
report_utilization    -hierarchical -hierarchical_depth 5 -file $out/post_route_util_hier.rpt
report_timing_summary -max_paths 10 -file $out/post_route_timing.rpt
report_power          -file $out/post_route_power.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts [format "========== ARA BOARD BUILD: WNS %+.3f ns at %.2f MHz ==========" $wns [expr {$fhz / 1e6}]]

write_hw_platform -fixed -include_bit -force [file join $here ara_ps_zcu102$sfx.xsa]
puts "XSA written: [file join $here ara_ps_zcu102$sfx.xsa]"
