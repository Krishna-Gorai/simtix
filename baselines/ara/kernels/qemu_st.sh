#!/bin/bash
# qemu_st.sh - the AK_SELFTEST program under qemu-riscv64 (RVV 1.0, VLEN 1024: QEMU's maximum; the kernels set vl with vsetvl), the
# reference model for the vector kernels: ./qemu_st.sh [AK_ST_MASK]
set -e
cd "$(dirname "$0")"
GCC=/c/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc
CF="-mabi=lp64d -mcmodel=medany -O3 -ffp-contract=off -fno-math-errno -fno-common -std=gnu11 -I. -I../../../kernels/suite2 -I../../../kernels/rodinia -I../../../kernels/rivec -DAK_SELFTEST -DAK_QEMU -DAK_ST_MASK=${1:-0xFFF}"
mkdir -p build/q
"$GCC" $CF -march=rv64gc -c ak_scalar.c -o build/q/scalar.o
"$GCC" $CF -march=rv64gcv -fno-tree-vectorize -fno-tree-slp-vectorize -c ak_vector.c -o build/q/vector.o
"$GCC" $CF -march=rv64gc -c ak_main.c -o build/q/main.o
"$GCC" -mabi=lp64d -march=rv64gcv -mcmodel=medany -Wl,-Ttext-segment=0x80000000 build/q/main.o build/q/scalar.o build/q/vector.o -o build/q/ak_q.elf
MSYS_NO_PATHCONV=1 wsl -e bash -c "~/qemu_dl/root/usr/bin/qemu-riscv64 -cpu rv64,v=true,vlen=1024,elen=64,vext_spec=v1.0 /mnt/c/work/SIMTiX-v2/baselines/ara/kernels/build/q/ak_q.elf; echo EXIT \$?"
