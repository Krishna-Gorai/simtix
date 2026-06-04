# synth_ooc.tcl  -  M7b: out-of-context synthesis + PPA of simt_accel on ZCU104
#
# Target: Zynq UltraScale+ MPSoC xczu7ev-ffvc1156-2-e (the ZCU104 eval board).
# Produces area (LUT/FF/BRAM/DSP), a post-synth timing estimate (=> Fmax), and a
# vectorless power estimate. Run from the fpga/ directory:
#
#   vivado -mode batch -source synth_ooc.tcl
#
# Notes for the 8 GB host (this host peaks ~3 GB free; an earlier timing-driven
# run hit 4.25 GB *before* "Start Timing Optimization" and then thrashed for 4 h):
#   * maxThreads 2 + flatten_hierarchy none -> per-module optimization, lower peak
#     RAM (proven recipe on this host); reports stay readable per-module.
#   * -no_timing_driven skips the timing-optimization phase that was the memory
#     hog AND the stall point. For this design the critical path is an irreducible
#     single-cycle ALU + 128:1 VRF mux + writeback, so the post-synth WNS is a
#     realistic Fmax estimate, not a pessimistic floor.
#   * no write_checkpoint: it has a known silent-hang signature here and the .rpt
#     files already carry every PPA number we need.

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
set out_dir [file normalize ./reports]
file mkdir $out_dir

# ── RTL (package first, then leaf-to-top) ───────────────────────────────────────
read_verilog -sv [list \
    $rtl_dir/simtix_pkg.sv \
    $rtl_dir/mmio_regs.sv  \
    $rtl_dir/warp_pool.sv  \
    $rtl_dir/simt_accel.sv ]

# NB: wrap paths in [list ...] so read_xdc does not re-split on the space in the
# "Verilog Projects" parent directory (it would otherwise see two files).
read_xdc [list [file normalize ./constr/simt_accel_ooc.xdc]]

# ── Out-of-context synthesis ────────────────────────────────────────────────────
# This register-heavy design (1024-entry VRF + scratch + stacks, variable-indexed
# -> huge mux trees) makes the timing-driven optimization phase blow past the
# host's RAM and thrash. -no_timing_driven skips that phase outright; flatten none
# keeps peak RAM low by optimizing each module on its own. Result: a reliable, fast
# area + power run, with a valid (conservative) post-synth Fmax from the timing rpt.
synth_design -top simt_accel -part $part -mode out_of_context \
    -flatten_hierarchy none -no_timing_driven

# ── Reports: area, timing (Fmax), power ─────────────────────────────────────────
report_utilization      -file $out_dir/post_synth_util.rpt
report_timing_summary   -max_paths 10 -file $out_dir/post_synth_timing.rpt
report_power            -file $out_dir/post_synth_power.rpt

# ── Console summary (also captured in vivado.log) ───────────────────────────────
set clk_period 5.000
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "================ M7b PPA SUMMARY (xczu7ev / ZCU104) ================"
if {[llength $paths] > 0} {
    set wns  [get_property SLACK $paths]
    set fmax [expr {1000.0 / ($clk_period - $wns)}]
    puts [format "  Setup WNS at 200 MHz : %.3f ns" $wns]
    puts [format "  Estimated Fmax       : %.1f MHz" $fmax]
} else {
    puts "  (no timing path returned — see post_synth_timing.rpt)"
}
report_utilization -hierarchical -hierarchical_depth 1
puts "==================================================================="
