# RiVEC on SIMTiX, CVA6, Ara and Vortex (plan, 2026-11-11)

The goal is the RiVEC benchmark suite on the four machines of the paper's comparison, all
measured on the ZCU102, documented for the TVLSI paper as Rodinia was
(`docs/rodinia_plan.md`, `docs/rodinia_results.md`).

- **SIMTiX v3:** 8 lanes, 115.4 MHz, hand-written kernels (assembly).
- **CVA6:** the scalar RV64GC core of the Ara system, 78.95 MHz.
- **Ara:** 2 lanes, VLEN 2048, RVV 1.0, attached to CVA6, 78.95 MHz.
- **Vortex 3.0:** 1 core, 8 warps of 8 threads, 125 MHz.

The ARM Cortex-A53 generates or loads the inputs, computes the reference results and checks
every output, as in the other suites.

## Source

RiVEC (C. Ramírez et al., "A RISC-V simulator and benchmark suite for designing and
evaluating vector architectures," ACM TACO 17(4), article 38, 2020),
github.com/RALC88/riscv-vectorized-benchmark-suite, master branch (RVV 1.0 intrinsics),
commit 32a14ddf (2024-11-04). Cloned outside the repository at
`C:\work\rivec_src\riscv-vectorized-benchmark-suite`.

## User decisions (2026-11-11)

| Question | Decision |
|---|---|
| Ara code | **RiVEC's own vector code**, changed only where Ara has a hardware bug, for FP32, or for bare-metal input and output. Every change is listed in this document. |
| Precision | **FP32 on every machine** (SIMTiX and Vortex have no FP64), as for Rodinia. The paper says so. |
| Scope | **All 12 applications**, the quicker ports first. |

## The applications

| App | Origin | RiVEC precision | Input | RiVEC "large" size | Functions | Batch |
|---|---|---|---|---|---|---|
| axpy | BLAS | FP64 | generated | n = 2,048 | | 1 |
| matmul | BLAS | FP64 | file `data_512.in` | 512 x 512 x 512 | | 1 |
| spmv | BLAS | FP64 | SuiteSparse `poisson3Db.mtx` | 85,623 rows, 2.37 M non-zeros | | 1 |
| jacobi-2d | PolyBench | FP64 | generated | 256 x 256, 2,000 steps | | 1 |
| pathfinder | Rodinia | integer | file `data_large.in` | 1,024 rows x 2,048 columns | | 1 |
| blackscholes | PARSEC | FP32 | file `in_64K.input` | 65,536 options | exp, log, sqrt, div | 1 |
| streamcluster | PARSEC | FP64 and FP32 | generated | 8,192 points, 128 dimensions | | 2 (moved, see its section) |
| lavaMD | Rodinia | FP32 | generated | 10 x 10 x 10 boxes | exp | 1 |
| particlefilter | Rodinia | FP64 | generated | 128 x 128 x 24 frames, 8,192 particles | cos, log, sqrt, div | 2 |
| somier | | FP64 | generated | 4 steps, 128^3 | sqrt, div | 2 |
| swaptions | PARSEC | FP64 | generated | per run.sh "large" | exp, log, div | 2 |
| canneal | PARSEC | FP64 | netlist file `400000.nets` (125 MB of inputs) | 400,000 elements | | 2 |

Sizes are RiVEC's `run.sh` "large" sets. Where one does not fit the hosts' memory regions
(the Ara host's arena is 192 MB), the largest that fits is used and stated. `spmv`'s
"medium" matrix, `venkat25.mtx`, is in the repository; all inputs are present.

## Method

- **One definition per application, in FP32.** Each RiVEC application has a serial and a
  vector version, and they do not always perform the same operations (the vector code
  fuses multiply-adds that the serial code keeps separate, and uses its own exp and log
  where the serial code calls libm). The definition is:
  - for the work done per element (one option, one grid point, one particle pair): the
    operation sequence of **RiVEC's vector code, read per element**, including its fused
    multiply-adds and its exp, log and cos routines (`common/__exp.h`, `__log.h`,
    `__cos.h`, the Cephes polynomials; their masks are only `vmerge` selectors, so a
    scalar copy repeats them exactly);
  - for sums over many elements (dot products, row sums, force sums): the **serial
    order**, one term after the other.
  SIMTiX, Vortex, CVA6 and the A53 compute exactly this and must match the A53 reference
  bit for bit, except where CVA6's divider and square root apply (below).
- **Ara runs RiVEC's vector version**, in FP32. It is bit-exact where it computes per
  element (axpy, pathfinder, matmul's integer data, the per-element parts of blackscholes
  and lavaMD). Where it keeps partial sums per vector element and reduces them at the end
  (spmv, lavaMD's force sums, and in batch 2 streamcluster, swaptions, canneal), it is
  checked within a relative tolerance stated per application.
- **Transcendental functions.** RiVEC's own routines, as above. sqrt and division are
  hardware instructions.
- **Divider and square root of CVA6 and Ara.** Not correctly rounded (8.7% of quotients and
  6.9% of square roots one ulp off). Where an application divides or takes a square root,
  CVA6 and Ara are checked within a stated tolerance; the largest error is reported.
- **Each machine's natural parallel form.** One output (or work item) per thread on SIMTiX
  and Vortex, per vector element on Ara (as RiVEC vectorizes it), per loop iteration on CVA6
  and the A53.
- **Host parts and timing.** As for Rodinia: input reading and output writing are not
  timed; the kernels are, for SIMTiX and Vortex with the A53's timer around the launches, for
  CVA6 and Ara with CVA6's cycle counter around the kernel.
- **Simulation before the board.** Every kernel passes in each machine's simulation model at
  the board sizes before any board run.

## Changes to RiVEC's code for Ara (to be completed per application)

| App | Change | Reason |
|---|---|---|
| all | `double` -> `float`, `e64`/`f64` intrinsics -> `e32`/`f32` | FP32 decision |
| all | file reading and `printf` output replaced by host-supplied arrays | bare metal |
| particlefilter, canneal | `vid.v` replaced (table of indices, as `ak_iota`) | `vid.v` deadlocks Ara (`ak_vector.c`, item 6) |
| any with masked operations | reviewed against `ak_vector.c` item 2 | masked operations misbehave on Ara |

## Code layout (as Rodinia)

| Machine | Where |
|---|---|
| SIMTiX | `kernels/rivec/<name>.S` |
| A53 reference, CVA6 | `kernels/rivec/rv_ref.h` (RiVEC's serial code in FP32) |
| Ara | `baselines/ara/kernels/ak_rivec.inc` (RiVEC's vector code, changes marked) |
| Vortex | `baselines/vortex/simtix_apps/kernel.cpp` |
| host driver | `sw/ps_host/rivec.inc`, hosts built with a `rivec` argument |
| inputs | `sim/rv_data.py` (RiVEC's input files as a blob, as `sim/rd_data.py`) |
| simulation cases | `sim/gen_rivec.py` |
| results | `docs/rivec_results.md` and `.csv` |

## Order

1. Batch 1 (the quicker ports): axpy, matmul, spmv, jacobi-2d, pathfinder, blackscholes,
   lavaMD. For each: read RiVEC's serial and vector code, write the definition
   below, then the kernels, then simulation on every machine, then one board session.
2. Batch 2: streamcluster, particlefilter, somier, swaptions, canneal.

## Application definitions

Each section is written when its batch starts: inputs, the serial operation order, how
RiVEC's vector version differs from it, sizes, and the tolerance for CVA6 and Ara.

### axpy (read 2026-11-11)
- **Input:** n = 1,024 x the size argument; "large" = 2,048 -> n = 2,097,152. `dx[i] = 1.83`,
  `dy[i] = 2.22`, `a = 1.53` (RiVEC's `init_vector`, constant vectors).
- **Serial (`axpy_serial`):** `dy[i] += a*dx[i]`. RiVEC's vector version uses `vfmacc`
  (fused), and GCC contracts the serial C to a fused multiply-add as well, so the
  definition is `dy[i] = fma(a, dx[i], dy[i])` on every machine.
- **Ara:** RiVEC's `axpy_vector` unchanged except FP32: exact.

### jacobi-2d (read 2026-11-11)
- **Input:** n = 256, `A[i][j] = (i*(j+2) + 2) / n`, `B[i][j] = (i*(j+3) + 3) / n`
  (PolyBench `init_array`), 2,000 time steps; each step updates B from A and then A from B,
  over the interior (254 x 254). Rows are separate allocations in RiVEC; here one array.
- **Serial (`kernel_jacobi_2d`):**
  `B[i][j] = 0.2 * ((((A[i][j] + A[i][j-1]) + A[i][j+1]) + A[i+1][j]) + A[i-1][j])`.
- **Definition (RiVEC's vector order, per element):**
  `B[i][j] = (((A[i][j] + A[i][j-1]) + A[i][j+1]) + (A[i+1][j] + A[i-1][j])) * 0.2f`,
  and the same for A from B. The serial code adds in another order; the definition
  follows the vector code, so Ara is checked exactly.
- **Ara:** RiVEC's `kernel_jacobi_2d_vector` unchanged except FP32 and contiguous rows.

### pathfinder (read 2026-11-11)
- **Input:** `data_large.in`, 1,024 rows x 2,048 columns of integers (0-9).
- **Serial (`run`):** `dst[n] = wall[t+1][n] + min(src[n-1], src[n], src[n+1])`, the
  missing neighbours at the two edges left out; the whole computation repeated
  `NUM_RUNS` = 100 times. Integer: exact.
- **RiVEC's vector version** works in place on one row with `vslide1up`/`vslide1down` and
  the saved left neighbour (`aux`, read before the store): the same result. Exact.
- **Repetition:** RiVEC times the 100 runs; here too, so the reported time covers 100 runs
  of 1,023 row steps (about 209 M cells). SIMTiX's existing `kernels/suite2/pathfinder.S`
  computes the same row step.

### matmul (read 2026-11-11)
- **Input:** `data_512.in`: m = n = p = 512, then A (512 x 512), B (512 x 512) and RiVEC's
  reference C. The entries of A and B are the integers 0-3.
- **Serial (`matmul_serial`):** `c[i][j] = sum over k of a[i][k]*b[k][j]`, k ascending,
  contracted by GCC to `fma(a, b, c)`. Every product and partial sum is an integer below
  2^24 (at most 512 x 9 = 4,608), exact in FP32, so the result does not depend on the order
  of the additions or on fusing: every machine, Ara included, must match exactly, and
  RiVEC's own reference C in the file is a second check.
- **RiVEC's vector version** computes one c[i][j] at a time: a unit-stride load of row i of
  A, a strided load of column j of B, `vfmacc` into partial sums per element, then
  `vfredosum`. Kept as written (it is RiVEC's algorithm, not the fastest RVV form).

### spmv (read 2026-11-11)
- **Input:** SuiteSparse `poisson3Db.mtx` (Matrix Market, real general; 85,623 x 85,623,
  2,374,949 non-zeros, the entries sorted by column); `x[i] = 1.0`.
- **What RiVEC computes, and a bug in it.** RiVEC's `main.c` reads each entry as
  `col row value`, so the CSR it builds is that of the transpose: y = A^T x, the column
  sums. It keeps the 1-based indices: CSR row 0 is empty, row k holds column k, and
  `x[ja]` reaches `x[N]`, one past the end of `x`. RiVEC's `poisson3Db.verif` shows both:
  `verif[0] = 0`, `verif[k]` = the sum of column k, and its last entry (-0.532) is not
  the column sum (-0.018) because of the read past the end.
- **Definition:** y = A^T x with 0-based indices, all 85,623 rows: row k of the CSR holds
  column k+1 of the file, with the file's row indices minus one. The transpose is kept,
  as RiVEC computes it: A's own row sums are about 1e-16 (a Poisson matrix's rows cancel),
  so y = A x with x = 1 would check only rounding. `verif[k+1]` (FP64) is a second check of
  `y[k]` for k = 0 .. 85,621.
- **Serial (`spmv_serial`):** `sum = 0; for idx in row: sum += a[idx] * x[ja[idx]]`,
  contracted to `fma`.
- **RiVEC's vector version** keeps partial sums per element (`vfmacc` over chunks of the
  row) and reduces them with `vfredosum`: a different order, so Ara is checked within a
  relative tolerance per row.
- **Changes for Ara:** FP32 values; 32-bit column indices (`vsll` by 2 instead of 3,
  `vloxei32`), since 64-bit indices would double the index traffic for no reason in an
  FP32 run; check the indexed load against `ak_vector.c` item 4 (an indexed load must
  not write its own index register) and use `ld_idx` if GCC allocates it so.

### blackscholes (read 2026-11-11)
- **Input:** `in_64K.input`: 65,536 options, each `S K r divq v T type divs DGrefval`, read
  with `fscanf("%f")` (rounded once to FP32); type `P` -> 1, `C` -> 0. RiVEC repeats the
  whole set `NUM_RUNS` = 100 times and times the 100 runs; here too.
- **Definition (RiVEC's `BlkSchlsEqEuroNoDiv_vector` and `CNDF_SIMD`, per option):**
  - `lt = log(S / K)`; `sq = sqrt(T)`; `fv = exp(-(r*T))` (sign flip with `vfsgnjn`);
    `pw = (v*v) * 0.5`; `d1 = fma(r + pw, T, lt) / (v*sq)`; `d2 = d1 - v*sq`;
  - `CNDF(x)`: `xa = |x|`; `n = exp((xa*xa) * -0.5) * inv_sqrt_2pi`;
    `k2 = 1 / fma(0.2316419, xa, 1)`; `k2^2..k2^5` by successive products;
    `l1 = k2*a1`; `l2 = fma(k2^5, a5, fma(k2^4, a4, fma(k2^3, a3, k2^2*a2)))`;
    `loc = 1 - (l2 + l1)*n`; where `x < 0`, `loc = 1 - loc`;
  - `fv = fv * K`; for a call (type 0) `N1 = CNDF(d1)`, `N2 = CNDF(d2)`, for a put
    `N1 = 1 - CNDF(d1)`, `N2 = 1 - CNDF(d2)`; `price = |fv*N2 - S*N1|`.
  - exp and log: RiVEC's `__exp_2xf32` and `__log_2xf32`.
  - The exact argument order of every `_MM_MADD`/`_MM_MACC` is fixed from
    `common/vector_defines.h` when the reference is written.
- **CVA6/Ara:** three divisions and one square root per option: within a tolerance in ulp,
  set when the reference exists. RiVEC's DerivaGem value (`DGrefval`, FP64) is a second,
  loose check.
- **Changes for Ara:** `CNDF_SIMD`'s masked subtract (`_MM_SUB_f32_MASK`) becomes a
  `vmerge` of the subtracted and unsubtracted values (`ak_vector.c` item 2: masked
  arithmetic misbehaves on Ara).
- **A bug in RiVEC.** `_MM_SUB_f32_MASK` is `__riscv_vfsub_vv_f32m1_m`, the
  mask-agnostic form: RVV 1.0 leaves the unselected elements (the options with x >= 0)
  unspecified, and the compiler may use any register as the destination. Built with GCC
  15.2 and run under QEMU 10.2, RiVEC's vector Black-Scholes as written gives 46,277 of
  65,536 prices that differ from the definition; with the `vmerge` none differ
  (`kernels/rivec/qtest/rv_qtest.c`, 2026-11-11). The `vmerge` is therefore also the
  correction of RiVEC's intent, and the paper says so.
- **SIMTiX:** suite 2's `kernels/suite2/blackscholes.S` uses its own exp and log and
  produces both prices; a new kernel follows this definition.

### lavaMD (read 2026-11-11)
- **Input:** 10 x 10 x 10 boxes of 96 particles (`-boxes1d 10`), alpha = 0.5
  (a2 = 2*alpha^2 = 0.5). RiVEC fills the positions, charges and forces with `rand()`
  seeded from the clock; here the hosts' generator with RiVEC's value ranges and a fixed
  seed.
- **Definition, per particle pair (i in the home box, j in a neighbour box, including the
  home box), RiVEC's `kernel_vector.c` read per element:**
  `r2 = (B.v + A.v) - fma(A.z, B.z, fma(A.y, B.y, B.x*A.x))`; `u2 = r2*a2`;
  `vij = exp(-u2)`; `fs = 2*vij`; `d = A - B` (x, y, z); `f = fs*d`.
- **Force sums:** for each i, over the neighbour boxes in RiVEC's order and j ascending:
  `fA[i].v = fma(qB[j], vij, fA[i].v)`, and the same for x, y, z with `fxij`, `fyij`, `fzij`
  (serial order). SIMTiX and Vortex: one thread per particle of the home box.
- **Ara:** RiVEC's vector code keeps partial sums per element over j (96 particles: one
  chunk of 64 and one of 32 at VLEN 2048) and reduces them into `fA[i]` per neighbour box:
  checked within a relative tolerance.
- **Size:** about 1,000 x 96 x (up to 27 x 96) = 0.25 G pair interactions; CVA6 is
  expected to need several minutes.

### streamcluster (read 2026-11-11; moved to batch 2)
RiVEC vectorizes only the distance (128 dimensions, partial sums per element, then
`vfredosum`). The rest is PARSEC's algorithm: random sampling with `lrand48`, local search
and `pgain`, whose decisions compare accumulated costs (in FP64 in RiVEC). A one-ulp
difference in a distance can change a decision and send the run down another path, so a
tolerance on the output cannot check Ara, and the timed work would differ between
machines. The natural SIMTiX kernel (pgain's loop over points) also accumulates per-centre
sums. A method that keeps the decisions identical on every machine (for example, the
decisions taken from the A53 reference and replayed, with only the distance phases timed)
is to be designed in batch 2.

## Checks of the reference (2026-11-11)

`kernels/rivec/qtest/run_qtest.sh` builds `rv_qtest.c` for RV64GCV and runs it under
qemu-riscv64 (RVV 1.0, VLEN 1024). It compares `kernels/rivec/rv_ref.h` with RiVEC's own
vector code, compiled from RiVEC's headers and source text:

| Check | Result |
|---|---|
| `rv_exp` against `__exp_2xf32`, 4,194,304 arguments in [-100, 100] | 0 differ |
| `rv_log` against `__log_2xf32`, 4,194,304 positive normal arguments | 0 differ |
| `rv_blackscholes` against `BlkSchlsEqEuroNoDiv_vector` with the `vmerge`, in_64K | 0 of 65,536 differ |
| the same, RiVEC's code as written (mask-agnostic subtract) | 46,277 of 65,536 differ |

`kernels/rivec/qtest/rv_native_check.c` (native, WSL gcc) compares `rv_ref.h` with the
results that RiVEC ships with its inputs, read from the board blob (`sim/rv_data.py`):

| Check | Result |
|---|---|
| matmul 512^3 against RiVEC's C in `data_512.in` | 0 of 262,144 differ |
| pathfinder 1,024 x 2,048 against RiVEC's result row in `data_large.in` | 0 of 2,048 differ |
| spmv against RiVEC's `poisson3Db.verif` (FP64) | largest difference 1.5e-7 of the row's sum of absolute values |
| blackscholes against RiVEC's DerivaGem prices (FP64) | largest absolute difference 0.0146 |

The spmv comparison skips 17 rows, and RiVEC's last entry, because RiVEC's `verif` is wrong
there: all 17 columns whose RiVEC value differs from the column sum computed in double
precision have an entry in the matrix's last row, where RiVEC reads `x[N]` past the end of
`x` (2026-11-11, check in Python against the `.mtx` file).

`sim/rv_xcheck.py` compares the exact Python model of `sim/gen_rivec.py` (against which the
SIMTiX and Vortex kernels are checked) with `rv_ref.h` (which the A53 and CVA6 run), bit
for bit: exp and log 20,000 arguments each, blackscholes all 65,536 options of in_64K,
jacobi-2d 32 x 32 for 3 steps, lavaMD 2 x 2 x 2 boxes (2 home boxes): 0 differ
(2026-11-11).

## Simulation (SIMTiX RTL, Verilator, board configuration B3+B4)

`sim/run_rivec_tb.sh` runs the cases of `sim/gen_rivec.py` on the SIMTiX board top
(`tests/tb_apps.sv`; its kernel loader now takes images up to the 1,024 words of the
instruction RAM, since `bs_rv` has 274).

| Size | Cases | Result |
|---|---|---|
| small (2026-11-11) | axpy 4,096 (random data), matmul 64^3 (gemm_rb, RiVEC's C), spmv football (spmv_z), pathfinder 32 x 32 (RiVEC's result), jacobi 32^2 x 2, blackscholes 512, lavaMD 2^3 boxes x 1 home box | 11,283 words checked, 0 errors |
| board (2026-11-11) | matmul 512^3 (gemm_rb, RiVEC's C), spmv poisson3Db (spmv_z), axpy 2,097,152 (RiVEC's inputs), jacobi 256^2 x 2 steps (of 2,000), blackscholes 65,536, lavaMD 10^3 boxes (2 home boxes of 1,000), pathfinder 1,024 x 2,048 (RiVEC's result; 1,023 launches, one of RiVEC's 100 runs) | 2,644,343 words checked, 0 errors (`build_vortex/rv_board_sim.log`) |

## Simulation (Vortex: simx and the board-wrapper testbench, 2026-11-12)

`build_vortex/rv_vx_check.sh`: the ports in `baselines/vortex/simtix_apps/kernel.cpp` (the
per-element work calls `kernels/rivec/rv_ref.h`, copied by `run_apps.sh`; matmul and spmv
use the base gemm and spmv kernels, `gen_rivec.py --base`, with the same results).

| Run | Result |
|---|---|
| small, simx | 7 cases pass |
| small, wrapper testbench, seeds 1 and 7 | 11,283 words each, 0 wrong |
| board, wrapper testbench | spmv 85,623, axpy 2,097,152, jacobi 131,072, blackscholes 65,536, lavaMD 768, pathfinder 2,048 words: 0 wrong |
| board matmul | the whole 512^3 product exceeds the testbench's limit of 200 M cycles per launch (6.5 M cycles per 16 rows); the first 16 rows of C on the full data (`--mm-rows 16`) pass, 8,192 words, 0 wrong |
