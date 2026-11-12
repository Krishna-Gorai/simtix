# Rodinia on SIMTiX, CVA6, Ara and Vortex (plan, 2026-11-10)

The goal is the Rodinia 3.1 benchmark suite on the four machines of the paper's
comparison, all measured on the ZCU102:

- **SIMTiX v3:** 8 lanes, 115.37 MHz, hand-written kernels (assembly).
- **CVA6:** the scalar RV64GC core of the Ara system, 78.95 MHz.
- **Ara:** 2 lanes, VLEN 2048, the RVV vector unit attached to CVA6, 78.95 MHz.
- **Vortex 3.0:** 1 core, 8 warps of 8 threads, 125 MHz.

The ARM Cortex-A53 of the ZCU102's processing system generates the inputs, computes the
reference results and checks every output. Its own times are recorded too.

The results go into the TVLSI paper as one table of execution times and speed-ups,
with the method below stated in the text.

## Scope

Rodinia 3.1 has 23 benchmarks. Nineteen run here. Four are left out because their
published form depends on inputs that a bare-metal host cannot use without replacing the
benchmark's data:

| Left out | Reason |
|---|---|
| heartwall | tracks a heart wall through the frames of an AVI ultrasound video |
| leukocyte | detects and tracks white blood cells in the frames of an AVI microscope video |
| mummergpu | builds a suffix tree from genome files and matches reads against it |
| huffman | encodes an input file; its kernels depend on the file's symbol statistics |

The nineteen, with Rodinia's default data set (from its `run` scripts):

| Benchmark | Domain | Rodinia default | GPU kernels | State |
|---|---|---|---|---|
| backprop | neural network training | 2,097,152 input units, 16 hidden | forward layer, weight adjust | suite 2 (2^19 units); Vortex port missing |
| bfs | graph traversal | graph65536 | two (mask, update) | suite 1 (to be checked against Rodinia) |
| b+tree | database search | mil.txt, command.txt | findK, findRangeK | new |
| cfd | unstructured-grid Euler solver | fvcorr.domn.097K | step factor, flux, time step | new |
| dwt2d | image compression | 1024x1024 RGB, 3 levels | 5/3 and 9/7 lifting | new |
| gaussian | dense linear solver | -s 16 or a matrix file | Fan1, Fan2 | new |
| hotspot | thermal simulation | 512x512, 2 iterations | one stencil | suite 2 (4 steps); Vortex port missing |
| hotspot3D | 3-D thermal simulation | 512x512x8, 100 iterations | one stencil | new |
| hybridsort | sorting | random floats (`r`) | bucket sort, merge sort | new |
| kmeans | clustering | kdd_cup | point assignment | suite 1 (to be checked against Rodinia) |
| lavaMD | molecular dynamics | 10x10x10 boxes | particle forces | new |
| lud | dense LU decomposition | 256x256 | diagonal, perimeter, internal | new |
| myocyte | cardiac cell ODE | 100 steps, 1 instance | ODE solver | new |
| nn | nearest neighbour | hurricane records, k = 5 | distance | new |
| nw | sequence alignment (DP) | 2048x2048, penalty 10 | wavefront blocks | new |
| particlefilter | object tracking | 128x128x10 frames, 1,000 particles | likelihood, normalise, resample | new |
| pathfinder | dynamic programming | 100,000 columns, 100 rows | one row step | suite 2 (65,536 / 262,144 columns); Vortex port missing |
| srad | image speckle reduction | 502x458 (v1), 2048x2048 (v2) | prepare, reduce, srad, srad2 | new |
| streamcluster | online clustering | 65,536 points, 256 dims | pgain | new |

## Method

The rules of the first two suites stay:

- **One definition per benchmark.** Each benchmark is defined by Rodinia's computation
  on Rodinia's data set: the exact sequence of FP32 operations that produces one output,
  each rounded once to nearest even. `fma(a, b, c)` is the fused multiply-add. All
  machines perform those operations in that order and never re-associate them. Integer
  sums may be reordered. The definitions are written below, one section per benchmark,
  before the kernels are written.
- **Each machine's natural parallel form.** A SIMTiX or Vortex thread, an Ara vector
  element and a CVA6 or A53 loop iteration each compute one output or one unit of work.
  The CUDA kernels' thread blocks, shared memory and barriers are Rodinia's GPU
  implementation, not part of the benchmark. A machine uses its own scratchpad and
  barriers where they help.
- **FP32 everywhere.** SIMTiX and Vortex have no FP64. lavaMD, myocyte and the reference
  particlefilter use `double` in Rodinia; here every machine runs them in FP32, and the
  paper says so.
- **Inputs.** Where Rodinia reads a data file, its own file from the Rodinia 3.1 data
  archive (`rodinia-3.1-data.tar.gz`, checked against the SHA-256 in Rodinia's README) is
  converted into a binary image that the hosts load: bfs and b+tree (graph and tree
  files), cfd (mesh), dwt2d (image), hotspot and hotspot3D (temperature and power files),
  kmeans (kdd_cup), nn (record files), srad v1 (image). Where Rodinia generates its input,
  the A53 generates it with Rodinia's value ranges (for example `rand() % 10` for
  pathfinder); the generator is the hosts' own, so the values differ from glibc's
  `rand()` but the distribution is Rodinia's.
- **Transcendental functions.** exp, log, sin, cos and pow are software routines defined
  in this document, the same instruction sequence on every machine. sqrt and division are
  the hardware instructions.
- **Sizes.** The board runs Rodinia's default data set where it fits the hosts' arenas
  (the Ara host's arena is 192 MB) and a smaller simulation size. Where the default does
  not fit, the largest size that fits is used and stated.

### Checking the results

- **SIMTiX, Vortex and the A53** must match the A53 reference bit for bit.
- **CVA6 and Ara** must match bit for bit in every benchmark that has no division or
  square root. Their divide and square-root unit is not correctly rounded: on 4,096 random
  operands, 8.7% of quotients and 6.9% of square roots are 1 ulp off (2026-11-09,
  `baselines/ara/kernels/dbg_divsqrt.c`). In benchmarks with division or square root
  (cfd, gaussian, lud, nn, particlefilter, srad, streamcluster), CVA6 and Ara pass when
  every output is within the benchmark's stated tolerance of the reference. The
  tolerance is set per benchmark in its section below, in ulp or as a relative error for
  iterative benchmarks whose rounding differences grow. The largest error found is
  recorded and reported in the paper with the divider finding.
- **Errors are never hidden.** Any output outside its tolerance is a failure and is
  reported as one.

## Code layout

| Machine | Where the Rodinia code goes |
|---|---|
| SIMTiX | `kernels/rodinia/<name>.S`, built by `kernels/rodinia/build.py` |
| A53 reference, inputs | `kernels/rodinia/rd_ref.h` (shared by every host), `sw/ps_host/rodinia.inc` |
| simulation cases | `sim/gen_rodinia.py` (as `sim/gen_suite2.py`) |
| CVA6 and Ara | `baselines/ara/kernels/ak_rodinia.inc` (scalar and RVV), host in `apps_ara.c` |
| Vortex | `baselines/vortex/simtix_apps/kernel.cpp` (as the first suite) |
| results | `docs/rodinia_results.md` and `.csv` (from a script, as `compare_simtix.py`) |

## Order

The work runs in batches. Each batch is finished on every machine, first in simulation
(each machine's model, board sizes included, as the sim-before-board rule requires) and
then in one board session, before the next batch starts.

| Batch | Benchmarks | Why together |
|---|---|---|
| 0 | backprop, bfs, hotspot, kmeans, pathfinder | Already ported: check each against Rodinia's definition and data set, add the missing Vortex ports. |
| 1 | nw, lud, gaussian, hotspot3D, srad | Dense and regular; integer DP, elimination, stencils. |
| 2 | nn, lavaMD, streamcluster, b+tree, particlefilter | Irregular access, reductions, transcendental functions. |
| 3 | cfd, myocyte, dwt2d, hybridsort | The largest ports. |

Board sessions: one per batch. CVA6 is about 20 times slower than SIMTiX, so the CVA6
and Ara runs set the session length; each batch's sizes are chosen so that a session
stays under about an hour.

## Batch 0: the five existing kernels against Rodinia (audit 2026-11-10)

| Benchmark | Same computation as Rodinia? | Changes needed |
|---|---|---|
| pathfinder | Yes: `wall[r][c] + min` of the three upper neighbours, `rand() % 10` walls, 100 rows. | Board size 100,000 columns (Rodinia's default) instead of 65,536 / 262,144; Vortex port. |
| backprop | Yes: the two GPU kernels (input-to-hidden partial sums, weight adjust with eta = momentum = 0.3); the sigmoid and the small layers stay on the host, as in Rodinia. | Rodinia's CUDA run uses 2,097,152 inputs, whose two 2^21 x 16 weight arrays (256 MB) exceed the Ara host's 192 MB arena; 2^19 stays as the largest size that fits, stated in the paper. Vortex port. |
| hotspot | No. Rodinia computes every cell, and a neighbour outside the grid is replaced by the cell itself (clamped index). Suite 2 computes only the interior with a fixed ghost border. Rodinia runs 2 iterations; suite 2 runs 4. | New kernel with the clamped boundary; 512 x 512 and 1024 x 1024 with Rodinia's temp/power files, 2 iterations. Vortex port. |
| bfs | Same traversal: level-synchronous top-down BFS from node 0, output the cost (level) of every node. Rodinia uses two kernels per level (mask, update); one kernel per level that tests `level == L` gives the same costs. | Rodinia's graph65536.txt instead of our random graph. |
| kmeans | No. Rodinia: FP32 points with 34 features (kdd_cup, 494,020 points), k = 5, distance = sum of squared FP32 differences, iterated until no point changes cluster (Rodinia compares the count of changed points with a threshold of 0.001) or 500 iterations, centres updated on the host. Suite 1: integer 2-D points, one assignment step. | New FP32 kernel; kdd_cup from the data archive. |

## Benchmark definitions

Each section is written when its batch starts: the inputs and their generator, the
exact operation sequence of one output, the parallel form per machine, the sizes, and
the tolerance for CVA6 and Ara.

The first group (2026-11-10) is the eight benchmarks that are quickest to port:
pathfinder, backprop, bfs, hotspot, nn, hotspot3D, gaussian and kmeans. Common to all:

- **Files.** SIMTiX kernels `kernels/rodinia/<name>.S` (pathfinder and backprop are suite
  2's, `kernels/suite2`), the shared C reference `kernels/rodinia/rd_ref.h` (A53 and
  CVA6), the board driver `sw/ps_host/rodinia.inc` (SIMTiX, Vortex, CVA6, Ara), the Ara
  kernels `baselines/ara/kernels/ak_vector_rd.inc` with self-tests `ak_st_rd.inc`, the
  Vortex ports in `baselines/vortex/simtix_apps/kernel.cpp`, the simulation cases
  `sim/gen_rodinia.py`, Rodinia's data files as a blob `sim/rd_data.py`.
- **Board run.** Hosts built with `rodinia` (define `RD_ONLY`) run only this suite; the
  board scripts with the `rodinia` argument load `build_rodinia/rd_data.bin` at
  0x7000_0000 first.
- **Instruction RAM.** Suite 2's kernels and then the Rodinia kernels: 3,840 of 4,096 bytes.
- **Timing.** Only the kernel launches are timed (SIMTiX and Vortex: the launches, with
  Vortex's L1 flush; CVA6 and Ara: the cycles of the kernel inside the program). Host
  work that Rodinia does on the CPU (bfs's level loop control, nn's top-k selection,
  kmeans' centre update, gaussian's back substitution) runs on the A53 for every system
  and is not timed.
- **Vortex launches.** Blocks of 32 threads; the last block is partly empty when the
  thread count is not a multiple of 32 (`kernel_main` skips `t >= threads`). Before
  2026-11-10 the grid was the thread count divided by the block size, which dropped the
  last threads of counts that are not multiples of 32 (found by pathfinder's 300-column
  simulation case).

### pathfinder
- **Input:** `wall[100][100000]`, `rand() % 10` (the host's generator).
- **Computation:** `dst[c] = wall[r][c] + min(src[c-1], src[c], src[c+1])`, the rows
  padded with INT_MAX; one launch per row (99), one thread per column. Integer: exact.
- **Machines:** SIMTiX `kernels/suite2/pathfinder.S`; Vortex port; CVA6 the C loop; Ara
  vector rows (`vmin`).
- **Sizes:** board 100 x 100,000 (Rodinia's default); simulation 12 x 300 and 100 x 100,000.

### backprop
- **Input:** N = 2^19 inputs, 16 hidden units (random, Rodinia's ranges).
- **Computation:** suite 2's (`docs/suite2_plan.md`): forward partial sums
  `fma(w[16b+i][j], in[16b+i], acc)` over 16 inputs per thread, then the weight update
  `dw = fma(ed[j], in[i], m * ow)`, `w += dw`, `ow = dw`.
- **Size:** Rodinia's CUDA run uses 2^21 inputs; its two 2^21 x 16 weight arrays (256 MB)
  do not fit the Ara host's 192 MB arena, so 2^19 is used. Simulation 512 and 2^19.

### bfs
- **Input:** Rodinia's `graph65536.txt` (65,536 nodes, 393,216 edges, CSR as in the
  file); the source is node 0 (`bfs.cu` ignores the file's source).
- **Computation:** level-synchronous BFS: launch L marks every unvisited neighbour of a
  node at level L with L+1; the host launches until no node is discovered. Output: the
  level of every node (Rodinia's `h_cost`, -1 unreached). Rodinia's two kernels per level
  (mask, update) give the same levels. Integer: exact.
- **Sizes:** board graph65536; simulation graph4096 and graph65536.

### hotspot
- **Input:** Rodinia's `temp_512`/`power_512` and `temp_1024`/`power_1024`, read with
  `fscanf("%f")` (`sim/rd_data.py` rounds each decimal once to FP32).
- **Constants:** Rodinia's derivation, with its mix of float and double steps (`rd_ref.h
  rd_hotspot_consts`).
- **Computation:** every cell of the n x n grid; a neighbour outside the grid is replaced
  by the cell itself. `a = (tN + tS) - (t + t)`, `b = (tE + tW) - (t + t)`, `c = amb - t`,
  `s = fma(a, ry1, p)`, `s = fma(b, rx1, s)`, `s = fma(c, rz1, s)`, `out = fma(sdc, s, t)`;
  2 iterations (Rodinia's default `512 2 2`), one launch per iteration.
- **Machines:** SIMTiX `hotspot_rd.S` (clamps with Zbb `max`/`minu`); Ara vector columns
  1 .. n-2 and the two edge columns in scalar code (no masks).
- **Sizes:** board 512 and 1024; simulation 64 and 512.

### nn
- **Input:** Rodinia's four `cane4_*.db` files (42,764 hurricane records); latitude and
  longitude read with `atof` into a float (rounded to double, then to FP32); target
  `-lat 30 -lng 90`.
- **Computation:** `dist = sqrt(dx*dx + dy*dy)`, `dx = lat - x`, `dy = lng - y`, every
  operation rounded once (no fma); the A53 then picks the 5 nearest (Rodinia's host part).
- **CVA6/Ara:** only the square root may differ: every distance within 1 ulp.
- **Sizes:** board 42,764 records; simulation 2,048 and 42,764.

### hotspot3D
- **Input:** Rodinia's `temp_512x8`/`power_512x8` (`sscanf("%f")`), reordered from the
  file's row, column, layer order to 3D.cu's layout `i + j*n + k*n*n`.
- **Constants:** 3D.cu's derivation (`rd_ref.h rd_hotspot3d_consts`); `cw = ce`, `cs = cn`,
  `cb = ct`.
- **Computation:** one thread per (i, j) column walking the 8 layers (Rodinia's
  hotspotOpt1), every neighbour clamped. `s = cc*t`, then in order
  `fma(cw, tW)`, `fma(ce, tE)`, `fma(cs, tS)`, `fma(cn, tN)`, `fma(cb, tB)`, `fma(ct, tT)`,
  `fma(sdc, p)`, `fma(ct, amb)`: Rodinia's sum from the left, fused.
- **Sizes:** board 512 x 512 x 8, 100 iterations (Rodinia's default); simulation
  64 x 64 x 8 and 512 x 512 x 8, 2 iterations.

### gaussian
- **Input:** Rodinia's `-s n` matrix (`create_matrix`: `a[i][j] = 10*exp(-0.01*|i-j|)`
  through Rodinia's float and double steps, `b = 1`), made by `sim/rd_data.py`.
- **Computation:** forward elimination without pivoting. For t = 0 .. n-2: Fan1
  `m[i][t] = a[i][t] / a[t][t]` (one thread per row below the pivot), Fan2
  `a[i][j] = fma(-m[i][t], a[t][j], a[i][j])` for j = t .. n (one thread per column,
  walking the rows). `b` is column n of an augmented n x (n+1) matrix, so Rodinia's `b`
  update is the last column. Outputs `a` and `m`; the back substitution runs on the A53.
- **Why not `matrix1024.txt`:** without pivoting, elimination on Rodinia's random matrix
  file grows the entries to 5.3e4, and changing 8.7% of the quotients by 1 ulp (CVA6's
  divider) changes rows of the result by up to 6.3 times their largest entry. No
  tolerance can then tell a rounding difference from an error. On the `-s` matrix the
  entries stay at most 10 and the same perturbation changes rows by at most 2.0e-4 of
  their largest entry (n = 2048; `sim/rodinia_exp/gauss_growth_file.c`, `gauss_growth_s.c`).
- **CVA6/Ara:** every row of `a` and of `m` within 1e-3 of the row's largest reference
  value (`RDREL` rows in the log, the largest ratio in parts per billion).
- **Ara:** Fan1 runs on CVA6's scalar divider and Fan2 on Ara. Ara's vector Fan1
  (strided load, `vfdiv.vf`, strided store) gave wrong multipliers, or deadlocked Ara, when it ran after nn
  (`baselines/ara/kernels/ak_vector.c`, item 7 of the header). Fan1 is O(n) per step
  against Fan2's O(n^2).
- **Sizes:** board 1024; simulation 48 and 256 (the exact Python model of 1024 takes
  hours; 256 already exceeds the caches).

### kmeans
- **Input:** Rodinia's `kdd_cup` (494,020 points, 34 features, `atof` into float); k = 5;
  the initial centres are the first 5 points (Rodinia's `rand()` call is commented out).
- **Computation:** per point and centre `ans = fma(d, d, ans)` over the features in
  order with `d = f - c`; the first strictly smaller distance wins. The A53 then counts
  the changed points and recomputes the centres (Rodinia's CPU part: sums in point order,
  divided by the counts). Iterated until no point changes or 500 loops: 37 iterations on
  kdd_cup (`sim/rodinia_exp/kmeans_iters.c`). Every system's final memberships, centres and iteration count must equal the
  A53's (no division or square root in the kernel, so CVA6 and Ara are exact too).
- **Machines:** SIMTiX and Vortex on Rodinia's feature-major layout, one thread per point
  (SIMTiX selects with `fmin` and Zicond, no branch); Ara feature-major at LMUL 1, the
  comparison mask only as a `vmerge` selector; the A53 and CVA6 on the point-major layout.
- **Sizes:** board 494,020 points; simulation one assignment step on 512 and 65,536 points
  (the centre update between iterations is A53 code, checked on the board).
