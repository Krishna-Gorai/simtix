# run_board.tcl  -  program the ZCU104 over JTAG and run the A53 host program
#
#   xsdb sw/ps_host/run_board.tcl        (from the repository root)
#
# Board setup: boot-mode switch SW6 = JTAG (all ON), USB-JTAG and USB-UART cables
# connected, a terminal on the UART (115200 8N1; the A53 console is the first of
# the board's four USB-UART ports). Expects sw/ps_host/build_vitis.py to have
# built the workspace sw/ps_host/ws.

set here [file dirname [file normalize [info script]]]
set ws   [file join $here ws]

proc find_one {dir pattern} {
    set hits {}
    foreach f [glob -nocomplain -directory $dir -types f $pattern] { lappend hits $f }
    foreach d [glob -nocomplain -directory $dir -types d *] {
        set hits [concat $hits [find_one $d $pattern]]
    }
    return $hits
}

set bit  [lindex [find_one [file join $ws simtix_plat] *.bit] 0]
set init [lindex [find_one [file join $ws simtix_plat] psu_init.tcl] 0]
set elf  [file join $ws ps_host build ps_host.elf]
foreach {what f} [list bitstream $bit psu_init $init elf $elf] {
    if {$f eq "" || ![file exists $f]} { error "missing $what (run build_vitis.py first)" }
    puts "$what: $f"
}

connect
targets -set -nocase -filter {name =~ "*PSU*"}
rst -system
after 2000

# PL first, then the PS initialisation generated for this design.
targets -set -nocase -filter {name =~ "*PL*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "*PSU*"}
configparams force-mem-access 1
source $init
psu_init
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
catch {psu_protection}

targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $elf
configparams force-mem-access 0
con
puts "running: watch the UART for the BOARD,... lines and RESULT"
