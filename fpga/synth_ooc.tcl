# synth_ooc.tcl  -  M9: out-of-context, timing-driven synthesis + PPA of simt_accel
#
# Target: Zynq UltraScale+ MPSoC xczu7ev-ffvc1156-2-e (the ZCU104 eval board).
# Produces area (LUT/FF/BRAM/DSP), a post-synth timing estimate (=> Fmax), and a
# vectorless power estimate. Run from the fpga/ directory:
#
#   vivado -mode batch -source synth_ooc.tcl
#
# History on this 8 GB host: the original M7b FF design had 1024-entry VRF +
# 256-word scratch held in flip-flops with variable indexing -> huge mux trees.
# Timing-driven synthesis of that netlist peaked 4.25 GB *before* "Start Timing
# Optimization" and thrashed for 4 h, so M7b ran -no_timing_driven as a workaround.
#
# M8 moved the VRF and M9 moved the scratchpad into distributed RAM (LUTRAM): the
# mux trees are gone, FFs dropped ~70%, and peak synthesis RAM falls to ~2.4 GB.
# That headroom lets us turn the timing-optimization phase back ON (real placement-
# aware Fmax instead of the conservative raw-path estimate). We keep the host-proven
# memory guards:
#   * maxThreads 2 + flatten_hierarchy none -> per-module optimization, lower peak
#     RAM; reports stay readable per-module.
#   * no write_checkpoint: it has a known silent-hang signature here and the .rpt
#     files already carry every PPA number we need.

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
# M14.5: write the FP-enabled PPA to a separate dir so the M9 integer-baseline
# reports under ./reports are preserved for the before/after comparison.
set out_dir [file normalize ./reports_fp]
file mkdir $out_dir

# ── RTL (package first, then leaf-to-top) ───────────────────────────────────────
read_verilog -sv [list \
    $rtl_dir/simtix_pkg.sv \
    $rtl_dir/mmio_regs.sv  \
    $rtl_dir/simt_fpu.sv   \
    $rtl_dir/fp_divsqrt.sv \
    $rtl_dir/warp_pool.sv  \
    $rtl_dir/simt_accel.sv ]

# NB: wrap paths in [list ...] so read_xdc does not re-split on the space in the
# "Verilog Projects" parent directory (it would otherwise see two files).
read_xdc [list [file normalize ./constr/simt_accel_ooc.xdc]]

# ── Out-of-context synthesis ────────────────────────────────────────────────────
# M14.5: the FP-enabled accelerator adds a per-lane FPU (add/sub/mul/FMA/cvt/cmp)
# and a per-lane iterative div/sqrt SFU, so the netlist is markedly larger than the
# M9 integer design. On this 8 GB host the timing-optimization phase would peak
# above available RAM, so we synthesize -no_timing_driven (the M7b host-proven
# low-memory recipe): area (LUT/FF/DSP/LUTRAM) and power are exact, and for this
# largely single-cycle datapath the raw critical-path delay is a realistic Fmax
# floor (reported below). flatten none still bounds peak RAM per module.
synth_design -top simt_accel -part $part -mode out_of_context \
    -flatten_hierarchy none -no_timing_driven

# ── Reports: area, timing (Fmax), power ─────────────────────────────────────────
report_utilization      -file $out_dir/post_synth_util.rpt
report_timing_summary   -max_paths 10 -file $out_dir/post_synth_timing.rpt
report_power            -file $out_dir/post_synth_power.rpt

# ── Console summary (also captured in vivado.log) ───────────────────────────────
set clk_period 10.000
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "========== M14.5 FP-ENABLED PPA SUMMARY (xczu7ev / ZCU104) =========="
if {[llength $paths] > 0} {
    set wns  [get_property SLACK $paths]
    set raw  [expr {$clk_period - $wns}]
    set fmax [expr {1000.0 / $raw}]
    puts [format "  Constrained period   : %.3f ns (%.1f MHz)" $clk_period [expr {1000.0/$clk_period}]]
    puts [format "  Setup WNS            : %+.3f ns  (%s)" $wns [expr {$wns >= 0 ? "MET" : "VIOLATED"}]]
    puts [format "  Critical-path delay  : %.3f ns" $raw]
    puts [format "  Max Fmax             : %.1f MHz" $fmax]
    # Timing-driven => the raw path was optimized for THIS constraint, so the table
    # below is an approximate guide only (a re-synth at a tighter period may do
    # slightly better). The headline WNS/Fmax above is the real result.
    puts "  WNS vs target period (approx, extrapolated from this run):"
    foreach p {10.0 9.0 8.0 7.0 6.0 5.0} {
        puts [format "    %4.1f ns (%5.1f MHz) -> WNS %+.3f ns  %s" \
              $p [expr {1000.0/$p}] [expr {$p - $raw}] \
              [expr {($p-$raw) >= 0 ? "MET" : "violated"}]]
    }
} else {
    puts "  (no timing path returned — see post_synth_timing.rpt)"
}
report_utilization -hierarchical -hierarchical_depth 1
puts "==================================================================="
