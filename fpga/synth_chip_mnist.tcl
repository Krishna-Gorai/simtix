# synth_chip_mnist.tcl  -  AI-4: out-of-context, timing-driven synthesis + PPA of the
#                         COMPLETE MNIST chip config (host CPU + SIMTiX accelerator +
#                         LUTRAM shared memory + MNIST driver ROM + 256 KB BRAM weight
#                         store) on the ZCU104 (xczu7ev-ffvc1156-2-e).
#
# This is the first SIMTiX build with a non-zero BRAM footprint: the 65536-word
# (256 KB) weight/data store is inferred as block RAM (ram_style="block" in
# weight_rom.sv). The purpose of this run is the BRAM-inclusive PPA — LUT/FF/BRAM/DSP,
# a post-synth Fmax estimate, and vectorless power — for the deployable on-chip
# MNIST accelerator.
#
#   cd fpga && vivado -mode batch -source synth_chip_mnist.tcl
#
# Same 8 GB-host guards as the M10 chip flow: maxThreads 2 + flatten_hierarchy none.
# No write_checkpoint (silent-hang signature on this host); the .rpt files carry
# every PPA number. Top = chip_top_mnist (fixes DRIVER="mnist" + 256 KB store).

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set acc_dir [file normalize ../rtl/accel]
set soc_dir [file normalize ../rtl/soc]
set cpu_dir [file normalize ../rtl/cpu]
set out_dir [file normalize ./reports_chip_mnist]
file mkdir $out_dir

# chip_top_mnist gives its $readmemh INIT files as basenames; the weight ROM and
# driver ROM resolve them relative to this run's working directory. Copy the two
# generated hex images next to us so the block-RAM store initialises with the real
# MNIST weights/images (matters for a faithful BRAM inference + power estimate).
file copy -force [file normalize ../ml/data/mnist_store.hex]        ./mnist_store.hex
file copy -force [file normalize ../kernels/mnist/mnist_driver.hex] ./mnist_driver.hex

# ── RTL: SystemVerilog (package first, leaf-to-top), then the Verilog CPU ────────
read_verilog -sv [list \
    $acc_dir/simtix_pkg.sv \
    $acc_dir/mmio_regs.sv  \
    $acc_dir/simt_fpu.sv   \
    $acc_dir/fp_divsqrt.sv \
    $acc_dir/warp_pool.sv  \
    $acc_dir/simt_accel.sv \
    $soc_dir/shared_mem.sv \
    $soc_dir/weight_rom.sv \
    $soc_dir/driver_rom.sv \
    $soc_dir/cpu_driver_rom.sv \
    $soc_dir/chip_top.sv \
    $soc_dir/chip_top_mnist.sv ]

# Host CPU pipeline + leaf modules (Verilog-2001).
read_verilog [list \
    $cpu_dir/alu.v \
    $cpu_dir/control_unit.v \
    $cpu_dir/extend.v \
    $cpu_dir/forwarding_unit.v \
    $cpu_dir/hazard_unit.v \
    $cpu_dir/register_file.v \
    $cpu_dir/riscv_pipeline.v ]

# NB: wrap the path in [list ...] so read_xdc does not re-split on the space in the
# "Verilog Projects" parent directory.
read_xdc [list [file normalize ./constr/chip_top_ooc.xdc]]

# ── Out-of-context, timing-driven synthesis of the whole MNIST chip ─────────────
synth_design -top chip_top_mnist -part $part -mode out_of_context \
    -flatten_hierarchy none

# ── Reports: area, timing (Fmax), power ─────────────────────────────────────────
report_utilization      -file $out_dir/post_synth_util.rpt
report_timing_summary   -max_paths 10 -file $out_dir/post_synth_timing.rpt
report_power            -file $out_dir/post_synth_power.rpt

# ── Console summary (also captured in the log) ──────────────────────────────────
set clk_period 10.000
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts "============== AI-4 MNIST FULL-CHIP PPA SUMMARY (xczu7ev / ZCU104) =============="
if {[llength $paths] > 0} {
    set wns  [get_property SLACK $paths]
    set raw  [expr {$clk_period - $wns}]
    set fmax [expr {1000.0 / $raw}]
    puts [format "  Constrained period   : %.3f ns (%.1f MHz)" $clk_period [expr {1000.0/$clk_period}]]
    puts [format "  Setup WNS            : %+.3f ns  (%s)" $wns [expr {$wns >= 0 ? "MET" : "VIOLATED"}]]
    puts [format "  Critical-path delay  : %.3f ns" $raw]
    puts [format "  Max Fmax             : %.1f MHz" $fmax]
} else {
    puts "  (no timing path returned — see post_synth_timing.rpt)"
}
report_utilization -hierarchical -hierarchical_depth 2
puts "================================================================================"
