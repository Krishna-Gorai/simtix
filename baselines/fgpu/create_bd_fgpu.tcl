# create_bd_fgpu.tcl - FGPU (1 CU x 8 PEs, FP32 + atomics) as a ZCU102 PS peripheral
# (docs/fgpu_plan.md, phase 0 step 4), the block design of baselines/vortex/create_bd_vortex.tcl:
#
#   ARM A53 --M_AXI_HPM0_FPD--> SmartConnect --AXI4-Lite--> fgpu_ps_wrap.s_axi (0xA000_0000, 64 KB)
#   fgpu_ps_wrap.m_axi (FGPU's m0: 64-bit AXI4, 6-bit ID) --> S_AXI_HP0_FPD (64-bit) --> DDR4
#
# FGPU is GPL v3: its RTL is copied and configured in C:/work/fgpu_build/board/rtl (outside the
# repository) exactly as sim_fgpu_ps.tcl's tested configuration: FLOAT_IMPLEMENT = 1,
# ATOMIC_IMPLEMENT = 1, N_TAG_MANAGERS_W = N_CU_W+1, the .mif files by absolute path, and the
# floating-point cores regenerated for the XCZU9EG by gen_fp_ip.tcl (C:/work/fgpu_build/ip).
# Run from baselines/fgpu, Vivado launched from PowerShell with NoDefaultCurrentDirectoryInExePath
# cleared:
#   vivado -mode batch -nojournal -log create_bd_fgpu.log -source create_bd_fgpu.tcl \
#          -tclargs [build] [mhz<n>] [tag<name>]
# PL clock: 1.5 GHz / integer; FGPU's out-of-context Fmax on the XCZU9EG is 187.5 MHz, so the
# default is mhz150 (1.5 GHz / 10). Outputs: fgpu_ps_zcu102[_tag]/ (project),
# reports_ps_zcu102[_tag]/, fgpu_ps_zcu102[_tag].xsa.

set build [expr {[lsearch -exact $argv build] >= 0}]
set mhz 150
foreach a $argv { if {[regexp {^mhz(\d+)$} $a -> n]} { set mhz $n } }
set sfx ""
foreach a $argv { if {[regexp {^tag(\w+)$} $a -> t]} { append sfx "_$t" } }
set part  xczu9eg-ffvb1156-2-e
set bpart xilinx.com:zcu102:part0:3.4
set SRC C:/work/fgpu_src/FGPU/RTL
set BLD C:/work/fgpu_build

set_param general.maxThreads 2
set here     [file dirname [file normalize [info script]]]
set proj_dir [file join $here fgpu_ps_zcu102$sfx]

# ── FGPU's RTL, configured (as sim_fgpu_ps.tcl) ─────────────────────────────────────
set rdir $BLD/board$sfx/rtl
file delete -force $BLD/board$sfx
file mkdir $rdir
foreach f [glob $SRC/*.vhd $SRC/*.mif] { file copy $f $rdir/ }
proc subst_file {path re repl} {
    set fh [open $path r]; set t [read $fh]; close $fh
    set k [regsub -all -line $re $t $repl t]
    if {$k == 0} { error "no match for $re in $path" }
    set fh [open $path w]; fconfigure $fh -translation lf; puts -nonewline $fh $t; close $fh
}
set D $rdir/FGPU_definitions.vhd
subst_file $D {(constant N_TAG_MANAGERS_W\s*: natural := N_CU_W)\+0;} {\1+1;}
subst_file $D {(constant FLOAT_IMPLEMENT\s*: natural := )\d+;} {\11;}
subst_file $D {(constant ATOMIC_IMPLEMENT\s*: natural := )\d+;} {\11;}
subst_file $rdir/FGPU.vhd {init_krnl_ram\("krnl_ram.mif"\)} "init_krnl_ram(\"$rdir/krnl_ram.mif\")"
subst_file $rdir/FGPU.vhd {init_CRAM\("cram.mif", } "init_CRAM(\"$rdir/cram.mif\", "

create_project fgpu_ps $proj_dir -part $part -force
set_property board_part $bpart [current_project]
set rtl {}
foreach f [glob $rdir/*.vhd] {
    if {[regexp {FGPU_tb|global_mem|FGPU_simulation_pkg} $f]} continue
    lappend rtl $f
}
add_files -norecurse $rtl
set_property file_type {VHDL 2008} [get_files $rtl]
add_files -norecurse [file join $here rtl fgpu_ps_wrap.v]
foreach x [glob $BLD/ip/*/*.xci] { add_files -norecurse $x }
set_property top fgpu_ps_wrap [current_fileset]
update_compile_order -fileset sources_1

# ── Block design ─────────────────────────────────────────────────────────────────────
create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {64} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $mhz \
] $ps

set fg [create_bd_cell -type module -reference fgpu_ps_wrap fgpu_0]
set fhz [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]]
puts "PL clock 0: $fhz Hz (requested $mhz MHz)"
set sc   [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
set rstc [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl0]

set clk [get_bd_pins $ps/pl_clk0]
connect_bd_net $clk [get_bd_pins $ps/maxihpm0_fpd_aclk] [get_bd_pins $ps/saxihp0_fpd_aclk] \
    [get_bd_pins $sc/aclk] [get_bd_pins $fg/clk] [get_bd_pins $rstc/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rstc/ext_reset_in]
connect_bd_net [get_bd_pins $rstc/peripheral_aresetn] [get_bd_pins $sc/aresetn] [get_bd_pins $fg/aresetn]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $fg/s_axi]
connect_bd_intf_net [get_bd_intf_pins $fg/m_axi] [get_bd_intf_pins $ps/S_AXI_HP0_FPD]

assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces $ps/Data] -filter {NAME =~ "*fgpu_0*"}]
set_property offset 0xA0000000 $seg
set_property range 64K $seg

validate_bd_design
foreach {p w} {m_axi_awid 6 m_axi_bid 6 m_axi_arid 6 m_axi_rid 6 m_axi_wdata 64 m_axi_rdata 64 s_axi_awaddr 16} {
    set got [expr {[get_property LEFT [get_bd_pins $fg/$p]] + 1}]
    if {$got != $w} { error "fgpu_0/$p is $got bits, expected $w" }
}
save_bd_design
puts "========== ADDRESS MAP =========="
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces]] {
    puts [format "  %-60s %s %s" [get_property NAME $s] [get_property OFFSET $s] [get_property RANGE $s]]
}
set_property synth_checkpoint_mode None [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file normalize $proj_dir/fgpu_ps.gen/sources_1/bd/system/hdl/system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {!$build} { puts "BD created (no build requested)"; return }

# ── Build ────────────────────────────────────────────────────────────────────────────
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
puts [format "========== FGPU BOARD BUILD: WNS %+.3f ns at %.2f MHz ==========" $wns [expr {$fhz / 1e6}]]
write_hw_platform -fixed -include_bit -force [file join $here fgpu_ps_zcu102$sfx.xsa]
puts "XSA written: [file join $here fgpu_ps_zcu102$sfx.xsa]"
