# create_project.tcl  -  generate a managed Vivado project for the full chip so it
#                       can be opened and driven from the Vivado GUI.
#
# The repo's normal flow is non-project batch Tcl (synth_chip.tcl / impl_chip.tcl) —
# there is no .xpr checked in. Run this ONCE to build a clickable project:
#
#     cd fpga && vivado -mode batch -source create_project.tcl
#
# then open the GUI on it:
#
#     vivado fpga/vivado_project/simtix_chip.xpr
#         (or launch Vivado and File -> Open Project -> that .xpr)
#
# In the Flow Navigator you then get Run Synthesis / Run Implementation / Generate
# Bitstream, the RTL/synthesized schematic, the device floorplan, and timing/power
# reports. The project targets the ZCU104's xczu7ev and uses constr/chip_top_impl.xdc
# (auto-placed I/O, since the ZCU104 board files are not installed here).
#
# The generated project lives under fpga/vivado_project/ and is git-ignored.

set proj_name simtix_chip
set proj_dir  [file normalize ./vivado_project]
set part      xczu7ev-ffvc1156-2-e

set acc_dir [file normalize ../rtl/accel]
set soc_dir [file normalize ../rtl/soc]
set cpu_dir [file normalize ../rtl/cpu]
set tb_dir  [file normalize ../tests]

create_project $proj_name $proj_dir -part $part -force

# ── Design sources (the chip_top hierarchy) ─────────────────────────────────────
add_files -fileset sources_1 [list \
    $acc_dir/simtix_pkg.sv \
    $acc_dir/mmio_regs.sv  \
    $acc_dir/warp_pool.sv  \
    $acc_dir/simt_accel.sv \
    $soc_dir/shared_mem.sv \
    $soc_dir/cpu_driver_rom.sv \
    $soc_dir/chip_top.sv \
    $cpu_dir/alu.v \
    $cpu_dir/control_unit.v \
    $cpu_dir/extend.v \
    $cpu_dir/forwarding_unit.v \
    $cpu_dir/hazard_unit.v \
    $cpu_dir/register_file.v \
    $cpu_dir/riscv_pipeline.v ]

# Make sure the SystemVerilog files are typed as SV (package + accel + soc).
set_property file_type SystemVerilog [get_files [list \
    $acc_dir/simtix_pkg.sv $acc_dir/mmio_regs.sv $acc_dir/warp_pool.sv \
    $acc_dir/simt_accel.sv $soc_dir/shared_mem.sv $soc_dir/cpu_driver_rom.sv \
    $soc_dir/chip_top.sv ]]

set_property top chip_top [current_fileset]

# ── Constraints ─────────────────────────────────────────────────────────────────
# Wrap single paths in [list ...] so the space in "Verilog Projects" is not re-split.
add_files -fileset constrs_1 [list [file normalize ./constr/chip_top_impl.xdc]]

# ── Simulation: the self-checking full-chip testbench ───────────────────────────
add_files -fileset sim_1 [list $tb_dir/tb_chip_top.sv]
set_property file_type SystemVerilog [get_files [list $tb_dir/tb_chip_top.sv]]
set_property top tb_chip_top [get_filesets sim_1]

# Keep hierarchy flat-none to match the batch flow's reporting (optional; the GUI
# user can change this in Settings -> Synthesis).
set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} -value {none} \
    -objects [get_runs synth_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "================================================================="
puts " Project created: $proj_dir/$proj_name.xpr"
puts " Open it with:    vivado $proj_dir/$proj_name.xpr"
puts " Top (synth/impl): chip_top      Top (sim): tb_chip_top"
puts "================================================================="
