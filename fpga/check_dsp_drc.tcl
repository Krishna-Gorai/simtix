# check_dsp_drc.tcl  -  OOC synth of simt_accel + confirm the inferred DSP48s are
# FULLY PIPELINED (AREG/BREG + MREG + PREG) so report_drc finds no DPIP-2/DPOP-3/
# DPOP-4 advisories. This validates the B1 (decomposed integer multiply) + B2 (shared
# fully-pipelined FP significand multiply) clean-DRC work IN CONTEXT (the dsp_pack_probe
# only proved the isolated patterns). Run from fpga/:
#
#   vivado -mode batch -source check_dsp_drc.tcl
#
# Host notes (8 GB): maxThreads 2 + flatten none bounds peak RAM; NO -retiming (the
# registers sit directly on the multiply I/O so direct inference packs them, and
# -retiming has a known helper-spawn crash signature here); -no_timing_driven keeps it
# fast since this run only checks DSP packing/DRC, not Fmax.

set_param general.maxThreads 2

set part    xczu7ev-ffvc1156-2-e
set rtl_dir [file normalize ../rtl/accel]
set out_dir [file normalize ./reports_dsp_drc]
file mkdir $out_dir

read_verilog -sv [list \
    $rtl_dir/simtix_pkg.sv \
    $rtl_dir/mmio_regs.sv  \
    $rtl_dir/simt_fpu.sv   \
    $rtl_dir/fp_divsqrt.sv \
    $rtl_dir/warp_pool.sv  \
    $rtl_dir/simt_accel.sv ]
read_xdc [list [file normalize ./constr/simt_accel_ooc.xdc]]

synth_design -top simt_accel -part $part -mode out_of_context \
    -flatten_hierarchy none -no_timing_driven

# ── DSP pipeline-register inventory ─────────────────────────────────────────────
set dsps [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.dsp.* || REF_NAME =~ DSP48*}]
set fh [open $out_dir/dsp_attrs.rpt w]
puts $fh [format "%-60s %-7s %-7s %-7s %-7s %-8s %-7s" cell AREG BREG MREG PREG ADREG ACASC]
set nfull 0
set npart 0
foreach c [lsort [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]] {
    set areg  [get_property AREG  $c]
    set breg  [get_property BREG  $c]
    set mreg  [get_property MREG  $c]
    set preg  [get_property PREG  $c]
    set adreg [get_property ADREG $c]
    set acasc [get_property ACASCREG $c]
    puts $fh [format "%-60s %-7s %-7s %-7s %-7s %-8s %-7s" $c $areg $breg $mreg $preg $adreg $acasc]
    if {$mreg >= 1 && $preg >= 1 && $areg >= 1 && $breg >= 1} { incr nfull } else { incr npart }
}
close $fh
puts "========== DSP PIPELINE INVENTORY =========="
puts [format "  total DSP48 : %d" [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]]
puts [format "  fully packed (A/B + M + P) : %d" $nfull]
puts [format "  partially packed           : %d" $npart]

# ── DRC: just the DSP-pipelining advisories we are trying to zero ────────────────
report_drc -checks {DPIP-2 DPOP-3 DPOP-4} -file $out_dir/dsp_drc.rpt
set dpip [llength [get_drc_violations -name * ]]
puts "========== DSP DRC (DPIP-2 / DPOP-3 / DPOP-4) =========="
puts "  see reports_dsp_drc/dsp_drc.rpt"
report_utilization -file $out_dir/util.rpt
puts "  (utilization -> reports_dsp_drc/util.rpt)"
puts "========================================================"
