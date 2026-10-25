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
order, checks every word of the `.gold` file and prints one `APPCSV` line per launch
with its cycles and retired warp instructions.

Blocks have tb_apps' shape (2^blk warps) unless `-b <threads>` sets the block of the
launches without a barrier (scan keeps its 32-thread blocks). A Vortex block cannot
exceed the core's 32 hardware threads; 8- and 32-thread blocks differ by under 1%,
and the runs use `-b 32`.

Two differences come from the ISAs: Vortex has no packed INT8 dot product, so the
MLP kernel multiplies the four bytes of each word separately where SIMTiX uses
`pdot8`; and the kernels are compiled by Vortex's LLVM at `-O3` where the SIMTiX
ones are hand-written assembly. The kernels walk their arrays with pointer
increments as the assembly does, and are built with `-fno-math-errno`, without which
clang calls `fmaf()` instead of emitting `fmadd.s` (GEMM took 3.4x SIMTiX's cycles
that way, 2.0x without).

## Running (WSL)

Vortex is built in `~/v2/vortex/build` (toolchain in `~/v2/tools`) with

    export CMAKE_POLICY_VERSION_MINIMUM=3.5   # CMake 4 and yaml-cpp's old minimum
    make -s third_party                       # serial: ramulator's cmake fetches spdlog
    make -s -j2 software

Then

    python sim/gen_apps.py                    # build_apps/apps.manifest
    RUN_NAME=vx_default HOST_ARGS="-b 32" baselines/vortex/run_apps.sh rtlsim

The log and the `APPCSV` lines go to `build_vortex/<RUN_NAME>.{log,csv}`.
`EXTRA_CONFIGS` adds Vortex defines; the three settings compared are

| Run | `EXTRA_CONFIGS` | Memory, FPU |
|---|---|---|
| `vx_default` | (none) | HBM2 model clocked with the core, 64 B per cycle; DPI FPU, FMA latency 8 |
| `vx_bus128` | `-DVX_CFG_PLATFORM_MEMORY_DATA_SIZE=16` | the same behind a 128-bit bus (Vortex's own width adapter), 16 B per cycle like the ZCU104's HP port |
| `vx_bus128_ip` | the above and `-DVX_CFG_FMA_LATENCY=16 -DVX_CFG_FDIV_LATENCY=28 -DVX_CFG_FSQRT_LATENCY=28` | and the latencies of the Xilinx FP IPs in the synthesized netlist |

`WARPS=8` or `WARPS=16` (with the `vx_bus128_ip` defines) gives the warp-count runs
`vx_w8_bus128_ip` and `vx_w16_bus128_ip`; `syn/gen_sources.sh` takes the same
`WARPS`.

`python sim/vortex_compare.py NAME=build_vortex/RUN.csv ...` lines the runs up with
SIMTiX's `docs/apps_agg.csv` (variant `ser`, which also carries SIMTiX's issued warp
instructions) and writes `docs/vortex_apps.csv`.

Vortex compiles its simulators with `-Werror`, and GCC 13 and later report a false `-Wdangling-reference` in the `fmt`
library bundled with ramulator, so `run_apps.sh` puts `g++`/`c++` wrappers that add
`-Wno-dangling-reference` first on the `PATH` (`~/v2/gccwrap`). `configure` copies the
app's `Makefile` into the build tree once, so `run_apps.sh` refreshes that copy too.
On simx and rtlsim all seven cases of `gen_apps.py --size small` match their `.gold`
files.

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
built the same way.

    python sim/vortex_syn.py simtix=simtix_ps_top w4_bus128_ip=zcu104_1c4w8t \
        w8_bus128_ip=zcu104_1c8w8t w16_bus128_ip=zcu104_1c16w8t

collects each build's `synth_summary.csv` and `power_vectorless.rpt` into
`docs/vortex_syn.csv` (a build that has not finished is skipped) and pairs each
Vortex build with the run of `docs/vortex_apps.csv` it is named after.

## Results

Post-route, out of context, 10 ns constraint. Power is Vivado's vectorless estimate
(toggle rate 12.5%, static probability 0.5) at 100 MHz.

| | SIMTiX (`simt_ps_top`) | Vortex, 4 warps | Vortex, 8 warps | Vortex, 16 warps |
|---|---|---|---|---|
| LUT | 84,443 | 80,119 | 91,831 | 110,158 |
| of which LUTRAM and SRL | 5,924 | 5,128 | 5,450 | 5,996 |
| FF | 31,959 | 78,613 | 86,452 | 98,570 |
| RAMB36 | 16 | 46 | 62 | 95.5 |
| DSP | 72 | 48 | 48 | 48 |
| WNS, Fmax | +0.162 ns, 101.6 MHz | +2.899 ns, 140.8 MHz | +2.641 ns, 135.9 MHz | +2.537 ns, 134.0 MHz |
| Power, total (dynamic + static) | 1.096 W (0.501 + 0.594) | 1.701 W (1.103 + 0.598) | 1.851 W (1.252 + 0.599) | 2.075 W (1.475 + 0.600) |

`simt_ps_top` also holds SIMTiX's AXI-Lite registers and AXI4 master (570 LUT); the
`Vortex` top has no AXI or host adapter.

Vortex / SIMTiX on the suite (`vx_bus128_ip` and its warp-count runs, `-b 32`); above
1 favours SIMTiX. Run time takes each design at its own Fmax; energy is power ×
cycles × 10 ns. 4w, 8w and 16w are Vortex's warp counts.

| Case | Cycles 4w | 8w | 16w | Run time 4w | 8w | 16w | Energy 4w | 8w | 16w |
|---|---|---|---|---|---|---|---|---|---|
| GEMM | 2.01 | 1.23 | 1.16 | 1.45 | 0.92 | 0.88 | 3.12 | 2.09 | 2.19 |
| SpMV | 1.66 | 1.10 | 1.06 | 1.19 | 0.82 | 0.80 | 2.57 | 1.85 | 2.00 |
| Stencil | 2.99 | 1.76 | 1.42 | 2.16 | 1.32 | 1.08 | 4.64 | 2.97 | 2.70 |
| k-means | 1.97 | 1.42 | 1.43 | 1.42 | 1.06 | 1.09 | 3.05 | 2.41 | 2.71 |
| BFS | 4.99 | 2.60 | 1.90 | 3.60 | 1.94 | 1.44 | 7.74 | 4.39 | 3.59 |
| Scan | 3.36 | 1.92 | 1.48 | 2.42 | 1.43 | 1.12 | 5.21 | 3.24 | 2.81 |
| MLP | 3.92 | 3.58 | 3.58 | 2.83 | 2.68 | 2.71 | 6.09 | 6.05 | 6.77 |
| Geometric mean | 2.78 | 1.80 | 1.58 | 2.01 | 1.34 | 1.20 | 4.32 | 3.04 | 3.00 |
