# create_bd_ps.tcl  -  v2 board build: SIMTiX as a Zynq UltraScale+ PS peripheral
#
#   ARM A53 --M_AXI_HPM0_FPD--> SmartConnect --AXI4-Lite--> simt_ps_wrap.s_axi
#   simt_ps_wrap.m_axi (128-bit AXI4) --> S_AXI_HP0_FPD --> DDR4
#
# Targets: ZCU102 (xczu9eg-ffvb1156-2-e, the default) or ZCU104
# (xczu7ev-ffvc1156-2-e); the PS takes the board preset, PL clock 0 = 100 MHz.
# The accelerator's AXI4-Lite window is at 0xA000_0000 (64 KB, see
# rtl/soc/simt_ps_top.sv). Run from fpga/ (launch Vivado from PowerShell):
#
#   vivado -mode batch -source create_bd_ps.tcl -tclargs [build] [zcu102|zcu104] [tag<name>]
#          [warps<n>] [l1kb<n>] [mshr<n>] [mtags<n>]
#
# Without "build" only the project and block design are created. The ZCU102
# writes simtix_ps_zcu102/, reports_ps_zcu102/ and simtix_ps_zcu102.xsa; the
# ZCU104 keeps the names simtix_ps/, reports_ps/ and simtix_ps.xsa.

set build [expr {[lsearch -exact $argv build] >= 0}]
set board [expr {[lsearch -exact $argv zcu104] >= 0 ? "zcu104" : "zcu102"}]
array set part {zcu102 xczu9eg-ffvb1156-2-e zcu104 xczu7ev-ffvc1156-2-e}
array set bpart {zcu102 xilinx.com:zcu102:part0:3.4 zcu104 xilinx.com:zcu104:part0:1.1}
set sfx [expr {$board eq "zcu104" ? "" : "_$board"}]
# Optional tag<name> (no '=': cmd.exe splits arguments there) keeps a variant's
# project, reports and XSA apart, e.g. "tagv3b2" -> simtix_ps_v3b2/.
foreach a $argv { if {[regexp {^tag(\w+)$} $a -> t]} { append sfx "_$t" } }
# Optional warps<n> (SIMTIX_NUM_WARPS, default 4), l1kb<n> (SIMTIX_L1_KB, 16), mshr<n>
# (SIMTIX_L1_MSHR, 4), mtags<n> (SIMTIX_MEM_TAGS, 8), e.g. "warps8 l1kb64 mshr16 mtags16".
set defs {}
array set dname {warps SIMTIX_NUM_WARPS l1kb SIMTIX_L1_KB mshr SIMTIX_L1_MSHR mtags SIMTIX_MEM_TAGS}
foreach a $argv {
    if {[regexp {^(warps|l1kb|mshr|mtags)(\d+)$} $a -> k n]} { lappend defs $dname($k)=$n }
}
puts "========== board $board ($part($board)) =========="

set_param general.maxThreads 2
set proj_dir [file normalize ./simtix_ps$sfx]
set rtl      [file normalize ../rtl]

create_project simtix_ps $proj_dir -part $part($board) -force
set_property board_part $bpart($board) [current_project]

add_files -norecurse [list \
    $rtl/accel/simtix_pkg.sv $rtl/accel/mmio_regs.sv \
    $rtl/accel/simt_fpu.sv $rtl/accel/fp_divsqrt.sv \
    $rtl/accel/mem_engine.sv $rtl/accel/warp_pool.sv $rtl/accel/simt_accel.sv \
    $rtl/accel/l1_dcache.sv $rtl/accel/axi_line_master.sv \
    $rtl/soc/simt_ps_top.sv $rtl/soc/simt_ps_wrap.v ]
if {[llength $defs]} {
    set_property verilog_define $defs [get_filesets sources_1]
    puts "Verilog defines: $defs"
}
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
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] $ps

set simt [create_bd_cell -type module -reference simt_ps_wrap simt_0]
puts "PL clock 0: [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]] Hz"
set sc   [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
set rstc [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl0]

# Clock and reset
set clk [get_bd_pins $ps/pl_clk0]
connect_bd_net $clk [get_bd_pins $ps/maxihpm0_fpd_aclk] [get_bd_pins $ps/saxihp0_fpd_aclk] \
    [get_bd_pins $sc/aclk] [get_bd_pins $simt/clk] [get_bd_pins $rstc/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rstc/ext_reset_in]
connect_bd_net [get_bd_pins $rstc/peripheral_aresetn] [get_bd_pins $sc/aresetn] \
    [get_bd_pins $simt/aresetn]

# Host path and data path
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $simt/s_axi]
connect_bd_intf_net [get_bd_intf_pins $simt/m_axi] [get_bd_intf_pins $ps/S_AXI_HP0_FPD]

# Addresses: the accelerator window at 0xA000_0000; the HP0 port reaches DDR4.
assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data] -filter {NAME =~ "*simt_0*"}]
set_property offset 0xA0000000 $seg
set_property range 64K $seg

validate_bd_design
save_bd_design
puts "========== ADDRESS MAP =========="
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces]] {
    puts [format "  %-60s %s %s" [get_property NAME $s] [get_property OFFSET $s] [get_property RANGE $s]]
}

# With Verilog defines, synthesise the block design globally (inside synth_1, which
# uses the fileset's defines) instead of as out-of-context IP runs, whose use of the
# project defines is not guaranteed.
if {[llength $defs]} { set_property synth_checkpoint_mode None [get_files system.bd] }
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file normalize $proj_dir/simtix_ps.gen/sources_1/bd/system/hdl/system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {!$build} { puts "BD created (no build requested)"; return }

# ── Build ────────────────────────────────────────────────────────────────────────
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
# The design is wire-bound (routing is ~75% of its long paths): finish with a
# post-route physical optimisation pass.
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }

open_run impl_1
set out [file normalize ./reports_ps$sfx]
file mkdir $out
report_utilization    -file $out/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out/post_route_timing.rpt
report_power          -file $out/post_route_power.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts [format "========== BOARD BUILD ($board): WNS %+.3f ns at 100 MHz ==========" $wns]

write_hw_platform -fixed -include_bit -force [file normalize ./simtix_ps$sfx.xsa]
puts "XSA written: [file normalize ./simtix_ps$sfx.xsa]"
