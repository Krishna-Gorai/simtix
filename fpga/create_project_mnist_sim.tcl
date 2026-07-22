# create_project_mnist_sim.tcl  -  managed Vivado project for a FAST post-synthesis
#                                  gate-level simulation of the on-chip MNIST chip.
#
# Post-synthesis simulation runs the SYNTHESIZED NETLIST, so the fast run needs the
# reduced-image driver baked into the driver ROM at synth time. This project's synth
# top is therefore chip_top_mnist_short (identical hardware to chip_top_mnist, but its
# ROM holds the -DNIMG=2 driver), and its sim top is tb_chip_mnist_short. The netlist
# LOGIC is the same as the PPA build (chip_top_mnist / simtix_mnist.xpr) — only the
# driver ROM contents differ — so this proves the synthesized gate-level design
# computes correct digits, in minutes instead of hours.
#
# PREREQUISITE (build the reduced driver hex once):
#     cd sim && make mnist-driver-short          # -> kernels/mnist/mnist_driver_short.hex
#   (and ml/data/mnist_store.hex from `python3 ml/mnist_quant.py`, already present)
#
# BUILD + OPEN:
#     cd fpga && vivado -mode batch -source create_project_mnist_sim.tcl
#     vivado vivado_project_mnist_sim/simtix_mnist_sim.xpr
#
# RUN THE POST-SYNTH SIM (in the GUI):
#     1. Flow Navigator -> SYNTHESIS -> Run Synthesis  (wait for it to finish)
#     2. Flow Navigator -> SIMULATION -> Run Simulation
#          -> Run Post-Synthesis Functional Simulation
#     The sim runtime is preset to run until $finish, so it stops itself and prints
#     PASS when the netlist reproduces the golden for both images (result = 2).
#
# The generated project lives under fpga/vivado_project_mnist_sim/ and is git-ignored.

set proj_name simtix_mnist_sim
set proj_dir  [file normalize ./vivado_project_mnist_sim]
set part      xczu7ev-ffvc1156-2-e

set acc_dir  [file normalize ../rtl/accel]
set soc_dir  [file normalize ../rtl/soc]
set cpu_dir  [file normalize ../rtl/cpu]
set tb_dir   [file normalize ../tests]
set data_dir [file normalize ../ml/data]
set kern_dir [file normalize ../kernels/mnist]

create_project $proj_name $proj_dir -part $part -force

# ── Design sources (the chip_top_mnist_short hierarchy) ─────────────────────────
add_files -fileset sources_1 [list \
    $acc_dir/simtix_pkg.sv           \
    $acc_dir/mmio_regs.sv            \
    $acc_dir/simt_fpu.sv             \
    $acc_dir/fp_divsqrt.sv           \
    $acc_dir/warp_pool.sv            \
    $acc_dir/simt_accel.sv           \
    $soc_dir/shared_mem.sv           \
    $soc_dir/weight_rom.sv           \
    $soc_dir/driver_rom.sv           \
    $soc_dir/cpu_driver_rom.sv       \
    $soc_dir/chip_top.sv             \
    $soc_dir/chip_top_mnist_short.sv \
    $cpu_dir/alu.v                   \
    $cpu_dir/control_unit.v          \
    $cpu_dir/extend.v                \
    $cpu_dir/forwarding_unit.v       \
    $cpu_dir/hazard_unit.v           \
    $cpu_dir/register_file.v         \
    $cpu_dir/riscv_pipeline.v ]

set_property file_type SystemVerilog [get_files [list \
    $acc_dir/simtix_pkg.sv $acc_dir/mmio_regs.sv $acc_dir/simt_fpu.sv \
    $acc_dir/fp_divsqrt.sv $acc_dir/warp_pool.sv $acc_dir/simt_accel.sv \
    $soc_dir/shared_mem.sv $soc_dir/weight_rom.sv $soc_dir/driver_rom.sv \
    $soc_dir/cpu_driver_rom.sv $soc_dir/chip_top.sv $soc_dir/chip_top_mnist_short.sv ]]

# The $readmemh init images (reduced driver + full store) — added as design sources
# so their directory lands on the readmem search path (referenced by basename). Their
# contents are captured into the synthesized netlist's ROM/BRAM INIT, so the
# post-synth netlist carries the driver/weights/images/golden.
add_files -fileset sources_1 [list \
    $kern_dir/mnist_driver_short.hex \
    $data_dir/mnist_store.hex ]

set_property top chip_top_mnist_short [current_fileset]

# ── Constraints (auto-placed I/O; ZCU104 board files not installed here) ─────────
add_files -fileset constrs_1 [list [file normalize ./constr/chip_top_impl.xdc]]

# ── Simulation: the reduced-image self-checking testbench ───────────────────────
add_files -fileset sim_1 [list $tb_dir/tb_chip_mnist_short.sv]
set_property file_type SystemVerilog [get_files [list $tb_dir/tb_chip_mnist_short.sv]]
set_property top tb_chip_mnist_short [get_filesets sim_1]

# Run each simulation until $finish (the tb stops itself on PASS/FAIL) rather than
# the default 1 us, for behavioral AND post-synth/post-impl runs.
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]

set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} -value {none} \
    -objects [get_runs synth_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "======================================================================"
puts " Project created: $proj_dir/$proj_name.xpr"
puts " Open it with:    vivado $proj_dir/$proj_name.xpr"
puts " Top (synth): chip_top_mnist_short   Top (sim): tb_chip_mnist_short"
puts " Then: Run Synthesis -> Run Simulation -> Post-Synthesis Functional"
puts "======================================================================"
