#!/bin/bash
# build.sh - build the Ara/CVA6 benchmark program (Git Bash, Windows xPack GCC 15.2).
#
#   build/ak.elf     board program (reads the mailbox, ak.h)
#   build/ak_st.elf  self-test for the Verilator wrapper model (run_ps_sim.sh)
#
# Scalar code (kernels, main, Ara's printf/string/serial) is compiled for RV64GC, so
# GCC cannot vectorize the CVA6 kernels; only ak_vector.c (and crt0.S, which enables
# the vector unit) is compiled with V, and with GCC's auto-vectorizer off: every vector
# instruction is one of the intrinsics. (Left on, GCC vectorizes the kernels' scalar
# set-up, e.g. pointer arrays stored with vse64 and read back by scalar loads, which
# Ara does not order, and uses fractional LMUL and in-place narrowing.) -ffp-contract=off: no fused multiply-add
# besides the explicit fmaf / vfmacc / vfmadd. Flags otherwise as Ara's GCC build
# (apps/common/runtime.mk), without -ffast-math.
#
#   ./build.sh [extra CFLAGS, e.g. -DAK_ST_MASK=0x001]
set -e
cd "$(dirname "$0")"
GCC=/c/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc
COMMON=/c/work/ara/apps/common
LD=/c/work/ara/sw_gcc/link.ld          # arch.link.ld, L2 = 0x8000_0000, 32 MB
mkdir -p build
CF="-mabi=lp64d -mcmodel=medany -O3 -ffp-contract=off -fno-math-errno -fno-common -fno-builtin-printf \
    -fno-tree-loop-distribute-patterns -ffunction-sections -fdata-sections -std=gnu11 \
    -Wall -Wextra -I$COMMON -I. -I../../../kernels/suite2 -I../../../kernels/rodinia -I../../../kernels/rivec -DNR_LANES=2 -DVLEN=2048 $*"
S="-march=rv64gc"
V="-march=rv64gcv"

obj() { # <out> <arch> <src> [defines]
    "$GCC" $CF $2 $4 -c "$3" -o "build/$1"
}
obj crt0.o     "$V" $COMMON/crt0.S
obj printf.o   "$S" $COMMON/printf.c
obj string.o   "$S" $COMMON/string.c
obj serial.o   "$S" $COMMON/serial.c
obj scalar.o   "$S" ak_scalar.c
if [ "$VCC" = clang ]; then   # VCC=clang ./build.sh: the vector kernels with clang 21 (Ara's own flow uses LLVM)
    MSYS_NO_PATHCONV=1 wsl -e bash -c "export LD_LIBRARY_PATH=\$HOME/clang_dl/root/usr/lib/x86_64-linux-gnu:\$HOME/clang_dl/root/usr/lib/llvm-21/lib; cd /mnt/c/work/SIMTiX-v2/baselines/ara/kernels && \$HOME/clang_dl/root/usr/lib/llvm-21/bin/clang --target=riscv64-unknown-elf -march=rv64gcv -mabi=lp64d -mcmodel=medany -O3 -ffp-contract=off -fno-math-errno -fno-vectorize -fno-slp-vectorize -fno-common -std=gnu11 -I. $* -c ak_vector.c -o build/vector.o"
else
    obj vector.o   "$V" ak_vector.c "-fno-tree-vectorize -fno-tree-slp-vectorize"
fi
obj main.o     "$S" ak_main.c
obj main_st.o  "$S" ak_main.c -DAK_SELFTEST

LF="-mabi=lp64d -march=rv64gcv -mcmodel=medany -nostdlib -nostartfiles -T $LD -Wl,--gc-sections"
B=build
"$GCC" $LF $B/crt0.o $B/main.o    $B/scalar.o $B/vector.o $B/printf.o $B/string.o $B/serial.o -lgcc -o $B/ak.elf
"$GCC" $LF $B/crt0.o $B/main_st.o $B/scalar.o $B/vector.o $B/printf.o $B/string.o $B/serial.o -lgcc -o $B/ak_st.elf
/c/toolchains/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-size $B/ak.elf $B/ak_st.elf
