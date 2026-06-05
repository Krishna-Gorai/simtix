# chip_top_ooc.xdc  -  out-of-context timing constraint for the M10 full chip
#
# The complete chip (host RISC-V pipeline + SIMTiX accelerator + on-chip shared
# memory + driver ROM) synthesized OOC for PPA. OOC has no board/package pins, so
# we only define the clock. Target is 10 ns / 100 MHz — the period the M8/M9
# accelerator datapath meets; the CPU's 5-stage pipeline is comfortably faster, so
# the accelerator remains the timing-critical block. The true ceiling is read back
# from the post-synth timing report (Fmax = 1 / (period - WNS)). The ZCU104
# carries an xczu7ev (UltraScale+); the part is selected in fpga/synth_chip.tcl.

create_clock -name clk -period 10.000 [get_ports clk]

# Reset is asynchronous to the clock for OOC timing.
set_false_path -from [get_ports rst]
