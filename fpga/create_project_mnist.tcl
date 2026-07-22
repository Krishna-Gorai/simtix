# create_project_mnist.tcl  -  generate a managed Vivado GUI project for the AI-4
#                             on-chip MNIST chip config (chip_top_mnist), so the whole
#                             hierarchy can be browsed as an elaborated schematic and
#                             synthesised for the BRAM-inclusive PPA from the GUI.
#
# The repo's normal flow is non-project batch Tcl (synth_chip_mnist.tcl). Run this
# ONCE to build a clickable project:
#
#     cd fpga && vivado -mode batch -source create_project_mnist.tcl
#
# then open the GUI on it:
#
#     vivado fpga/vivado_project_mnist/simtix_mnist.xpr
#         (or launch Vivado and File -> Open Project -> that .xpr)
#
# WHAT YOU GET (the point of this project):
#   * "Open Elaborated Design" -> the RTL schematic with every functional unit as its
#     own browsable box:
#         chip_top_mnist -> chip_top -> { riscv_pipeline (alu/control_unit/extend/
#         forwarding_unit/hazard_unit/register_file), driver_rom, weight_rom (BRAM),
#         shared_mem (LUTRAM), simt_accel -> mmio_regs + warp_pool -> simt_fpu x8 +
#         fp_divsqrt } — click any net to trace the connections.
#   * "Run Synthesis" -> the synthesized netlist + the first non-zero BRAM utilisation
#     of the project (the 256 KB weight/data store inferred as block RAM).
#
# The two generated hex images (weight/data store + driver program) are added as
# DESIGN SOURCES so Vivado puts their directory on the $readmemh search path; the
# wrapper passes them as basenames, so they resolve in synth, elaboration and sim
# regardless of the run's working directory.
#
# The generated project lives under fpga/vivado_project_mnist/ and is git-ignored.

set proj_name simtix_mnist
set proj_dir  [file normalize ./vivado_project_mnist]
set part      xczu7ev-ffvc1156-2-e

set acc_dir  [file normalize ../rtl/accel]
set soc_dir  [file normalize ../rtl/soc]
set cpu_dir  [file normalize ../rtl/cpu]
set tb_dir   [file normalize ../tests]
set data_dir [file normalize ../ml/data]
set kern_dir [file normalize ../kernels/mnist]

create_project $proj_name $proj_dir -part $part -force

# ── Design sources (the chip_top_mnist hierarchy) ───────────────────────────────
add_files -fileset sources_1 [list \
    $acc_dir/simtix_pkg.sv     \
    $acc_dir/mmio_regs.sv      \
    $acc_dir/simt_fpu.sv       \
    $acc_dir/fp_divsqrt.sv     \
    $acc_dir/warp_pool.sv      \
    $acc_dir/simt_accel.sv     \
    $soc_dir/shared_mem.sv     \
    $soc_dir/weight_rom.sv     \
    $soc_dir/driver_rom.sv     \
    $soc_dir/cpu_driver_rom.sv \
    $soc_dir/chip_top.sv       \
    $soc_dir/chip_top_mnist.sv \
    $cpu_dir/alu.v             \
    $cpu_dir/control_unit.v    \
    $cpu_dir/extend.v          \
    $cpu_dir/forwarding_unit.v \
    $cpu_dir/hazard_unit.v     \
    $cpu_dir/register_file.v   \
    $cpu_dir/riscv_pipeline.v ]

# Type the SystemVerilog files as SV (package + accel + soc).
set_property file_type SystemVerilog [get_files [list \
    $acc_dir/simtix_pkg.sv $acc_dir/mmio_regs.sv $acc_dir/simt_fpu.sv \
    $acc_dir/fp_divsqrt.sv $acc_dir/warp_pool.sv $acc_dir/simt_accel.sv \
    $soc_dir/shared_mem.sv $soc_dir/weight_rom.sv $soc_dir/driver_rom.sv \
    $soc_dir/cpu_driver_rom.sv $soc_dir/chip_top.sv $soc_dir/chip_top_mnist.sv ]]

# The $readmemh init images — added as design sources so their directory lands on the
# readmem search path (the wrapper references them by basename).
add_files -fileset sources_1 [list \
    $data_dir/mnist_store.hex \
    $kern_dir/mnist_driver.hex ]

set_property top chip_top_mnist [current_fileset]

# ── Constraints (auto-placed I/O; ZCU104 board files not installed here) ─────────
# Wrap single paths in [list ...] so the space in "Verilog Projects" is not re-split.
add_files -fileset constrs_1 [list [file normalize ./constr/chip_top_impl.xdc]]

# ── Simulation: the self-checking on-chip MNIST testbench ───────────────────────
# NOTE: the proven functional run is `make -C sim test-chip-mnist`. In the GUI, the
# hex images resolve by basename via the search path above.
add_files -fileset sim_1 [list $tb_dir/tb_chip_mnist.sv]
set_property file_type SystemVerilog [get_files [list $tb_dir/tb_chip_mnist.sv]]
set_property top tb_chip_mnist [get_filesets sim_1]

# Match the batch flow's reporting (GUI user can change in Settings -> Synthesis).
set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} -value {none} \
    -objects [get_runs synth_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "======================================================================"
puts " Project created: $proj_dir/$proj_name.xpr"
puts " Open it with:    vivado $proj_dir/$proj_name.xpr"
puts " Top (synth/impl): chip_top_mnist     Top (sim): tb_chip_mnist"
puts " Then: Open Elaborated Design (browse modules) / Run Synthesis (BRAM PPA)"
puts "======================================================================"
