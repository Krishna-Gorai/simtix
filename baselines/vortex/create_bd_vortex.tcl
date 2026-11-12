# create_bd_vortex.tcl - Vortex 3.0 (1 core, 8 warps x 8 threads, RV32IMAF + A) as a ZCU102
# PS peripheral
#
#   ARM A53 --M_AXI_HPM0_FPD--> SmartConnect --AXI4-Lite--> vortex_ps_wrap.s_axi (0xA000_0000)
#   vortex_ps_wrap.m_axi (128-bit AXI4, 6-bit ID, always 0) --> S_AXI_HP0_FPD --> DDR4
#
# The same block design as SIMTiX's fpga/create_bd_ps.tcl and baselines/ara. Run from
# baselines/vortex (Vivado launched from PowerShell, NoDefaultCurrentDirectoryInExePath
# cleared), after gen_sources.sh has staged the sources:
#
#   vivado -mode batch -nojournal -log create_bd_vortex.log -source create_bd_vortex.tcl \
#          -tclargs [build] [mhz<n>] [tag<name>] [src<staged dir>]
#
# Sources: Vortex's preprocessed tree (syn/gen_sources.sh, default
# C:/work/vortex_syn/zcu102_1c8w8t: project_1/sources.txt with the defines, FPU_TYPE=DSP,
# i.e. the Xilinx floating-point IPs, Vortex's FPGA default) and rtl/vortex_ps_top.sv +
# rtl/vortex_ps_wrap.v. The floating-point IPs are created here with the settings of
# Vortex's hw/scripts/xilinx_ip_gen.tcl (latencies: FMA 16, div/sqrt 28).
# PL clock: the PS divides 1.5 GHz by an integer; the out-of-context Fmax of this
# configuration on the xczu7ev (-2) is 135.9 MHz, so mhz125 (1.5 GHz / 12) is the default.

set build [expr {[lsearch -exact $argv build] >= 0}]
set mhz 125
foreach a $argv { if {[regexp {^mhz(\d+)$} $a -> n]} { set mhz $n } }
set sfx ""
foreach a $argv { if {[regexp {^tag(\w+)$} $a -> t]} { append sfx "_$t" } }
set stage C:/work/vortex_syn/zcu102_1c8w8t
foreach a $argv { if {[regexp {^src(.+)$} $a -> d]} { set stage $d } }
set part  xczu9eg-ffvb1156-2-e
set bpart xilinx.com:zcu102:part0:3.4

set_param general.maxThreads 2
set here     [file dirname [file normalize [info script]]]
set proj_dir [file join $here vortex_ps_zcu102$sfx]

create_project vortex_ps $proj_dir -part $part -force
set_property board_part $bpart [current_project]

source [file join $here vortex_sources.tcl]

set_property top vortex_ps_wrap [current_fileset]
update_compile_order -fileset sources_1

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
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $mhz \
] $ps

set vx [create_bd_cell -type module -reference vortex_ps_wrap vortex_0]
set fhz [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]]
puts "PL clock 0: $fhz Hz (requested $mhz MHz)"
set sc   [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
set rstc [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl0]

set clk [get_bd_pins $ps/pl_clk0]
connect_bd_net $clk [get_bd_pins $ps/maxihpm0_fpd_aclk] [get_bd_pins $ps/saxihp0_fpd_aclk] \
    [get_bd_pins $sc/aclk] [get_bd_pins $vx/clk] [get_bd_pins $rstc/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rstc/ext_reset_in]
connect_bd_net [get_bd_pins $rstc/peripheral_aresetn] [get_bd_pins $sc/aresetn] \
    [get_bd_pins $vx/aresetn]

connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $vx/s_axi]
connect_bd_intf_net [get_bd_intf_pins $vx/m_axi] [get_bd_intf_pins $ps/S_AXI_HP0_FPD]

assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data] -filter {NAME =~ "*vortex_0*"}]
set_property offset 0xA0000000 $seg
set_property range 64K $seg

validate_bd_design
foreach {p w} {m_axi_awid 6 m_axi_bid 6 m_axi_arid 6 m_axi_rid 6 m_axi_wdata 128 m_axi_rdata 128} {
    set got [expr {[get_property LEFT [get_bd_pins $vx/$p]] + 1}]
    if {$got != $w} { error "vortex_0/$p is $got bits, expected $w" }
}
save_bd_design
puts "========== ADDRESS MAP =========="
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces]] {
    puts [format "  %-60s %s %s" [get_property NAME $s] [get_property OFFSET $s] [get_property RANGE $s]]
}

# The defines must reach the module-reference cell: synthesise the block design inside
# synth_1 (global), not as out-of-context IP runs.
set_property synth_checkpoint_mode None [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file normalize $proj_dir/vortex_ps.gen/sources_1/bd/system/hdl/system_wrapper.v]
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
puts [format "========== VORTEX BOARD BUILD: WNS %+.3f ns at %.2f MHz ==========" $wns [expr {$fhz / 1e6}]]

write_hw_platform -fixed -include_bit -force [file join $here vortex_ps_zcu102$sfx.xsa]
puts "XSA written: [file join $here vortex_ps_zcu102$sfx.xsa]"
