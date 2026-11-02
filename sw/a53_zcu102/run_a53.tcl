# run_a53.tcl  -  run the A53 references on the ZCU102 and collect the console
#
#   xsdb sw/a53_zcu102/run_a53.tcl [O2|O3] [output.txt]   (from the repository root)
#
# Needs the PS brought up by run_init.tcl (DDR4 in normal mode). Measures the
# system counter (IOU_SCNTRS) against the host clock over 10 s, passes the
# frequency to the program through its mailbox, runs build/a53_apps_<opt>.elf on
# A53 #0, waits for "DONE" and writes the console text (a buffer in DDR) to the
# output file (default docs/zcu102_a53_run_<opt>.txt).

set here [file dirname [file normalize [info script]]]
set opt  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "O2"}]
set elf  [file join $here build a53_apps_$opt.elf]
set out  [expr {[llength $argv] > 1 ? [lindex $argv 1] : [file join $here .. .. docs zcu102_a53_run_$opt.txt]}]
set OUTBUF 0x0E000000
set MB     0x0EF00000
if {![file exists $elf]} { error "missing $elf (run build_a53.py)" }

proc r32 {a} { return [lindex [mrd -force -value $a 1] 0] }
proc counter {} {
    set t0 [clock microseconds]
    set lo [r32 0xFF260008]
    set hi [r32 0xFF26000C]
    set t1 [clock microseconds]
    return [list [expr {($hi << 32) | $lo}] [expr {($t0 + $t1) / 2}]]
}

connect
targets -set -nocase -filter {name =~ "*PSU*"}
if {([r32 0xFD070004] & 7) != 1} { error "DDR4 is not in normal mode: run run_init.tcl first" }

lassign [counter] c0 t0
after 10000
lassign [counter] c1 t1
set cps [expr {round(double($c1 - $c0) * 1e6 / double($t1 - $t0))}]
puts [format "system counter: %d Hz (%.3f s of host time)" $cps [expr {($t1 - $t0) / 1e6}]]

mwr -force $MB [list $cps 0 0 0]
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
after 500
dow $elf
con
puts "running $elf ..."

targets -set -nocase -filter {name =~ "*PSU*"}
set done 0
set last -1
for {set i 0} {$i < 3600} {incr i} {
    after 2000
    if {[catch {set n [r32 [expr {$MB + 4}]]; set d [r32 [expr {$MB + 8}]]}]} { continue }
    if {$n != $last} { puts [format "  %4d s: %d bytes of console text" [expr {2 * ($i + 1)}] $n]; set last $n }
    if {$d == 0x444F4E45} { set done 1; break }
}
set n [r32 [expr {$MB + 4}]]
set words [expr {($n + 3) / 4}]
set bin [file join $here build console.bin]
if {$words > 0} { mrd -force -bin -file $bin $OUTBUF $words }
set f [open $bin rb]; set data [string range [read $f] 0 [expr {$n - 1}]]; close $f
set f [open $out wb]; puts -nonewline $f $data; close $f
puts [format "wrote %s (%d bytes)%s" $out $n [expr {$done ? "" : " -- run did NOT finish"}]]
disconnect
