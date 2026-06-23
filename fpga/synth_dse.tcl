# synth_dse.tcl  -  Part-2b: per-configuration OOC synthesis PPA for the DSE sweep
#
# Synthesizes simt_accel at a given (NUM_LANES, NUM_WARPS) and reports area, Fmax,
# and power, so the lanes/warps performance sweep (tb_dse) can be paired with an
# area/frequency/power Pareto.  Run from the fpga/ directory, e.g.:
#
#   vivado -mode batch -source synth_dse.tcl -tclargs 16 4
#
# Config is passed to elaboration via synth_design -verilog_define, so the RTL is
# unmodified.  Per-config reports land in reports_dse/L<lanes>_W<warps>/, and one
# machine-readable line is printed (grep '^DSEPPA,'):
#   DSEPPA,lanes,warps,LUT,FF,LUTRAM,DSP,BRAM,WNS_ns,Fmax_MHz,Power_W
#
# Host guards (8 GB machine, see project notes): maxThreads 2, flatten none, no
# write_checkpoint.  NUM_LANES=32 is ~4x the 8-lane datapath and is the most
# memory-hungry point; free RAM before launching.

if {[llength $argv] < 2} { puts "usage: -tclargs <lanes> <warps>"; exit 1 }
set lanes [lindex $argv 0]
set warps [lindex $argv 1]

set_param general.maxThreads 2

set part        xczu7ev-ffvc1156-2-e
set rtl_dir     [file normalize ../rtl/accel]
set out_dir     [file normalize ./reports_dse/L${lanes}_W${warps}]
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

# Override the configuration at elaboration (RTL untouched).
synth_design -top simt_accel -part $part -mode out_of_context \
    -flatten_hierarchy none \
    -verilog_define SIMTIX_NUM_LANES=$lanes \
    -verilog_define SIMTIX_NUM_WARPS=$warps

report_utilization    -file $out_dir/util.rpt
report_timing_summary -max_paths 10 -file $out_dir/timing.rpt
report_power          -file $out_dir/power.rpt

# ── Extract a machine-readable PPA line ─────────────────────────────────────────
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

puts "================ DSE PPA  L=$lanes W=$warps  (xczu7ev) ================"
puts [format "  LUT=%s  FF=%s  LUTRAM=%s  DSP=%s  BRAM=%s" $lut $ff $lutram $dsp $bram]
puts [format "  WNS=%+.3f ns @100MHz   Fmax=%.1f MHz   Power=%s W" $wns $fmax $pwr]
puts [format "DSEPPA,%s,%s,%s,%s,%s,%s,%s,%.3f,%.1f,%s" \
      $lanes $warps $lut $ff $lutram $dsp $bram $wns $fmax $pwr]
puts "======================================================================"
