#!/bin/bash
# RiVEC batch 1 (docs/rivec_plan.md) on the SIMTiX board top in Verilator (WSL): builds
# tests/tb_apps.sv once (as `make test-apps`), generates the cases with gen_rivec.py and
# runs them.
#   sim/run_rivec_tb.sh [small|board] [app ...]
#   MANIFEST=/mnt/c/.../apps.manifest sim/run_rivec_tb.sh small|board   (pre-generated cases)
set -eo pipefail
SIZE=${1:-small}; shift || true
REPO=$(cd "$(dirname "$0")/.." && pwd)
MDIR=${MDIR:-$HOME/simtix_suite2}          # shares the Verilator build with suite 2
WLG=${WORDS_LG:-20}; [ "$SIZE" = small ] || WLG=${WORDS_LG:-25}
export PATH=$HOME/v2/tools/verilator/bin:$PATH
cd "$REPO/sim"
A=../rtl/accel
ACCEL="$A/simtix_pkg.sv $A/mmio_regs.sv $A/simt_fpu.sv $A/fp_divsqrt.sv $A/mem_engine.sv $A/warp_pool.sv $A/simt_accel.sv"
# the board build (B3+B4: fpga/create_bd_ps.tcl ... warps8 l1kb64 mshr16 mtags16), writes
# effective only at their B response (MEM_LATE, as run_xsim.py apps_b34_late)
B34="-DSIMTIX_NUM_WARPS=8 -DSIMTIX_L1_KB=64 -DSIMTIX_L1_MSHR=16 -DSIMTIX_MEM_TAGS=16 -GMEM_LATE=1"
mkdir -p "$MDIR"
BIN=$MDIR/tb_apps_w$WLG
if [ ! -x "$BIN" ] || [ -n "$REBUILD" ]; then
  verilator --binary -sv -Wall --timing -Wno-fatal $B34 -GWORDS_LG=$WLG --Mdir "$MDIR/obj_w$WLG" --top-module tb_apps \
    $ACCEL ../rtl/accel/l1_dcache.sv ../rtl/accel/axi_line_master.sv ../rtl/soc/simt_ps_top.sv \
    ../tests/axi_mem_model.sv ../tests/tb_apps.sv -o "$BIN" > "$MDIR/build_w$WLG.log" 2>&1
fi
# MANIFEST=<path> runs cases generated elsewhere (gen_rivec.py on Windows, paths /mnt/c/...)
if [ -n "$MANIFEST" ]; then "$BIN" +MANIFEST="$MANIFEST"; exit $?; fi
python3 gen_rivec.py --size "$SIZE" --out "$MDIR/rv_cases_$SIZE" --words-lg $WLG ${1:+--only "$@"}
"$BIN" +MANIFEST="$MDIR/rv_cases_$SIZE/apps.manifest"
