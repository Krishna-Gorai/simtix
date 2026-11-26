# sim_fgpu_tb.tcl - FGPU's own testbench (RTL/FGPU_tb.vhd) in xsim on Vivado 2025.1 with the
# floating-point cores regenerated for the XCZU9EG (gen_fp_ip.tcl): docs/fgpu_plan.md, phase 0
# step 2. Works on a copy of FGPU's RTL (GPL v3, outside the repository):
#   vivado -mode batch -source baselines/fgpu/sim_fgpu_tb.tcl -tclargs <kernel> <runtime> [float] [atomic]
#   kernel: a value of kernel_type in FGPU_simulation_pkg.vhd (copy, mat_mul, add_float, ...)
#   runtime: xsim run time, e.g. 2ms; float/atomic: set FLOAT_IMPLEMENT/ATOMIC_IMPLEMENT = 1
# The testbench reports "Kernel finished successfully! Size was :N" per problem size and stops
# with a failure on a wrong result; the log is <build>/sim_<kernel>/sim.log.
set kernel  [lindex $argv 0]
set runtime [lindex $argv 1]
set opts    [lrange $argv 2 end]
set SRC  C:/work/fgpu_src/FGPU/RTL
set BLD  C:/work/fgpu_build
set IP   $BLD/ip
set dir  $BLD/sim_$kernel
file delete -force $dir
file mkdir $dir/rtl

# working copy of the RTL, configured
foreach f [glob $SRC/*.vhd $SRC/*.mif] { file copy $f $dir/rtl/ }
proc subst_file {path re repl} {
    set fh [open $path r]; set t [read $fh]; close $fh
    set n [regsub -all -line $re $t $repl t]
    if {$n == 0} { error "no match for $re in $path" }
    set fh [open $path w]; fconfigure $fh -translation lf; puts -nonewline $fh $t; close $fh
}
subst_file $dir/rtl/FGPU_simulation_pkg.vhd {(CONSTANT kernel_name\s*: kernel_type := )\w+;} "\\1$kernel;"
# FGPU's shipped default N_TAG_MANAGERS_W = N_CU_W+0 is 0 at one CU, which FGPU.vhd's own
# assertion rejects ("at least two tag managers"); the comment allows N_CU_W+0 or +1
subst_file $dir/rtl/FGPU_definitions.vhd {(constant N_TAG_MANAGERS_W\s*: natural := N_CU_W)\+0;} {\1+1;}
if {"float" in $opts} {
    subst_file $dir/rtl/FGPU_definitions.vhd {(constant FLOAT_IMPLEMENT\s*: natural := )\d+;} {\11;}
}
if {"atomic" in $opts} {
    subst_file $dir/rtl/FGPU_definitions.vhd {(constant ATOMIC_IMPLEMENT\s*: natural := )\d+;} {\11;}
}

create_project fgpu_sim $dir/prj -part xczu9eg-ffvb1156-2-e -force
set_property target_language VHDL [current_project]
# the floating-point wrappers of FGPU are replaced by the regenerated IP
set rtl [lsearch -all -inline -not [glob $dir/rtl/*.vhd] *FGPU_tb.vhd]
add_files -norecurse $rtl
set_property file_type {VHDL 2008} [get_files $rtl]
foreach x [glob $IP/*/*.xci] { add_files -norecurse $x }
add_files -fileset sim_1 -norecurse $dir/rtl/FGPU_tb.vhd
set_property file_type {VHDL 2008} [get_files $dir/rtl/FGPU_tb.vhd]
add_files -fileset sim_1 -norecurse [glob $dir/rtl/*.mif]
set_property top FGPU_tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value $runtime -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value false -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim -quiet
set log [glob -nocomplain $dir/prj/fgpu_sim.sim/sim_1/behav/xsim/simulate.log]
if {$log ne ""} { file copy -force $log $dir/sim.log }
puts "SIMDONE $kernel"
