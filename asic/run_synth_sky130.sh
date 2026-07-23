#!/usr/bin/env bash
# run_synth_sky130.sh - SkyWater 130 nm synthesis of the SIMTiX accelerator.
#
# Run from WSL:
#     cd /mnt/d/Verilog\ Projects/simtix/asic && ./run_synth_sky130.sh
#
# Requires the Docker daemon to be up (it needs a password, so start it first):
#     sudo service docker start
#
# Yosys comes from the OpenLane image, which already bundles a yosys built with
# SystemVerilog support and is pinned to the same open_pdks commit as the local
# sky130 install, so the liberty files and the tool agree.

set -euo pipefail

IMAGE="efabless/openlane:2023.09.07"
PDK_ROOT="${HOME}/.volare"
CORNER="sky130_fd_sc_hd__tt_025C_1v80"
LIB="/build/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/${CORNER}.lib"

# Clock target. The FPGA build closes 100 MHz; sky130 is a much slower process
# than 16 nm FinFET FPGA fabric, so this is a starting constraint to be swept,
# not a claim. 10 ns = 100 MHz.
PERIOD_NS="${PERIOD_NS:-10}"
PERIOD_PS=$(awk "BEGIN{printf \"%d\", ${PERIOD_NS}*1000}")

# Which module to synthesize, and whether to flatten.
#   TOP=simt_fpu   FLATTEN=1  ./run_synth_sky130.sh   # one lane's FP unit
#   TOP=simt_accel            ./run_synth_sky130.sh   # whole accelerator
# simt_accel MUST NOT be flattened on an 8 GB host: abc gets a 483k-gate network
# and is killed for memory. See the note in synth_sky130.ys.
TOP="${TOP:-simt_accel}"
if [ "${FLATTEN:-0}" = "1" ]; then FLATTEN_OPT="-flatten"; else FLATTEN_OPT=""; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "${HERE}/.." && pwd)"

mkdir -p "${HERE}/reports" "${HERE}/results" "${HERE}/gen"

# ---------------------------------------------------------------------------
# SystemVerilog -> Verilog-2005. The OpenLane image's yosys 0.30 supports only a
# small SystemVerilog subset and cannot parse the package import in a module
# header these sources use. sv2v elaborates packages/typedefs/enums/generates
# first. Regenerated every run so the RTL remains the single source of truth.
# ---------------------------------------------------------------------------
SV2V="${SV2V:-$HOME/tools/sv2v-Linux/sv2v}"
if [ ! -x "${SV2V}" ]; then
    echo "ERROR: sv2v not found at ${SV2V}." >&2
    echo "       Install (no root needed):" >&2
    echo "         mkdir -p ~/tools && cd ~/tools && curl -sL -o sv2v.zip \\" >&2
    echo "           https://github.com/zachjs/sv2v/releases/download/v0.0.13/sv2v-Linux.zip" >&2
    echo "         python3 -c 'import zipfile; zipfile.ZipFile(\"sv2v.zip\").extractall(\".\")'" >&2
    echo "         chmod +x ~/tools/sv2v-Linux/sv2v" >&2
    exit 1
fi

# -E Always: keep always_comb/always_ff rather than lowering them to explicit
# Verilog-2005 sensitivity lists. Yosys supports those two natively, whereas the
# lowered form lists unpacked arrays (rv1, rv2, frv1 ...) in the sensitivity
# list, which yosys rejects with "Invalid array access". Everything else --
# packages, typedefs, enums, generates -- is still converted.
echo "=== sv2v: SystemVerilog -> Verilog-2005 (keeping always_comb/always_ff) ==="
"${SV2V}" -E Always \
    "${PROJ}/rtl/accel/simtix_pkg.sv" \
    "${PROJ}/rtl/accel/mmio_regs.sv"  \
    "${PROJ}/rtl/accel/simt_fpu.sv"   \
    "${PROJ}/rtl/accel/fp_divsqrt.sv" \
    "${PROJ}/rtl/accel/warp_pool.sv"  \
    "${PROJ}/rtl/accel/simt_accel.sv" \
    > "${HERE}/gen/simt_accel_flat.v"
echo "    gen/simt_accel_flat.v: $(wc -l < "${HERE}/gen/simt_accel_flat.v") lines"

# always_comb -> always @*. Yosys enforces always_comb's no-latch rule, and it
# fires on the loop index sv2v declares INSIDE each converted block
# ("Latch inferred for signal \sv2v_autoblock_18.l"). That index is an artifact
# of the conversion, not design state -- there is no latch in the RTL. always @*
# derives the same sensitivity automatically, without the strict check and
# without naming the unpacked arrays that broke the explicit-list form.
# always_ff is left alone; yosys handles it directly.
sed -i 's/\balways_comb\b/always @*/g' "${HERE}/gen/simt_accel_flat.v"
echo "    always_comb rewritten to always @*: $(grep -c 'always @\*' "${HERE}/gen/simt_accel_flat.v") blocks"
echo

if [ ! -d "${PDK_ROOT}/sky130A" ]; then
    echo "ERROR: sky130A not found under ${PDK_ROOT}." >&2
    echo "       Install it with volare, or point PDK_ROOT at an existing tree." >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: the Docker daemon is not running." >&2
    echo "       Start it with:  sudo service docker start" >&2
    echo "       (If it fails with a docker0 bridge conflict: stop docker," >&2
    echo "        'sudo ip link delete docker0', remove" >&2
    echo "        /var/lib/docker/network/files/local-kv.db, then start again.)" >&2
    exit 1
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "NOTE: ${IMAGE} is not present locally; pulling (~2 GB, one time)."
    docker pull "${IMAGE}"
fi

# The .ys file carries placeholders so it stays readable; substitute them into a
# scratch copy rather than hard-coding container paths into the tracked script.
sed -e "s|LIBERTY_PATH|${LIB}|g" \
    -e "s|CLOCK_PERIOD_PS|${PERIOD_PS}|g" \
    -e "s|TOP_MODULE|${TOP}|g" \
    -e "s|FLATTEN|${FLATTEN_OPT}|g" \
    "${HERE}/synth_sky130.ys" > "${HERE}/.synth_sky130.resolved.ys"

echo "=== SIMTiX -> sky130 synthesis ==="
echo "    top     : simt_accel"
echo "    corner  : ${CORNER}"
echo "    period  : ${PERIOD_NS} ns (${PERIOD_PS} ps)"
echo

docker run --rm \
    -v "${PDK_ROOT}:/build/pdk" \
    -v "${PROJ}:/work" \
    -e PDK_ROOT=/build/pdk \
    -w /work/asic \
    "${IMAGE}" \
    yosys -c /dev/null -s .synth_sky130.resolved.ys 2>&1 | tee "${HERE}/reports/yosys.log"

echo
echo "=== done ==="
echo "  cell/area report : asic/reports/stat.txt"
echo "  full log         : asic/reports/yosys.log"
echo "  gate netlist     : asic/results/simt_accel_sky130.v"
