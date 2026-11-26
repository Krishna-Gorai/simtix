# FGPU in the SIMTiX comparison: draft text for the paper (2026-11-20)

Draft paragraphs for the TVLSI paper's evaluation section, to be completed with the board
results (docs/fgpu_plan.md has the engineering record). Numbers marked TBD come from the board
runs (docs/zcu102_board_run_<suite>_fgpu.txt via baselines/ara/compare_rodinia.py and
compare_rivec.py).

## Baseline description

FGPU [Al Kadi et al., FPGA 2016] is an open-source soft GPGPU written in VHDL. A compute unit
(CU) has eight processing elements (PEs) and runs wavefronts of 64 work-items; a wavefront
issues one instruction over eight cycles, and up to eight wavefronts share a CU. Kernels are
written in OpenCL C and compiled by FGPU's LLVM 3.7 back end. We use one CU with FGPU's
single-precision floating-point units and its global atomics, the configuration closest to
SIMTiX's eight lanes. FGPU has no fused multiply-add, no conversion from float to integer and
no integer division.

## Platform

FGPU runs on the same ZCU102 as the other four machines, as a peripheral of the Arm Cortex-A53:
an AXI4-Lite port for its control registers and kernel descriptor, and a 64-bit AXI4 master to
the DDR4 through S_AXI_HP0. Its clock is TBD MHz (1.5 GHz / 8 if the 187.5 MHz build closes
timing; 150 MHz otherwise). Utilization: TBD LUT, TBD FF, TBD RAMB36, 64 DSP (150 MHz build:
43,995 LUT, 58,582 FF, 49.5 RAMB36, 64 DSP; Vivado estimate 1.12 W for FGPU).

## Kernels and checking

Every benchmark kernel is ported to OpenCL C with one work-item per output, reading the same
parameter blocks as the SIMTiX kernels, so the A53 host runs, checks and times FGPU exactly as
it does SIMTiX, Vortex, CVA6 and Ara. Each fused multiply-add of a benchmark definition becomes a
multiply followed by an add. Outputs that depend on such operations are compared with the A53
reference within 10^-3 of the largest reference value in the row, and the largest difference
is reported; all other outputs are compared bit for bit. Where every product is exact (the
stencil's coefficients and the Mandelbrot grid are powers of two, or multiples of 2^-k), the
separate add equals the fused one and the check stays exact. For the INT8 requantization the
A53 reference multiplies and adds separately on FGPU's runs, so its bytes are compared
exactly. k-means on the kdd_cup input gives the same 37 iterations, memberships and centres
without fused multiply-adds as with them (checked offline in IEEE single precision).

Before the board, each kernel runs on FGPU's RTL in simulation with the small inputs of the
SIMTiX test suite, and a single-precision model of each port checks its logic on the same
inputs; the simulation is checked bit for bit against that model.

## Notes for the results discussion (to verify against the board numbers)

- FGPU's memory-bound throughput on a vector add was ~21 M work-items/s at 150 MHz (phase 0),
  slower than the A53 on that kernel (6.8x).
- FGPU hides latency only with resident wavefronts: kernels with few work-items (lavaMD's 96
  per box, the radix sort's 16 digit threads) run far below its peak.
- FGPU signals completion when its end-of-kernel cache write-back has been queued, not when it
  has reached memory; the host's next register accesses cover the remaining tens of cycles.
