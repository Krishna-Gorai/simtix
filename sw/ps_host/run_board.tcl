# run_board.tcl  -  program the ZCU102 (or ZCU104) over JTAG and run the A53 host
#
#   xsdb sw/ps_host/run_board.tcl [zcu104] [out.txt]     (from the repository root)
#
# Board setup: the USB-JTAG cable (ZCU102: micro-USB J2) is enough. The host
# program's console is copied into DDR, and this script waits for the run to finish
# and writes it to docs/<board>_board_run.txt. A terminal on the UART (ZCU102: J83,
# 115200 8N1, first of the four ports; or sw/ps_host/capture_uart.ps1) shows it live.
# Expects sw/ps_host/build_vitis.py to have built the board's workspace,
# sw/ps_host/ws_zcu102 or sw/ps_host/ws.

set here [file dirname [file normalize [info script]]]
set ws   [file join $here [expr {[lsearch -exact $argv zcu104] >= 0 ? "ws" : "ws_zcu102"}]]
# Console text of the run (also on the UART): docs/<board>_board_run.txt or a .txt argument
set brd  [expr {[lsearch -exact $argv zcu104] >= 0 ? "zcu104" : "zcu102"}]
set out  [file normalize [file join $here .. .. docs ${brd}_board_run.txt]]
foreach a $argv { if {[string match -nocase *.txt $a]} { set out [file normalize $a] } }

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

# System counter (IOU_SCNTRS) against the host clock over 10 s: the A53 times use
# COUNTS_PER_SECOND from the hardware description, printed at the end of the run.
proc r32 {a} { return [lindex [mrd -force -value $a 1] 0] }
proc counter {} {
    set t0 [clock microseconds]
    set lo [r32 0xFF260008]
    set hi [r32 0xFF26000C]
    set t1 [clock microseconds]
    return [list [expr {($hi << 32) | $lo}] [expr {($t0 + $t1) / 2}]]
}
lassign [counter] c0 t0
after 10000
lassign [counter] c1 t1
set cps [expr {round(double($c1 - $c0) * 1e6 / double($t1 - $t0))}]
puts "system counter: $cps Hz (measured)"

targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $elf
# The Rodinia suite (argument rodinia): the data blob of sim/rd_data.py at 0x7000_0000
if {[lsearch -exact $argv rodinia] >= 0} {
    set blob [file normalize [file join $here .. .. build_rodinia rd_data.bin]]
    if {![file exists $blob]} { error "missing $blob (run python sim/rd_data.py first)" }
    puts "data blob: $blob"
    dow -data $blob 0x70000000
}
configparams force-mem-access 0
con
puts "running: the console also goes to DDR and is written to $out at the end"

# Wait for the DONE mark of main.c, then read the console text back over JTAG.
set OUTBUF 0x0E000000
set MB     0x0EF00000
targets -set -nocase -filter {name =~ "*PSU*"}
set done 0
set last -1
for {set i 0} {$i < 1800} {incr i} {
    after 2000
    if {[catch {set n [r32 [expr {$MB + 4}]]; set d [r32 [expr {$MB + 8}]]}]} { continue }
    if {$n != $last} {
        puts [format "  %4d s: %d bytes of console text" [expr {2 * ($i + 1)}] $n]; set last $n
        # keep what has run so far on the PC (<out>.partial), in case the board loses power
        catch { mrd -force -bin -file $out.partial $OUTBUF [expr {($n + 3) / 4}] }
    }
    if {$d == 0x444F4E45} { set done 1; break }
}
set n [r32 [expr {$MB + 4}]]
set bin [file join $here console.bin]
if {$n > 0} { mrd -force -bin -file $bin $OUTBUF [expr {($n + 3) / 4}] }
set f [open $bin rb]; set data [string range [read $f] 0 [expr {$n - 1}]]; close $f
set f [open $out wb]
puts $f "# run_board.tcl [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}], system counter measured: $cps Hz"
puts -nonewline $f $data
close $f
file delete $bin
puts [format "wrote %s (%d bytes)%s" $out $n [expr {$done ? "" : " -- run did NOT finish"}]]
disconnect
