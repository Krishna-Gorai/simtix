# SIMTiX v3 vs Ara, CVA6 and Vortex on the ZCU102 (for the paper)

All four were measured on the same ZCU102 board, with the same application inputs
and the same A53 reference loops. The inputs are drawn by `baselines/ara/host/apps_ara.c`
and by the Vortex host exactly as `sw/ps_host/apps.c` draws them, and every result is checked word for word
against the A53.

- **SIMTiX v3:** default build (serial AMO), 115.37 MHz, about 107.7k LUT.
  Log `docs/zcu102_board_run_v3_apps3.txt` (2026-11-06).
- **Ara:** 2 lanes, VLEN 2048, plus its CVA6 scalar core, 78.95 MHz.
  The `ara_system` uses 177.2k LUT / 59.1k FF / 96 BRAM.
  Log `docs/zcu102_board_run_ara.txt` (2026-11-08).
- **CVA6:** the scalar version of each app (the A53 reference loop compiled for RV64GC, no vector unit).
- **Ara:** the RVV version of each app (`baselines/ara/kernels/ak_vector.c`).
- **Vortex:** Vortex 3.0, 1 core with 8 warps of 8 threads (RV32IMAF), 125 MHz (setup slack
  +1.308 ns). Its FPU is the Xilinx floating-point IPs, Vortex's FPGA default (FMA latency 16,
  divide/square root 28). `Vortex_axi` uses 84.2k LUT / 84.4k FF / 48 DSP; the whole design
  uses 85.2k LUT / 85.6k FF / 62 BRAM. Log `docs/zcu102_board_run_vortex.txt` (2026-11-09).
  It runs SIMTiX's base kernels ported to Vortex (`baselines/vortex/simtix_apps`); the v3
  variants (gemmrb, spmvz, stencilrb, kmeansu, scanseg) are not ported.

Regenerate the table with `python baselines/ara/compare_simtix.py`; it writes
`docs/ara_cva6_simtix_comparison.csv`.

## Table: large board sizes, wall-clock time

| App (size) | SIMTiX best (µs) | Ara (µs) | CVA6 (µs) | Vortex (µs) | Ara ÷ SIMTiX (time) | Ara ÷ SIMTiX (cycles) | CVA6 ÷ SIMTiX | Vortex ÷ SIMTiX (time) | Vortex ÷ SIMTiX (cycles) |
|---|---|---|---|---|---|---|---|---|---|
| gemm 256 | 37,750 (gemmrb) | 77,355 | 3,689,658 | 198,196 | 2.05 | 1.40 | 98 | 5.25 | 5.69 |
| stencil 512 | 18,936 (stencilrb) | 53,403 | 570,880 | 134,768 | 2.82 | 1.93 | 30 | 7.12 | 7.71 |
| embag 4096 | 37,470 | 95,108 | 884,775 | 100,495 | 2.54 | 1.74 | 24 | 2.68 | 2.91 |
| kmeans 262144 | 72,257 (kmeansu) | 275,354 | 1,064,140 | 183,051 | 3.81 | 2.61 | 15 | 2.53 | 2.74 |
| scan 1M | 35,485 (scanseg) | 139,246 | 146,090 | 268,018 | 3.92 | 2.69 | 4.1 | 7.55 | 8.18 |
| conv8 128 | 290,698 | 1,581,350 | 27,266,482 | 2,066,402 | 5.44 | 3.72 | 94 | 7.11 | 7.70 |
| spmv 65536 | 19,338 (spmvz) | 313,168 | 362,299 | 46,215 | 16.2 | 11.1 | 19 | 2.39 | 2.59 |
| bfs 262144 | 162,924 | 3,442,600 | 1,494,581 | 514,767 | 21.1 | 14.5 | 9.2 | 3.16 | 3.42 |
| hashj 22 | 99,285 | 2,369,129 | 1,192,848 | 252,057 | 23.9 | 16.3 | 12 | 2.54 | 2.75 |
| mlp 256 | 189,686 | wrong result | 6,880,235 | 920,937 | — | — | 36 | 4.86 | 5.26 |
| mandel 1024 | 1,019,712 | not run | 11,142,545 | 5,324,035 | — | — | 11 | 5.22 | 5.66 |
| swat 16384 | 1,613,364 | wrong result | 41,092,919 | 5,583,563 | — | — | 25 | 3.46 | 3.75 |

How to read the ratio columns:
- "Ara ÷ SIMTiX" is Ara's time divided by SIMTiX's, so a value above 1 means SIMTiX is faster.
- The "cycles" columns remove the clock difference (SIMTiX 115.37 MHz, Ara 78.95 MHz,
  Vortex 125 MHz).
- "SIMTiX best" is the fastest SIMTiX kernel for the same computation. The v3 variants give the
  same outputs. The CSV also holds the base kernel's time and both board sizes.

Geometric means at the large sizes:
- **SIMTiX vs Ara:** 5.98× in time and 4.09× per cycle, over the 9 apps that Ara completes correctly.
- **SIMTiX vs CVA6:** 21.2× in time, over all 12 apps.
- **SIMTiX vs Vortex:** 4.11× in time and 4.45× per cycle, over all 12 apps. Against SIMTiX's
  base kernels, which are the same code Vortex runs, it is 2.98× in time and 3.23× per cycle.

## Table: Vortex against the same SIMTiX kernel (large board sizes)

Vortex runs SIMTiX's base kernels, so this table compares the two machines on identical code.

| App (size) | SIMTiX base (µs) | Vortex (µs) | Vortex ÷ SIMTiX (time) | Vortex ÷ SIMTiX (cycles) |
|---|---|---|---|---|
| gemm 256 | 150,636 | 198,196 | 1.32 | 1.43 |
| kmeans 262144 | 115,999 | 183,051 | 1.58 | 1.71 |
| spmv 65536 | 20,235 | 46,215 | 2.28 | 2.47 |
| scan 1M | 108,022 | 268,018 | 2.48 | 2.69 |
| hashj 22 | 99,285 | 252,057 | 2.54 | 2.75 |
| embag 4096 | 37,470 | 100,495 | 2.68 | 2.91 |
| stencil 512 | 43,557 | 134,768 | 3.09 | 3.35 |
| bfs 262144 | 162,924 | 514,767 | 3.16 | 3.42 |
| swat 16384 | 1,613,364 | 5,583,563 | 3.46 | 3.75 |
| mlp 256 | 189,686 | 920,937 | 4.86 | 5.26 |
| mandel 1024 | 1,019,712 | 5,324,035 | 5.22 | 5.66 |
| conv8 128 | 290,698 | 2,066,402 | 7.11 | 7.70 |
| **geometric mean** | | | **2.98** | **3.23** |

## Points for the text

- **SIMTiX's own base kernels.** SIMTiX's base gemm takes 150,636 µs, about 2× slower than
  Ara's 77,355 µs; SIMTiX is faster only with the register-blocked v3 kernel. Per cycle, Ara's
  stencil roughly matches SIMTiX's base stencil, and in time SIMTiX's base stencil is still 1.2×
  faster. Ara's strength is dense, regular work.
- **Irregular work.** On spmv, bfs and hashj SIMTiX is 16–24× faster. Ara is no faster than its
  own scalar core here, and on bfs and hashj it is slower than CVA6. A 2-lane vector unit handles
  gathers and per-element control flow poorly.
- **Ara restrictions found.** The RVV code is shaped by Ara bugs found in simulation; the list
  is in the header of `ak_vector.c`. In short:
  - kernels that compare run at LMUL 1;
  - masks are used only as `vmerge` selectors;
  - no masked loads, stores or arithmetic;
  - sign-extended scalars for widening ops;
  - no spills, no auto-vectorization;
  - inline-assembly narrowing.

  These cost some speed on the masked kernels (spmv, kmeans, bfs, hashj). Every kernel passes
  unchanged under QEMU 10.2 (RVV 1.0).
- **Clocks.** Ara closes timing at 78.95 MHz on the XCZU9EG (2 lanes with the full FP64/32/16
  FPU). Four lanes do not fit, at 316.6k LUT, or 115%.
- **Vortex.** On identical code SIMTiX is faster on all 12 apps, from 1.32× (gemm) to
  7.11× (conv8). Vortex uses fewer LUTs (84.2k against about 107.7k), so per LUT SIMTiX's
  same-code advantage is about 2.3× (SIMTiX's figure is its whole build; Vortex's whole
  design is 85.2k).
- **Vortex's FPU on the FPGA.** The board build uses the Xilinx floating-point IPs, Vortex's
  FPGA default. Their longer latency costs Vortex cycles on FP-bound work: mandel 256 takes
  44.6M cycles on the board against 25.0M in the Verilator testbench, which uses Vortex's
  simulation FPU, a 1.78× difference. gemm 64 differs by 7% (422.5k against 396.1k); the
  other ten apps differ by 3% or less, in either direction (the two testbenches also model
  DDR differently). This is the configuration Vortex ships for FPGAs, so the paper should
  name it.
- **A53 column.** The A53 times in the CSV come from the `-O2` host build in all three logs
  (they agree within 1.5%). The paper's fair A53 references (`-O3` NEON, `A53T` rows) are separate.

## Open items (2026-11-09)

1. **Ara mlp and swat give wrong results on the board**, at both sizes:
   - mlp: every logit wrong (160/160 and 2,560/2,560);
   - swat: exactly half the pairs wrong (1,024/2,048 and 8,192/16,384).

   Both pass in the simulation self-test, including at vector length 256: mlp with 256
   hidden outputs and swat with 300 pairs both pass (the self-test sizes are now enlarged
   that way in `ak_main.c`). So vl = 256 is not the cause.

   Both apps, and only these two, give Ara a vector-specific input layout that the A53 host
   builds in `apps_ara.c`:
   - mlp: `W[k][npad]`;
   - swat: `q[i][pair]` and `t[j][pair]`.

   The self-test builds these layouts itself, and CVA6 uses the A53 layout. So the first
   suspect is the host code that prepares them. Check it next, against the self-test's
   construction in `t_mlp` / `t_swat`.
2. **Ara mandel is not run.** The host skips it and prints `ARAK,mandel,<n>,ara,skip`. The vector
   kernel deadlocks Ara in the Verilator model in every form tried, the mask-free form included.
   It passes standalone and under QEMU, which points to a layout- and timing-dependent Ara hazard.
   This was the user's decision on 2026-11-08: go to the board without it.
   The later board run with suite 2 (`docs/zcu102_board_run_ara_s2.txt`, 2026-11-09) does run
   mandel; this table still uses the 2026-11-08 log.
3. **Power for Ara/CVA6 is not measured yet.** Vivado's on-chip estimate is 4.514 W, of which
   ara_0 is 1.045 W and the PS 2.735 W.
4. **Vortex has no suite-2 ports**, so it appears in the suite-1 table only.
5. **Vortex power is read but not analysed.** The board log has the INA226 rail readings
   (`POWER` rows); Vivado's on-chip estimate is 5.020 W, of which 4.287 W is dynamic.
