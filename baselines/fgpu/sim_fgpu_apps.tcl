# sim_fgpu_apps.tcl - SIMTiX's simulation cases on FGPU's board wrapper in xsim (tb/tb_fgpu_apps.sv),
# the exact board configuration (as sim_fgpu_ps.tcl): docs/fgpu_plan.md phase 1, before board runs.
#   vivado -mode batch -source baselines/fgpu/sim_fgpu_apps.tcl -tclargs <cases.txt> <code.hex> <words> <tag>
# Log: C:/work/fgpu_build/sim_apps_<tag>/sim.log (FGCASE lines, PASS/FAIL).
lassign $argv cases code codelen tag
set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
set SRC C:/work/fgpu_src/FGPU/RTL
set BLD C:/work/fgpu_build
set dir $BLD/sim_apps_$tag
file delete -force $dir
file mkdir $dir/rtl
foreach f [glob $SRC/*.vhd $SRC/*.mif] { file copy $f $dir/rtl/ }
proc subst_file {path re repl} {
    set fh [open $path r]; set t [read $fh]; close $fh
    set k [regsub -all -line $re $t $repl t]
    if {$k == 0} { error "no match for $re in $path" }
    set fh [open $path w]; fconfigure $fh -translation lf; puts -nonewline $fh $t; close $fh
}
set D $dir/rtl/FGPU_definitions.vhd
subst_file $D {(constant N_TAG_MANAGERS_W\s*: natural := N_CU_W)\+0;} {\1+1;}
subst_file $D {(constant FLOAT_IMPLEMENT\s*: natural := )\d+;} {\11;}
subst_file $D {(constant ATOMIC_IMPLEMENT\s*: natural := )\d+;} {\11;}
subst_file $dir/rtl/FGPU.vhd {init_krnl_ram\("krnl_ram.mif"\)} "init_krnl_ram(\"$dir/rtl/krnl_ram.mif\")"
subst_file $dir/rtl/FGPU.vhd {init_CRAM\("cram.mif", } "init_CRAM(\"$dir/rtl/cram.mif\", "

create_project fgpu_apps_sim $dir/prj -part xczu9eg-ffvb1156-2-e -force
set rtl {}
foreach f [glob $dir/rtl/*.vhd] {
    if {[regexp {FGPU_tb|global_mem|FGPU_simulation_pkg} $f]} continue
    lappend rtl $f
}
add_files -norecurse $rtl
set_property file_type {VHDL 2008} [get_files $rtl]
add_files -norecurse $here/rtl/fgpu_ps_wrap.v
foreach x [glob $BLD/ip/*/*.xci] { add_files -norecurse $x }
add_files -fileset sim_1 -norecurse [list $here/tb/tb_fgpu_apps.sv $repo/tests/axi_mem_model.sv]
set_property top tb_fgpu_apps [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value all -objects [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} \
    -value "-testplusarg CASES=$cases -testplusarg CODE=$code -testplusarg CODELEN=$codelen" \
    -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim -quiet
set log [glob -nocomplain $dir/prj/fgpu_apps_sim.sim/sim_1/behav/xsim/simulate.log]
if {$log ne ""} { file copy -force $log $dir/sim.log }
puts "SIMDONE fgpu_apps $tag"
