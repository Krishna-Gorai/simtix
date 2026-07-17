# impl_ai.tcl  -  placed (OOC) PPA of the FP+INT8(pdot8) accelerator, 8 lanes / 4 warps.
#
# Same proven flow as impl_dse.tcl (synth -> opt -> place -> phys_opt -> route ->
# power), constrained at 100 MHz, but writes to reports_ai_pdot8/ so the AI-1/AI-2
# build's PPA is kept distinct from the FP DSE sweep. Gives the measured numbers
# behind the TOPS/W figure: LUT/FF/DSP/BRAM, placed WNS/Fmax @100 MHz, Power.
#
#   vivado -mode batch -source impl_ai.tcl
#
# Host guards (8 GB): maxThreads 2, flatten none, no write_checkpoint; free RAM
# (close Chrome) before launching -- place_design peaks ~5 GB.

set_param general.maxThreads 2

set part        xczu7ev-ffvc1156-2-e
set rtl_dir     [file normalize ../rtl/accel]
set out_dir     [file normalize ./reports_ai_pdot8]
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
    -flatten_hierarchy none -retiming

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

puts "============ AI (pdot8) PLACED PPA  L=8 W=4  (xczu7ev / ZCU104) ============"
puts [format "  LUT=%s  FF=%s  LUTRAM=%s  DSP=%s  BRAM=%s" $lut $ff $lutram $dsp $bram]
puts [format "  Setup WNS=%+.3f ns @100MHz   Fmax=%.1f MHz   Power=%s W" $wns $fmax $pwr]
puts [format "PLACEDAI,8,4,%s,%s,%s,%s,%s,%.3f,%.1f,%s" \
      $lut $ff $lutram $dsp $bram $wns $fmax $pwr]
puts "==========================================================================="
