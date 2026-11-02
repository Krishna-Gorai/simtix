# run_init.tcl  -  bring up the ZCU102 PS over JTAG and check DDR4
#
#   xsdb sw/a53_zcu102/run_init.tcl        (from the repository root)
#
# Loads build/psu_init.elf (build_init.py) into OCM on A53 #0, runs U-Boot's
# zcu102-rev1.1 psu_init(), waits for the mailbox at 0xFFFF_F000, then tests DDR4
# by writing and reading patterns over the debug port and prints the APU clock.

set here [file dirname [file normalize [info script]]]
set elf  [file join $here build psu_init.elf]
if {![file exists $elf]} { error "missing $elf (run build_init.py)" }

proc r32 {a} { return [lindex [mrd -force -value $a 1] 0] }

connect
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
after 500
dow $elf
con
puts "psu_init running..."
set mb 0xFFFFF000
set done 0
for {set i 0} {$i < 120} {incr i} {
    after 250
    if {[catch {set d [r32 [expr {$mb + 12}]]}]} { continue }
    if {$d == 0x444F4E45} { set done 1; break }
}
targets -set -nocase -filter {name =~ "*PSU*"}
puts [format "mailbox: tag 0x%08X stage %d result %d done 0x%08X messages %d" \
    [r32 $mb] [r32 [expr {$mb + 4}]] [r32 [expr {$mb + 8}]] [r32 [expr {$mb + 12}]] \
    [r32 [expr {$mb + 16}]]]
if {!$done} {
    targets -set -nocase -filter {name =~ "*A53*#0"}
    catch {stop}
    puts "psu_init did not finish; A53 #0 state: [state]"
    catch {puts "pc: [rrd pc]"}
    error "PS initialisation incomplete"
}

# APU clock: PS_REF_CLK 33.333 MHz * FBDIV / (DIV2 ? 2 : 1) / ACPU divisor
set apll [r32 0xFD1A0020]
set acpu [r32 0xFD1A0060]
set fb   [expr {($apll >> 8) & 0x7F}]
set div2 [expr {($apll >> 16) & 1}]
set byp  [expr {($apll >> 3) & 1}]
set adiv [expr {($acpu >> 8) & 0x3F}]
set src  [expr {$acpu & 0x7}]
set fvco [expr {33.333 * $fb}]
set fout [expr {$div2 ? $fvco / 2.0 : $fvco}]
puts [format "APLL_CTRL 0x%08X (FBDIV %d DIV2 %d BYPASS %d)  ACPU_CTRL 0x%08X (SRC %d DIV %d)" \
    $apll $fb $div2 $byp $acpu $src $adiv]
if {$src == 0 && $adiv > 0} { puts [format "A53 clock: %.1f MHz" [expr {$fout / $adiv}]] }
puts [format "DDRC_STAT 0x%08X (operating mode %d)" [r32 0xFD070004] [expr {[r32 0xFD070004] & 7}]]

# DDR4 test over the debug port: three regions of the low 2 GB
set bad 0
foreach base {0x00100000 0x10000000 0x7FF00000} {
    for {set k 0} {$k < 64} {incr k} {
        set a [expr {$base + 4 * $k}]
        set v [expr {(0xA5A50000 | $k) ^ ($base >> 4)}]
        mwr -force $a $v
    }
    for {set k 0} {$k < 64} {incr k} {
        set a [expr {$base + 4 * $k}]
        set v [expr {((0xA5A50000 | $k) ^ ($base >> 4)) & 0xFFFFFFFF}]
        if {[r32 $a] != $v} { incr bad }
    }
    puts [format "DDR 0x%08X: %s" $base [expr {$bad ? "ERRORS so far $bad" : "ok"}]]
}
puts [expr {$bad ? "DDR TEST FAILED ($bad words)" : "DDR TEST PASSED"}]
disconnect
