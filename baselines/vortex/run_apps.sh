#!/bin/bash
# Run the SIMTiX application suite on Vortex (WSL).
#
#   baselines/vortex/run_apps.sh [rtlsim|simx] [manifest] [case]
#
# Copies simtix_apps/ into Vortex's regression tree, reconfigures the build so it
# picks the folder up, and runs it through ci/blackbox.sh with the configuration the
# xczu7ev synthesis uses (syn/): 1 core, 4 warps, 8 threads, RV32IMAF, one memory
# bank. The manifest defaults to build_apps/apps.manifest from sim/gen_apps.py.
# Output: the run log in build_vortex/<driver>.log, APPCSV lines in
# build_vortex/<driver>.csv.
set -eo pipefail

DRIVER=${1:-rtlsim}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
MANIFEST=${2:-$REPO/build_apps/apps.manifest}
CASE=${3:-}
VX=${VORTEX_HOME:-$HOME/v2/vortex}
OUT=$REPO/build_vortex
mkdir -p "$OUT"

# Vortex builds its simulators with -Werror, and GCC 13+ flags spdlog's bundled fmt
# with a false-positive -Wdangling-reference. A CXXFLAGS in the environment would be
# exported, with the app's flags appended, into the simulator builds, so a g++/c++
# wrapper adds the -Wno instead.
WRAP=$HOME/v2/gccwrap
for n in g++ c++; do
  if [ ! -x "$WRAP/$n" ]; then
    mkdir -p "$WRAP"
    printf '#!/bin/sh\nexec /usr/bin/%s "$@" -Wno-dangling-reference\n' "$n" > "$WRAP/$n"
    chmod +x "$WRAP/$n"
  fi
done
export PATH=$WRAP:$HOME/v2/tools/verilator/bin:$PATH
export CONFIGS="-DVX_CFG_EXT_A_ENABLE -DVX_CFG_PLATFORM_MEMORY_NUM_BANKS=1 ${EXTRA_CONFIGS:-}"

mkdir -p "$VX/tests/regression/simtix_apps"
cp "$HERE"/simtix_apps/{Makefile,common.h,kernel.cpp,main.cpp} "$VX/tests/regression/simtix_apps/"
if [ ! -f "$VX/build/tests/regression/simtix_apps/Makefile" ]; then
  (cd "$VX/build" && ../configure --xlen=32 --tooldir="$HOME/v2/tools" \
     --osversion=ubuntu/focal --prefix="$VX/build/install")
fi

ARGS="-m $MANIFEST"
[ -n "$CASE" ] && ARGS="$ARGS -c $CASE"
cd "$VX/build"
./ci/blackbox.sh --driver="$DRIVER" --app=simtix_apps --cores=1 --warps=4 --threads=8 \
  --args="$ARGS" 2>&1 | tee "$OUT/$DRIVER.log"
grep '^APPCSV' "$OUT/$DRIVER.log" > "$OUT/$DRIVER.csv" || true
