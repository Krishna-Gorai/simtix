#!/usr/bin/env bash
# build_kernels.sh  -  assemble every SIMTiX benchmark kernel and emit, for each:
#     <name>.elf   <name>.bin            (committed, as the existing kernels are)
#     <name>.hex   one 8-digit word/line (little-endian instruction words)
#     <name>.svh   SystemVerilog `mem[at+k] = 32'h....;` lines for the harness
#
# Usage:  bash kernels/build_kernels.sh        (run from the repo root or anywhere)
set -euo pipefail

GCC=riscv-none-elf-gcc
OBJCOPY=riscv-none-elf-objcopy
OBJDUMP=riscv-none-elf-objdump
command -v "$GCC" >/dev/null || { echo "ERROR: $GCC not on PATH"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Accelerator kernels (rv32im) — the SIMT engine supports `mul`.
KERNELS="vadd/vadd saxpy/saxpy fir/fir relu/relu collatz/collatz reduce/reduce \
         matmul/matmul_naive matmul/matmul_smem divergence/heavy_div"
# Scalar host-CPU baselines (rv32i — the 5-stage core has no `mul`; built below).
SCALAR="scalar/s_vadd scalar/s_saxpy scalar/s_fir scalar/s_relu scalar/s_collatz scalar/s_reduce"
# Floating-point kernels (rv32imf — M14: the engine has an f-regfile + flw/fsw).
FPKERNELS="fptest/fpcopy fptest/fparith"

emit_words() {  # $1 = .bin  -> stdout: one 32-bit little-endian word per line (hex)
    python - "$1" <<'PY'
import sys, struct
data = open(sys.argv[1], "rb").read()
assert len(data) % 4 == 0, "binary not word-aligned"
for i in range(0, len(data), 4):
    print("%08x" % struct.unpack("<I", data[i:i+4])[0])
PY
}

build_one() {  # $1 = name (dir/base) ; $2 = -march
    local k="$1" march="$2"
    local dir="$HERE/$(dirname "$k")" base="$(basename "$k")"
    local src="$dir/$base.S"
    [ -f "$src" ] || { echo "skip (no source): $src"; return; }
    echo "=== $k ($march) ==="
    "$GCC" -march="$march" -mabi=ilp32 -nostdlib -nostartfiles \
           -Wl,-Ttext=0 -o "$dir/$base.elf" "$src"
    "$OBJCOPY" -O binary "$dir/$base.elf" "$dir/$base.bin"
    emit_words "$dir/$base.bin" > "$dir/$base.hex"
    nwords=$(wc -l < "$dir/$base.hex")
    # SystemVerilog include: mem[at+k] = 32'hXXXXXXXX;   (one per word)
    awk '{printf "        mem[at+%d] = 32'\''h%s;\n", NR-1, $0}' "$dir/$base.hex" > "$dir/$base.svh"
    echo "    $nwords words -> $dir/$base.{elf,bin,hex,svh}"
    "$OBJDUMP" -d "$dir/$base.elf" | sed -n '/<_start>:/,$p'
}

for k in $KERNELS;   do build_one "$k" rv32im;  done
for k in $SCALAR;    do build_one "$k" rv32i;   done
for k in $FPKERNELS; do build_one "$k" rv32imf; done
echo "DONE."
