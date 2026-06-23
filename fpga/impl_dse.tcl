# impl_dse.tcl  -  placed (OOC) PPA of the FP-enabled accelerator at a given
# (NUM_LANES, NUM_WARPS), for the FP design-space exploration.
#
# Synth Fmax is congestion-blind (it does not place), so the whole point of the
# FP DSE -- whether trimming the FP fabric relieves the routing congestion that
# bounds Fmax -- is invisible without placement. This runs the real place+route
# so the reported Fmax reflects placed routing.
#
#   vivado -mode batch -source impl_dse.tcl -tclargs <lanes> <warps>
#
# Config is passed to elaboration via -verilog_define, RTL untouched. Reports land
# in reports_dse_impl/L<lanes>_W<warps>/, plus a machine-readable line:
#   PLACEDDSE,lanes,warps,LUT,FF,LUTRAM,DSP,BRAM,WNS_ns,Fmax_MHz,Power_W
#
# Host guards (8 GB): maxThreads 2, flatten none, no write_checkpoint; free RAM
# (kill Chrome) before launching. Larger lane counts peak higher -- 16 lanes is
# ~2x the 8-lane fabric and is the most memory-hungry placement.

if {[llength $argv] < 2} { puts "usage: -tclargs <lanes> <warps>"; exit 1 }
set lanes [lindex $argv 0]
set warps [lindex $argv 1]

set_param general.maxThreads 2

set part        xczu7ev-ffvc1156-2-e
set rtl_dir     [file normalize ../rtl/accel]
set out_dir     [file normalize ./reports_dse_impl/L${lanes}_W${warps}]
set clk_period  10.000
file mkdir $out_dir

read_verilog -sv [list \
    $rtl_dir/simtix_pkg.sv \
    $rtl_dir/mmio_regs.sv  \
    $rtl_dir/simt_fpu.sv   \
    $rtl_dir/fp_divsqrt.sv \
    $rtl_dir/warp_pool.sv  \
    $rtl_dir/simt_accel.sv ]
read_xdc [list [file normalize ./constr/simt_accel_ooc.xdc]]

synth_design -top simt_accel -part $part -mode out_of_context \
    -flatten_hierarchy none -retiming \
    -verilog_define SIMTIX_NUM_LANES=$lanes \
    -verilog_define SIMTIX_NUM_WARPS=$warps

opt_design
place_design
phys_opt_design
route_design

report_utilization    -file $out_dir/post_route_util.rpt
report_timing_summary -max_paths 10 -file $out_dir/post_route_timing.rpt
report_power          -file $out_dir/post_route_power.rpt

# ── Extract a machine-readable PLACED PPA line ──────────────────────────────────
proc grab {str re} { if {[regexp $re $str -> v]} { return $v } else { return "NA" } }
set u [report_utilization -return_string]
set lut    [grab $u {CLB LUTs[^|]*\|\s*(\d+)}]
set ff     [grab $u {CLB Registers[^|]*\|\s*(\d+)}]
set lutram [grab $u {LUT as Memory[^|]*\|\s*(\d+)}]
set dsp    [grab $u {DSPs[^|]*\|\s*(\d+)}]
set bram   [grab $u {Block RAM Tile[^|]*\|\s*(\d+)}]
set p [report_power -return_string]
set pwr [grab $p {Total On-Chip Power \(W\)[^|]*\|\s*([\d.]+)}]

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $paths] > 0} {
    set wns  [get_property SLACK $paths]
    set raw  [expr {$clk_period - $wns}]
    set fmax [expr {1000.0 / $raw}]
} else { set wns NA; set fmax NA }

puts "============ FP DSE PLACED PPA  L=$lanes W=$warps  (xczu7ev) ============"
puts [format "  LUT=%s  FF=%s  LUTRAM=%s  DSP=%s  BRAM=%s" $lut $ff $lutram $dsp $bram]
puts [format "  Setup WNS=%+.3f ns @100MHz   Fmax=%.1f MHz   Power=%s W" $wns $fmax $pwr]
puts [format "PLACEDDSE,%s,%s,%s,%s,%s,%s,%s,%.3f,%.1f,%s" \
      $lanes $warps $lut $ff $lutram $dsp $bram $wns $fmax $pwr]
puts "========================================================================"
