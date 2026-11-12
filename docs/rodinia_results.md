# Rodinia on SIMTiX, CVA6, Ara and Vortex: results (ZCU102, 2026-11-10/11)

This document records the board results of the first eight Rodinia benchmarks on the four
machines of the paper's comparison, how they were obtained, and what they show. The plan,
the scope and the exact definition of every benchmark are in `docs/rodinia_plan.md`. The
paper's text and table are in `docs/paper/simtix_tvlsi.tex`, Section "Rodinia on Four
Machines" (`sec:rodinia`, Table `tab:rodinia`).

## 1. Machines

All four machines are separate bitstreams for the same ZCU102 board (XCZU9EG). In every
run the board's ARM Cortex-A53 (one core, 1.2 GHz, bare metal) loads the program,
generates or loads the inputs, computes the reference results and checks every output.

| Machine | Configuration | Clock | Kernels |
|---|---|---|---|
| SIMTiX v3 | 1 core, 8 lanes, 4 warps, RV32IMAF + Zba/Zbb/Zicond | 115.37 MHz | hand-written assembly, `kernels/rodinia/*.S` (pathfinder, backprop: `kernels/suite2`) |
| Vortex 3.0 | 1 core, 8 warps of 8 threads, RV32IMAF, Xilinx FP IP cores | 125 MHz | C++ ports of the same algorithms, Vortex's LLVM toolchain, `baselines/vortex/simtix_apps/kernel.cpp` |
| Ara | 2 lanes, VLEN 2048 bits, RVV 1.0, attached to CVA6 (pulp-platform/ara 34bd3bc) | 78.95 MHz | C with RVV intrinsics, GCC 15.2, `baselines/ara/kernels/ak_vector_rd.inc` |
| CVA6 | the RV64GC scalar core of the Ara system, without the vector unit | 78.95 MHz | the C reference `kernels/rodinia/rd_ref.h`, GCC 15.2 `-O3` for RV64GC |
| Cortex-A53 | one core of the processing system | 1.2 GHz | the same C reference, GCC 14.2 `-O2` |

## 2. Benchmarks and inputs

Rodinia 3.1 (Che et al., IISWC 2009). The input files come from Rodinia's data archive
`rodinia-3.1-data.tar.gz` (SHA-256 checked against Rodinia's README), converted by
`sim/rd_data.py` into one binary image that the board scripts load at DDR address
0x7000_0000.

| Benchmark | Domain | Input (board) | Kernel launches | Integer / FP |
|---|---|---|---|---|
| pathfinder | dynamic programming | 100 rows x 100,000 columns, `rand() % 10` | 99 (one per row) | integer |
| backprop | neural-network training | 2^19 inputs, 16 hidden units | 2 (forward, weight adjust) | FP32 |
| bfs | graph traversal | `graph65536.txt` (65,536 nodes, 393,216 edges) | one per level | integer |
| hotspot | 2-D thermal stencil | `temp_512`/`power_512` and `temp_1024`/`power_1024`, 2 iterations | 2 | FP32 |
| nn | nearest neighbour | the four `cane4_*.db` files, 42,764 records | 1 | FP32 with sqrt |
| hotspot3D | 3-D thermal stencil | `temp_512x8`/`power_512x8`, 100 iterations | 100 | FP32 |
| gaussian | dense linear system, elimination | Rodinia's generated matrix `-s 1024` | 2 x 1,023 (Fan1, Fan2) | FP32 with division |
| kmeans | clustering | `kdd_cup` (494,020 points, 34 features), k = 5, run to convergence | 37 (one per iteration) | FP32 |

Departures from Rodinia's default runs, all stated in the paper:

- **FP32.** Every machine computes in FP32.
- **backprop at 2^19 inputs.** Rodinia's CUDA run uses 2^21. Its two 2^21 x 16 weight arrays
  (256 MB) do not fit the Ara host's 192 MB arena.
- **gaussian on the generated matrix.** Rodinia also ships `matrix1024.txt`. Elimination
  without pivoting on that random matrix grows the entries to 5.3e4. Changing 8.7% of the
  quotients by one ulp then changes rows of the result by up to 6.3 times their largest
  entry, so no tolerance could separate rounding from error. On the `-s` matrix the same
  perturbation changes rows by at most 2.0e-4 of their largest entry
  (`sim/rodinia_exp/gauss_growth_*.c`).
- **Host parts.** Work that Rodinia does on the CPU runs on the A53 for every machine and
  is not timed: bfs's level loop, nn's choice of the 5 nearest records, kmeans' centre
  update and gaussian's back substitution.

## 3. Method

- **One definition per benchmark.** Each benchmark is Rodinia's computation on Rodinia's
  data: the exact sequence of FP32 operations that produces one output, each rounded once
  to nearest even (`fma` where Rodinia's sum is fused). Every machine performs those
  operations in that order. The definitions are in `docs/rodinia_plan.md`.
- **Each machine's natural parallel form.** A SIMTiX or Vortex thread, an Ara vector element
  and a CVA6 or A53 loop iteration each compute one output. Rodinia's CUDA thread blocks,
  shared memory and barriers are its GPU implementation and are not reproduced.
- **Timing.**
  - SIMTiX and Vortex: the A53's global timer, from before the first launch to after the
    last. This includes the host's work between launches, and Vortex's L1 flush after
    each launch.
  - CVA6 and Ara: the cycle counter of the program running on CVA6, around the kernel, at
    78.95 MHz. The loop over launches (iterations, elimination steps) runs on CVA6 itself.
  - kmeans: every machine, the A53 included, is timed on the assignment step only, summed
    over the 37 iterations.
  - Per-cycle ratios divide each time by each machine's clock period.
- **Checking.**
  - SIMTiX, Vortex and the A53 must match the A53 reference bit for bit.
  - CVA6's divide and square-root unit, which Ara shares, is not correctly rounded. On
    4,096 random operands 8.7% of quotients and 6.9% of square roots are one ulp off
    (`baselines/ara/kernels/dbg_divsqrt.c`). Where a benchmark divides or takes a square
    root, CVA6 and Ara must therefore be within a stated tolerance: nn within 1 ulp per
    distance, gaussian within 1e-3 of each row's largest reference value. All other
    benchmarks must match bit for bit.
- **Simulation before the board.** Every kernel passed in each machine's simulation model at
  the board sizes before the board runs: SIMTiX in its RTL simulation, Vortex in its PS
  testbench, Ara in the Verilator model of its board wrapper.

## 4. Results

### 4.1 Time (ms)

| Benchmark | SIMTiX | CVA6 | Ara | Vortex | A53 |
|---|---|---|---|---|---|
| pathfinder 100,000 | 250.5 | 4,428.8 | 421.2 | 960.9 | 97.2 |
| backprop 2^19 | 299.2 | 5,729.0 | 3,055.4 | 1,008.8 | 214.2 |
| bfs 65,536 | 36.7 | 299.8 | 794.1 | 126.8 | 21.9 |
| hotspot 512 | 33.6 | 553.1 | 45.3 | 103.0 | 21.0 |
| hotspot 1024 | 134.2 | 2,475.0 | 172.8 | 411.2 | 85.5 |
| nn 42,764 | 15.3 | 24.4 | 8.9 | 4.8 | 1.0 |
| hotspot3D 512x512x8 | 9,449.6 | 491,642.8 | 20,528.6 | 21,504.5 | 16,522.7 |
| gaussian 1024 | 4,965.0 | 104,642.3 | 10,176.9 | 6,064.0 | 3,916.4 |
| kmeans kdd_cup | 31,810.0 | 726,014.0 | 56,290.0 | 64,442.3 | 28,064.9 |

### 4.2 Time and cycles relative to SIMTiX

A value above 1 means that SIMTiX is faster by that factor. The geometric means are over
the eight benchmarks, with hotspot at 1024.

| Benchmark | CVA6 time | CVA6 cycles | Ara time | Ara cycles | Vortex time | Vortex cycles | A53 time |
|---|---|---|---|---|---|---|---|
| pathfinder | 17.7 | 12.1 | 1.68 | 1.15 | 3.84 | 4.15 | 0.39 |
| backprop | 19.1 | 13.1 | 10.2 | 6.99 | 3.37 | 3.65 | 0.72 |
| bfs | 8.17 | 5.60 | 21.7 | 14.8 | 3.46 | 3.75 | 0.60 |
| hotspot 512 | 16.5 | 11.3 | 1.35 | 0.92 | 3.07 | 3.33 | 0.63 |
| hotspot 1024 | 18.4 | 12.6 | 1.29 | 0.88 | 3.06 | 3.32 | 0.64 |
| nn | 1.59 | 1.09 | 0.58 | 0.40 | 0.31 | 0.34 | 0.07 |
| hotspot3D | 52.0 | 35.6 | 2.17 | 1.49 | 2.28 | 2.47 | 1.75 |
| gaussian | 21.1 | 14.4 | 2.05 | 1.40 | 1.22 | 1.32 | 0.79 |
| kmeans | 22.8 | 15.6 | 1.77 | 1.21 | 2.03 | 2.19 | 0.88 |
| **Geometric mean** | **14.6** | **9.97** | **2.62** | **1.79** | **1.98** | **2.15** | **0.56** |

### 4.3 Correctness

- Every run passed.
- SIMTiX, Vortex and the A53 agree bit for bit on every output.
- CVA6 and Ara stay within their tolerances. nn: largest difference 1 ulp on both.
  gaussian: largest row-relative difference 2.2e-4, against the 1e-3 limit.
- kmeans converged after 37 iterations on all five machines, with the same final
  memberships and centres.
- Ara's hotspot3D run was repeated in a second session: 1,620,681,102 against
  1,620,681,855 cycles, a difference of 5e-7.

## 5. Observations

- **SIMTiX against CVA6.** SIMTiX is faster on every benchmark: 14.6x in time and 10.0x
  per cycle on the geometric mean, from 1.6x (nn) to 52x (hotspot3D).
- **SIMTiX against Ara.** 2.62x in time and 1.79x per cycle on the geometric mean.
  - The largest margins are on bfs (21.7x) and backprop (10.2x).
  - On the hotspot stencil, whose loads are unit-stride rows that the vector unit streams,
    Ara is within 1.3x in time and slightly faster per cycle (0.88 to 0.92).
- **SIMTiX against Vortex.** Vortex runs the same algorithms, compiled from C. SIMTiX is
  1.98x faster in time and 2.15x per cycle on the geometric mean, from 1.22x (gaussian) to
  3.84x (pathfinder).
- **nn is the one benchmark that SIMTiX loses.** Ara is 1.7x faster and Vortex 3.2x
  faster. nn computes one square root per record and little else. SIMTiX has one shared
  digit-recurrence divide and square-root unit that the active lanes pass through in
  turn: a unit per lane would cost 3.7k LUTs (paper, Section 3). It needs 41 cycles per
  record (1.76 M cycles for 42,764 records). Vortex's FPU has one square-root unit per
  lane (`NUM_PES_SQRT = NUM_LANES` in `VX_fpu_dsp.sv`), and Ara applies `vfsqrt` to whole
  vectors in its two lanes.
- **Against the A53.** The A53 runs at 10.4 times SIMTiX's clock. It is faster on seven of
  the eight benchmarks; SIMTiX wins only hotspot3D (1.75x), the largest working set (2 x 8
  MB per iteration).

## 6. Problems found on the way, and how they were handled

- **Ara gaussian.** Ara's vector form of Fan1 (strided load, `vfdiv.vf`, strided store)
  gave wrong multipliers, or deadlocked Ara, when it ran after nn. Fan1 runs on CVA6's
  scalar divider, which gives the same quotients, and Ara runs Fan2. Recorded as item 7 of
  the restriction list in `baselines/ara/kernels/ak_vector.c`.
- **Vortex host.** The host loaded SIMTiX's kernels into SIMTiX's instruction RAM before
  the suite. On the Vortex bitstream those addresses reach Vortex's control registers,
  which decode only the low 8 address bits, and Vortex stayed in reset. The Vortex build
  now skips the load (`sw/ps_host/apps.c`, `rodinia.inc`).
- **CVA6 hotspot3D.** It exceeded the Ara host's 300 s limit per run in the full session.
  It was rerun alone with a 1 h limit: 491.6 s
  (`docs/zcu102_board_run_rodinia_ara_hs3d.txt`).
- **32-bit counters.** Two counts overflowed:
  - The Ara host printed CVA6's kmeans time as 429.5 s; the true time, from its cycle
    count, is 726.0 s.
  - The SIMTiX/Vortex host summed Vortex's kmeans cycles in 32 bits: 3.76e9 printed,
    8.05e9 true, consistent with the printed time.

  `compare_rodinia.py` corrects both from the logs. The hosts now print 64-bit values.

## 7. Files and reproduction

| File | Content |
|---|---|
| `docs/zcu102_board_run_rodinia_simtix.txt` | SIMTiX board log, 2026-11-10 |
| `docs/zcu102_board_run_rodinia_ara.txt` | Ara/CVA6 board log, 2026-11-11 |
| `docs/zcu102_board_run_rodinia_ara_hs3d.txt` | CVA6/Ara hotspot3D rerun, 2026-11-11 |
| `docs/zcu102_board_run_rodinia_vortex.txt` | Vortex board log, 2026-11-11 |
| `docs/rodinia_results.csv` | the tables above, with cycles and errors |

```
python sim/rd_data.py                       # Rodinia's data files -> build_rodinia/rd_data.bin
vitis -s sw/ps_host/build_vitis.py zcu102 <xsa> rodinia          # SIMTiX host
vitis -s baselines/vortex/host/build_vitis_vortex.py rodinia     # Vortex host
vitis -s baselines/ara/host/build_vitis_ara.py rodinia [rd_sel=<mask>]   # Ara/CVA6 host
xsdb <board script> docs/zcu102_board_run_rodinia_<machine>.txt rodinia
python baselines/ara/compare_rodinia.py     # -> docs/rodinia_results.csv
```

## 8. Remaining work

- The other eleven runnable Rodinia benchmarks: nw, lud, srad, streamcluster, lavaMD,
  b+tree, particlefilter, cfd, myocyte, dwt2d, hybridsort.
- Power on the board for CVA6, Ara and Vortex, as the paper reports for SIMTiX and the A53.
