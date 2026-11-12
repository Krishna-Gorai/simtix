#!/bin/bash
# Build the Verilator model of vortex_ps_top + vx_ps_tb.cpp (WSL), at the board
# configuration: 1 core, WARPS (8) warps, 8 threads, RV32IMAF + A, one memory bank.
#   WARPS=8 baselines/vortex/tb/build_tb.sh
set -eo pipefail
W=${WARPS:-8}
VX=${VORTEX_HOME:-$HOME/v2/vortex}
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=$HOME/v2/gccwrap:$HOME/v2/tools/verilator/bin:$PATH
mkdir -p "$VX/build/sim/vxps"
cp "$HERE/Makefile" "$VX/build/sim/vxps/Makefile"
sed "s|@VORTEX_HOME@|$VX|g" "$VX/sim/xrtsim/verilator.vlt.in" > "$VX/build/sim/vxps/verilator.vlt"
cd "$VX/build/sim/vxps"
make -s CONFIGS="-DVX_CFG_NUM_CORES=1 -DVX_CFG_NUM_WARPS=$W -DVX_CFG_NUM_THREADS=8 -DVX_CFG_EXT_A_ENABLE -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1" \
     SIM_DIR_VLT=verilator.vlt
ls -la vx_ps_tb
