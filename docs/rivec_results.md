# RiVEC batch 1 on SIMTiX, CVA6, Ara and Vortex: results (ZCU102, 2026-11-12)

This document records the board results of the first seven RiVEC applications on the four
machines of the paper's comparison, how they were obtained, and what they show. The plan,
the decisions and the definition of every application are in `docs/rivec_plan.md`; the
paper's text, table and figure are in `docs/paper/simtix_tvlsi.tex`, Section "RiVEC on Four
Machines" (`sec:rivec`, Table `tab:rivec`, Fig. `fig:rivec`).

## 1. Machines

The same four machines and the same board as for Rodinia (`docs/rodinia_results.md`): SIMTiX
v3 (8 lanes, 8 warps, 115.37 MHz), Vortex 3.0 (1 core, 8 warps of 8 threads, 125 MHz), Ara
(2 lanes, VLEN 2048, RVV 1.0, 78.95 MHz) with CVA6 (RV64GC, 78.95 MHz), and one Cortex-A53
at 1.2 GHz as host and reference.

| Machine | RiVEC kernels |
|---|---|
| SIMTiX | hand-written assembly: `kernels/rivec/{axpy_rv,jacobi_rv,bs_rv,lavamd_rv}.S`; matmul with `kernels/apps/gemm_rb.S`, spmv with `spmv_z.S`, pathfinder with `kernels/suite2/pathfinder.S` |
| Vortex | C++ ports (`baselines/vortex/simtix_apps/kernel.cpp`, calling `kernels/rivec/rv_ref.h`), LLVM; matmul and spmv with the base `gemm` and `spmv` kernels |
| Ara | **RiVEC's own vector code** (`baselines/ara/kernels/ak_vector_rv.inc`, RiVEC's headers in `rivec/`), compiled with clang 21; the changes are listed in `docs/rivec_plan.md` |
| CVA6 | `kernels/rivec/rv_ref.h`, GCC 15.2 `-O3` |
| A53 | `kernels/rivec/rv_ref.h`, GCC 14.2 `-O2` |

## 2. Applications and inputs

RiVEC (C. Ramírez et al., ACM TACO 2020), master 32a14ddf, its `run.sh` "large" inputs:

| App | Origin | Input | Repetition (as RiVEC) |
|---|---|---|---|
| axpy | BLAS | 2,097,152 elements (dx = 1.83, dy = 2.22, a = 1.53) | 1 |
| matmul | BLAS | `data_512.in`: 512 x 512 x 512, integers 0-3 | 1 |
| spmv | BLAS | SuiteSparse `poisson3Db` (85,623 rows, 2,374,949 non-zeros); y = A^T x, x = 1 | 1 |
| jacobi-2d | PolyBench | 256 x 256, 2,000 time steps (4,000 sweeps) | 1 |
| pathfinder | Rodinia | `data_large.in`: 1,024 rows x 2,048 columns | 100 runs |
| blackscholes | PARSEC | `in_64K.input`: 65,536 options | 100 runs |
| lavaMD | Rodinia | 10 x 10 x 10 boxes of 96 particles | 1 |

All in FP32. The inputs come from RiVEC's files through `sim/rv_data.py` (a 33 MB blob at DDR
0x7000_0000) or are generated on the hosts as RiVEC generates them.

## 3. Method

- **Definition** (`docs/rivec_plan.md`): per element, RiVEC's vector code read per element
  (its fused multiply-adds, its Cephes exp and log); sums over many elements in serial order.
  `kernels/rivec/rv_ref.h` is bit-exact with RiVEC's vector code under QEMU, with the results
  RiVEC ships (matmul, pathfinder) and with the exact Python model against which the SIMTiX
  and Vortex kernels were simulated.
- **Timing:** SIMTiX and Vortex with the A53's timer around the launches (host work between
  launches included); CVA6 and Ara with CVA6's cycle counter around the kernel.
- **Checking:** every output word against the A53 reference: exactly for SIMTiX, Vortex and
  CVA6 (except CVA6's blackscholes); for Ara exactly where its vector code computes per
  element, within a relative tolerance where it keeps partial sums per element (spmv, lavaMD:
  1e-5 of the sum of the magnitudes of the terms); blackscholes on CVA6 and Ara within a
  tolerance because their divider and square root are not correctly rounded (Section 5).
- **Simulation before the board:** SIMTiX (RTL) and Vortex (simx and the board-wrapper
  testbench) passed every case at RiVEC's sizes; Ara's self-tests passed under QEMU and in
  the Verilator model of its board wrapper, each in the sequence of the board run.

## 4. Results

### 4.1 Time (ms)

| App | SIMTiX | CVA6 | Ara | Vortex | A53 |
|---|---|---|---|---|---|
| axpy | 31.5 | 513.4 | 50.7 | 179.2 | 25.0 |
| matmul | 300.3 | 65,174.2 | 14,918.2 | 1,562.4 | 2,152.8 |
| spmv | 79.2 | 1,211.9 | 567.1 | 173.6 | 52.8 |
| jacobi-2d | 10,116.6 | 145,978.7 | 19,324.5 | 36,713.8 | 4,461.7 |
| pathfinder | 5,556.7 | 116,179.1 | 8,907.6 | 22,044.9 | 2,473.0 |
| blackscholes | 9,328.3 | 45,462.0 | 5,665.7 | 9,095.9 | 3,460.8 |
| lavaMD | 15,868.0 | 268,712.8 | 159,494.0 | 69,823.7 | 23,438.5 |

### 4.2 Time and cycles relative to SIMTiX (above 1: SIMTiX faster)

| App | CVA6 time | CVA6 cycles | Ara time | Ara cycles | Vortex time | Vortex cycles | A53 time |
|---|---|---|---|---|---|---|---|
| axpy | 16.3 | 11.2 | 1.61 | 1.10 | 5.69 | 6.16 | 0.80 |
| matmul | 217 | 149 | 49.7 | 34.0 | 5.20 | 5.64 | 7.17 |
| spmv | 15.3 | 10.5 | 7.16 | 4.90 | 2.19 | 2.37 | 0.67 |
| jacobi-2d | 14.4 | 9.88 | 1.91 | 1.31 | 3.63 | 3.93 | 0.44 |
| pathfinder | 20.9 | 14.7 | 1.60 | 1.13 | 3.97 | 4.15 | 0.45 |
| blackscholes | 4.87 | 3.33 | 0.61 | 0.42 | 0.98 | 1.06 | 0.37 |
| lavaMD | 16.9 | 11.6 | 10.1 | 6.88 | 4.40 | 4.77 | 1.48 |
| **Geometric mean** | **20.1** | **13.8** | **3.76** | **2.59** | **3.27** | **3.53** | **0.88** |

Vortex's lavaMD is one launch of 8.73e9 cycles, whose busy-cycle count the host holds in 32
bits per launch (printed as 137,153,714); `compare_rivec.py` adds back the two wraps from
the measured time (69.82 s at 125 MHz).

### 4.3 Correctness

- SIMTiX, Vortex and CVA6 agree with the A53 bit for bit on every output except CVA6's
  blackscholes; matmul and pathfinder also equal RiVEC's own results.
- Ara: exact on axpy, matmul, jacobi-2d and pathfinder; spmv within 1.95e-7 and lavaMD
  within 3.73e-6 (its reduction order).
- blackscholes on CVA6 and Ara: the same 264 of 65,536 prices exceeded the host's limit of
  1e-4, the largest by 5.68e-4 of |price| + 0.01; within the final tolerance of 1e-3
  (Section 5). CVA6 and Ara give identical prices.

## 5. The blackscholes tolerance

The board host's limit for CVA6 and Ara blackscholes, 1e-4 of |price| + 0.01, was set before
the run and turned out too tight. `kernels/rivec/qtest/bs_sens.c` evaluates RiVEC's
Black-Scholes on the same 65,536 options with every quotient one ulp off with probability
8.7% and every square root with probability 6.9%, CVA6's measured rates: over 200 random
trials the largest change is 5.68e-4 of |price| + 0.01, and 140 options per run on average
move by more than 1e-4. The board's 264 options and 5.68e-4 are of the same size, and CVA6
and Ara, which share the divider, agree with each other bit for bit; the differences are the
divider's rounding. The final tolerance is 1e-3, above the analysis' bound.

## 6. Findings for the paper

- **Against CVA6:** SIMTiX is faster on every application, 20x in time and 14x per cycle on
  the geometric mean, from 4.9x (blackscholes) to 217x (matmul).
- **Against Ara (RiVEC's own vector code):** 3.76x in time and 2.6x per cycle on the geometric
  mean, with a wide spread:
  - matmul, 50x: RiVEC's matmul forms each element of C as a dot product with a strided load
    down a column of B, one element at a time: a poor fit for a vector unit, written by
    RiVEC's authors;
  - lavaMD 10x and spmv 7x: reductions per particle and per row;
  - axpy, jacobi-2d and pathfinder 1.6-1.9x: unit-stride streaming, where Ara is close
    per cycle (1.1-1.3x); Ara's jacobi-2d loads its rows three times (Ara item 8);
  - **blackscholes: Ara is 1.6x faster than SIMTiX** (2.4x per cycle): three divisions and a
    square root per option, which Ara applies to whole vectors and SIMTiX passes lane by lane
    through its one shared divide unit.
- **Against Vortex** (the same algorithms, compiled): 3.3x in time and 3.5x per cycle; equal
  on blackscholes, for the same reason as Ara's lead there.
- **Against the A53** (1.2 GHz): SIMTiX is faster on matmul (7.2x) and lavaMD (1.5x); the A53
  is faster on the others, 0.88x on the geometric mean.

## 7. Problems found and how they were handled

- **Two bugs in RiVEC** (`docs/rivec_plan.md`): blackscholes' mask-agnostic masked subtract
  (46,277 of 65,536 prices wrong as written, under QEMU), replaced by a `vmerge`; spmv's
  1-based indices and read past the end of x (17 of its verification values wrong), so the
  definition is y = A^T x with 0-based indices.
- **Ara** (`baselines/ara/kernels/ak_vector.c`, items 5 and 8): GCC spilled a vector register
  in RiVEC's blackscholes and Ara reloads whole-register spills wrongly (prices up to 3e34):
  RiVEC's kernels are compiled with clang, which needs no spill. jacobi-2d with RiVEC's
  register reuse across rows gave wrong last elements, differently from run to run, after
  another kernel; loading the rows for every output row is correct (user decision), at about
  46% more cycles in the small self-test.
- **Vortex testbench:** the whole 512^3 matmul exceeds the testbench's 200 M cycles per launch
  (the board takes 195 M cycles; the testbench's memory model is slower); the first 16 rows of
  C on the full data were simulated.

## 8. Files and reproduction

| File | Content |
|---|---|
| `docs/zcu102_board_run_rivec_simtix.txt` | SIMTiX board log, 2026-11-12 |
| `docs/zcu102_board_run_rivec_vortex.txt` | Vortex board log, 2026-11-12 |
| `docs/zcu102_board_run_rivec_ara.txt` | Ara/CVA6 board log, 2026-11-12 |
| `docs/rivec_results.csv` | the tables above, with cycles and errors |

```
python sim/rv_data.py                         # RiVEC's input files -> build_rivec/rv_data.bin
build_vortex/build_hosts_rv.ps1               # the three hosts with `rivec` (RV_ONLY)
build_vortex/board_rv.ps1                     # SIMTiX, Vortex, Ara/CVA6 on the board
python baselines/ara/compare_rivec.py         # -> docs/rivec_results.csv
python docs/plot_rivec.py                     # -> docs/figs/rivec_ratio.pdf
```
