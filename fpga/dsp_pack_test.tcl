# dsp_pack_test.tcl — OOC synth of dsp_pack_probe to confirm the multiply register
# pattern packs into a FULLY pipelined DSP48E2 (no DPIP/DPOP warnings). Fast (~minutes).
# Single-threaded so synth does NOT spawn the multithreaded helper process, which races
# against a concurrently-running impl synth over shared Vivado install-dir scripts.
set_param general.maxThreads 1
set part xczu7ev-ffvc1156-2-e
read_verilog -sv [list [file normalize ../tests/dsp_pack_probe.sv]]
# The registers sit directly on the multiply I/O (no logic between), so standard DSP
# inference packs them into AREG/BREG/MREG/PREG without needing -retiming.
synth_design -top dsp_pack_probe -part $part -mode out_of_context

set out [file normalize ./dsp_pack_test.out]
set fh [open $out w]
proc emit {fh s} { puts $fh $s; flush $fh }

# DSP cells and their pipeline-register attributes.
emit $fh "=== DSP48E2 cells and pipeline-register attributes ==="
foreach c [get_cells -hier -filter {REF_NAME =~ DSP48E2 || PRIMITIVE_TYPE =~ *DSP*}] {
    set areg "?"; set breg "?"; set mreg "?"; set preg "?"
    catch { set areg [get_property AREG   [get_cells $c]] }
    catch { set breg [get_property BREG   [get_cells $c]] }
    catch { set mreg [get_property MREG   [get_cells $c]] }
    catch { set preg [get_property PREG   [get_cells $c]] }
    emit $fh [format "  %-40s AREG=%s BREG=%s MREG=%s PREG=%s" $c $areg $breg $mreg $preg]
}
emit $fh "  (DSP count: [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2}]])"

# DRC: are there any DPIP/DPOP warnings left?
report_drc -checks {DPIP-2 DPOP-3 DPOP-4} -file [file normalize ./dsp_pack_drc.rpt]
emit $fh "\n=== DRC (DPIP-2/DPOP-3/DPOP-4) written to dsp_pack_drc.rpt ==="
emit $fh "DONE"
close $fh
puts "WROTE dsp_pack_test.out"
