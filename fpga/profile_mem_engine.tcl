# profile_mem_engine.tcl - where the memory engine's LUTs go (docs/lanes16_plan.md, phase 5).
# Out-of-context synthesis of mem_engine alone, configured as the board's warp pool builds
# it (NC = 2 contexts per warp, AGG = 1, APAR = 0, BYP = 0, 16 tags), on the ZCU102 part,
# then every LUT and MUXF cell grouped by the RTL signal it was named after (synthesis
# names a LUT after the net it drives, e.g. dmem_wdata[37]_INST_0_i_2 -> dmem_wdata).
# No RTL change. Run from fpga/:
#
#   vivado -mode batch -source profile_mem_engine.tcl -tclargs <lanes> <warps> [ctx<n>]
#
# ctx<n> overrides the context count (default 2 * warps). Writes
# reports_me_profile/L<lanes>_W<warps>[_C<n>]/{profile.csv,util.rpt} and prints
#   MEPROF,<group>,<LUTs>,<MUXF7+F8>      (largest first)
#   METOTAL,lanes,warps,contexts,LUT,FF,LUTRAM

if {[llength $argv] < 2} { puts "usage: -tclargs <lanes> <warps> \[ctx<n>\]"; exit 1 }
set lanes [lindex $argv 0]
set warps [lindex $argv 1]
set nc    [expr {2 * $warps}]
foreach a [lrange $argv 2 end] { if {[regexp {^ctx(\d+)$} $a -> n]} { set nc $n } }

set_param general.maxThreads 2
set_param synth.maxThreads 1

set part    xczu9eg-ffvb1156-2-e
set rtl     [file normalize ../rtl/accel]
set tag     L${lanes}_W${warps}
if {$nc != 2 * $warps} { append tag _C$nc }
set out_dir [file normalize ./reports_me_profile/$tag]
file mkdir $out_dir

read_verilog -sv [list $rtl/simtix_pkg.sv $rtl/mem_engine.sv]
set xdc $out_dir/ooc.xdc
set f [open $xdc w]
puts $f "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $f
read_xdc -mode out_of_context $xdc

synth_design -top mem_engine -part $part -mode out_of_context -flatten_hierarchy rebuilt \
    -verilog_define SIMTIX_NUM_LANES=$lanes -verilog_define SIMTIX_NUM_WARPS=$warps \
    -verilog_define SIMTIX_L1_KB=64 -verilog_define SIMTIX_L1_MSHR=16 -verilog_define SIMTIX_MEM_TAGS=16 \
    -generic NC=$nc -generic AGG=1 -generic APAR=0 -generic BYP=0

report_utilization -file $out_dir/util.rpt

# group name of a cell: strip bus indices, Vivado's _i_<n>/_INST_<n>/__<n> suffixes and
# hierarchy (loops and generate blocks keep their base signal name)
proc group_of {name} {
    set n [lindex [split $name /] end]
    regsub -all {\[[0-9]+\]} $n {} n
    regsub -all {(_i_[0-9]+|_INST_[0-9]+|__[0-9]+|_rep|_bret|_fret)+} $n {} n
    regsub -all {_[0-9]+$} $n {} n
    return $n
}
array set lut {}
array set muxf {}
foreach c [get_cells -hier -filter {REF_NAME =~ LUT*}] {
    set g [group_of [get_property NAME $c]]
    if {![info exists lut($g)]} { set lut($g) 0; set muxf($g) 0 }
    incr lut($g)
}
foreach c [get_cells -hier -filter {REF_NAME =~ MUXF*}] {
    set g [group_of [get_property NAME $c]]
    if {![info exists lut($g)]} { set lut($g) 0; set muxf($g) 0 }
    incr muxf($g)
}
set rows {}
foreach g [array names lut] { lappend rows [list $g $lut($g) $muxf($g)] }
set rows [lsort -integer -decreasing -index 1 $rows]
set f [open $out_dir/profile.csv w]
puts $f "group,LUTs,MUXF"
foreach r $rows { puts $f [join $r ,] }
close $f
foreach r [lrange $rows 0 39] { puts "MEPROF,[join $r ,]" }

set nlut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set nff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set nram [llength [get_cells -hier -filter {REF_NAME =~ RAM*}]]
puts "METOTAL,$lanes,$warps,$nc,$nlut,$nff,$nram"
