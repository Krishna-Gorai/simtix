# vortex_sources.tcl - add the board build's Vortex design to the open project: the
# staged sources (syn/gen_sources.sh: project_1/sources.txt with Vortex's defines,
# FPU_TYPE=DSP), rtl/vortex_ps_top.sv + rtl/vortex_ps_wrap.v, their headers, and the
# Xilinx floating-point IPs. Sourced by create_bd_vortex.tcl and tb/sim_xsim_vortex.tcl
# with $here (baselines/vortex), $stage and $proj_dir set.

# ── Vortex sources (sources.txt: files, +incdir+, +define+, relative to the stage) ──
source [file join [file dirname $stage] scripts parse_vcs_list.tcl]
set cwd [pwd]
cd $stage
set vlist [parse_vcs_list project_1/sources.txt]
cd $cwd
set srcs {}
foreach f [lindex $vlist 0] { lappend srcs [file normalize [file join $stage $f]] }
set incs {}
foreach d [lindex $vlist 1] { lappend incs [file normalize [file join $stage $d]] }
set defs [lindex $vlist 2]
add_files -norecurse $srcs
add_files -norecurse [list [file join $here rtl vortex_ps_top.sv] [file join $here rtl vortex_ps_wrap.v]]
set_property include_dirs $incs [current_fileset]
set_property verilog_define $defs [current_fileset]
# A module-reference cell needs every included header in the project as a file.
set hdrs {}
foreach d $incs { set hdrs [concat $hdrs [glob -nocomplain -directory $d -types f *.vh *.svh]] }
set hdrs [lsort -unique $hdrs]
set have [get_files -quiet $hdrs]
set new {}
foreach h $hdrs { if {[lsearch -exact $have [file normalize $h]] < 0} { lappend new $h } }
if {[llength $new]} { add_files -norecurse $new }
if {[llength $hdrs]} { set_property file_type {Verilog Header} [get_files $hdrs] }
puts "Vortex: [llength $srcs] sources, [llength $incs] include dirs, [llength $hdrs] headers"
puts "Verilog defines: $defs"

# ── Floating-point IPs (Vortex hw/scripts/xilinx_ip_gen.tcl) ─────────────────────
set ipd [file join $proj_dir fpu_ip]
file mkdir $ipd
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name xil_fdiv -dir $ipd
set_property -dict [list CONFIG.Component_Name {xil_fdiv} CONFIG.Operation_Type {Divide} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.C_Has_DIVIDE_BY_ZERO {true} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.C_Mult_Usage {No_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.C_Latency {28} CONFIG.C_Rate {1}] [get_ips xil_fdiv]
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name xil_fsqrt -dir $ipd
set_property -dict [list CONFIG.Component_Name {xil_fsqrt} CONFIG.Operation_Type {Square_root} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.C_Mult_Usage {No_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.C_Latency {28} CONFIG.C_Rate {1}] [get_ips xil_fsqrt]
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name xil_fma -dir $ipd
set_property -dict [list CONFIG.Component_Name {xil_fma} CONFIG.Operation_Type {FMA} CONFIG.Add_Sub_Value {Add} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Has_UNDERFLOW {true} CONFIG.C_Has_OVERFLOW {true} CONFIG.C_Has_INVALID_OP {true} CONFIG.Has_A_TUSER {false} CONFIG.A_Precision_Type {Single} CONFIG.C_A_Exponent_Width {8} CONFIG.C_A_Fraction_Width {24} CONFIG.Result_Precision_Type {Single} CONFIG.C_Result_Exponent_Width {8} CONFIG.C_Result_Fraction_Width {24} CONFIG.C_Mult_Usage {Medium_Usage} CONFIG.Has_RESULT_TREADY {false} CONFIG.C_Latency {16} CONFIG.C_Rate {1} CONFIG.A_TUSER_Width {1}] [get_ips xil_fma]
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name xil_fmul -dir $ipd
set_property -dict [list CONFIG.Operation_Type {Multiply} CONFIG.A_Precision_Type {Single} CONFIG.Result_Precision_Type {Single} CONFIG.Has_RESULT_TREADY {false} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Rate {1} CONFIG.C_Mult_Usage {Full_Usage}] [get_ips xil_fmul]
create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name xil_fadd -dir $ipd
set_property -dict [list CONFIG.Operation_Type {Add_Subtract} CONFIG.A_Precision_Type {Single} CONFIG.Result_Precision_Type {Single} CONFIG.Has_RESULT_TREADY {false} CONFIG.Flow_Control {NonBlocking} CONFIG.Has_ACLKEN {true} CONFIG.C_Rate {1} CONFIG.C_Mult_Usage {Full_Usage}] [get_ips xil_fadd]
generate_target all [get_ips]

