#!/bin/bash
# run_qtest.sh - build rv_qtest.c for RV64GCV and run it under qemu-riscv64 (RVV 1.0, VLEN 1024).
# RIVEC: the RiVEC checkout (default C:/work/rivec_src/riscv-vectorized-benchmark-suite).
set -e
cd "$(dirname "$0")"
RIVEC=${RIVEC:-C:/work/rivec_src/riscv-vectorized-benchmark-suite}   # C:/ works for Git Bash and Windows Python
GCC=/c/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc
mkdir -p build
# Generated from the RiVEC checkout (not in the repository): RiVEC's Black-Scholes vector
# functions verbatim (lines 102-233 of blackscholes.cpp), the same with the masked subtract
# made a vmerge (the Ara version), and in_64K.input as FP32 bits.
BS=$RIVEC/_blackscholes/src/blackscholes.cpp
awk 'NR>=102 && NR<=233' "$BS" > rivec_bs_vector.inc
sed -e 's/xLocal   = _MM_SUB_f32_MASK(xMask, xOne, xLocal, gvl);/xLocal   = _MM_MERGE_f32(xLocal, _MM_SUB_f32(xOne, xLocal, gvl), xMask, gvl);/' \
    -e 's/CNDF_SIMD/CNDF_SIMD_M/g' -e 's/BlkSchlsEqEuroNoDiv_vector/BlkSchlsEqEuroNoDiv_vector_M/g' \
    rivec_bs_vector.inc > rivec_bs_vector_merge.inc
grep -q "_MM_MERGE_f32(xLocal" rivec_bs_vector_merge.inc || { echo "vmerge substitution failed"; exit 1; }
RIVEC="$RIVEC" python ../../../sim/rv_qtest_input.py bs_input.h
"$GCC" -mabi=lp64d -march=rv64gcv -mcmodel=medany -O2 -ffp-contract=off -fno-math-errno -std=gnu11 \
    -fgnu89-inline -fno-tree-vectorize -fno-tree-slp-vectorize -I. -I"$RIVEC/common" \
    -Wl,-Ttext-segment=0x80000000 rv_qtest.c -o build/rv_qtest.elf
MSYS_NO_PATHCONV=1 wsl -e bash -c "~/qemu_dl/root/usr/bin/qemu-riscv64 -cpu rv64,v=true,vlen=1024,elen=64,vext_spec=v1.0 /mnt/c/work/SIMTiX-v2/kernels/rivec/qtest/build/rv_qtest.elf; echo EXIT \$?"
