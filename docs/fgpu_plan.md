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

## Progress 2026-11-19 (resumed)

- Compiler: `JOBS=1 bash baselines/fgpu/build_fgpu_llvm.sh` resumed in WSL (log
  ~/fgpu_llvm/build.log); 56 LLVM libraries were already built, clang/llc links remaining.
  FGPU's `kernels/compile.sh` expects `../llvm-3.7.1.build/bin/`: point BIN_DIR at
  ~/fgpu_llvm/build/bin.
- `RTL/DSP48E1.vhd` is FGPU's own behavioural multiply-add named DSP48E1, not the 7-series
  primitive: Vivado infers UltraScale+ DSP48E2 from it (watch for a name clash with unisim).
- Floating point: FGPU ships encrypted Vivado-2016 floating_point_v7_1_2 sources for
  "zynq" (7-series). Regenerate for XCZU9EG with `baselines/fgpu/gen_fp_ip.tcl` (same entity
  names/ports/latencies: fadd_fsub 11, fmul 8, fdiv 28, fsqrt 28, frsqrt 28, fslt 2,
  uitofp 5 cycles, matching the *_DELAY constants), output outside the repo.
- Configuration to set in FGPU_definitions.vhd: FLOAT_IMPLEMENT = 1 (default 0),
  ATOMIC_IMPLEMENT = 1 (default 0; needed by the AMO kernels), N_CU_W = 0 (1 CU of 8 PEs).
- Testbench: FGPU_tb.vhd selects a kernel by `kernel_name` in FGPU_simulation_pkg.vhd,
  programs the kernel descriptor over AXI-Lite and checks results in global_mem.vhd;
  code from cram.mif / krnl_ram.mif.

### Phase 0 status (2026-11-19)
- **Step 1 compiler: DONE.** clang 3.7.1 + llc (FGPU backend) + llvm-objdump/llvm-mc in
  ~/fgpu_llvm/build/bin. Compiling from a copy (~/fgpu_work/kernels, compile.sh BIN_DIR
  pointed there; compiler_outputs/ of the source kept as ref_outputs): vec_add and
  vec_add_hard_float produce the reference instruction words exactly; matrix_multiply has the
  same 741 words except one two-instruction pair placed 4 words later with another register
  (0x1103f803/0xb2000862 vs 0x1103f804/0xb2000882), a scheduling difference of the backend
  revision.
- **Step 2 simulation: in progress.** baselines/fgpu/gen_fp_ip.tcl regenerated the 7 FP cores
  for XCZU9EG in C:/work/fgpu_build/ip (latencies 11/8/28/28/28/2/5, ports identical to
  FGPU's wrappers; 2025.1 names the op Rec_Square_Root). baselines/fgpu/sim_fgpu_tb.tcl runs
  FGPU_tb in xsim on a configured copy of the RTL (needs NoDefaultCurrentDirectoryInExePath
  cleared, run from PowerShell). Fix needed: N_TAG_MANAGERS_W = N_CU_W+1 at one CU (the
  shipped +0 fails FGPU.vhd's own assertion). STAT = 1 prints "Note: Size=..." per finished
  size instead of "finished successfully"; integer mismatches and missing writes are fatal,
  float mismatches are non-fatal "Error:" lines (count them).
  Results: copy 13 sizes, mat_mul 3 sizes (8^2..24^2), add_float 5 sizes (regenerated fadd):
  all 0 errors.
  Also mul_float 4 sizes and sum_atomic 12 sizes (ATOMIC_IMPLEMENT = 1; it prints
  "Problem size=", not "Size="), 0 errors. **Step 2 DONE.**
- **Step 3 out-of-context synthesis: started 2026-11-19 19:14.**
  baselines/fgpu/synth_fgpu_ooc.tcl (launched detached from PowerShell): XCZU9EG, 100 MHz,
  the OPT_LEVEL-3 strategy of the SIMTiX/Vortex study, 1 CU x 8 PEs, float + atomic on,
  frsqrt off; outputs in C:/work/fgpu_build/syn/fgpu_1cu_100mhz/ (summary.txt, timing.rpt,
  post_impl_util.rpt, power_vectorless.rpt).
- **Step 3 DONE** (19:44): FGPU 1 CU x 8 PEs, float + atomic, XCZU9EG out of context, Vortex's
  OPT_LEVEL-3 flow: 44,596 LUT (2,262 LUTRAM), 61,491 FF, 55 RAMB36, 64 DSP; WNS +4.668 ns at
  100 MHz -> Fmax 187.5 MHz; 1.48 W vectorless (0.86 dynamic). FP units are per PE (8 each of
  fadd 173 LUT/2 DSP, fmul 100/2, fdiv 771, fsqrt, uitofp): 14,649 LUT of float. Worst path in
  gmem_cntrl (atomic -> read tag), 92% routing. Synthesis peaked at 3.6 GB.
- **Step 4 (board), 2026-11-19:** baselines/fgpu/rtl/fgpu_ps_wrap.v (our Verilog wrapper, as
  FGPU_v3_0.vhd: byte address 15:2, cache 0010, m1..m3 tied off); tb/tb_fgpu_ps.sv +
  sim_fgpu_ps.tcl: the A53 host sequence (code, descriptor, INITIATE, CLEAN_CACHE, START, poll
  STATUS) against the randomized AXI4 model (LAT 24, OOO, STALL, LATE): vec_add and
  add_hard_float at 4,096 work-items + vec_add 256: 8,448 checks, 0 errors, PASS (exact board
  configuration; xsim needs the frsqrt core present). create_bd_fgpu.tcl: BD validated (FGPU at
  0xA000_0000, HP0 64-bit, DDR low 0..2 GB, PL 149.985 MHz). host/main_fgpu.c (FGB rows: kernel,
  n, fgpu_us, a53_us, errors; sizes 64..1M), gen_fgpu_image.py -> fgpu_image.h (GPL-derived,
  .gitignore), build_vitis_fgpu.py, run_board_fgpu.tcl. NEXT: board build (asked the user).
- **Board build DONE** (2026-11-19 21:17 -> 22:35, laptop, apps closed; synthesis peak 4.7 GB,
  write_bitstream 5.7 GB): create_bd_fgpu.tcl build at 149.99 MHz, WNS +2.064 ns (Fmax ~217
  MHz); 43,995 LUT (2,467 LUTRAM), 58,582 FF, 49.5 RAMB36, 64 DSP; FGPU 1.12 W (PS 2.74 W,
  total 4.60 W, Vivado estimate). Worst path: float_units code_vec -> res_float, 95% routing.
  fgpu_ps_zcu102.xsa written. 187.5 MHz (1.5 GHz / 8) likely closes too (option for later).
- **First board run PASS (2026-11-19 22:53)**, docs/zcu102_board_run_fgpu.txt: vec_add and
  add_hard_float at 64 .. 1,048,576 work-items, 10 runs, every output checked against the A53,
  0 errors. 1M work-items: FGPU 50.3 ms (vec_add) / 50.4 ms (float), A53 7.4 / 9.0 ms. Int and
  float equal -> memory-bound: ~21 M work-items/s, ~250 MB/s (2 loads + 1 store) at 150 MHz on
  one 64-bit port. Host build note: a stale Vitis java/vitis_c++ server can hold ws .lock.
  **PHASE 0 COMPLETE.** Next: phase 1 (the suites in OpenCL for FGPU).

## Phase 1: Rodinia (started 2026-11-19 evening)

- **Kernels:** baselines/fgpu/kernels/rodinia.cl (our code): pathfinder, bp_forward, bp_adjust,
  hotspot_rd, nn, hotspot3d, gauss_fan1, gauss_fan2, kmeans_rd, bfs; each takes (parameter block
  p, work-item count n), reads the same parameter blocks as the SIMTiX kernels, keeps every
  definition's operation order; FP_CONTRACT OFF, each fma = multiply then add. Compiled with
  -hard-float: 580 words (code RAM 4,096); fadd/fmul/fsub, 1 fsqrt (nn), 1 fdiv (fan1), no soft
  float calls.
- **Simulation before the board:** tb/gen_fgpu_cases.py turns SIMTiX's cases (sim/gen_rodinia.py
  --size small: same images, launches, gold) into FGPU cases (slot -> entry word);
  tb/tb_fgpu_apps.sv + sim_fgpu_apps.tcl run them on the wrapper as the A53 does (descriptor:
  size rounded to 64, wg 64, 2 params). Gold indices are hex. FMA definitions (hotspot,
  hotspot3d, gaussian, backprop) are checked within 1e-3 of the case's largest |gold|, the rest
  exactly. xsim runs FGPU at ~340 cycles/s.
  Results: pathfinder_12x300 300/300 exact, nn_2048 2048/2048 exact (FGPU's fsqrt is correctly
  rounded). The other six running (C:/work/fgpu_build/sim_apps_rest).
- **Host:** sw/ps_host/apps.c gets a SIMTIX_FGPU backend (fg_launch, fg_entry_of, FGB rows,
  fg_skip, load() no-op, fg_load_code); FG_FP_DIFF = exact diff() on every other build,
  row-relative 1e-3 (FGREL rows: worst ppb, exact words) under SIMTIX_FGPU, at the four FMA call
  sites (suite2.inc backprop; rodinia.inc hotspot, hotspot3d, gaussian). rd_load_all and
  s2_load_all skip under SIMTIX_FGPU. main_fgpu.c FG_SUITE mode; build_vitis_fgpu.py rodinia
  (SIMTIX_FGPU, FG_SUITE, RD_ONLY). apps.c syntax-checked clean (-Wall -Wextra) for SIMTiX,
  Vortex, A53-only and FGPU. Board: run_board_fgpu.tcl rodinia (loads build_rodinia/rd_data.bin).

### RiVEC (phase 1, started 2026-11-19 23:00)
- baselines/fgpu/kernels/rivec.cl: gemm and spmv (the base kernels, as Vortex; rivec.inc runs
  them under SIMTIX_FGPU as under SIMTIX_VORTEX), pathfinder, axpy_rv, jacobi_rv, bs_rv,
  lavamd_rv; rv_ref.h's rv_exp/rv_log/rv_cndf ported operation by operation. FGPU limits met:
  no float->int conversion and no signed int->float (exact magic-constant forms with 1.5*2^23),
  only fslt compares (every comparison written a < b; rv_log's invalid test as an exact bit
  test), no fneg (exact sign-bit flip), no static functions in OpenCL 1.x (inline always_inline),
  no divider (lavaMD's t/96 = ((t>>5)*0xAAAB)>>17, exact). 825 words, 4 fdiv, 1 fsqrt, no calls.
- Host: per-suite FGPU images (fg_use_suite from run_rodinia / run_rivec, like SIMTiX's IRAM),
  fg_entry_of dispatching per suite (kernel IDs of suites overlap); image names prefixed
  FG_<IMAGE>_<KERNEL>_POS; FG_FP_DIFF at axpy, spmv, blackscholes, lavamd (matmul exact:
  integer data; jacobi, pathfinder exact); build_vitis_fgpu.py rivec (RV_ONLY). All host
  configurations (SIMTiX, Vortex, A53-only, FGPU RD/RV) syntax-clean with -Wall -Wextra.
- Simulation: SIMTiX's small RiVEC cases (gen_rivec.py --size small), gemm_rb -> gemm x16
  work-items, spmv_z -> spmv; running (C:/work/fgpu_build/sim_apps_rivec).

### Overnight 2026-11-20: simulation results and fixes
- **Rodinia (small cases, FGPU RTL in xsim):** pathfinder_12x300 300/300 exact, nn_2048 exact,
  backprop_512 0 errors (13,914 of 16,896 words bit-exact, worst 1.2e-7 of the largest |gold|),
  bfs_graph4096 4,104/4,104 exact, hotspot_rd_64x2 4,096/4,096 exact. hotspot3d, gaussian,
  kmeans_rd still running at 04:50 (two xsims in parallel: ~200 FGPU cycles/s each).
- **RiVEC:** axpy_4096 0 errors (worst 6.6e-8), spmv_z_football 115/115 exact, pathfinder_32x32
  exact, jacobi_32x2 exact, bs_512 0 errors (worst 9.3e-7). lavamd_2x1 still running (8 boxes
  per particle x 96 = 768 interactions of ~80 instructions, 2 wavefronts: latency-bound).
  matmul_gemm_rb_64: 4,032/4,096 exact, the last 64 outputs read 0 -- a testbench race, below.
- **FGPU signals STATUS before its last write-backs land.** gmem_cntrl_tag.vhd's end-of-kernel
  sweep walks the 128 cache lines (16 KB, 128-byte lines) in order and raises finish_exec when
  the sweep is done and the AXI writers are idle at that moment, while the last dirty lines can
  still be in the finish FIFO. gemm_rb_64's C is 0x8000..0xBFFF: its last 64 words are lines
  126-127, the last two swept, and the testbench read them 40 cycles after STATUS. Fix:
  tb_fgpu_apps.sv waits for 128 cycles without AXI write traffic after STATUS (gemm to be
  re-simulated). On the board the window is tens of FGPU cycles, inside the next launch's ~15
  AXI-Lite descriptor writes or the A53's cache invalidate before a check: no host change
  (comment in fg_launch).
- **kmeans without FMA:** the A53 reference uses fmaf, FGPU d*d then + (no FMA unit). Replayed
  offline in float32 (exact FMA via round-to-odd, checked against rationals on 20,000 cases) for
  Rodinia's whole loop on kdd_cup (494,020 points, k = 5, 34 features): both converge in 37
  iterations with identical assignments at every step and bit-identical centres, so the board's
  exact kmeans check holds for FGPU.
- **Host robustness:** fg_launch gives up after 300 s (FG_TIMEOUT_S; no launch needs more than
  seconds), prints the kernel, counts one error and skips the remaining FGPU runs, so a hang
  still yields the rest of the rows. build_vitis_fgpu.py builds into ws_zcu102_rodinia /
  ws_zcu102_rivec (ws_zcu102 for phase 0), run_board_fgpu.tcl picks the matching workspace and
  writes docs/zcu102_board_run_<suite>_fgpu.txt (the other machines' naming).
- **Port models (logic check in seconds):** baselines/fgpu/tb/model_fgpu_cases.py runs float32
  models of the ports (multiply then add, the .cl operation order) on the same cases and checks
  as the testbench does. hotspot3d_64x8x2 32,671/32,768 exact, worst 1.8e-7; gaussian_48 0
  errors, worst 1.7e-6; kmeans_rd_512 512/512 exact; matmul_gemm_rb_64 4,096/4,096 exact (so the
  RTL's 64 zero words are the read-after-STATUS race, not the kernel); lavamd_2x1 0 errors,
  worst 1.1e-7. Negative test: without the launches the checker reports errors in every case.
- **The 1e-3 limit is loose for hotspot data:** temperatures near 323 K change little per step,
  so 1e-3 of the largest value (~0.3 K) passes 98% of hotspot3d's words even with no kernel run
  at all (worst 1.1e-3). The evidence is the worst ratio, which the host prints (FGREL, ppb):
  ~1e-7 expected from the models, ~1e-3 would mean a wrong kernel. compare_rodinia.py and
  compare_rivec.py now read zcu102_board_run_<suite>_fgpu.txt (fgpu_us, fgpu_errors,
  fgpu_max_error from FGREL, fgpu_over_simtix; old columns unchanged).

## Phases 2 and 3: suite 1 and suite 2 (ported 2026-11-20 early morning)
- **Kernels (our code):** baselines/fgpu/kernels/apps.cl (suite 1: gemm, spmv, stencil, kmeans,
  bfs, scan, scan_add, mlp, conv8, embag, hashj, mandel, swat; from the Vortex ports'
  per-thread code) and s2.cl (suite 2: pathfinder, hotspot, jacobi2d, mv_row, mv_col,
  pr_contrib, pr_pull, cc_step, bp_forward, bp_adjust, rs_hist, rs_scan, rs_scatter,
  blackscholes; from the .S headers and s2_ref.h). FGPU-specific choices:
  - FGPU's backend has no byte or halfword LOADS ("lb" is a word load at a byte offset;
    FgpuInstrInfo.td), but has sb/sh: the INT8 kernels load words and unpack with shifts.
  - atomics: FGPU has only atomic_add / atomic_max (FGPUlib.c). kmeans (suite 1) uses
    atomic_add at a per-cluster address -- the case FGPU's known_bugs.md lists as never tested
    ("changing the address of atomic operation within the same kernel"): xsim must show it.
    bfs / cc_step store their flag (no atomic_or; every writer stores 1).
  - no barriers / local memory / shuffles in FGPU's compiler: scan sums each 32-element block
    directly (integer adds, any order gives the same words).
  - exact products: stencil (c1 = 0.125), mandel (x * 2, pixel = integer * 5 * 2^-k): the
    separate add equals the fma, so these stay exact checks. Requantization (mlp, conv8):
    under SIMTIX_FGPU the A53 reference multiplies then adds too (RQ_FMA), bytes exact.
  - FG_FP_DIFF (row-relative 1e-3, FGREL rows) for gemm, spmv, hotspot (suite 2), atax/bicg,
    pagerank, blackscholes; jacobi2d, cc, sort, pathfinder exact.
  - rs_hist / rs_scatter count and place in memory as SIMTiX's .S do (read-modify-write of
    the worker's own hist / off words). FGPU's scheduler holds a wavefront in
    wait_gmem_finish after every global memory instruction until its requests are queued
    (stores) or answered (loads), and requests enter gmem_cntrl through one FIFO, so a work-
    item's load after its own store should see the store; the sort case checks it in xsim.
- **Host:** apps.c FG_AP / FG_S2 images (when fgpu_image.h has FG_APPS_LEN / FG_S2_LEN),
  fg_entry_of_ap (overlay kernels through load()'s fg_ovl_of, as Vortex), fg_entry_of_s2;
  run_apps loads the suite-1 image before suite 1 and the suite-2 image before run_suite2.
  build_vitis_fgpu.py apps / run_board_fgpu.tcl apps (ws_zcu102_apps, docs/
  zcu102_board_run_apps_fgpu.txt). All host builds syntax-clean with and without the images.
- **Models:** model_fgpu_cases.py covers suites 1 and 2: on gen_apps.py --size small (12 cases,
  zbtest excluded) and gen_suite2.py --size small (10 cases) every case passes; mlp and conv8
  are byte-exact even with the unfused requantization. Without the launches every case fails
  except suite 2's hotspot, which passes the 1e-3 check with no kernel run at all: hence
  --fgpu-gold, which writes the model's words as <case>.fgpu.gold and a tol-0 cases file, so
  xsim checks the RTL bit for bit against the model (the model is checked against SIMTiX's
  gold separately).
- **Result tables:** compare_simtix.py (suite 1) also reads docs/zcu102_board_run_apps_fgpu.txt
  (fgpu_us, fgpu_errors, fgpu_max_error, fgpu_over_simtix_time / _base_time; FGPU has no cycle
  counter), like compare_rodinia.py and compare_rivec.py; existing columns unchanged (checked
  against the previous CSVs). TO DO with the board numbers: FGPU as a machine in
  plot_machines_suites.py (machines_suites.csv, the heatmap / bars) and the paper's tables.
- **Simulation plan after the 187.5 MHz build:** FGPU-gold (tol 0) case files ready:
  rd_small/fgpu_rest_fg.txt (kmeans_rd, gaussian, hotspot3d, shortest first) and
  rv_small/fgpu_rv_fg.txt (gemm_rb_64 with the write-idle wait, then lavamd); suite 1 and 2
  files after apps.cl / s2.cl compile.

### 187.5 MHz board build and hosts (2026-11-20 05:01 -> 05:44)
- create_bd_fgpu.tcl build mhz188 tagf188 (FREQMHZ 187 gave 166.65 MHz: Vivado picks the
  nearest frequency not above the request from the 1499.85 MHz IOPLL; 188 gives 187.48 MHz).
  Routed: WNS +1.020 ns, WHS +0.010 ns at 187.48 MHz (Fmax ~231 MHz); 43,995 LUT, 58,582 FF,
  49.5 RAMB36, 64 DSP (as at 150 MHz); FGPU 1.40 W, on-chip total 4.88 W (Vivado estimate).
  fgpu_ps_zcu102_f188.xsa, reports_ps_zcu102_f188/. FGPU runs at 187.48 MHz from now on.
  Launch gotcha: Start-Process cmd.exe '/c vivado.bat ... > out' failed twice in
  create_bd_design ("couldn't read file .../ipintegrator/addr.tcl", a file that exists);
  Start-Process vivado.bat with an argument array (as the 150 MHz build) works.
- Kernels compiled: apps.cl 1,169 words, s2.cl 992 words (code RAM 4,096). FGPU's toolchain
  left kernels named rs_* out of the object's symbol table (code present, no entry in the .h):
  renamed sort_hist / sort_scan / sort_scatter. fgpu_image.h now holds vec_add,
  vec_add_hard_float, rodinia, rivec (both identical to before), apps, s2.
- Hosts (vitis -s build_vitis_fgpu.py <suite> fgpu_ps_zcu102_f188.xsa): ws_zcu102_rodinia,
  ws_zcu102_rivec, ws_zcu102_apps, each ELF with the 187.48 MHz bitstream. Gotchas: vitis.bat
  splits arguments at commas; a build leaves its Vitis servers running (java ...RigelApp and
  python slxcmd.py, so Get-Process RigelApp does not find them) and they lock the next build's
  workspace: stop them by command line.
- xsim started 05:35-05:44, all against the model's words (tol 0): sim_apps_ap (suite 1, kmeans
  / mlp / conv8 first), sim_apps_s2 (suite 2, sort / cc first), sim_apps_rvfg (gemm_rb_64 with
  the write-idle wait, then lavamd), sim_apps_rdfg (kmeans_rd, gaussian, hotspot3d).
- **FINDING: FGPU's atomic add serves one address per kernel.** Suite 1's kmeans (cluster sums
  by atomic_add at 3 x K addresses) hung in xsim (no FGCASE after 35 min against ~8 min
  expected). gmem_atomics.vhd: the add unit latches the first atomic's address (idle ->
  listening), reads it once, then stays in `functioning` adding every request whose address
  matches until the kernel's `finish`; a request for another address only raises
  rcv_must_read (one at a time) and is never retired, so the kernel cannot finish. This is
  the case known_bugs.md calls never tested. FGPU's own atomic kernels use one address.
  Host: fg_entry_of_ap maps PC_KMEANS to FG_NONE (skip row; otherwise the 300 s timeout would
  fire and skip every later FGPU run); suite-1 xsim restarted without kmeans (sim_apps_ap;
  the hung run's log kept as sim_apps_ap_kmeans_hang.vlog). ws_zcu102_apps rebuilt.
  OPEN (user decision): an FGPU k-means without multi-address atomics, e.g. (a) assignment
  kernel + per-worker partial sums in the worker's own memory column (as sort_hist) + a
  reduction kernel over the workers, or (b) one launch per (array, cluster) address with
  a single-address atomic each; or (c) report k-means as "no FGPU port".
- **k-means on FGPU, option (a) (user's choice, 2026-11-20 07:00):** apps.cl gains kmeans_part
  and kmeans_reduce, appended so every other kernel keeps its entry word and code (the first
  1,169 words of apps.hex are identical to the image under simulation; 1,317 words now).
  kmeans_part: W = min(512, points) workers, worker w takes points w, w+W, ... (coalesced),
  assigns each as kmeans.S and adds x, y, 1 into its own partials part[(a*K + k)*W + w]
  (read-modify-write of the worker's own words, as SIMTiX's rs_hist.S); kmeans_reduce: 3K
  work-items sum the W partials into sx, sy, cn. Integer adds: the same words as kmeans.S.
  Host: app_kmeans under SIMTIX_FGPU launches both (timed together; FG_KM_W = 512); the
  kmeans_u variant still skips. gen_fgpu_cases.py rewrites the suite-1 kmeans case into the
  two launches (<case>.fgpu.mem = the case's memory + both parameter blocks + the partials);
  model: 1,048/1,048 words equal SIMTiX's gold; xsim sim_apps_km started 07:07 (FGPU gold).
  ws_zcu102_apps rebuilt 07:11.

## Rodinia on the board (2026-11-20 07:44 -> 07:59, FGPU at 187.48 MHz): PASS, 0 errors
xsdb run_board_fgpu.tcl rodinia -> docs/zcu102_board_run_rodinia_fgpu.txt (blob 100.8 MB over
JTAG ~12 min, run 160 s). compare_rodinia.py -> rodinia_results.csv (FGPU columns):

| benchmark | N | SIMTiX ms | Vortex ms | FGPU ms | A53 ms | FGPU/SIMTiX | max dev (FGREL) |
|---|---|---|---|---|---|---|---|
| pathfinder | 100000 | 250.5 | 960.9 | 650.0 | 97.2 | 2.60 | exact |
| backprop | 524288 | 299.2 | 1008.8 | 791.4 | 214.2 | 2.64 | 1.5e-7 |
| bfs | 65536 | 36.7 | 126.8 | 138.3 | 21.9 | 3.77 | exact |
| hotspot | 1024 | 134.2 | 411.2 | 241.4 | 85.5 | 1.80 | 9.4e-8 |
| nn | 42764 | 15.3 | 4.8 | 2.1 | 1.0 | 0.14 | exact |
| hotspot3d | 512 | 9449.6 | 21504.5 | 22239.8 | 16522.7 | 2.35 | 1.7e-6 |
| gaussian | 1024 | 4965.0 | 6064.0 | 9923.2 | 3916.4 | 2.00 | 2.0e-4 |
| kmeans | 494020 | 31810.0 | 64442.3 | 63549.7 | 28064.9 | 2.00 | exact, 37 iterations |

Geomean over the 8 benchmarks: FGPU/SIMTiX 1.67x time (SIMTiX v3 at 115.37 MHz, FGPU at
187.48 MHz: ~2.7x per clock); Vortex/SIMTiX 1.98x. The FGPU host's A53 times equal the other
runs' (kmeans 28.07 vs 28.06 s). gaussian's 2.0e-4 is elimination compounding the unfused
rounding over 1,024 steps, inside the 1e-3 limit. nn: FGPU faster than SIMTiX (as Vortex).
- xsim: gemm_rb_64 rerun with the write-idle wait 4,096/4,096 bit-exact: the earlier 64 zero
  words were the testbench reading before FGPU's last write-backs (confirmed).

## RiVEC on the board (2026-11-20 08:52 -> 08:58): 6/7 PASS; lavaMD FAILED -> root cause, fixed
Run 1 (docs/zcu102_board_run_rivec_fgpu_lavamd_spill.txt): axpy, matmul, spmv, jacobi,
pathfinder, blackscholes 0 errors; lavamd 96,000 wrong words (one per particle, worst 0.97 of
the row's largest value).
- **Root cause: FGPU's per-work-item stack is 16 words.** lmem.vhd addresses the local
  scratchpad by phase (3 bits), wavefront (3) and sp (LMEM_ADDR_W - 6 = 4 bits), each entry
  one word per lane: private per work-item, but 16 words deep; a deeper frame wraps. FGPU's
  compiler spills to it (lswi/llwi) without knowing the limit. lavamd_rv had a 72-byte
  (18-word) frame, 22 spills: two slots aliased. The small xsim/model case cannot show it
  (all lanes in one box hold the same values in the aliased slots). Other frames: swat 14,
  conv8 14 words (apps), blackscholes 6 (s2); all other kernels none.
- **Fix:** the spills come from LLVM's machine LICM hoisting rv_exp's float constants out of
  the inner loop. rivec.cl compiled with llc -disable-machine-licm (compile.sh in WSL now
  passes $LLC_EXTRA): lavamd_rv frame 24 bytes (6 words), 230 -> 185 instructions (inner loop
  83 -> 100: the constants rebuilt each iteration, no spill traffic); every other RiVEC
  kernel's code identical, image words 0..594 identical to the board-tested one (780 words
  now). ws_zcu102_rivec rebuilt 09:08; xsim of lavamd_2x1 on the new image started 09:05
  (sim_apps_lava; the run on the old image stopped). Needs a RiVEC board rerun.
- The DDR dump of the failing run did not happen: the debug AP reported an AXI AP
  transaction error after the run, then the board was switched off.
- **RiVEC rerun (2026-11-20 09:24 -> 09:30, fixed lavamd image): PASS, 0 errors.** lavamd
  0 errors, worst 4.4e-7 (was 0.97). docs/zcu102_board_run_rivec_fgpu.txt; rivec_results.csv:
  axpy 103.1 ms (3.27x SIMTiX), matmul 2840.4 (9.46x), spmv 1152.7 (14.55x), jacobi 18790.4
  (1.86x), pathfinder 14464.1 (2.60x), blackscholes 3420.8 (0.37x: FGPU faster), lavamd
  13980.1 (0.88x: FGPU faster). Geomean FGPU/SIMTiX 2.55x (Vortex 3.27x). The board had
  needed a full power cycle: after the first RiVEC run the debug AP reported "AXI AP
  transaction error" and no PSU target until SW1 off ~10 s and on.

## Suites 1/2 in xsim: slow, not stuck; FGPU byte stores are word stores (2026-11-20 ~10:00)
- The runs printed nothing until a case ended. Calibration from finished cases: ~78 cycles
  per wavefront memory instruction with 8 wavefronts overlapping (gemm_rb_64), several
  hundred for a lone wavefront (kmeans_reduce). Suite 2's first case, sort_4096x64, is one
  wavefront doing ~6,150 memory instructions: ~4-5M cycles, 9-14 h of xsim at 100-150
  cycles/s; suite 1's mlp ~1.2M cycles. tb_fgpu_apps.sv now prints FGLAUNCH (entry, n,
  cycles) after every launch. Tiny cases (scratchpad gen_tiny.py from the SIMTiX generators):
  ap_tiny (mlp_32x8x8_b1, conv8_4x8_4x8x8, swat_8x8x16), s2_tiny (sort_256x16); suite 2
  restarted without its sort (sim_apps_s2b), suite 1 without mlp/conv8 (sim_apps_ap2).
- **FINDING: sb writes the whole word.** Tiny mlp: word 72 = 4b40000f (one work-item's whole
  register), expected 03110f06 (four packed bytes). FGPU places sub-word stores only with
  SUB_INTEGER_IMPLEMENT /= 0 (CU_mem_cntrl.vhd, gmem_cntrl.vhd); it is 0 in our build and in
  every configuration FGPU ships. Rodinia and RiVEC store only words.
- **Fix (user: option 1, keep the bitstream):** apps.cl gains mlpw (four outputs per
  work-item, one word store; n = batch * npad / 4) and conv8w (work-item = pixel x group of 4
  output channels, one word; same parameter block and work-item count), appended (first
  1,317 words unchanged; 1,814 words; conv8w frame 6 words, mlpw none). Host: app_mlp
  launches mlpw under FGPU, the conv8 overlay maps to conv8w, PC_MLP -> FG_NONE. Models
  match SIMTiX's gold exactly (tiny and small mlp/conv8). ws_zcu102_apps rebuilt 10:13;
  xsim sim_apps_tw (tiny mlpw/conv8w) started 10:06.
- swat_8x8x16 (14-word stack frame) PASS bit-exact in xsim: frames up to 16 words work.

## Suites 1 + 2 on the board (2026-11-20 10:47 -> 10:51) and the sort (session end 11:15)
docs/zcu102_board_run_apps_fgpu.txt: suite 1 all 12 benchmarks 0 errors (two-kernel k-means,
mlpw, conv8w; the SIMTiX-only variants skip); suite 2 9/10 0 errors; **sort FAILED** (65,536
keys: 128,640 wrong words; 1M: 2,095,684).
- Not a write-back race between kernels: docs/zcu102_board_run_sorttest_fgpu.txt (sorttest
  host, FG_SORT_TEST: sort alone, 0 / 20 / 200 us after every launch) failed the same way.
- Diagnosis: inside sort_hist / sort_scatter a work-item re-reads, a few instructions later,
  a word it just stored (count++, off++), with 4+ wavefronts in flight; k-means' partial sums
  (re-reads tens of instructions apart) pass on the board; the tiny xsim sort (one wavefront,
  ~1 increment per word) passed. FGPU does not keep a short store->load of the same word in
  order under load (to note in the paper as an FGPU limitation).
- Fix (s2.cl, appended; first 992 words unchanged, 1,306 now): sort_hist2 (counts in
  registers, 16 counters packed 2 per word), sort_base (16 W work-items add the digit bases
  to off, one read-modify-write each), sort_scatter2 (reads off only; running counts in
  registers). Host: per pass hist2, scan, base (fg_launch), scatter2. Models: sort_256x16 and
  sort_4096x64 exact. Frames 4 words. Hosts ws_zcu102_sorttest and ws_zcu102_apps rebuilt
  11:08 / 11:14 with it. xsim sim_apps_ts3 (tiny 4-kernel sort) started 11:00.
- FGREL cosmetic: fg_diff_rel also prints for skipped runs (ppb 4294967295) and in the power
  phase; compare_simtix.py takes the max per key, so it must ignore FGREL lines of skipped
  runs / the power phase before the suite-1 FGPU table is final (TO DO).
- xsim at 11:14: suite 1 (sim_apps_ap2) scan, stencil PASS; suite 2 (sim_apps_s2b) cc,
  pathfinder, jacobi2d, hotspot, atax PASS; Rodinia hotspot3d and lavamd (fixed) running.

**Next session:** (1) board: xsdb run_board_fgpu.tcl sorttest (expect 0 errors), then
run_board_fgpu.tcl apps (full suites 1+2, one log); (2) compare_simtix.py FGREL filter, then
suite-2 FGPU columns + FGPU in plot_machines_suites.py / the paper tables (user's call on
presentation); (3) read the remaining xsim results; (4) nothing is committed yet.
- **Sort fix confirmed on the board (2026-11-20 12:05):** zcu102_board_run_sorttest_fgpu.txt
  (the failing run kept as _v1): sort 65,536 keys 0 errors with 0 / 20 / 200 us pauses,
  471.6 / 472.4 / 478.2 ms (A53 16.0 ms). Next: the full suites 1+2 run (apps).

## ALL FOUR SUITES PASS ON THE BOARD (2026-11-20 12:13), FGPU at 187.48 MHz
docs/zcu102_board_run_apps_fgpu.txt (suites 1+2, 12:09 -> 12:13; the sort-failing run kept as
zcu102_board_run_apps_fgpu_v1_sortfail.txt): RESULT PASS, 0 errors, 44 runs.
- Suite 1 (compare_simtix.py -> ara_cva6_simtix_comparison.csv, FGPU columns; FGREL lines now
  attributed only to the next non-skip FGB row of the same benchmark): SIMTiX best variant
  vs FGPU 3.42x time geomean (12 apps, large sizes), same base kernel 2.48x; FGPU faster on
  mandel 1024 (0.84) and swat (0.74); worst deviation gemm 4.3e-7.
- Suite 2 (vs zcu102_board_run_v3_s2.txt, largest sizes): FGPU/SIMTiX geomean 4.16x; FGPU
  faster on blackscholes (0.23); slowest relative: atax / bicg (19.7x: column walks of A,
  uncoalesced), pagerank 9.1x, cc 8.4x, sort 8.0x.
- Overall FGPU/SIMTiX time: Rodinia 1.67x, RiVEC 2.55x, suite 1 3.42x (2.48x same kernel),
  suite 2 4.16x. TO DO: a suite-2 FGPU CSV / FGPU in plot_machines_suites.py and the paper
  (presentation to agree with the user); commit (nothing committed yet).

## Paper and figures updated with FGPU (2026-11-20 afternoon)
- Heatmap (plot_machines_alt.py -> figs/machines_heatmap.pdf, also machines_dots.pdf): FGPU
  is a fourth machine column for the 8- and 16-lane SIMTiX; plot_machines_suites.collect()
  carries FGPU times ('fgpu', not in its own MACH, so machines_suites.csv and the bar
  figures are unchanged, checked byte for byte).
- Decomposition (model_decomp.py, plot_decomp.py -> figs/decomp.pdf): FGPU added (clock
  187.48, peak 8, cycles = time x clock): over the 15 Rodinia+RiVEC benchmarks time 2.03 =
  clock 0.62 x width 1.00 x efficiency 3.31; efficiency < 1 only on nn (0.22) and
  blackscholes (0.60); old machines' rows unchanged.
- simtix_tvlsi.tex: abstract and conclusion (2.0x over FGPU, efficiency factor 3.3 at a
  1.6x higher clock), intro (cache sentence, contribution: five machines), related work,
  Sec. V-A "Five Machines" (Table III with an FGPU column; FGPU paragraph; kernels,
  no-FMA checking, the four hardware limits in one sentence each), Tables IV/V FGPU
  columns (generated from the CSVs; Rodinia 1.67 time / 2.71 cycles, all twelve 2.20 /
  3.57, RiVEC 2.55 / 4.16), heatmap caption, results text (FGPU means, slowest where
  requests in flight matter, faster in time on lavaMD / Mandelbrot / Smith-Waterman but
  not per cycle), decomposition text, limitations (FGPU compiled by LLVM).
- simtix_tvlsi_supp.tex: new section "FGPU: Build, Kernels and Hardware Limits" (sup:fgpu)
  and FGPU's suite-2 result (4.16x) in the suite-2 section; fgpu bibitem added.
- Paper 14 pages (13 + the end of the bibliography on page 14), supplement 9 pages.

## Paper format pass, heatmaps, Table I, references (2026-11-20 to 2026-11-23)
- TVLSI/PULP format: IEEEtran journal (Times, CM math), all fonts embedded, no Type 3;
  abstract 245 words (limit 250); "speedup" in text and figure labels; KiB/MiB; roadmap
  paragraph ending the introduction; \label{sec:concl}; commented IEEE biography
  templates before \end{document} (degrees, years and interests to be filled by the
  authors). Serial comma not applied (IEEE copyediting adds it).
- Heatmaps switched to viridis (authors' choice): plot_machines_alt.py (Fig. 9: log norm
  centred on 1, white mark at 1 on the colour bar, text colour by luminance; caption now
  describes purple -> teal -> yellow), plot_lanes_throughput.py (default viridis, the
  colour-choice variants no longer generated), plot_ideality.py, plot_machines_throughput.py
  (patched but not regenerated: its op-count logs build_dram8/apps/*/sim_l8_w8_ops.log are
  gone).
- Table I "Resource Comparison" removed at the authors' request (no literature LUT/DSP/Fmax
  comparison in the paper); with it eGPU's "5,600 ALMs, above 770 MHz", Ventus's "329k
  LUTs" and the intro's "Vortex and Ventus ... are large". LUT and DSP are defined at first
  body use (Sec. III-C). Same-board results (machines table, decomposition, Vortex
  out-of-context section) unchanged.
- References completed from the publishers' records: CVA6 pp. 2629-2640 Nov. 2019; Ara2
  vol. 73 no. 7 pp. 1822-1836 Jul. 2024; FlexGrip pp. 230-237; MIAOW Art. 21; Nyami
  pp. 173-182; eGPU given its DOI 10.1109/FPL60245.2023.00047 (page range not found);
  Ara and RiVEC confirmed; all "TO CHECK" comments removed.
- Supplement: American spelling (centers, Synchronization; also in
  sim/compare_board_l16.py, which generates supp_lanes16_board.tex); the ISA table's
  overfull header fixed with Synchro\-nization. Paper 14 pp., supplement 9 pp., no overfull
  boxes, no undefined references.

## Axis labels and short captions (2026-11-23)
- Every data plot has a real x- and y-axis label; panel descriptions moved out of the
  x-label slot into an (a)/(b) tag (plot_style.panel_tag) and the caption. Scripts:
  plot_decomp.py, plot_lanes_suites.py (narrow panels saved with fixed margins so
  Fig. 7(b)/(c) line up), plot_lanes16_board.py (legend for hollow markers, two-line
  geo. means), plot_rodinia.py, plot_rivec.py, plot_vortex.py (a y-label per panel),
  figs/arch_v2_tikz/gen_lat_fig.py (x-axis label in (b), 64 KiB, in-figure note moved
  to the text).
- Captions shortened to the reference papers' style (Vortex 2-7 words, Ara one sentence,
  CVA6 tables ~7 words): figures 2-32 words (Fig. 1 keeps its abbreviation key), tables
  3-10 words. What the long captions said moved into the text (issue rules of Fig. 2(a),
  how Fig. 2(b) was measured, largest inputs of Fig. 5, ordering of Fig. 6(b), panels of
  Fig. 8) or the table notes (clocks of Table V). "Speed-Up" heading and table column
  fixed (also in sim/compare_board_l16.py). Backups: scratchpad caption_bak/, axes_bak/.

## No table notes (2026-11-23)
- Every note under a table removed (paper: Tables I-IX; supplement: SI-SVI) with its
  superscript markers; the essentials are now one or two short sentences in the text where
  each table is cited (board designs and power, Table II's abbreviations, what a ratio
  is, the output checks, the A53 clocks and energy ratio, the AMO kernels' sizes, the
  Vortex performance definitions, the 16-lane designs, the supplement's metrics and ISA
  abbreviations). The board inputs of the twelve applications moved to the supplement's
  text. sim/compare_board_l16.py no longer writes notes. Paper now 13 pages.

## Speedup bar graphs replaced by execution time, IPC and throughput (2026-11-23)
- Authors' request: no speedup bar graphs; plot execution time, IPC and throughput as the
  reference papers do (Ara: ops/cycle against the peak per lane count; Vortex: IPC per
  configuration).
- Fig. 2(b) (gen_lat_fig.py): IPC after each step (geo. mean bar, range whisker), 0.47 -> 0.78.
- Fig. 7 (new plot_lanes_metrics.py -> figs/lanes_metrics_paper.pdf): lane operations per
  cycle (peak L) and IPC at 4/8/16 lanes for the applications, Rodinia and RiVEC, from the
  APPCSV counters (cycles, warp instructions, active lanes); docs/lanes_metrics.csv.
  Supplement Fig. S4: same for suite 2 and the sync kernels (lanes_metrics_supp.pdf).
- Fig. 8 (plot_lanes16_board.py): (a) execution time at 8 and 16 lanes, A53 as marker;
  (b) board cycles against simulated cycles for the 35 cases with the same iterations
  (median error 1.9% at 8 lanes, 3.8% at 16).
- Supplement Figs. S1/S2 (new plot_machines_time.py -> rodinia_time.pdf, rivec_time.pdf):
  execution time of all six machines and cycles of five; Fig. S3 (plot_vortex.py ->
  vortex_metrics.pdf): IPC, execution time, energy of SIMTiX and Vortex 4/8/16 warps.
- Text and captions updated. Still ratio-based: Fig. 5 heatmap (speedup) and Fig. 6
  (decomposition of the time ratio) - left as they are pending the authors' decision.

## Lane figures: utilization and memory bandwidth instead of IPC (2026-11-23)
- Authors' request: replace the IPC panels of Fig. 7 and Fig. S4 with lane utilization and
  memory bandwidth (Fig. 2(b) keeps its IPC: same instructions in every step).
- tests/tb_apps.sv: under SIMTIX_AXICOUNT, counts the R and W data beats of the AXI4
  master per launch and prints AXICSV,case,launch,read_bytes,write_bytes (beats x 16 B,
  so masked bytes count: bus occupancy). sim/run_lanes_board.sh: AXICOUNT=1 adds the
  define and the _axi suffix (cycles unchanged: GEMM 8L 253,472 both ways).
  The L1 miss counter is no bandwidth measure (counts joins, ignores write-through stores).
- sim/run_lanes_axi.sh runs only the cases without an _axi log, one lane count at a time;
  run from a separate window (Claude Code's low-memory reaper stopped the background runs
  three times). All 162 runs (54 cases x 4/8/16 lanes) PASS.
- plot_lanes_metrics.py: three rows, (a) lane ops/cycle vs peak L, (b) lane utilization
  vs 1, (c) bytes read (solid) + written (hatched) per cycle vs 16 B/cycle per direction;
  docs/lanes_metrics.csv now has the four metrics per lane count.
- Results (geo. mean util 4/8/16L): apps 0.89/0.86/0.83, Rodinia 0.93/0.90/0.88, RiVEC
  0.98/0.97/0.96, suite 2 0.96/0.94/0.93, sync 1.00. Dense kernels 0.99-1.00 at every L;
  gathers fall (BFS 0.55->0.35, hash join 0.71->0.47, Rodinia BFS 0.58->0.37). Mean
  traffic at 16L: apps 3.5, Rodinia 6.7, RiVEC 5.9 B/cycle; highest read 10.1 (RiVEC spmv),
  highest write 7.7 (radix sort). axpy reads 0.80 B per lane op at every L (port bound 20).
- Paper Sec. VI-G text and Fig. 7 caption, supplement S4 caption and text rewritten;
  paper back to 13 pages after trimming (figure 3.6 in tall), supplement 9.
- Authors' request: utilization bars looked bad (a wall of bars at 1.0). Panel (b) is now a
  dot plot: one marker per lane count, joined by a thin line, y axis zoomed to the data
  (0.25-1.0 paper, 0.5-1.0 supplement). Paper still 13 pages, supplement 9.

## Fig. 6: panel (a) removed, efficiency factor on every benchmark of Fig. 7 (2026-11-23)
- Authors' request. model_decomp.py now also writes the 17 applications (base and
  optimized kernels at the larger board input; SIMTiX cycles from lanes16_board_results.csv
  cycles_8L, the other machines from ara_cva6_simtix_comparison.csv; no Ara rows for MLP,
  Smith-W. (wrong results) and Mandelbrot (deadlock)); new 'key' column. The 15 Rodinia/
  RiVEC rows and the geometric means of the text are unchanged.
- plot_decomp.py: one panel, Fig. 7's order and groups, log efficiency factor per machine.
  Application geo. means: CVA6 1.43, Ara 1.38 (14), Vortex 3.63, FGPU 5.34.
- Text of Sec. VI-C rewritten (geometric means without the figure; per-benchmark groups
  with the applications; scans: 3 shuffle steps + second pass). Supplement now cites
  Section VI-C for the split. Paper 14 pages (last page: half a column of references).
- Authors' request: read and written were hard to tell apart (stacked, hatched). Panel (c)
  of Fig. 7 and S4 is now mirrored: bytes read per cycle up from zero, bytes written down,
  same lane colors, port peak at +16 and -16, "read" and "written" labelled at the right;
  captions say "(c) Bytes read (up) and written (down) per cycle."
- Authors' request: no peak lines in any plot. Removed from Fig. 7 and S4 (the only
  figures that had them: lane peaks 4/8/16, utilization 1.0, port +/-16); axes now span the
  data, the bandwidth panel from -1.25x the largest write to 1.25x the largest read. Fig. 6
  keeps its line at 1 (the boundary between "SIMTiX more efficient" and "machine more
  efficient", not a peak).

## Fig. 5: speedup heatmap replaced by measured execution time (2026-11-23)
- Authors' request: heatmaps of real measured metrics, not speedup. plot_machines_alt.py
  heatmap_time() -> figs/machines_heatmap.pdf: execution time (ms) on the ZCU102 of the 8-
  and 16-lane SIMTiX, CVA6, Ara, Vortex, FGPU and the A53 (-O2 reference, a53_O2_us of the
  three result CSVs), largest input per benchmark (hotspot 1024), 12 applications |
  Rodinia + RiVEC, log viridis 1 ms .. 10^6 ms, value in each cell, n/a for Ara's MLP,
  Smith-W., Mandelbrot. No geometric-mean rows (Ara's apps set differs). The old speedup
  heatmap is kept as heatmap_speedup() -> figs/machines_heatmap_speedup.pdf (not used).
- Caption "Execution time of each machine on the ZCU102."; text says Fig. 5 gives the
  measured times and that ratios in the text are against the eight-lane SIMTiX. Fixed the
  kernel list: SIMTiX runs GEMM-RB, Stencil-RB, k-means-U, segmented scan and SpMV-Z
  (the text named only GEMM-RB and SpMV-Z).
- Then (authors' request) Fig. 5 became the FP32 THROUGHPUT heatmap (plot_machines_alt.py
  heatmap_throughput -> figs/machines_heatmap.pdf, docs/machines_throughput.csv): MFLOP/s =
  FP32 operations (FMA = 2; the same on every machine) / board time, for the 17 FP32
  benchmarks (GEMM, SpMV, Stencil, Emb. bag, Mandelbrot; Backprop, Hotspot, NN, Hotspot3D,
  Gaussian, k-means; Matmul, AXPY, SpMV, Jacobi-2D, Black-Scholes, LavaMD) at their largest
  input; rows SIMTiX 8L/16L, CVA6, Ara, Vortex, FGPU, A53; log viridis 2..2,000 MFLOP/s.
  Range 2.9 (CVA6 SpMV) .. 1,564 (SIMTiX 16L Matmul).
- Op counts regenerated (the old _ops logs were gone): sim/run_opcount.sh (OPCOUNT=1, 8 lanes,
  run from a separate window), 17/17 PASS (build_dram8/apps/embag regenerated: it had no gold
  and an empty manifest). Mandelbrot 1024^2: 8 FLOP per iteration + 4 per pixel over the
  gold iteration counts (sim/gen_apps.py --size dram --only mandel -> build_dram8/apps/mandel),
  checked exactly on the simulated 256^2 case (36,066,504). LavaMD: 45 FLOP per particle pair
  after removing lavamd_rv.S's one FADD per thread that makes 2.0 (setup, not benchmark work).
  All other scaling formulas reproduce the simulated counts exactly.
- The execution-time heatmap moved to the supplement (Fig. S3, machines_heatmap_time.pdf), so
  the integer benchmarks' times on every machine stay in the paper set. Paper 14 pages,
  supplement 10.

## Ara's Mandelbrot result restored (2026-11-26)
- Ara's Mandelbrot has run correctly since the 2026-11-09 board run (zcu102_board_run_ara_s2.txt,
  after the vid.v fix of kernels/ak_vector.c): 1024^2: 359,490,012 cycles, 4,553.5 ms, 0 errors.
  The comparison CSV came from the 2026-11-08 run (Mandelbrot skipped), so the paper and
  Figs. 5/6/S3 said "deadlocks" while Table III already listed 4,553.5 ms.
- baselines/ara/compare_simtix.py now fills only the rows the 11-08 run skipped from the 11-09
  log (its other rows repeat the 11-08 run within 0.2%), so no other number moves. Regenerated:
  ara_cva6_simtix_comparison.csv (only the two mandel rows changed), machines_suites.csv,
  machines_throughput.csv, model_decomp.csv, Figs. 5 (Ara 127 MFLOP/s), 6 (Ara factor 1.53),
  S3. Text: Ara's application time ratio 6.0x -> 5.8x (10 apps); Fig. 5's Ara mean 56 (16
  benchmarks) -> 59 (17); "Mandelbrot deadlocks Ara" removed from the paper (Sec. VI-B, VI-C)
  and supplement S1; docstrings of plot_machines_alt/plot_decomp/model_decomp/
  plot_machines_suites. Paper 15 pages, supplement 10, no warnings.

## Fig. 10 (16 vs 8 lanes on the board) removed (2026-11-26, authors' request)
- lanes16_board.pdf ((a) execution time 8L/16L/A53, (b) board vs simulated cycles) is no longer
  in the paper; Sec. VI-H now cites Table IX alone ("the supplementary material lists every
  run") and keeps the numbers (1.45x, 75/82, the 1.9%/3.8% median errors, 1.0% ratio error) in
  the text; the supplement's S-section on the 82 runs cites Table IX only. The figure script
  (plot_lanes16_board.py) is kept. Paper: 9 figures, 15 pages, page 15 holds only reference [22].
