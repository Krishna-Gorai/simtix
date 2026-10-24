#!/bin/bash
# Generate Vortex's preprocessed source tree for an out-of-context Vivado build on the
# ZCU104's xczu7ev, and stage it on C: for Vivado on Windows (run_syn.ps1). WSL.
#
#   baselines/vortex/syn/gen_sources.sh [name]
#
# Configuration matched to SIMTiX: 1 core, 4 warps, 8 threads, RV32IMAF, one memory
# bank. Everything else is Vortex's default (16 KB 4-way I- and D-cache, 64 B lines,
# local memory, FPU_TYPE=DSP, i.e. the Xilinx floating-point IPs).
set -eo pipefail
NAME=${1:-zcu104_1c4w8t}
VX=${VORTEX_HOME:-$HOME/v2/vortex}
WIN=${VORTEX_SYN_DIR:-/mnt/c/work/vortex_syn}
CONFIGS="-DVX_CFG_NUM_CORES=1 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_EXT_A_ENABLE -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1"
export PATH=$HOME/v2/tools/verilator/bin:$PATH

# The flow runs in the build tree, where config.mk lives.
cd "$VX/build/hw/syn/xilinx/dut"
mkdir -p "${NAME}_vortex"
cp build.mk "${NAME}_vortex/Makefile"
make -C "${NAME}_vortex" DUT=vortex gen-sources CONFIGS="$CONFIGS" DEVICE=xczu7ev-ffvc1156-2-e
SRC=$PWD/${NAME}_vortex/project_1

mkdir -p "$WIN/scripts" "$WIN/dut" "$WIN/$NAME/project_1"
cp -r "$VX/hw/scripts/." "$WIN/scripts/"
cp "$VX"/hw/syn/xilinx/dut/{project.tcl,project.xdc,pre_opt_hook.tcl} "$WIN/dut/"
rm -rf "$WIN/$NAME/project_1/src"
cp -r "$SRC/src" "$WIN/$NAME/project_1/src"
# Vivado runs in $WIN/$NAME: make the file list relative to it.
sed "s#^\(+incdir+\)\?$SRC/#\1project_1/#" "$SRC/sources.txt" > "$WIN/$NAME/project_1/sources.txt"
{ (cd "$VX" && git rev-parse --short HEAD); echo "CONFIGS=$CONFIGS"; } > "$WIN/$NAME/vortex_rev.txt"
echo "staged $WIN/$NAME"
