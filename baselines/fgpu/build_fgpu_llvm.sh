#!/bin/bash
# build_fgpu_llvm.sh - FGPU's OpenCL compiler (docs/fgpu_plan.md, phase 0): LLVM and clang
# 3.7.1 with FGPU's backend (github.com/malkadi/FGPU, llvm-3.7.1.src.fgpu), built in WSL.
#
# FGPU's own script (scripts/download_and_compile_llvm.sh) builds twice: clang for MIPS
# (the OpenCL front end, -target mips) and then LLVM for FGPU (llc -march=fgpu). This
# builds once with both targets and clang, in Release. LLVM 3.7 does not build with the
# system's GCC 15 and CMake 4, so the toolchain is GCC 7, CMake 3.16 and Python 2.7 from
# conda-forge in ~/fgpu_tools/env (micromamba, no root):
#   micromamba create -p ~/fgpu_tools/env -c conda-forge gxx_linux-64=7 gcc_linux-64=7 \
#       cmake=3.16 make python=2.7 sysroot_linux-64=2.17
# (the sysroot pin matters: conda's default sysroot, glibc 2.39, has .relr.dyn sections
# that GCC 7's binutils 2.36 cannot read, and every link fails)
# Sources (releases.llvm.org) in ~/fgpu_llvm/dl, build in ~/fgpu_llvm/build (ext4).
#   bash baselines/fgpu/build_fgpu_llvm.sh          (from WSL; log ~/fgpu_llvm/build.log)
set -eo pipefail
FGPU=${FGPU:-/mnt/c/work/fgpu_src/FGPU}
TOP=$HOME/fgpu_llvm
ENV=$HOME/fgpu_tools/env
JOBS=${JOBS:-2}
mkdir -p "$TOP/dl"
cd "$TOP/dl"
for f in llvm-3.7.1.src cfe-3.7.1.src; do
  [ -s $f.tar.xz ] || curl -fsSLO "https://releases.llvm.org/3.7.1/$f.tar.xz" \
    || curl -fsSLO "https://github.com/llvm/llvm-project/releases/download/llvmorg-3.7.1/$f.tar.xz"
done
cd "$TOP"
if [ ! -d src ]; then
  tar xf dl/llvm-3.7.1.src.tar.xz && mv llvm-3.7.1.src src
  tar xf dl/cfe-3.7.1.src.tar.xz -C src/tools && mv src/tools/cfe-3.7.1.src src/tools/clang
  # FGPU's backend files (copied, as the original links them)
  S=$FGPU/llvm-3.7.1.src.fgpu
  cp "$S/CMakeLists.txt" src/
  cp "$S/cmake/config-ix.cmake" src/cmake/
  cp "$S/include/llvm/ADT/Triple.h" src/include/llvm/ADT/
  cp "$S/include/llvm/Object/ELFObjectFile.h" src/include/llvm/Object/
  cp "$S/include/llvm/Support/ELF.h" src/include/llvm/Support/
  cp "$S/lib/Support/Triple.cpp" src/lib/Support/
  cp "$S/lib/Target/LLVMBuild.txt" src/lib/Target/
  cp -r "$S/lib/Target/Fgpu" src/lib/Target/
fi
export PATH=$ENV/bin:$PATH
mkdir -p build && cd build
cmake -G "Unix Makefiles" ../src \
  -DCMAKE_C_COMPILER=$ENV/bin/x86_64-conda-linux-gnu-gcc \
  -DCMAKE_CXX_COMPILER=$ENV/bin/x86_64-conda-linux-gnu-g++ \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD="Mips;Fgpu" \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF -DPYTHON_EXECUTABLE=$ENV/bin/python2.7
make -j$JOBS clang llc llvm-objdump llvm-mc
ls -la bin/clang bin/llc bin/llvm-objdump
