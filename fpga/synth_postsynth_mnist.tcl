# synth_postsynth_mnist.tcl  -  synthesize the reduced-image MNIST chip config and
#                              emit a functional-simulation netlist, for a headless
#                              POST-SYNTHESIS gate-level sim proof.
#
# Synthesizes chip_top_mnist_short (identical hardware to the PPA build, but the
# driver ROM holds the -DNIMG=2 driver) and writes a funcsim netlist + the $readmemh
# ROM/BRAM contents are captured as INIT, so the netlist is self-contained. The
# companion xsim step (mirroring run_postimpl_fp_sim.bat) then simulates it.
#
#   cd fpga && vivado -mode batch -source synth_postsynth_mnist.tcl

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set acc_dir [file normalize ../rtl/accel]
set soc_dir [file normalize ../rtl/soc]
set cpu_dir [file normalize ../rtl/cpu]
set sim_dir [file normalize ./postsynth_mnist]
file mkdir $sim_dir

# The reduced driver + store are referenced by basename; copy them into the run cwd
# so $readmemh resolves and the netlist ROM/BRAM initialise with the real contents.
file copy -force [file normalize ../ml/data/mnist_store.hex]              ./mnist_store.hex
file copy -force [file normalize ../kernels/mnist/mnist_driver_short.hex] ./mnist_driver_short.hex

read_verilog -sv [list \
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
    $soc_dir/chip_top_mnist_short.sv ]

read_verilog [list \
    $cpu_dir/alu.v             \
    $cpu_dir/control_unit.v    \
    $cpu_dir/extend.v          \
    $cpu_dir/forwarding_unit.v \
    $cpu_dir/hazard_unit.v     \
    $cpu_dir/register_file.v   \
    $cpu_dir/riscv_pipeline.v ]

# In-context synthesis (real primitives; no OOC) so the funcsim netlist is complete.
synth_design -top chip_top_mnist_short -part $part -flatten_hierarchy none

# Functional-simulation netlist (UNISIM primitives; ROM/BRAM INIT captured).
write_verilog -mode funcsim -force $sim_dir/chip_top_mnist_short_funcsim.v
puts "=== wrote funcsim netlist: $sim_dir/chip_top_mnist_short_funcsim.v ==="
