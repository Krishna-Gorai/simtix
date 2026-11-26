# check_const_pins.tcl - in the routed board design, what drives the accelerator cell's AXI pins
# that the extracted cell netlist (create_bd_ps.tcl finish, write_verilog -cell) leaves
# unconnected (Vivado moved their constant / duplicate drivers out of the cell).
#   vivado -mode batch -source check_const_pins.tcl -tclargs <routed.dcp>
# Prints, per pin bit: CONSTPIN,<pin>,<driver cell>,<driver ref>,<value if GND/VCC>
set dcp [lindex $argv 0]
open_checkpoint $dcp
set cell [lindex [get_cells -hier -filter {NAME =~ "*simt_0" && IS_PRIMITIVE == 0}] 0]
puts "cell: $cell"
set ports {m_axi_arlen m_axi_arsize m_axi_arburst m_axi_arcache m_axi_arprot
           m_axi_awlen m_axi_awsize m_axi_awburst m_axi_awcache m_axi_awprot m_axi_awid
           m_axi_rready s_axi_wready s_axi_awready s_axi_bresp s_axi_rresp}
foreach p $ports {
    foreach pin [lsort -dictionary [get_pins -quiet $cell/$p*]] {
        if {[get_property DIRECTION $pin] ne "OUT"} { continue }
        set net [get_nets -quiet -of_objects $pin]
        if {$net eq ""} { puts "CONSTPIN,$pin,NO_NET,,"; continue }
        set drv [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
        if {$drv eq ""} { puts "CONSTPIN,$pin,NO_DRIVER,,"; continue }
        set dc  [get_cells -of_objects $drv]
        set ref [get_property REF_NAME $dc]
        set val [expr {$ref eq "GND" ? 0 : $ref eq "VCC" ? 1 : ""}]
        set loads [llength [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == IN}]]
        puts "CONSTPIN,$pin,$dc,$ref,$val,net=[get_property NAME $net],loads=$loads"
    }
}
