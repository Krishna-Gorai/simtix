# create_project_fp.tcl  -  generate a managed Vivado project for the COMPLETE
#   FP-enabled chip (host CPU + pipelined FP32/FP16 SIMT accelerator + shared
#   memory + driver ROM), so it can be opened and driven from the Vivado GUI.
#
# This is the FP counterpart of create_project.tcl. That script builds the
# integer-only chip and DOES NOT add the floating-point sources; this one adds
# simt_fpu.sv (the M17 three-stage pipelined FP unit) and fp_divsqrt.sv (the
# shared iterative divide/square-root core) that the current warp_pool.sv now
# instantiates unconditionally. Default geometry is 8 lanes / 4 warps -- the
# configuration that meets 100 MHz in the placed FP timing-closure study.
#
# It writes a SEPARATE project (simtix_chip_fp under fpga/vivado_project_fp/) and
# never touches the existing fpga/vivado_project/simtix_chip.xpr.
#
# Build it ONCE:
#     cd fpga && vivado -mode batch -source create_project_fp.tcl
#
# then open the GUI on it:
#     vivado fpga/vivado_project_fp/simtix_chip_fp.xpr
#         (or launch Vivado and File -> Open Project -> that .xpr)
#
# In the Flow Navigator you then get Run Synthesis / Run Implementation / Generate
# Bitstream, the RTL/synthesized schematic, the device floorplan, and timing/power
# reports for the full FP chip. Targets the ZCU104's xczu7ev and uses
# constr/chip_top_impl.xdc (auto-placed I/O, as the ZCU104 board files are not
# installed here). The generated project is git-ignored.

set proj_name simtix_chip_fp
set proj_dir  [file normalize ./vivado_project_fp]
set part      xczu7ev-ffvc1156-2-e

set acc_dir [file normalize ../rtl/accel]
set soc_dir [file normalize ../rtl/soc]
set cpu_dir [file normalize ../rtl/cpu]
set tb_dir  [file normalize ../tests]

create_project $proj_name $proj_dir -part $part -force

# ── Design sources (the chip_top hierarchy, now WITH the FP datapath) ───────────
#   The two FP files (simt_fpu.sv, fp_divsqrt.sv) are the only difference from the
#   integer create_project.tcl; warp_pool.sv instantiates them per-lane / shared.
add_files -fileset sources_1 [list \
    $acc_dir/simtix_pkg.sv \
    $acc_dir/mmio_regs.sv  \
    $acc_dir/simt_fpu.sv   \
    $acc_dir/fp_divsqrt.sv \
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
    $acc_dir/simtix_pkg.sv $acc_dir/mmio_regs.sv $acc_dir/simt_fpu.sv \
    $acc_dir/fp_divsqrt.sv $acc_dir/warp_pool.sv $acc_dir/simt_accel.sv \
    $soc_dir/shared_mem.sv $soc_dir/cpu_driver_rom.sv $soc_dir/chip_top.sv ]]

set_property top chip_top [current_fileset]

# ── Constraints ─────────────────────────────────────────────────────────────────
# Wrap single paths in [list ...] so the space in "Verilog Projects" is not re-split.
add_files -fileset constrs_1 [list [file normalize ./constr/chip_top_impl.xdc]]

# ── Simulation: the self-checking full-chip testbench ───────────────────────────
add_files -fileset sim_1 [list $tb_dir/tb_chip_top.sv]
set_property file_type SystemVerilog [get_files [list $tb_dir/tb_chip_top.sv]]
set_property top tb_chip_top [get_filesets sim_1]

# Keep hierarchy flat-none to match the batch flow's reporting (optional; the GUI
# user can change this in Settings -> Synthesis). The FP fabric is large, so on an
# 8 GB host you may also want Settings -> Synthesis -> tcl.pre maxThreads 2.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} -value {none} \
    -objects [get_runs synth_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "================================================================="
puts " FP project created: $proj_dir/$proj_name.xpr"
puts " Open it with:       vivado $proj_dir/$proj_name.xpr"
puts " Top (synth/impl): chip_top      Top (sim): tb_chip_top"
puts " Includes simt_fpu.sv (3-stage pipelined FP32/FP16) + fp_divsqrt.sv"
puts " Existing simtix_chip.xpr is untouched."
puts "================================================================="
