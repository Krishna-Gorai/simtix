# paths_at.tcl  -  list the setup paths of a routed design that would fail at a
#                  faster clock, grouped by the blocks they start and end in
#
#   vivado -mode batch -source paths_at.tcl -tclargs <routed.dcp> <target_ns> <out.csv>
#
# Read-only: opens the checkpoint, writes one CSV row per failing endpoint (worst
# path to it): slack at the target, logic levels, source and destination cells.
set dcp    [lindex $argv 0]
set target [lindex $argv 1]
set out    [lindex $argv 2]
set_param general.maxThreads 2
open_checkpoint $dcp
set period 10.0
set lim [expr {$period - $target}]
set paths [get_timing_paths -setup -max_paths 100000 -nworst 1 -unique_pins -slack_lesser_than $lim]
set fh [open $out w]
puts $fh "slack_at_target,levels,source,destination"
foreach p $paths {
    set s [expr {[get_property SLACK $p] - $lim}]
    puts $fh [format "%.3f,%d,%s,%s" $s [get_property LOGIC_LEVELS $p] \
        [get_property PARENT_CELL [get_cells -of [get_property STARTPOINT_PIN $p]]] \
        [get_property PARENT_CELL [get_cells -of [get_property ENDPOINT_PIN $p]]]]
}
close $fh
puts "PATHS [llength $paths] failing at $target ns -> $out"
