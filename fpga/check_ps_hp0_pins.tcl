# check_ps_hp0_pins.tcl - the PS8 HP0 (SAXIGP2) inputs the accelerator's constant AXI outputs
# feed, in the routed board design: each bit's driver (GND/VCC = tied constant).
#   vivado -mode batch -source check_ps_hp0_pins.tcl -tclargs <routed.dcp>
open_checkpoint [lindex $argv 0]
set ps [lindex [get_cells -hier -filter {REF_NAME == PS8}] 0]
puts "PS8: $ps"
foreach f {ARLEN ARSIZE ARBURST ARCACHE ARPROT AWLEN AWSIZE AWBURST AWCACHE AWPROT AWID ARID RREADY BREADY} {
    set bits {}
    foreach pin [lsort -dictionary [get_pins -quiet $ps/SAXIGP2$f*]] {
        set net [get_nets -quiet -of_objects $pin]
        if {$net eq ""} { lappend bits "?" ; continue }
        set drv [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
        set ref [expr {$drv eq "" ? "none" : [get_property REF_NAME [get_cells -of_objects $drv]]}]
        lappend bits [expr {$ref eq "GND" ? 0 : $ref eq "VCC" ? 1 : "s"}]
    }
    # bits listed LSB first; s = driven by logic (a signal)
    puts "HP0PIN,$f,[join $bits {}]"
}
