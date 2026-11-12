# FGPU on the ZCU102: a second SIMT baseline (plan, 2026-11-12)

The goal is to build FGPU, a published soft SIMT GPGPU, on the ZCU102 and run the
benchmark kernels of every suite on it, so that the paper compares SIMTiX with two SIMT
designs measured on the same board (Vortex and FGPU), besides Ara and CVA6.

## FGPU

M. Al Kadi, B. Janssen and M. Huebner, "FGPU: An SIMT-architecture for FPGAs," FPGA 2016;
M. Al Kadi and M. Huebner, "Integer computations with soft GPGPU on FPGAs," FPT 2016.
Source: github.com/malkadi/FGPU (last commit ea418e86, 2018-07-01), cloned outside the
repository at `C:\work\fgpu_src\FGPU`. **Licence: GPL v3**; FGPU's files stay outside this
repository, as Vortex's and Ara's do; our wrapper, scripts and kernels are our own.

- **Architecture.** Compute units (CUs) of 8 processing elements (PEs, `CV_SIZE`); a
  wavefront is 64 work-items executed over 8 phases; up to 8 wavefronts per CU
  (`N_WF_CU_W` = 3); a work-group dispatcher, a shared data cache in banks
  (`CACHE_N_BANKS_W`), AXI masters to global memory (`GMEM_N_BANK_W`), optional local
  memory and atomics. Configured by constants in `RTL/FGPU_definitions.vhd`.
- **Floating point.** Optional units (`FLOAT_IMPLEMENT`, `FADD/FMUL/FDIV/FSQRT_IMPLEMENT`,
  and int-to-float, less-than): Xilinx floating-point IP cores (`RTL/floating_point`).
  **No fused multiply-add and no float-to-int conversion.**
- **Programming.** OpenCL C kernels compiled by FGPU's LLVM 3.7.1 backend
  (`llvm-3.7.1.src.fgpu`, `scripts/download_and_compile_llvm.sh`); the host was bare-metal
  code on the ZC706's Cortex-A9 (Xilinx SDK).
- **Target in the repository:** ZC706 (Zynq-7000 XC7Z045), Vivado of about 2016;
  `RTL/DSP48E1.vhd` instantiates 7-series DSP blocks.
- **Known bugs** (`known_bugs.md`): a branch inside a function called from a branch
  corrupts the divergence stack; 3-D index spaces untested; atomics at changing addresses
  untested; only the `.text` section (no `.rodata` constants).

## User decisions (2026-11-12)

| Question | Decision |
|---|---|
| No FMA in FGPU | **Separate multiply and add** (FGPU's natural form, two roundings). FGPU's results then differ slightly from the FMA definitions; FGPU is checked within a stated relative tolerance per application, as CVA6 and Ara are for division and square root, and the largest error is reported. Where a definition has no FMA (or is integer), FGPU is checked exactly. |
| Configuration | **1 CU of 8 PEs**: the same parallel width as SIMTiX (8 lanes) and Vortex (8 threads per warp). Its area, Fmax and power are reported alongside. |
| Scope | **All suites, in phases**: feasibility first (2-3 kernels end to end), then suite 1 (12 apps), Rodinia (8), RiVEC batch 1 (7), suite 2 (10). |

## Phases

### Phase 0: feasibility (each step must pass before the next)
1. **Compiler.** Build FGPU's LLVM 3.7.1 backend (WSL; LLVM 3.7 may need an older GCC or
   an older Ubuntu container). Compile FGPU's own `vec_add` and `matrix_multiply` kernels
   and compare with the binaries in `kernels/compiler_outputs`.
2. **Simulation.** Run FGPU's testbench (`RTL/FGPU_tb.vhd`) on one of its kernels in xsim
   (Vivado 2025.1), with the floating-point IP regenerated.
3. **Synthesis for the ZCU102.** FGPU at 1 CU with the float units, out of context for
   XCZU9EG: DSP48E1 retargeting, IP versions, timing (target first 100 MHz, then higher).
4. **Board design.** A wrapper and block design like `baselines/vortex` (PS8, AXI4-Lite
   control, AXI masters to S_AXI_HP0, PL clock from the PS), an A53 host driver; first a
   vec_add on the board.

### Phase 1 onwards: the suites
For each suite: the kernels in OpenCL C for FGPU (one work-item per output, as SIMTiX's
thread; multiply and add separate), the cases of `sim/gen_*.py` run in FGPU's simulation
(board sizes included, as the sim-before-board rule requires), then one board session per
suite. Results added to the comparison tables of each suite.

## Open questions (to be answered in phase 0)
- Does FGPU's compiler handle our kernels' control flow within its known divergence bug?
- FGPU's integer support for the INT8 applications (sub-integer loads exist).
- Float-to-int conversion (RiVEC's exp, Mandelbrot's escape test): software in the kernel.
- FGPU's memory consistency: its cache and the host's cache maintenance (as for SIMTiX:
  clean before start, invalidate after).
