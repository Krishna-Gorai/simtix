# simt_accel_ooc.xdc  -  out-of-context timing constraint for M7b PPA
#
# OOC synthesis has no board/package pins, so we only define the clock. The target
# is 10 ns / 100 MHz: the single-cycle datapath (VRF read -> 32-bit ALU incl. a DSP
# multiply -> writeback) cannot close at 200 MHz, so we constrain a period the
# design actually MEETS (positive WNS) and read the true ceiling back from the
# post-synth timing report (Fmax = 1 / (period - WNS)). The ZCU104 carries an
# xczu7ev (UltraScale+); the part is selected in fpga/synth_ooc.tcl.

create_clock -name clk -period 10.000 [get_ports clk]

# Treat reset and the host-bus controls as asynchronous to the clock for OOC
# timing (they are not the critical datapath under study).
set_false_path -from [get_ports rst]
