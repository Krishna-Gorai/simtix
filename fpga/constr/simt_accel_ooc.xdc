# simt_accel_ooc.xdc  -  out-of-context timing constraint for M7b PPA
#
# OOC synthesis has no board/package pins, so we only define the clock. A 5 ns
# period (200 MHz) is the target; the achieved Fmax is read back from the
# post-synth timing report (Fmax = 1 / (period - WNS)). The ZCU104 carries an
# xczu7ev (UltraScale+); the part is selected in fpga/synth_ooc.tcl.

create_clock -name clk -period 5.000 [get_ports clk]

# Treat reset and the host-bus controls as asynchronous to the clock for OOC
# timing (they are not the critical datapath under study).
set_false_path -from [get_ports rst]
