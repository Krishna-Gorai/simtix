# Vortex baseline

The head-to-head comparison runs the SIMTiX application suite on
[Vortex](https://github.com/vortexgpgpu/vortex) 3.0, sized like SIMTiX, and builds
Vortex for the ZCU104's FPGA with the same Vivado (2025.1).

| | SIMTiX | Vortex (this baseline) |
|---|---|---|
| Cores × warps × threads | 1 × 4 × 8 | 1 × 4 × 8 |
| ISA | RV32I + `mul`, RV32A AMOs, FP32 and FP16 | RV32IMAF |
| Data cache | 16 KB, 4-way, 32 B lines, write-through | 16 KB, 4-way, 64 B lines, write-back (Vortex default) |
| Instructions | 4 KB on-chip RAM | 16 KB, 4-way I-cache (Vortex default) |
| FPU | own pipelined FP32/FP16 FMA, shared div/sqrt | Xilinx floating-point IPs (`FPU_TYPE=DSP`, Vortex's FPGA default) |
| Memory port | one 128-bit AXI4 master | one 512-bit memory bank interface |

Everything not in the table is Vortex's default (`VX_config.toml`).

## Applications (`simtix_apps/`)

`kernel.cpp` holds the eight kernels of `kernels/apps/*.S` (GEMM, SpMV, stencil,
k-means, BFS, scan + scan-add, INT8 MLP) written against Vortex's `vx_spawn2` API,
one thread per output as in the assembly versions, with the same order of FP
operations. `main.cpp` replays the cases that `sim/gen_apps.py` writes for
`tests/tb_apps.sv`: it copies each case's memory image into a device buffer, moves
the address fields of each parameter block to that buffer, runs the launches in
order with the same block shape (2^blk warps per block), checks every word of the
`.gold` file and prints one `APPCSV` line per launch with its cycles.

Two differences come from the ISAs: Vortex has no packed INT8 dot product, so the
MLP kernel multiplies the four bytes of each word separately where SIMTiX uses
`pdot8`; and the kernels are compiled by Vortex's LLVM at `-O3` where the SIMTiX
ones are hand-written assembly.

## Running (WSL)

Vortex is built in `~/v2/vortex/build` (toolchain in `~/v2/tools`) with

    export CMAKE_POLICY_VERSION_MINIMUM=3.5   # CMake 4 and yaml-cpp's old minimum
    make -s third_party                       # serial: ramulator's cmake fetches spdlog
    make -s -j2 software

Then

    python sim/gen_apps.py                    # build_apps/apps.manifest
    baselines/vortex/run_apps.sh rtlsim       # or simx

The log and the `APPCSV` lines go to `build_vortex/`. Vortex compiles its simulators
with `-Werror`, and GCC 13 and later report a false `-Wdangling-reference` in the `fmt`
library bundled with ramulator, so `run_apps.sh` puts `g++`/`c++` wrappers that add
`-Wno-dangling-reference` first on the `PATH` (`~/v2/gccwrap`). On simx all seven
cases of `gen_apps.py --size small` match their `.gold` files.

Long runs from Windows go through `Start-Process wsl.exe ...`: the WSL VM stops
when no `wsl.exe` is attached, which ends background jobs and clears `/tmp`.

## Synthesis (`syn/`)

    baselines/vortex/syn/gen_sources.sh                                  # WSL
    powershell -ExecutionPolicy Bypass -File baselines\vortex\syn\run_syn.ps1   # Windows

`gen_sources.sh` runs Vortex's own `hw/syn/xilinx/dut` flow as far as the
preprocessed source list for the `Vortex` top (cores, caches, memory interface;
no AXI or host adapter) and copies it to `C:\work\vortex_syn`. `run_syn.ps1` runs
that flow's `project.tcl` (out of context, its default strategy `OPT_LEVEL=3`) for
xczu7ev-ffvc1156-2-e at 100 MHz. The flow's SLR interface check is switched off: it
needs IP stubs that only the data-centre-card flow produces, and the xczu7ev has a
single die.

`run_syn.ps1 -Name simtix_ps_top -Top simt_ps_top` puts SIMTiX's board top
(`simtix_sources.txt`) through the same script and strategy, so both designs are
built the same way; that run has not been made yet.
