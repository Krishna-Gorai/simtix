# create_bd_ps.tcl  -  v2 board build: SIMTiX as a Zynq UltraScale+ PS peripheral
#
#   ARM A53 --M_AXI_HPM0_FPD--> SmartConnect --AXI4-Lite--> simt_ps_wrap.s_axi
#   simt_ps_wrap.m_axi (128-bit AXI4) --> S_AXI_HP0_FPD --> DDR4
#
# Target: ZCU104 (xczu7ev-ffvc1156-2-e), PL clock 0 = 100 MHz. The accelerator's
# AXI4-Lite window is at 0xA000_0000 (64 KB, see rtl/soc/simt_ps_top.sv).
# Run from fpga/ (launch Vivado from PowerShell, not Git Bash):
#
#   vivado -mode batch -source create_bd_ps.tcl                 # project + BD only
#   vivado -mode batch -source create_bd_ps.tcl -tclargs build  # + bitstream + .xsa

set build [expr {[llength $argv] > 0 && [lindex $argv 0] eq "build"}]

set_param general.maxThreads 2
set proj_dir [file normalize ./simtix_ps]
set rtl      [file normalize ../rtl]

create_project simtix_ps $proj_dir -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]

add_files -norecurse [list \
    $rtl/accel/simtix_pkg.sv $rtl/accel/mmio_regs.sv \
    $rtl/accel/simt_fpu.sv $rtl/accel/fp_divsqrt.sv \
    $rtl/accel/mem_engine.sv $rtl/accel/warp_pool.sv $rtl/accel/simt_accel.sv \
    $rtl/accel/l1_dcache.sv $rtl/accel/axi_line_master.sv \
    $rtl/soc/simt_ps_top.sv $rtl/soc/simt_ps_wrap.v ]
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
set out [file normalize ./reports_ps]
file mkdir $out
report_utilization    -file $out/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out/post_route_timing.rpt
report_power          -file $out/post_route_power.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts [format "========== BOARD BUILD: WNS %+.3f ns at 100 MHz ==========" $wns]

write_hw_platform -fixed -include_bit -force [file normalize ./simtix_ps.xsa]
puts "XSA written: [file normalize ./simtix_ps.xsa]"
