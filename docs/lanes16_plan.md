# SIMTiX with 16 lanes on the ZCU102 (plan, started 2026-11-15)

Goal (user, 2026-11-15): build the 16-lane SIMTiX for the ZCU102 and run every benchmark kernel
on the board; the 16-lane design must be faster than the 8-lane design. Timing is secondary
(66 MHz acceptable), but everything must work on the board, so every step is verified before
the next (sim-before-synth rule).

## 0. What the simulations already tell us (docs/throughput_sweep.csv, Tables X-XI of the paper)

8 -> 16 lanes, same clock: 1.75x fewer cycles on the geometric mean over 15 kernels; compute
kernels 1.93-2.05x, gather kernels 1.27-1.60x. Clock the 16-lane design needs to beat the
8-lane board design (115.37 MHz) on each kernel = 115.37 / cycle speed-up:

| Kernel group (8->16 cycle speed-up) | Break-even 16-lane clock |
|---|---|
| compute: GEMM, GEMM-RB, stencils, embedding bag, CNN, MLP, k-means (1.93-2.05x) | 57-60 MHz |
| scan, segmented scan, k-means-U (1.68-1.85x) | 62-69 MHz |
| SpMV (1.40x), BFS (1.44x) | 80-82 MHz |
| hash join (1.33x) | 87 MHz |
| SpMV-Z (1.27x) | 91 MHz |
| geometric mean (1.75x) | 66 MHz |

Target: >= 95 MHz (faster on every kernel); fallback >= 66 MHz (faster on average, slower on the
gather kernels). Available PS clocks: 1.5 GHz / n (e.g. 107.1, 100.0, 93.75, 88.2, 83.3, 75 MHz).

## 1. Audit (done 2026-11-15)

| Item | State |
|---|---|
| RTL | parameterised by SIMTIX_NUM_LANES; stack depth = L (Theorem 1); line = L words = 64 B, AXI4 burst 4 beats; lane count 16 last simulated on the v2 design (4 warps) |
| board design script fpga/create_bd_ps.tcl | supports `lanes16` |
| kernels/apps, rodinia, rivec, suite2 build.py | support `--lanes` |
| kernels/sync (reduce_shfl, histogram, hist_shared, amo_contend, amo_test) | written for 8 lanes (e.g. three shuffle steps), build.py has no `--lanes`: port |
| sw/ps_host/apps.c | `#define LANES 8u` (segmented-scan plan); input sizes to check against 16-lane kernel constraints (e.g. GEMM-RB n % 64) |
| sw/ps_host/gen_kernels{,_s2,_rd,_rv}.py | read the 8-lane images: need a lane/kdir option |
| sim/gen_rodinia.py, gen_rivec.py, gen_suite2.py | no lane option: needed for the board-size simulations at 16 lanes |
| host RAM | 7.8 GB: a ~200k-LUT place-and-route in Vivado needs more (OPEN DECISION) |

## Decisions (user, 2026-11-15)

- Vivado runs on this laptop (7.8 GB): **reduce the design to fit**. Candidates, chosen with
  data: (A) 16 lanes x 8 warps, (B) 16 lanes x 4 warps (half the register-file depth, smaller
  warp table and scoreboard; costs latency hiding, 8 vs 4 warps was worth 1.15x in v3).
  For each: synthesis LUTs and peak memory, and the simulated speed-up over the 8-lane
  board design (throughput sweep at that configuration). Pick the one that fits and still
  beats 8 lanes on every kernel at the achievable clock.
- Clock: aim >= 95 MHz (faster on every kernel); 66 MHz is the floor.
- Benchmarks: all sets the 8-lane board ran (12 applications, 4 sync kernels ported to 16
  lanes, 8 Rodinia, 7 RiVEC).

## 2. Phases (each ends with its checks; nothing on the board before phase 5 passes)

1. **RTL at 16 lanes, v3 configuration** (8 warps, 64 KB L1, 16 MSHRs, 16 tags, AGG=1 APAR=0):
   Verilator lint; full xsim regression (all testbenches, all memory configurations including
   late write responses) with SIMTIX_NUM_LANES=16; fix anything lane-dependent.
2. **Kernels**: build every suite with `--lanes 16`; port kernels/sync to L lanes
   (log2 L shuffle steps, lane-count constants from a macro); check every kernel's size
   constraints against the board inputs.
3. **Host**: LANES from the build (`lanes16` argument of build_vitis.py, also for the Vortex/Ara
   hosts untouched); gen_kernels*.py `--lanes`; input sizes valid for 16 lanes; the host prints
   the accelerator's lane count (INFO register) and refuses a mismatch.
4. **Simulation at board size, exact board configuration**: every suite (applications, sync
   kernels, Rodinia, RiVEC) at 16 lanes through the board top (simt_ps_top) with the host's
   inputs, late write responses on; all outputs bit-exact. Same runs give the expected cycles.
5. **Out-of-context implementation** of the 16-lane accelerator: LUTs, FF, BRAM, DSP, Fmax;
   choose the PS clock (>= 95 MHz target).
6. **Board design**: `create_bd_ps.tcl build zcu102 tag16l lanes16 warps8 l1kb64 mshr16
   mtags16 mhz<f> retime`; timing met; post-route functional simulation of the routed netlist
   on a few kernels (gate-level check, as for v3).
7. **Board run**: all suites, all outputs checked by the A53; compare time with the 8-lane
   board logs at the same inputs (docs/zcu102_board_run_*); results table + paper.

## Findings

- 2026-11-15, sync kernels (no lane-dependent assembly; no 16-lane rebuild needed):
  histogram lane-independent; reduce_shfl's xor 1/2/4 butterfly reduces aligned 8-lane
  groups, so at 16 lanes each half-warp stores its own sum: same outputs as at 8 lanes;
  amo_contend: each 8-thread group owns its words, so results are unchanged; **hist_shared
  assumes 32-thread blocks** (lid = tid & 31): the host's REG_BLOCK must give 2-warp blocks at
  16 lanes (4-warp blocks = 64 threads would merge every bin twice).
- Board-size simulations (gen_apps.py, gen_rodinia.py, gen_rivec.py) exercise the kernels and
  the board top, not sw/ps_host's C code: apps.c, main.c, rodinia.inc and rivec.inc need a
  line-by-line review for lane assumptions (launch sizes, padding, block sizes), since a host
  bug would first show on the board (the host checks every output, so it would not be silent).
- run_xsim.py gained `--define NAME=VALUE` (added to every test), for the regression at 16 lanes.
- 2026-11-15, phase 1 (regression at 16 lanes), first run: 24/38 passed; every failure analysed
  was a testbench written for 8 lanes, none an RTL fault:
  - tb_warp_pool: 8-thread grids (1 line/op and 2 divergences at 8 lanes; at 16 lanes 64-byte
    lines and one warp) -> expectations computed from NUM_LANES; the "hang" was xsim not
    exiting after $fatal (run_xsim.py now has a wall-clock limit per tool run, 2 h);
  - tb_pdot8: result regions 8 words apart overlapped at 16 lanes -> NUM_LANES apart (8-lane
    encodings identical);
  - tb_sync: kernels and reference models assumed 8-lane warps -> kernels/sync/lanes.h
    (LANES, LOG2L), build.py --lanes (8-lane images byte-identical, 16-lane in kernels/sync/l16),
    models from NUM_LANES, hist_shared in 32-thread blocks, run_xsim picks kernels/sync/l<L>;
    passes at 8 (1154 checks) and 16 lanes (898 checks);
  - tb_apps: ran 8-lane kernel images -> run_xsim regenerates build_apps_reg_l<L> /
    build_apps_w8_reg_l<L> per invocation (a stale v2-era build_apps_l16 once gave 6838 false
    errors); small set at 16 lanes: 16031 checks, 0 errors;
  - ps_wrap failed only because the first run added the whole v3 configuration to every test
    (wrapper AXI ID width); the clean run adds only SIMTIX_NUM_LANES=16.

- 2026-11-15, clean regression at 16 lanes (only SIMTIX_NUM_LANES=16 added): 31/38; the 7
  failures were all tb_ps_top, whose reduce_shfl check assumed 8-lane sums (it passed in the
  first run only because that run still used the 8-lane sync kernels) -> N/NUM_LANES sums.
- 2026-11-15, phase 3 (host), found by comparing every LANES use in sim/gen_apps.py with
  sw/ps_host (the board host mirrors the generators):
  - apps.c `#define LANES 8u` -> SIMTIX_LANES (build define, default 8);
  - **stencil: row stride hard-coded n + 16 and the reference's interior offset + 8** ->
    n + 2*LANES and + LANES (as gen_apps.py stencil());
  - **scan: 32-thread blocks hard-coded (m/32, totals padded to 32) while the launch uses
    4-warp blocks (64 threads at 16 lanes)** -> b = 4*LANES (as gen_apps.py scan());
  - main.c: reduce_shfl check n/8 sums of 8 -> n/LANES sums of LANES; hist_shared launched with
    4-warp blocks -> 32-thread blocks (5 - log2 LANES); amo_contend unchanged (8-thread groups
    own disjoint words);
  - kernels/suite2/s2_ref.h `S2_LANES 8u` -> follows SIMTIX_LANES;
  - instruction-RAM slots: kernels grow at 16 lanes (scan 52->58 words, scan_seg 45->51,
    reduce_shfl 17->20) but all fit; _Static_asserts added for every fixed slot;
  - Rodinia and RiVEC: no lane dependence in generators or host drivers (only the 16-lane kernel
    images are needed).
- 2026-11-15, tb_ps_top lane-generic: all 7 configurations pass at 16 lanes (incl. ps_b34_board,
  262,144 threads, late write responses) -> **16-lane regression 38/38**.
- 2026-11-15, tooling (all defaults unchanged; regenerated 8-lane headers byte-identical):
  - sw/ps_host/genopts.py + gen_kernels{,_s2,_rd,_rv}.py `--kroot DIR --out DIR`;
  - sw/ps_host/build_kernels_lanes.py L: every suite + sync for L lanes into build_kernels_l<L>/,
    headers into sw/ps_host/gen_l<L>/; at 16 lanes the instruction RAM fits (suite 2 2624,
    Rodinia 3840, RiVEC 2752 of 4096 bytes: those kernels do not grow);
  - build_vitis.py `lanes16`: gen_l16 headers, -DSIMTIX_LANES=16, fpga/simtix_ps_zcu102_l16.xsa
    (board build with tagl16), workspace ws_zcu102_l16;
  - gen_suite2.py / gen_rodinia.py / gen_rivec.py `--lanes L --kroot DIR`: small sets generate at
    16 lanes.
- 2026-11-15, configuration register 0x10C = {0x5C, L1 KB, warps, lanes} in simt_ps_top (read
  only); main.c prints it and refuses a lane-count mismatch (an older bitstream reads 0 = 8
  lanes); tb_ps_top checks it. Full regressions after it: **38/38 at 8 lanes, 38/38 at 16 lanes**.
- Phase 4 tooling: sim/gen_lanes_board.py L (board-size cases, one manifest per application,
  build_b<L>/<suite>/<app>/) + sim/run_lanes_board.sh L (Verilator, exact board configuration,
  WARPS=4 for candidate B). First generation run and the 16-lane Verilator lint were stopped by
  low memory (laptop at ~1.3 GB free); build_b16 is partial (33 cases): regenerate.

- 2026-11-16, **phase 4 DONE**: all 42 board-size cases (17 applications, 10 suite 2, 8 Rodinia,
  7 RiVEC) pass bit-exact on the 16-lane board top in Verilator, exact board configuration (8 warps,
  64 KB L1, 16 MSHRs, 16 tags, MEM_LATE=1): 26,147,548 checks, 0 errors
  (docs/lanes16_board_sim.csv). The sync kernels are covered by the xsim regression at 16 lanes
  (tb_sync, tb_ps_top ps_b34_board with 262,144 threads). The runner did not keep cycle counts:
  run_lanes_board.sh now to save per-case logs before any rerun.
- Phase 5 started 2026-11-16: fpga/synth_lanes.tcl (OOC simt_ps_top, xczu9eg, v3 defines) for
  8Lx8W (baseline), 16Lx4W, 16Lx8W.
  - 8Lx8W: 108,369 LUTs (39.5 %), 48,516 FF, 72 DSP, 16 BRAM, est. 108 MHz, synth peak 3.9 GB
    (mem_engine 35,427, 8 FPUs ~33,300, warp-pool core 19,770, L1 10,240).
  - 16Lx4W: 190,184 LUTs (69.4 %), 71,194 FF, 144 DSP, 32 BRAM, est. 106 MHz, synth peak 4.7 GB
    (mem_engine 69,530 with 8 contexts, 16 FPUs ~70,000, core 29,110). 16Lx8W not run (engine
    redesign first).
- 2026-11-16, **memory-engine profile** (fpga/profile_mem_engine.tcl: engine alone, LUTs grouped
  by the signal they drive; the standalone engine is ~half its in-context size, cause not yet
  known):
  | group | 8Lx8W (16 ctx) | 16Lx8W (16 ctx) |
  |---|---|---|
  | store merge (dmem_wdata + dmem_be) | 8,488 | **37,450 (70 %)** |
  | writeback select (wb_data) | 1,321 | 3,925 |
  | response path (tag table -> load extract) | 2,216 | 3,807 |
  | AMO line buffer (a_line) | 1,755 | 3,010 |
  | coalescer lead line (o_line) | 951 | 2,262 |
  | total LUT (logic) | 16,989 | 53,653 |
  16Lx8W with 8 contexts: 51,028 LUT cells (-9 %), 10,604 FF (-45 %): contexts cost flip-flops,
  not LUTs.
- 2026-11-16, **store-merge rewrite** (me_store_merge in mem_engine.sv): each lane replicates its
  byte/half across a word with a byte enable, each line byte takes the highest writing lane by a
  one-hot AND-OR (no variable-position writes). The original kept as OLD=1
  (SIMTIX_ME_OLD_MERGE). Proved equal for all inputs by ABC (sim/formal/sm_equiv/run.ps1: miter
  of both forms, iprove UNSATISFIABLE at 4 lanes; a lowest-lane-wins mutant is caught in 0.05 s).
  Purely combinational and functionally equal, so cycle counts are unchanged by construction.
  Verification: formal (ABC) at 4 lanes; at 8 and 16 lanes the original form is too large for
  yosys on this laptop (stopped for memory), so tests/tb_sm_equiv.sv compares both forms on
  biased random requests: 2M (4 lanes, 46 % with overlapping lanes), 2M (8 lanes, 61 %), 1M
  (16 lanes, 74 %), 0 mismatches; the lowest-lane-wins mutant fails on half its requests.
  New regression test `smerge` (200k requests at the build's lane count).
  Area (engine alone, logic LUTs): 16Lx8W 53,653 -> **29,159 (-46 %)**, store merge 37,450 ->
  11,047; 8Lx8W 16,989 -> 12,005 (-29 %), store merge 8,488 -> 3,161; flip-flops unchanged.
  The 42 board-size cases at 16 lanes pass again with the new merge (per-case logs with cycles:
  build_b16/*/*/sim_l16_w8.log). Full xsim regressions
  with the new merge: 38/38 at 8 lanes and 38/38 at 16 lanes (before `smerge` was added).

- 2026-11-16, **board-size cycles, 42 cases, same inputs** (docs/lanes16_cycles.csv,
  sim/compare_lanes_cycles.py), speed-up over 8Lx8W (geomean per suite):
  | | 16Lx8W | 16Lx4W |
  |---|---|---|
  | apps (17) | 1.76x | 1.40x |
  | suite2 (10) | 1.38x | 1.12x |
  | rodinia (8) | 1.64x | 1.18x |
  | rivec (7) | 1.53x | 1.21x |
  | all 42 | **1.60x** | 1.25x |
  | break-even 16-lane clock (geomean, vs 115.37 MHz) | **72 MHz** | 92 MHz |
  **Decision: 16 lanes x 8 warps** (4 warps lose 22 % on average, up to 0.54x on axpy; the
  store-merge rewrite makes 8 warps fit). Cases below 1x at 16Lx8W and their causes:
  - suite2/sort 0.70x: L1 capacity in lines halves (line = L words: 1024 x 64 B at 16 lanes vs
    2048 x 32 B), misses ~3x with per-thread streams -> candidate fix: l1kb128 at 16 lanes;
  - rivec/spmv 0.87x: bound by the L1 port (one line per cycle; same hits/misses at both lane
    counts) -> needs a multi-line L1 (larger change); the 15 % loss still to explain;
  - blackscholes 1.01-1.02x, rodinia/nn 1.00x: the ONE shared fp_divsqrt core serialises the
    lanes (~26 cycles/div, ~37/sqrt), unchanged by lane count -> candidate fix: one core per 8
    lanes.

- 2026-11-16/17, **the two fixes** (user: "add both the fixes before the board build"):
  - SFU_CORES (simtix_pkg; default one per 8 lanes): warp_pool runs one fp_divsqrt per group of
    NL/SFU_CORES lanes in parallel, each group with its own result register (no run-time
    loop-indexed writes); 1 core = the M16 engine cycle for cycle. tb_fpdivsqrt gained ragged
    grids (3, 13, 27 threads) and an inactive-lane check.
  - L1 128 KB at 16 lanes (SIMTIX_L1_KB=128, `l1kb128`): 512 sets x 4 ways x 64 B.
  - Regressions 39/39 at 8 lanes and 39/39 at 16 lanes (2 cores); all 42 board-size cases pass
    with 2 cores and with 2 cores + 128 KB.
  - Cycle speed-up over 8Lx8W (geomean of 42): 1 core 1.60x -> 2 cores **1.68x** (blackscholes
    x2, rivec blackscholes 1.01 -> 1.99, nn 1.00 -> 2.00, gaussian 1.47 -> 1.55) -> + 128 KB L1
    **1.71x** (rivec/spmv 0.87 -> 1.05, atax/bicg/pagerank +10-13 %, rodinia bfs +7 %, no case
    slower). Break-even 16-lane clock 67.4 MHz (geomean).
  - Remaining loser: suite2/sort 0.74x: its scatter phase moves 64-B lines per scattered store
    (line = L words), ~2-3x the bytes of 8 lanes: bandwidth, not capacity (128 KB fixes the
    histogram phase only). Fix = decouple line size from lane count (later).
  - Against the A53 (measured A53 and 8-lane board times; 16 lanes projected at 100 MHz:
    sim/compare_lanes_a53.py, docs/lanes16_vs_a53.csv): geomean 8 lanes 0.66x -> 16 lanes 0.97x;
    faster than the A53 on 10 -> 18 of 42 cases.
- 2026-11-16, full-design synthesis 16Lx8W (new merge, 1 core, 64 KB): stalled 2 h 40 min in
  Timing Optimization at 5.25 GB private on the 7.8 GB laptop -> stopped; synth_lanes.tcl gained
  `lowmem` (flatten none + RuntimeOptimized), `l1kb<n>`, `sfu<n>`.
- 2026-11-17, **final configuration synthesised** (synth_lanes.tcl 16 8 l1kb128 lowmem; 18 min,
  peak 4.9 GB; reports_lanes/L16_W8_k128_lm): 207,084 LUTs (75.6 %: 185,099 logic + 21,985
  LUTRAM), 92,243 FF, 144 DSP, 32 BRAM tiles, WNS +1.065 ns at 10 ns (est. 112 MHz). Blocks:
  16 FPUs 69,328; warp-pool core 87,244 (12,800 LUTRAM register file); mem_engine 29,180;
  L1 12,304; fp_divsqrt 738 each; AXI 995. Worst path: u_l1 wack -> warp resume ->
  stk_npc CE, 29 levels, 81 % routing (pipeline candidate if P&R misses the clock). (With
  flatten none the engine no longer looks twice its standalone size: the rebuilt hierarchy had
  attributed pool logic to it.)
- Next: phase 6 board build (P&R needs more RAM than synthesis) -> post-route funcsim -> board
  run. **User decision 2026-11-17: build on this laptop with every other application closed**
  (Claude desktop app and browsers included), in its own window:
  `create_bd_ps.tcl build zcu102 tagl16 lanes16 warps8 l1kb128 mshr16 mtags16 mhz<f>` (+ retime
  if needed; check the BD module-ref IDW = log2(16)+1 and that SFU cores follow the package
  default of 2 at 16 lanes); then build_vitis.py zcu102 lanes16 (headers from gen_l16).
  Paused here at the end of the 2026-11-16 session; nothing running, nothing committed.

- 2026-11-17, **phase 6 board build DONE** (fpga/build_staged.ps1: create_bd_ps.tcl prep ->
  synth_1/runme.bat -> implprep -> impl_1/runme.bat -> finish, no Vivado holding the project
  while the runs execute; `tagl16 lanes16 warps8 l1kb128 mshr16 mtags16 mhz100 lowmem`):
  synth 21 min (0 critical warnings, peak 5.4 GB), impl 3 h 38 min; **WNS +0.041 ns at 100.00
  MHz** (WHS +0.010), 202,660 LUT (73.9 %), 93,351 FF, 144 DSP, 32 BRAM, CLB 95.8 %, 5.28 W;
  worst path mem_engine c_done -> scratchpad WE. fpga/simtix_ps_zcu102_l16.xsa;
  reports_ps_zcu102_l16/ incl. simt_0_routed_funcsim.v. Host: build_vitis.py zcu102 lanes16
  (ws_zcu102_l16, SIMTIX_LANES=16); run_board.tcl gained lanes<L>.
- 2026-11-17, **gate-level check of the routed netlist** (sim/run_netlist_sim.py; tb_ps_top
  NETLIST mode: no IDW parameter, outputs #0.5, reset 16 cycles, heartbeat; NETDBG = debug-window
  dumps at polls 20/60 for RTL-vs-gates diffs): first run hung after 8 AXI reads (n_rlast 0,
  rvalid stuck 1). RTL in the same tb mode passed, so the diff was real at first sight. Cause: the
  extracted cell netlist (write_verilog -cell) leaves the cell's CONSTANT AXI outputs
  unconnected (Vivado ties them at the PS HP0 inputs instead) -> arlen floated in the sim ->
  the memory model's rlast never matched. **Not a hardware fault**: fpga/check_ps_hp0_pins.tcl
  on the routed checkpoint shows HP0 ARLEN/AWLEN 3, SIZE 4, BURST INCR, CACHE 0011, PROT 0,
  AWID 010000, RREADY 1 (= the RTL constants); check_const_pins.tcl shows s_axi_wready and
  awready on one LUT (wr_fire). The tb now drives those ports with these verified values.
  **Routed gates PASS, cycle-exact with the RTL** (N=1024, MEM_LATE=1): reduce_shfl 1779 cycles
  0/64, histogram 1806 63/65, reduce_rerun 1783 0/64 (RTL in the same tb mode: identical);
  config 0x5C800810. Ready for the board run (phase 7).
- 2026-11-17, **phase 7 board run DONE: all three sessions PASS (0 errors)** (main, Rodinia,
  RiVEC; logs docs/zcu102_board_run_l16_{main,rodinia,rivec}.txt; summary
  docs/lanes16_board_results.md): 16 lanes @ 100 MHz vs 8 lanes @ 115 MHz = **1.45x faster
  (geomean of 82 rows), 75/82 faster**; vs the A53 0.56x -> 0.82x, faster than the A53 on
  20 -> 34 rows. Slower rows: sort (0.65x), DRAM-size atax/bicg/pagerank/cc (0.77-0.89x),
  rivec spmv (0.94x): 64-B lines on scattered traffic -> next = decouple line size from lanes.

## 3. Risks

| Risk | Mitigation |
|---|---|
| Vivado out of memory on a 7.8 GB host | run phases 5-6 on a machine with >= 16 GB (lab), or reduce the design (OPEN) |
| routing congestion at ~80% LUT use; Fmax below the 91 MHz needed for SpMV-Z | retiming, the memory-engine timing cuts of v3; accept 66-90 MHz if gather kernels may lose |
| lane-dependent bugs not seen at 8 lanes (16-lane stack overflow was one in v2) | phase 1 + phase 4 at board sizes before any build |
| Vivado mis-synthesis (the v3 ctx0 counter cast) | post-route functional simulation in phase 6 |
