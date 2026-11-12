# Suite 2: named benchmarks on SIMTiX, Ara and CVA6 (plan, 2026-11-09)

The user chose ten kernels, one or more from each of five well-known suites. All are
measured on the ZCU102, as the first suite (twelve applications) is.

| Suite | Kernel | New pattern |
|---|---|---|
| Rodinia | pathfinder | dynamic programming, one row per step |
| Rodinia | hotspot | 2-D stencil with more arithmetic per point |
| Rodinia | backprop | partial sums, then an element-wise weight update |
| RiVEC | Black-Scholes | FP32 with exp, log and sqrt |
| GAP | PageRank | irregular FP32 gather |
| GAP | connected components | iterated label propagation |
| SHOC | sort | radix sort of key-value pairs |
| PolyBench | atax | matrix-vector product, then transposed product |
| PolyBench | bicg | two matrix-vector products in one pass |
| PolyBench | jacobi-2d | PolyBench's 5-point form |

## Rules, as in the first suite

- **Exact results.** Every output is compared word for word with an A53 reference. Each
  kernel is defined below by the exact sequence of FP32 operations of one output, each
  rounded once (round to nearest even). `fma(a, b, c)` is the fused multiply-add. The
  A53 and CVA6 run the C version; SIMTiX runs hand-written assembly; Ara runs RVV.
  - All compute those operations in that order, never re-associated.
  - Integer sums may be reordered.
- **Workers.** "One thread per output" means a SIMTiX thread. On Ara it is one vector
  element; on CVA6 and the A53 it is one loop iteration.
- **Transcendentals.** exp and log are software routines defined here, the same on all
  architectures; sqrt is the hardware instruction. Neither libm nor RVV estimates are
  used.
- **Sizes.** Two board sizes per kernel (medium, DRAM-sized). The simulation cases are
  smaller.

## Kernels

### pathfinder (Rodinia)
- **Inputs:** `wall[rows][cols]` int32 in 0..9 (Rodinia: `rand() % 10`).
- **Recurrence:**
  - `dst[0][c] = wall[0][c]`;
  - for r >= 1: `dst[r][c] = wall[r][c] + min(dst[r-1][c-1], dst[r-1][c], dst[r-1][c+1])`,
    with neighbours outside 0..cols-1 left out.
- **Output:** the last row.
- **Layout:** the rows ping-pong between two buffers, one launch per row (`cols` threads).
- **Sizes:** rows 100, cols 65,536 and 262,144 (Rodinia's default: 100 rows, 100,000
  columns; 1,048,576 columns would need 400 MB, more than the hosts' arenas).

### hotspot (Rodinia)
- **Inputs:** temperature `t` and power `p` (FP32), on n x n grids with a one-cell ghost
  border that holds its initial value.
- **Constants:** `rx1, ry1, rz1, amb, sdc` (FP32, Rodinia's derivation from the chip
  size, as host constants).
- **One step,** per interior cell:
  - `a = (tN + tS) - (t + t)`
  - `b = (tE + tW) - (t + t)`
  - `c = amb - t`
  - `s = fma(a, ry1, p)`, `s = fma(b, rx1, s)`, `s = fma(c, rz1, s)`
  - `out = fma(sdc, s, t)`
- **Iteration:** ping-pong between two grids, 4 steps.
- **Sizes:** n = 512 and 1024 (Rodinia's data sets).
- **Difference from Rodinia:** a ghost border instead of clamped indices.

### backprop (Rodinia)
- **Shape:** input layer `in[N+1]` (`in[0] = 1`, the bias), hidden layer of H = 16,
  weights `w[N+1][H]`, previous changes `ow[N+1][H]`. These are the two GPU kernels of
  Rodinia's `bpnn`.
- **Forward partial sums:** thread (b, j) for blocks of 16 inputs:
  `ps[b][j] = fma(w[16b+15][j], in[16b+15], ... fma(w[16b][j], in[16b], +0))`, in index
  order. The A53 adds the blocks in order and applies the sigmoid on the host side, as
  Rodinia does.
- **Weight update:** per (i, j), `dw = fma(ed[j], in[i], m * ow[i][j])`, then
  `w[i][j] = w[i][j] + dw` and `ow[i][j] = dw`. Here `ed[j] = eta * delta[j]` is computed
  by the host, `eta = 0.3` and the momentum `m = 0.3`.
- **Timing:** only the two launches are timed for the accelerators, as in Rodinia.
- **Sizes:** N = 65,536 (Rodinia's default) and 524,288 (four N x 16 arrays, plus the A53
  reference copies, fit the arenas).

### Black-Scholes (RiVEC / PARSEC)
- **Inputs, per option:** `S, K, r, v, T` (FP32). Outputs: call and put prices.
- **Steps:**
  - `sq = sqrt(T)`
  - `d1 = (log(S / K) + (r + 0.5*v*v) * T) / (v * sq)`
  - `d2 = d1 - v*sq`
  - the call and put prices from `CNDF(d1)` and `CNDF(d2)` (PARSEC's polynomial CNDF)
    and `K*exp(-r*T)`.
- **Exact sequence:** fixed in `kernels/suite2/blackscholes.S`'s header. It includes:
  - `log`: range reduction to [sqrt(1/2), sqrt(2)), then a degree-8 polynomial in fma form;
  - `exp`: `2^k * p(f)`, a degree-6 polynomial;
  - one FP32 division each for `S/K`, `d1` and the CNDF.
- **Sizes:** 65,536 and 1,048,576 options.

### PageRank (GAP)
- **Graph:** pull form over the in-edges in CSR. The graph is the BFS generator's
  (symmetric, so in-edges = out-edges).
- **Per iteration:**
  1. `c[u] = pr[u] * invdeg[u]`, where `invdeg` is computed by the host once.
  2. `acc = +0; acc = acc + c[u]` over the edges in CSR order; `pr'[v] = fma(d, acc, base)`
     with `d = 0.85` and `base = (1 - d) / N`.
- **Iterations:** 10, fixed (GAP stops on a tolerance; a fixed count keeps the runs
  comparable).
- **Sizes:** 16,384 and 262,144 vertices, degree 8.

### Connected components (GAP)
- **Labels:** `lab[v] = v` at the start. Each round:
  `lab'[v] = min(lab[v], min over neighbours u of lab[u])`.
- **Determinism:** two arrays, so the result is independent of order. The host repeats
  rounds until a changed flag stays 0, as BFS does.
- **Difference from GAP:** label propagation instead of Afforest, the same output (the
  minimum vertex of each component).
- **Sizes:** the PageRank graphs.

### sort (SHOC)
- **Task:** a stable LSD radix sort of `n` 32-bit keys with 32-bit values, 4 bits per
  pass, 8 passes. SHOC sorts key-value pairs by radix.
- **Each pass,** with W workers, each owning a contiguous chunk:
  1. per-worker digit histograms;
  2. an exclusive scan over (digit, worker);
  3. each worker scatters its chunk in order.

  This makes the sort stable, so the output (keys and values) is unique.
- **Sizes:** 65,536 and 1,048,576 pairs.

### atax (PolyBench)
- **Computation:**
  - `tmp[i] = sum_j A[i][j] * x[j]` as an fma chain from +0 in j order;
  - `y[j] = sum_i A[i][j] * tmp[i]` as an fma chain in i order.
- **Launches:** two, threads over i, then over j.
- **Sizes:** N = M = 1024 and 4096.

### bicg (PolyBench)
- **Computation:**
  - `q[i] = sum_j A[i][j] * p[j]` (fma chain over j);
  - `s[j] = sum_i r[i] * A[i][j]` (fma chain over i).
- **Sizes:** 1024 and 4096.

### jacobi-2d (PolyBench)
- **Computation:**
  `B[i][j] = 0.2f * ((((A[i][j] + A[i][j-1]) + A[i][j+1]) + A[i+1][j]) + A[i-1][j])`,
  then the same from B back to A.
- **Steps:** T = 4 (8 sweeps).
- **Sizes:** N = 512 and 2048.

## Pipeline per kernel

1. **Gold:** the exact operations in Python, in `sim/gen_suite2.py`.
2. **SIMTiX:** `kernels/suite2/<k>.S`, checked with Verilator `tb_apps` on the
   gen_suite2 manifest.
3. **CVA6 / A53:** the scalar C in `ak_scalar.c` and the board hosts.
4. **Ara:** RVV in `ak_vector.c`, following the Ara rules found on 2026-11-08 (header of
   `ak_vector.c`). Checked on QEMU, then with the Ara self-test in Verilator.
5. **Board hosts:** the apps in `sw/ps_host/apps.c` (SIMTiX, later Vortex) and
   `baselines/ara/host/apps_ara.c`.
6. **Board runs:** the SIMTiX bitstream, the Ara bitstream, and later Vortex.

## Status (2026-11-09)

- **SIMTiX: all ten kernels pass** in Verilator `tb_apps`, small cases, board
  configuration B3+B4 with `MEM_LATE`: 30,917 words, 0 errors (`sim/run_suite2_tb.sh small`).
  - Kernels: `kernels/suite2/*.S`. Built by `kernels/suite2/build.py`; the gold comes from
    `sim/gen_suite2.py`.
  - Kernel sizes (words): pathfinder 15, hotspot 44, jacobi2d 32, mv_row 20, mv_col 22,
    pr_contrib 11, pr_pull 23, cc_step 26, bp_forward 24, bp_adjust 21, rs_hist 27,
    rs_scan 18, rs_scatter 44, blackscholes 234.
- **Scalar reference** `kernels/suite2/s2_ref.h`: used as the CVA6 kernels, the A53
  references and the Ara self-test's reference.
  - It equals the Python gold on all ten (`test_s2_ref.c`, native).
  - `S2_BS_C` and `s2_hotspot_consts` give the gold's constants bit for bit.
- **Ara.**
  - RVV in `baselines/ara/kernels/ak_vector_s2.inc`; app IDs 13-22 in `ak.h`; self-tests
    in `ak_st_s2.inc`.
  - All ten match the scalar versions under QEMU (VLEN 1024).
  - The Ara Verilator runs are in progress.
- **Next.**
  1. Board hosts: SIMTiX (`apps.c`) and Ara/CVA6 (`apps_ara.c`), with the same generator
     and A53 checks.
  2. Board runs.
  3. Vortex ports.
