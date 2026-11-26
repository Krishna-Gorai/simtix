#!/bin/bash
# run_lanes_board.sh - the board-size cases of every suite on the SIMTiX board top in Verilator
# (WSL), at another lane count, in the exact board configuration: 8 warps, 64 KB L1, 16 MSHRs,
# 16 tags (fpga/create_bd_ps.tcl ... warps8 l1kb64 mshr16 mtags16), writes effective only at
# their B response (MEM_LATE=1). Phase 4 of docs/lanes16_plan.md.
#   sim/run_lanes_board.sh 16 [suite[/app] ...]       (cases from sim/gen_lanes_board.py 16)
#   WARPS=4 sim/run_lanes_board.sh 16 ...             (the 16-lane x 4-warp candidate)
#   CTX=1 ...   memory contexts per warp (SIMTIX_MEM_CTX_PER_WARP, default 2)
#   SFU=<n> ... divide/sqrt cores (SIMTIX_SFU_CORES; default as simtix_pkg: L/8 from 16 lanes, else 1)
#   L1KB=128 ... L1 size in KB (SIMTIX_L1_KB, default 64 as the v3 board)
#   Each case's output (APPCSV lines: cycles per launch) is kept in <case dir>/sim_l<L>_w<W>[_c<C>].log.
# Prints one line per case: "PASS|FAIL suite/app (checks, errors, wall time)".
set -o pipefail
L=${1:-16}; shift || true
W=${WARPS:-8}
C=${CTX:-2}
SF=${SFU:-$(( L >= 16 ? L / 8 : 1 ))}
K=${L1KB:-64}
CS=""; [ "$C" = 2 ] || CS="_c$C"
[ "$SF" = 1 ] || CS="${CS}_s$SF"
[ "$K" = 64 ] || CS="${CS}_k$K"
#   OPCOUNT=1 ... also print each launch's useful operations (SIMTIX_OPCOUNT: OPCOUNT,flop=,mac8=,
#   laneops=); separate build directory and log name (suffix _ops), cycles unchanged
OPS=""; [ -n "$OPCOUNT" ] && { OPS="-DSIMTIX_OPCOUNT"; CS="${CS}_ops"; }
#   AXICOUNT=1 ... also print each launch's AXI4 bytes read and written by the accelerator
#   (AXICSV,case,launch,read_bytes,write_bytes); separate build directory and log name (_axi)
[ -n "$AXICOUNT" ] && { OPS="$OPS -DSIMTIX_AXICOUNT"; CS="${CS}_axi"; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
MDIR=${MDIR:-$HOME/simtix_l${L}_w${W}${CS}}
WLG=25
export PATH=$HOME/v2/tools/verilator/bin:$PATH
cd "$REPO/sim"
A=../rtl/accel
ACCEL="$A/simtix_pkg.sv $A/mmio_regs.sv $A/simt_fpu.sv $A/fp_divsqrt.sv $A/mem_engine.sv $A/warp_pool.sv $A/simt_accel.sv"
CFG="-DSIMTIX_NUM_LANES=$L -DSIMTIX_NUM_WARPS=$W -DSIMTIX_L1_KB=$K -DSIMTIX_L1_MSHR=16 -DSIMTIX_MEM_TAGS=16 -DSIMTIX_MEM_CTX_PER_WARP=$C -DSIMTIX_SFU_CORES=$SF -GMEM_LATE=1 $OPS"
mkdir -p "$MDIR"
BIN=$MDIR/tb_apps
if [ ! -x "$BIN" ] || [ -n "$REBUILD" ]; then
  echo "building $BIN ($L lanes, $W warps, $C contexts per warp, $SF div/sqrt cores, $K KB L1)"
  verilator --binary -sv -Wall --timing -Wno-fatal $CFG -GWORDS_LG=$WLG --Mdir "$MDIR/obj" --top-module tb_apps \
    $ACCEL ../rtl/accel/l1_dcache.sv ../rtl/accel/axi_line_master.sv ../rtl/soc/simt_ps_top.sv \
    ../tests/axi_mem_model.sv ../tests/tb_apps.sv -o "$BIN" > "$MDIR/build.log" 2>&1 || {
      echo "Verilator build failed: $MDIR/build.log"; exit 1; }
fi
BASE=$REPO/build_b$L
[ $# -gt 0 ] || set -- apps suite2 rodinia rivec
fails=0
for sel in "$@"; do
  for man in $(ls -d $BASE/$sel/apps.manifest $BASE/$sel/*/apps.manifest 2>/dev/null); do
    case=${man#$BASE/}; case=${case%/apps.manifest}
    t0=$(date +%s)
    out=$("$BIN" +MANIFEST="$man" 2>&1)
    t1=$(date +%s)
    echo "$out" > "$(dirname "$man")/sim_l${L}_w${W}${CS}.log"     # APPCSV lines: cycles per launch
    res=$(echo "$out" | grep -a "\[tb_apps\] [0-9]* checks" | tail -1)
    if echo "$out" | grep -aq "\[tb_apps\] PASS"; then st=PASS; else st=FAIL; fails=$((fails + 1)); fi
    echo "$st $case ($res, $((t1 - t0)) s)"
    [ $st = PASS ] || echo "$out" | grep -a "FAIL\|wrong\|TIMEOUT\|Error" | head -5
  done
done
echo "== $fails failing case(s)"
exit $fails
