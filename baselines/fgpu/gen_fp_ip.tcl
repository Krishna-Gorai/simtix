# gen_fp_ip.tcl - FGPU's floating-point cores regenerated for the ZCU102 (docs/fgpu_plan.md,
# phase 0 step 2). FGPU ships them as Vivado-2016 IP for the 7-series ("zynq", encrypted
# floating_point_v7_1_2 sources), so they are rebuilt here for the XCZU9EG with the same
# entity names, ports and latencies as RTL/floating_point/*.vhd and the *_DELAY constants of
# RTL/FGPU_definitions.vhd:
#   fadd_fsub  add/subtract, operation port, latency 11, full DSP usage
#   fmul       multiply,       latency 8,  full DSP usage
#   fdiv       divide,         latency 28, no DSP
#   fsqrt      square root,    latency 28, no DSP
#   frsqrt     recip. sqrt,    latency 28, full DSP usage (FRSQRT_IMPLEMENT = 0 by default)
#   fslt       compare a < b,  latency 2,  8-bit result
#   uitofp     int32 -> float, latency 5
# All: single precision, non-blocking AXI4-Stream, no ACLKEN/ARESETn/TREADY, speed optimised.
# Run (outside the repository, FGPU is GPL v3):
#   vivado -mode batch -source baselines/fgpu/gen_fp_ip.tcl -tclargs C:/work/fgpu_build/ip
set out [lindex $argv 0]
if {$out eq ""} { set out C:/work/fgpu_build/ip }
file mkdir $out
create_project -in_memory -part xczu9eg-ffvb1156-2-e
set_property target_language VHDL [current_project]

proc fp_ip {name cfg out} {
    create_ip -name floating_point -vendor xilinx.com -library ip -module_name $name -dir $out -force
    set ip [get_ips $name]
    set common [list CONFIG.Flow_Control NonBlocking CONFIG.Has_RESULT_TREADY false \
                    CONFIG.Has_ACLKEN false CONFIG.Has_ARESETn false CONFIG.Maximum_Latency false \
                    CONFIG.C_Optimization Speed_Optimized]
    set_property -dict [concat $cfg $common] $ip
    generate_target {synthesis simulation instantiation_template} $ip
    puts "IP $name: latency [get_property CONFIG.C_Latency $ip], DSP [get_property CONFIG.C_Mult_Usage $ip]"
}

set sp [list CONFIG.A_Precision_Type Single CONFIG.Result_Precision_Type Single]
fp_ip fadd_fsub [concat [list CONFIG.Operation_Type Add_Subtract CONFIG.Add_Sub_Value Both \
                         CONFIG.C_Mult_Usage Full_Usage CONFIG.C_Latency 11] $sp] $out
fp_ip fmul      [concat [list CONFIG.Operation_Type Multiply CONFIG.C_Mult_Usage Full_Usage \
                         CONFIG.C_Latency 8] $sp] $out
fp_ip fdiv      [concat [list CONFIG.Operation_Type Divide CONFIG.C_Mult_Usage No_Usage \
                         CONFIG.C_Latency 28] $sp] $out
fp_ip fsqrt     [concat [list CONFIG.Operation_Type Square_root CONFIG.C_Mult_Usage No_Usage \
                         CONFIG.C_Latency 28] $sp] $out
# frsqrt is unused by default (FRSQRT_IMPLEMENT = 0): a failure here is reported, not fatal
if {[catch {fp_ip frsqrt [concat [list CONFIG.Operation_Type Rec_Square_Root \
                 CONFIG.C_Mult_Usage Full_Usage CONFIG.C_Latency 28] $sp] $out} err]} {
    puts "WARNING: frsqrt not generated: $err"
    catch {remove_files [get_files -quiet frsqrt.xci]}
}
fp_ip fslt      [list CONFIG.Operation_Type Compare CONFIG.C_Compare_Operation Less_Than \
                     CONFIG.A_Precision_Type Single CONFIG.C_Mult_Usage No_Usage CONFIG.C_Latency 2] $out
fp_ip uitofp    [list CONFIG.Operation_Type Fixed_to_float CONFIG.A_Precision_Type Int32 \
                     CONFIG.Result_Precision_Type Single CONFIG.C_Mult_Usage No_Usage \
                     CONFIG.C_Latency 5] $out
puts "done: [llength [get_ips]] IP cores in $out"
