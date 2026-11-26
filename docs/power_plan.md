# Measured power and energy of every machine on every benchmark (plan, 2026-11-24)

Authors' request: a performance-per-watt plot per benchmark kernel, all machines (SIMTiX 8
and 16 lanes, CVA6, Ara, Vortex, FGPU, A53), all suites (the applications, Rodinia, RiVEC),
on the ZCU102; both metrics: FP32 MFLOP/s per watt (a heatmap paired with Fig. 5) and
energy per run for every benchmark (supplement).

## What existed

- `power.c`: the ZCU102's 18 INA226 monitors (10 PS rails, 8 PL rails) over PS I2C0;
  `pw_report` prints `POWER,<app>,<size>,<phase>,<rail>,<mV>,<mW>,<samples>,<reps>,<ms>`.
- `apps.c`'s power pass (applications, DRAM-sized inputs): per application an idle phase
  (A53 polls the status register), the accelerator run repeated for 2 s, the A53 reference
  repeated for 2 s, the rails sampled throughout. Logs with POWER rows: SIMTiX 8L
  (`zcu102_board_run_v3_s2.txt`), 16L (`_l16_main`), Vortex (`_vortex`), FGPU (`_apps_fgpu`).
- No power for CVA6/Ara (their host had no `power.c`), none for Rodinia or RiVEC.
- The BFS accelerator phase repeated the run without resetting the levels. Measured
  afterwards: this did NOT distort it (the level flags were never cleared, so every
  repetition still walked every level over all vertices): old 3.875 W, new 3.858 W, 13
  repetitions both. The reset is kept; every machine is measured again with one method.

## Changes (host programs only; no bitstream changes)

- `suite2.inc`: `S2_ACC_BEGIN/END` loop in the power pass (idle phase first, the
  accelerator part repeated for 2 s); `A53_BEGIN/END`, `A53_LOOP` repeat the A53 reference.
  Used by the five Rodinia and seven RiVEC functions and suite 2's pathfinder and backprop.
- `rodinia.inc`, `rivec.inc`: a power pass after the timing pass (Rodinia at hotspot 1024
  only), inputs re-seeded as in the timing pass; BFS resets its levels on every repetition
  (`ph_rep()`); k-means repeats its whole loop from the first centres.
- `apps.c`: `ph_rep()`; the application BFS resets its levels on every repetition;
  `PW_ONLY` skips the timing pass (and suite 2).
- `apps_ara.c` (CVA6/Ara): `power.c` imported; `ara_run` repeats the run for 2 s in the power
  pass (an idle phase first, CVA6/Ara in reset); POWER rows named `<app>@cva6`, `<app>@ara`;
  a power pass for the applications. Every Ara/CVA6 kernel writes its outputs from scratch
  (the host pre-fills them with garbage), so a repetition does the work of the first.
  `main.c` and the build now redirect xil_printf to the DDR console, so the POWER rows
  printed by `power.c` reach the log.
- Build option `power` (`-DPW_ONLY`) in `build_vitis.py`, `build_vitis_vortex.py`,
  `build_vitis_fgpu.py`, `build_vitis_ara.py`. All configurations compile without warnings
  (`-Wall -Wextra`, syntax check with the A53 GCC against each platform's BSP).

## Runs (sw/ps_host/run_power_all.ps1, from the user's PowerShell)

15 runs, each a Vitis build and an xsdb board run, logs in `docs/power_runs/`:
SIMTiX 8L (`fpga/simtix_ps_zcu102_v3b34.xsa`, the paper's 115.37 MHz design), SIMTiX 16L,
Vortex, FGPU (`fgpu_ps_zcu102_f188.xsa`), CVA6+Ara, each with the applications, Rodinia and
RiVEC. Estimated 3 to 4 hours, most of it CVA6 (Rodinia k-means alone 12 min per run).

## Metrics (decided when the data are in; every rail is kept)

- Power of a machine on a benchmark: the sum of the 18 rails while it runs (board power,
  as Table V of the paper); the A53's from the SIMTiX 8L run (its bitstream loaded, idle).
  Alternatives from the same rows: the increase over idle; PL rails only.
- Energy per run = power x the run's time from the timing pass (the paper's tables).
- FP32 MFLOP/s per watt = Fig. 5's throughput / power.

## Status 2026-11-24

- Fast runs DONE (10:39-12:42), all 12 `RESULT: PASS (0 errors)` with complete POWER sets
  (18 rails x 3 phases; SIMTiX apps 918 rows = 17 runs incl. its 5 variants, Vortex/FGPU
  apps 648, Rodinia 432, RiVEC 378): `power_runs/zcu102_power_{simtix8,simtix16,vortex,
  fgpu}_{apps,rodinia,rivec}.txt`. The new apps numbers repeat the old logs within 0.06 W.
- run_power_all.ps1 fixes found on the way: xsdb is in Vivado\bin (not Vitis\bin);
  vitis.bat returns only when its leftover server exits (~10 min) or exits early while the
  build goes on, so the build is started detached and the log watched for `ELF:`; cmd /c
  quoting needs an extra pair of quotes; `$r` in a loop clobbered `$R` (PowerShell names
  ignore case).
- plot_power.py run on them (CVA6/Ara n/a): power_results.csv, figs/machines_perf_per_watt.pdf,
  figs/machines_energy.pdf. Board power while running: SIMTiX 8L 3.31-4.44 W, 16L 3.69-5.89,
  Vortex 3.36-3.87, FGPU 3.47-3.89, A53 3.16-3.36 (idle 3.13-3.40 W by bitstream).
  FP32 MFLOP/s per W, geo. mean over 17 (max): 16L 63.1 (321 Matmul), 8L 47.9 (224),
  FGPU 23.1 (173 Mandelbrot), Vortex 19.5 (46), A53 63.9 (213). Lowest energy per run of 27:
  A53 16, SIMTiX 16L 10, 8L 1; SIMTiX below Vortex/FGPU except FGPU's Smith-W./Mandelbrot
  and Vortex's NN. A53 adds ~0.05 W over idle, so whole-board energy favours it: framing
  needed in the paper (hard 1.2 GHz core vs FPGA logic).
- NEXT SESSION: the slow runs, ONLY with the user's permission (asked for explicitly):
  `powershell -ExecutionPolicy Bypass -File sw\ps_host\run_power_all.ps1 -Only
  ara_apps,ara_rodinia,ara_rivec` (CVA6+Ara, ~1 h; launch in a separate window), then
  plot_power.py, then the paper/supplement figures and text.
- Figures redrawn (authors' request: proper axes and metric names), plot_power.py:
  machines_power.pdf (a) board power while running (W, dots), (b) power above idle (W, bars),
  27 benchmarks by suite; machines_perf_per_watt.pdf ("Machine" x "Benchmark", colour bar
  "FP32 energy efficiency (MFLOP/s per W)"); machines_energy.pdf ("Benchmark" x "Machine",
  "Energy per run (mJ)"). Only measured machines are drawn. Machine colours fixed: SIMTiX 8L
  #008300, 16L #eda100, CVA6 #2a78d6, Ara #eb6834, Vortex #1baf7a, FGPU #8e44ad, A53 #e87ba4;
  adjacent CVD dE >= 9.1 (target 8) and normal dE >= 22.3 with and without CVA6/Ara (Python
  port of the dataviz validator; Node is not installed).
- Added to the paper and supplement (authors' request, 2026-11-24):
  paper Sec. VI-E "Power and Energy" (\label{sec:evalpower}, after the A53 section) with
  Fig. 7 machines_power.pdf (fig:power) and Fig. 8 machines_perf_per_watt.pdf (fig:ppw):
  method (as Sec. VI-D, A53 -O2 reference with the 8L bitstream loaded), idle 3.1-3.4 W,
  above idle 8L 0.15-1.28 / 16L 0.30-2.49 / Vortex 0.12-0.62 / FGPU 0.10-0.52 / A53 <= 0.23 W;
  energy Vortex 2.8x, FGPU 2.3x the 8L SIMTiX (gm of 27; exceptions nn, blackscholes; FGPU
  also Smith-W., Mandelbrot, lavaMD); FP32 MFLOP/s/W gm 47.9 / 63.1 vs 19.5 / 23.1, max 321;
  16L 0.77 of 8L energy (lower on 24/27; more on both SpMV and hash join); A53 63.9 MFLOP/s/W,
  lowest energy on 16/27, 16L below the A53 on 11. Sec. VI-H's Vivado-based "14% more /
  18% less" sentence replaced by the measured numbers; Limitations: "measured at the board ...
  not yet for CVA6 and Ara". Supplement Sec. S2 "Energy per Run" with Fig. S4
  machines_energy.pdf. Paper 15 pages (was 14), supplement 10. AFTER THE CVA6/ARA RUNS:
  regenerate (plot_power.py) and update the text's machine list, ranges and counts.
- Terms (authors' choice): "system power" (sum of the 18 rails while a machine runs) and
  "dynamic power" (system power less the idle power with the same bitstream loaded; includes
  the PS/DDR4 activity the machine causes). Fig. 7 y-labels "System power (W)", "Dynamic
  power (W)"; caption "Measured power on the ZCU102. (a) System power. (b) Dynamic power.";
  both defined in Sec. VI-E and used in VI-E, VI-H, Limitations and supplement S2.

## 2026-11-26: power study narrowed to SIMTiX 8 and 16 lanes (authors' decision)

- The authors chose to compare power only across SIMTiX lane counts; 4 lanes would need a
  new board design (no 4-lane bitstream exists: phases 1-7 as docs/lanes16_plan.md,
  create_bd_ps.tcl ... tagl4 lanes4 warps8 l1kb32 ...), deferred: "for now 8 and 16 lanes".
  The CVA6/Ara power runs are no longer needed.
- plot_power.py now draws figs/simtix_lanes_power.pdf ((a) system power dots, (b) dynamic
  power bars, (c) FP32 MFLOP/s per W dots on a log axis, 27 benchmarks; lane-study blues
  #2a78d6 / #104281) and figs/simtix_lanes_energy.pdf (energy per run, log dots); the
  every-machine figures only with --all.
- Paper: the every-machine Sec. VI-E removed; new "Power and Energy" subsection after
  "Sixteen Lanes on the Board" (sec:evalpower, Fig. 8 = fig:power, placed before the 16-lane
  board figure, cited in VI-H where Vivado's estimate is mentioned). Numbers: idle 3.13-3.18
  -> 3.39-3.42 W; dynamic 0.15-1.28 vs 0.30-2.49 W (1.77x gm); system power 1.21x; time
  1.58x shorter (gm, these 27 inputs); energy 0.77x (0.64-1.15), lower on 24/27 (more on
  both SpMV and hash join); MFLOP/s/W 47.9 -> 63.1 (max 224 -> 321, matmul); dynamic energy
  1.12x: the 16-lane design saves energy by drawing the idle power for a shorter time.
  Limitations: power measured on the board only for SIMTiX and the A53. Supplement S2:
  energy per run of 8L vs 16L (Fig. S4). Paper 14 pages, supplement 10.
- Colours: FINAL (authors' option 2 of 7 drawn on the real data, after rejecting blue/blue, orange/blue, orange/violet, orange/pink): 8 lanes navy #1f4e79, 16 lanes gold #e6a817, in all three panels of Fig. 8 and in Fig. S4; CVD dE 37.6, normal dE 43.1; the gold is 2.1:1 on white, so all bars, dots and legend patches have a thin darker edge of their own hue.
- FP32 efficiency split into its own figure and compared with Vortex and FGPU (authors'
  request): figs/fp32_efficiency.pdf (fig:ppw), dots on a log axis, 17 FP32 benchmarks in
  Fig. 5's order; SIMTiX navy/gold circles, Vortex #1baf7a triangles, FGPU #8e44ad diamonds
  (Fig. 6's colours and markers; all 6 pairs CVD dE >= 9.1, normal >= 19.2). The power figure
  keeps (a) system and (b) dynamic power. Text: gm 47.9 / 63.1 / 19.5 (Vortex) / 23.1 (FGPU)
  MFLOP/s per W; 16L 3.2x Vortex, 2.7x FGPU, 8L 2.5x, 2.1x; 16L best on 13/17, 8L on both
  SpMV, FGPU on nn and blackscholes (divide/sqrt per lane). Both figures placed at the start
  of VI-H and cited there (numbering = first-citation order: Fig. 8 power, 9 efficiency,
  10 sixteen-lane board). Limitations: power measured for SIMTiX, Vortex, FGPU and the A53,
  not CVA6/Ara. Paper 15 pages, supplement 10.
- 2026-11-26 writing pass (authors: "explain each plot properly and shortly"): every data
  figure now has a short reading guide and its result in the text: Fig. 3(a)/(b) described
  (four line requests; CVA6 ~4 Lambda, Ara ~2 Lambda, SIMTiX ~Lambda); Fig. 5 rows/columns/
  log colour + results (16L best on 12/17, up to 1,564 MFLOP/s; gm 306 / 190 / A53 207 /
  FGPU 83 / Vortex 70 / Ara 56 / CVA6 9.5; A53 leads on both SpMV, nn, jacobi-2d, FGPU on
  blackscholes); Fig. 6 log axis, above 1 favours SIMTiX; Fig. 7 panel references (a)/(b)/(c);
  Fig. 8 system-power ranges with (a), dynamic with (b); Fig. 9 "log axis, higher is better";
  Fig. 10(a) what is plotted. Figs. 1, 2, 4 were already explained. Paper 15 pp, supp 10.
