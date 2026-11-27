# TVLSI paper rewrite: mechanisms, models, diagrams (started 2026-11-12)

Goal (user, 2026-11-12): show the mechanisms of SIMTiX that give its performance over CVA6,
Ara and Vortex, with the mathematical and logical reasons; clean architectural diagrams
with no overlapping; TVLSI-style metrics and graphs.

Decisions (user, 2026-11-12):
- the four-machine ZCU102 comparison is the centre of the evaluation; abstract, introduction
  and contributions are rewritten for v3 (8 warps, 64 KB L1, 115.37 MHz, ZCU102); the older
  out-of-context Vortex study becomes a shorter subsection;
- stay near 14 pages: the strongest figures go into the paper, the rest into a supplementary
  document;
- existing measurements only (no new simulations); a graph that needs new data is dropped.

## 1. The analytical backbone (done: docs/model_decomp.py, docs/plot_decomp.py)

For a benchmark on SIMTiX (S) and machine X, with time T, cycles C, clock f, and peak 32-bit
lane operations per cycle P:

    T_X/T_S = (f_S/f_X) * (P_S/P_X) * (eta_S/eta_X)

eta = useful operations / (P C), the fraction of the peak sustained; the operation count
cancels, so the efficiency factor eta_S/eta_X = (C_X/C_S)(P_X/P_S) is measured.
Peaks: SIMTiX 8, Vortex 8, Ara 4 (2 lanes x 64-bit, FP32 packed two per lane; Ara's
`vmfpu.sv` has EnableVectors = 1), CVA6 1.

Geometric means over 15 benchmarks (8 Rodinia with hotspot at 1024, 7 RiVEC):

| X | time | clock | peak | efficiency |
|---|---|---|---|---|
| CVA6 | 16.95 | 1.46 | 8.00 | 1.45 |
| Ara | 3.10 | 1.46 | 2.00 | 1.06 |
| Vortex | 2.51 | 0.92 | 1.00 | 2.71 |

Reading: against Ara the per-cycle lead is the width (Ara is more efficient on unit-stride
streaming, 0.44-0.75; SIMTiX far more on irregular access: bfs 7.4, matmul 17, backprop 3.5,
lavaMD 3.4, spmv 2.4); against Vortex it is all efficiency (instructions x IPC); efficiency
below 1 marks SIMTiX's known limits (shared divider: nn, blackscholes; divergence: bfs vs CVA6).

## 2. Mechanisms and the facts behind each model (verified in RTL)

| Mechanism | Model | Facts (source) |
|---|---|---|
| 2-stage issue, register scoreboard, sleeping warps | latency hiding: IPC = min(1, W r/(r+lambda)) | FPU 6 cycles issue->result, MUL 7, DOT 6, SHF 1 (`warp_pool.sv` FPC_LAT etc.); Vortex FMA 16, div/sqrt 28 (IP cores, paper) |
| hardware reconvergence stack | instruction count; depth <= L (proof in paper) | Vortex warp instructions 1.72x (Table V) |
| per-warp memory contexts, coalescer, non-blocking L1 | requests = distinct lines; bandwidth = misses in flight x line / latency | SIMTiX 16 contexts, 16 tags, 16 MSHRs, 32-byte line, 128-bit HP port; CVA6: WT 8 KB 4-way D-cache with ONE read MSHR, 2-entry load buffer (`cv64a6_imafdcv_sv39_config_pkg.sv`, `wt_dcache_missunit.sv`); Ara: AXI 32 x NrLanes = 64 bits, strided and indexed accesses are one single-beat AXI request per element (`addrgen.sv`, len 0) |
| line-aggregated AMOs | 2g vs 2k requests; rounds = max lanes on one word | already in the paper |
| LUTRAM register files with implicit initial values | 128:1 mux per lane and port removed: 170,868 -> 30,088 LUTs | paper |
| timing-closure cuts | 2,455 failing endpoints at 111 MHz -> closed 115.37 MHz, 0.3-3.8% cycles | paper |

Board resources (whole designs, ZCU102): SIMTiX 107,658 LUT / 50,091 FF / 16 BRAM / 72 DSP
(115.37 MHz); Vortex 85,179 / 85,577 / 62 / 48 (125 MHz); Ara + CVA6 182,331 / 63,650 /
92.5 / 130 (78.95 MHz) (`baselines/*/reports_ps_zcu102/post_route_util.rpt`; the split
between Ara and CVA6 needs a Vivado run, not done: existing data only).

## 3. Figures

Paper (target ~7 figures):
- [x] decomp: factors of the time ratio + efficiency per benchmark (`figs/decomp.pdf`)
- [ ] system + accelerator (existing `simtix_arch_v3.pdf`, check for crowding)
- [x] latency tolerance: (a) four warps under the issue rules of warp_pool.sv (lat_sched.py:
      round robin, a warp every other cycle, sleep on a pending source, non-blocking load;
      FPU 6), empty slots at cycles 6, 9, 16; (b) measured step chain from docs/v3_steps.csv:
      v2 1.00 (IPC 0.47), pipelined units 1.11, scoreboard + sleep 1.19, non-blocking loads
      1.29, eight warps 1.49, 16 MSHRs/16 tags/64 KB L1 1.68 (IPC 0.78); same instruction
      count throughout (`figs/arch_v2_tikz/gen_lat_fig.py` -> `figs/simtix_lat.pdf`)
- [x] memory-level parallelism: (a) one warp's gather through the coalescer, (b) the same
      eight loads on CVA6 (1 miss in flight), Ara (one request per element, <= 4 in flight)
      and SIMTiX (one per line, <= 16) (`figs/arch_v2_tikz/gen_mem_fig.py` -> `figs/simtix_mem.pdf`)
- [ ] line-aggregated AMOs (existing `simtix_amo.pdf`)
- [ ] Rodinia / RiVEC ratios (existing; possibly merged into one figure)

Supplementary:
- [ ] reconvergence stack example beside Vortex's split/join code
- [ ] FPU pipeline (DSP cascade, FP16 round to odd)
- [ ] AXI ordering hazard and the two rules
- [ ] timing-closure cuts
- [ ] the same loop in the four execution models

## 4. Text

- [x] abstract, introduction (new paragraph: scalar/vector alternatives never compared on one
      board), four contributions (latency tolerance, memory-level parallelism, line-aggregated
      AMOs, same-board comparison + decomposition), limitations (A53 faster on 12 of 15), conclusion
      (2026-11-13)
- [x] machine table: Table VIII `tab:machines` in new subsection "Four Machines on One Board"
      (`sec:machines`, before Rodinia); Rodinia's machine paragraph moved there
- [x] Execute stage: IPC bound (eq:ipc, d_w >= 2, FMA chain >= 7) + Fig. lat; L1 subsection:
      g requests per instruction, Little's law M/Lambda (16, 4, 1) + Fig. mem
- [x] new subsection "Where the Speed-Up Comes From" (`sec:decomp`, after RiVEC): eq:decomp +
      Fig. decomp + reading (Ara streaming group vs gather group; nn/blackscholes/bfs limits)
- [x] page budget: 14 pages (2026-11-13): ratio figures, lane figure and the v2 "Memory System
      and Reduction" moved to the supplementary; lane text condensed to one paragraph; empty
      4/16-lane rows of Table IV removed
- [x] evaluation order: machines, Rodinia, RiVEC, decomposition, applications vs A53,
      simulation and out-of-context builds, AMOs, out-of-context Vortex, lane scaling
- [x] supplementary: paper/simtix_tvlsi_supp.tex (3 pp; xr references to the paper; inputs
      prepared by paper/prep_supp.py from supp_figs.tex, supp_lanes.tex, supp_evalmem.tex)

## 5. Mathematics (2026-11-13, user: "mathematical or logical proof supporting my work")

Each result checked against the RTL before it was written:
- Theorem 1 (Fetch stage, thm:stack): stack depth <= |A0| <= L, tight. Push rule
  warp_pool.sv:1660-1673 (push only when 0 != taken != mask; pushed mask = mask & ~taken or taken).
- Proposition 1 (Execute, prop:ipc): IPC <= min(1, sum 1/d_w); d_w >= 2 (inflight set at
  fetch, cleared at issue, warp_pool.sv:1504/1514); FMA chain d_w >= 7 (FPC_LAT = 6).
- Proposition 2 (Execute, prop:fp16): FP16 via FP32 correctly rounded (RNE): Figueroa p >= 2q+2
  for + - x / sqrt; FMA via round to odd (Boldo-Melquiond, p >= q+2); FTZ both formats
  (simt_fpu.sv:47), RTO for FP16 FMA (simt_fpu.sv:676). Directed modes: test vectors only.
- Theorem 2 (L1, thm:order): R1 write-hit update + write-through, R2 write waits for an
  in-flight miss, R3 read miss waits for an in-flight write, R4 one AXI write ID ->
  WAW in order, RAW sees the write; invariant: cached line == memory with all accepted
  writes (l1_dcache.sv header). Corollary in text: AMO atomic w.r.t. the accelerator.
- Proposition 3 (L1, prop:mlp): g requests = distinct lines; E[g] = R(1-(1-1/R)^k)
  (R=2: 1.99; R=65,536: 7.9996); Little's law M/Lambda.
- Theorem 3 + Corollary 1 (AMO, thm:amo, cor:amo): serial equivalence; 2g vs 2k requests;
  apply cycles |G| (ser) vs m_G (par).
Page budget: 15 pp; Table I (ISA comparison) moved to the supplementary as Table SI.

## 16-lane board results (2026-11-17) — TO ADD TO THE PAPER (user: "very important")

Measured on the ZCU102 (docs/lanes16_board_results.md, docs/lanes16_board_table.md): 16 lanes x
8 warps (store-merge rewrite, two divide/sqrt units, 128 KB L1) at 100 MHz, all suites PASS:
1.45x faster than the 8-lane board design (115.37 MHz) over 82 kernel x input rows, 75/82
faster; vs the A53 0.56x -> 0.82x, faster than the A53 on 20 -> 34 rows; measured cycle
ratios match the board-size simulations (Tables X-XI predicted the 16-lane gains).
Ready-made, compile-tested tables: docs/paper/tab_lanes16_board.tex (paper, per suite) and
docs/paper/supp_lanes16_board.tex (supplement, every row); regenerate with
`python sim/compare_board_l16.py`. Natural home: sec:evallanes (after Tables X-XI: "the
16-lane design on the board"). Text to write: the store-merge rewrite (37k -> 11k LUTs, formal
+ random equivalence), SFU_CORES, 128 KB L1 at no BRAM cost, the 7 slower rows (64-B lines on
scattered traffic) as the stated limitation.

**DONE 2026-11-19: in the paper.** New Sec. VI-J "Sixteen Lanes on the Board" (sec:lanes16):
the three changes (store merge 37,450 -> 11,047 LUTs, engine -46 %, ABC proof at 4 lanes +
random equivalence; one divide/sqrt unit per 8 lanes, 738 LUTs each; 128 KB L1 at no BRAM
cost), 4 vs 8 warps (1.25x vs 1.60x), Table XII tab:lanes16_impl (8L vs 16L board designs),
Table XIII tab:lanes16_board (\input tab_lanes16_board.tex), Fig. 6 fig:lanes16_board
(docs/plot_lanes16_board.py -> figs/lanes16_board.pdf: per-benchmark speed-up; sim vs board cycle
ratio, median error 1.0 %, 34/42 within 5 %), gate-level check, the 7 slower rows (64-B lines),
energy (accelerator +14 %, system -18 % per run). Also: abstract sentence, contribution 5,
Sec. VI-I cost paragraph rewritten (old "190,401 LUTs ... better way" removed), Limitations
(A53 faster on 7 of 16 Rodinia/RiVEC runs at 16 lanes; 64-B line limit), Conclusion.
Supplement: new section sup:lanes16 with \input supp_lanes16_board.tex (82 rows).
Paper 18 pp (was 16), supplement 6 pp; both build clean (no undefined refs, no overfull).

**2026-11-19: 4/8/16-lane figures per suite in the paper** (user: "put these graphs in the
paper"): Sec. VI-I, Fig. 6 fig:lanes_suites1 ((a) applications, (b) suite 2) and Fig. 7
fig:lanes_suites2 ((a) Rodinia, (b) RiVEC, (c) sync kernels), from docs/plot_lanes_suites.py
(docs/lanes_scaling.{csv,md}); two paragraphs: method (one design per lane count, L1 of 2,048
lines, SFU per 8 lanes, 54 cases all pass, amo_contend order-independent check at 4 lanes),
per-suite geomeans, dense vs gather groups, Black-Scholes/NN, hist_shared, radix sort; note that
Tables X-XI keep one 64 KB L1 and one SFU. Paper 20 pp.

**2026-11-19: SIMTiX vs CVA6/Ara/Vortex per suite in the paper** (user: "add it in the paper"):
Fig. 5 fig:mach_suites1 ((a) applications, (b) suite 2) and Fig. 6 fig:mach_suites2 ((a)
Rodinia, (b) RiVEC), from docs/plot_machines_suites.py; new paragraph in Sec. VI-B that also
DEFINES suite 2 for the first time (ten kernels from Rodinia, RiVEC, GAP, SHOC, PolyBench; new
bibitems gap, shoc, polybench), per-suite geomeans (8L and 16L), the division/sqrt exceptions
(Ara Black-Scholes suite 2 + RiVEC, Vortex 0.975x RiVEC Black-Scholes, Ara/Vortex nn), Ara
MLP/SWAT/Mandelbrot not compared; Rodinia/RiVEC results sentences point to Fig. 6. Paper 21 pp.

## Focused rewrite (2026-11-19)

User: "rewrite the paper focusing only on the important things". Paper 20 -> 13 pages; supplement 6 -> 8. Backups: docs/paper/simtix_tvlsi_long_2026-11-19.tex and simtix_tvlsi_supp_long_2026-11-19.tex. Moved to the supplement (docs/paper/supp_moved.tex): benchmark rules and RiVEC/Rodinia changes, FP16 double-rounding proposition, suite 2 + sync lane panels, lane throughput/cycle tables, simulated-application table, timing-closure details. The stale v2 supp_lanes.tex is no longer included. All kept numbers unchanged.

## Operation figures from RTL traces (2026-11-26, user: "pictorially show the operations performed by simtix")
- New Figs. 2, 3 and 6 of the paper (TikZ, same style as Figs. 4/5/7), each drawn from an RTL
  trace, nothing hand-timed:
  - Fig. 2 simtix_launch.pdf (gen_launch_fig.py): SAXPY for N = 92 threads: threads -> 12 warps,
    the last warp's lanes 4-7 masked, register start values; (b) the 8 slots over the launch,
    with each warp's issue cycles (120 issues in 271 cycles; warp 10 refills slot 7 first).
  - Fig. 3 simtix_div.pdf (gen_div_fig.py): kernels/figs/divergence.S on one warp: one-sided if
    (lanes 3-7 pushed, pop at 0x110) and a per-lane trip-count loop (stack grows to 4 frames,
    3 pops at the exit, one issue slot each); two stack snapshots.
  - Fig. 6 simtix_pipe.pdf (gen_pipe_fig.py): one SAXPY warp through F, X, B, memory engine,
    L1, AXI4/DDR4 (24-cycle model), FPU and register write; axis breaks over memory-only
    stretches; notes: third load waits (two loads in flight per warp, LD_MAX), FMA sleeps on
    x/y, the store parks the warp until the write response.
- Trace flow: docs/figs/arch_v2_tikz/fig_trace.py assembles kernels/figs/{saxpy,divergence}.S
  and runs tests/tb_figtrace.sv (simt_ps_top, board defines B34 + SIMTIX_ISSUE_TRACE,
  deterministic axi_mem_model LAT 24) for saxpy1 / div / saxpy92; results checked (PASS);
  traces copied to docs/figs/arch_v2_tikz/traces/. Paper 16 pages (was 15).
- FOUND, FIXED the same day (user: "yes correct the proposition and the Fig. 4 model"): the RTL writes an FPU result 7 cycles after issue
  (wp_resq: queue capture at t+6, write t+7) and a dependent FMA chain on one warp issues every
  9 cycles (probe: issues at 2, 11, 20; sleep -> wake on write -> F -> X). The paper says
  "written six cycles after issue", d_w >= 7 and "a chain of dependent FMAs needs seven"
  (Prop. 1, Sec. III-C) and Fig. 4(a)'s schedule model (lat_sched.py) uses FPU = 6.
- Fix (2026-11-26): lat_sched.py rewritten as a two-stage (F, X) copy of warp_pool.sv:
  round-robin fetch of runnable, not-in-flight, awake warps; a held-back X loses its slot and the
  warp sleeps until ANY of its own results is written (fetchable the next cycle); FPU result
  written issue+7, register free from the next cycle; ecall waits for all. check_lat_sched.py
  replays kernels/figs/issue_rules.S on 4 warps against the RTL trace (fig_trace.py rules4):
  32 issues + 8 held-back X cycles identical. Fig. 4(a) regenerated: 13 issues in 17 cycles,
  the 4 lost slots (4, 7, 8, 13) are all held-back instructions. Paper: III-C "held back,
  which costs its issue slot", "written seven cycles after issue", "four of the 17 issue slots
  are lost", model reproduces the RTL trace; Prop. 1 now defines d_w as the least distance the
  warp's own instructions allow, d_w >= 8 for dependent FMAs (queue at 6, written in the 7th),
  "needs eight"; alone a dependent FMA chain issues every nine cycles (held back, refetched after
  the write). RTL check: with 4 warps the dependent FMA issued at +8 (2 -> 10), alone at +9.

## Figure explanations (2026-11-26, user: "make sure that you explain each figure properly in the text")
- Every paper figure now has a how-to-read sentence plus its result: Fig. 1 (upper/lower part,
  left-to-right stages), Fig. 2 (panels, bars, ticks, issue row; trace: 56 issues in cycles 0-59,
  none in 60-89 while all 8 warps wait on loads, 4 warps left after cycle 176, 120 issues in 271
  cycles), Fig. 3 (columns = issue slots, rows = lanes, colour = frames, hatch = pop, two stack
  tables), Fig. 4(a) (top row and warp rows), Fig. 5 (table colours, one box per request; (b) one
  bar per request on a time axis in units of Lambda), Fig. 6 (rows/boxes, axis breaks, marks 1-3
  tied to the text), Fig. 7 (state diagram; (b) eight lanes on one line, time axis), Fig. 9 (one
  marker per machine), Fig. 10 (bars/dots per lane count; bytes read up, written down), Fig. 11
  (points (a), bars (b)), Fig. 12 (one point per accelerator and benchmark). Fig. 8 was complete.
- Supplement: Rodinia/RiVEC bars (SIMTiX fastest in the PL on every Rodinia benchmark but nn and
  on 5 of 7 RiVEC apps, FGPU on blackscholes and lavaMD; A53 faster than SIMTiX on all Rodinia
  but hotspot3D), time heatmap reading, energy (16 lanes lower on 24 of 27; higher on the two
  SpMV and hash join), Vortex OOC (SIMTiX faster than Vortex-4w on all 7, than Vortex-16w on 5,
  not GEMM/SpMV; least energy on all 7; from vortex_apps.csv + vortex_syn.csv).
- Layout checked: paper 16 pp, figures next to their text (pp. 3-7), no warnings; supplement 10 pp.
- 2026-11-26 (user: "properly explain the diagrams, specially the ones that you have made now"):
  the new diagrams got their own walk-through paragraphs (set-up, how to read, cycle-by-cycle
  events, the point), every number from the traces: Fig. 2 (cycles 2-57 one issue per cycle =
  each warp's first 7 instructions; 58-100 none, FMAs wait for x and y; a from DDR4 once, 25 AXI
  reads for 36 loads; warps 0-7 end 145-175; warp 8 -> slot 0 at 146; IPC 0.44), Fig. 3 (bnez
  cycle 4, push lanes 3-7 RPC 0x110, pop 11; loop pushes, 4 frames at 35, pops 43/45/47, all
  lanes at 49; 22 slots for 18 instructions, lane utilization 102/144 = 0.71), Fig. 4(a)
  (held back at 4, 7, 8, 13; warp 1's addi at 5 with its load in flight), Fig. 6 (bgeu F1 X2
  B3; load of a: ME 6-7, L1 8-9 miss, AR 10, beats 35-36, f0 at 37; y held at 15 (two loads in
  flight), issues 40; FMA held 42 and 48, issues 75, FPU 76-81, written 82; store 84, ack 116;
  ecall, DONE 121; 10 instructions in 121 cycles vs 120 in 271 with 12 warps). Paper 16 pp.
- 2026-11-26 (user: "Fig. 2 ... not professional. Make ... proper cycle waveform diagram ... no
  limitation on the pages"): Fig. 2 rebuilt and a new full-page Fig. 3 added, both as timing
  diagrams from the saxpy92 RTL trace (tb_figtrace.sv now also logs Z <c> <slot> <wstate>
  <sleep> on slot-state changes; all other trace lines unchanged):
  - wavetikz.py: clock / one-bit / bus (crossing transitions) primitives in TikZ;
    launch_trace.py: the trace as per-cycle signals (warp in slot, state, fetch, issue, opcode,
    L1 request + miss/join/hit, AXI4 AR/R/AW/W/B named by line, RF writes load/FPU);
  - Fig. 2 (gen_launch_fig.py): (a) grid + warp 11's register start values (a0..a4 hex);
    (b) logic-analyser overview: busy, issue, slot[0..7] buses (shaded asleep/parked),
    axi.ar/r/aw/b, done, with the Fig. 3 windows marked;
  - Fig. 3 (gen_launch_wave_fig.py, figure* [p], full page): cycles 0-23, 44-67, 96-119 with
    clk, spawn, fetch, issue, opcode, 8 slots, l1.req, l1.tag, 5 AXI4 channels, rf.wr.
  Text rewritten (facts from the trace: a-line one miss + 7 joins, AR at 15; x/y reads every
  other cycle, max 14 in flight at cycle 75; a returns 40-41, x/y from 72; 25 reads for 36
  loads). Paper 18 pp (Fig. 3 takes page 5); supplement 10 pp.
- Waveform text (user: "explain these waveforms properly in the text"): six paragraphs in
  III-B: set-up and Fig. 2(a); how to read the waveforms (conventions, rows, colours, line
  names); Fig. 3(a) (spawn 0-7, bgeu 2-9, loads of a 10-17, L1 requests 13-20, miss 14, AR 15,
  7 joins); Fig. 3(b) (a written to f0 one warp per cycle 42-49, L1 one response per cycle;
  x/y loads, one miss every other cycle, 14 reads in flight by 75; FMAs held 58-65, warps asleep
  59-66, no issue 58-100); Fig. 3(c) (y lines one every 3 cycles, f2 written a cycle after the
  last beat; w0: FMA 101, store held 103, FPU write 108, store 110, parked from 111, L1 113, AW
  115, W 116-117); Fig. 2(b) (store ack 141, warps end 145-175, refill, IPC 0.44, 25 reads).
- Fig. 1 updated (2026-11-26, user: "figure 1 is ... outdated, make it ... neat, nothing overlaps,
  professional"), gen_arch_v3.py: command registers now the RTL map (KERNEL_PC, BASE_A/B/C =
  a1-a3, N = a4, BLOCK, CTRL.GO, STATUS DONE/BUSY, CYCLES, L1 hits/misses, AXI error + CONFIG,
  64-word debug window; was "PARAM (a1)"); SIMTiX box gives both clocks (L=8 115.37 MHz, L=16
  100 MHz); RF columns 0..L-1; FPU "operand reg. + 5 stages"; div/sqrt "one per 8 lanes"
  (SFU_CORES); new Store merge box (me_store_merge) under the Coalescer; per-unit result-queue
  icons (RQ, caption updated) instead of the overlapping "result queues" strip; compact \vd
  dots in all tables (they ran into "15"/"511"); B / 64L / load-done labels moved off wires;
  L1 note rewritten. Text: host registers (three argument pointers, status/config/debug), one
  divide unit per eight lanes, Fig. 1 reading guide (I2C reads the 18 board power monitors,
  both clocks, key). Paper 18 pp.
- Figure polish (2026-11-26, user: "make the other figures also look professional"): audited
  Figs. 4-13 at 150-170 dpi. Plots (Figs. 9-13) already clean. Diagrams Figs. 4-8: removed the
  dashed, rounded, gray-filled subfigure frames (panel style now invisible, layout unchanged),
  matching Figs. 1-3; Fig. 8 "touched words" split over two lines off the store-data wire;
  Fig. 4 "issue slot" right-aligned with the lane labels. Paper 18 pp, supplement 10 pp.
- Waveforms in the style of a reference TCAS-I paper (2026-11-27, user: "see how the waveforms
  have been made and properly fitted ... implement it"; chose the full rework):
  - new Fig. 9 simtix_phase.pdf (gen_phase_fig.py, one column): the critical path of one SAXPY
    warp as a phase-level timing diagram (clk with dotted gaps + T_clk, busy logic-1, the warp's
    memory operations in flight, Opr. phases with lambda_1..lambda_9 and cycles, the second row
    right to left joined by dotted arrows, T = 3 Lambda + 49 = 121 cycles); replaces the
    full-width pipeline chart, which moved to the supplement (Fig. S2);
  - latency model checked on the RTL: phase_model.py + check_phase_model.py, runs saxpy1,
    saxpy1_l48, saxpy1_l96 (fig_trace.py): phases [5, L+8, 3, L+8, 3, 7, 2, L+8, 5], T = 121,
    193, 337 = 3 Lambda + 49 exactly; load = 3 + 2 + (Lambda+1) + 1 + 1, store = 3 + 2 + 2 +
    Lambda + 1; paper eqs. (lld), (twarp);
  - Figs. 3-5 simtix_wave_{a,b,c}.pdf (gen_wave_col_fig.py, one column each, 15 cycles): the
    signals that matter in each window + dashed callouts (vertical arrows to cell edges, no
    label crossed); the full-page window figure moved to the supplement (Fig. S1);
  - text: conventions + per-window walk-through rewritten for the new figures; Prop. 1 now
    cites the wake phases lambda_3, lambda_5. Paper 17 pp, supplement 12 pp.
- Fig. 8 (memory-level parallelism) redrawn (2026-11-27, user: "looking very odd ... make it
  professional and updated with the text"), gen_mem_fig.py, one column: (a) the lane/word/line
  table coloured by line + the coalescer as a 4-cycle waveform (clk, l1.req line 0/2/5/11,
  lanes served); (b) the eight loads as a timing diagram, one row per request in flight, each
  request a bus value issue->data, time axis in Lambda with a dashed grid: CVA6 one miss row
  (lines 0, 2, 5, 11 in turn, ~4 Lambda), Ara req 0-3 with e0..e7 (~2 Lambda), SIMTiX req 0-3
  one per line (~Lambda) + issue high (other warps); end markers per machine. Text updated
  (l1.req/lanes rows; the (b) description). Figs. 8 and 9 now share the top of p. 7. Paper 17 pp.
- Fig. 8(b) now has all five machines (2026-11-27, user: "also show it for vortex and fgpu"),
  each from its RTL/build config: FGPU two line fills in flight (gmem_cntrl_tag N_WR_FIFOS = 2,
  N_TAG_MANAGERS = 2), 128-byte lines (BURST_WORDS_W = 5) -> lines 0 (lanes 0,1,2,4,5),
  1 (3,6), 2 (7): ~2 Lambda; Vortex 3.0 (vortex_syn zcu102_1c8w8t): VX_mem_unit coalescer
  NUM_REQS 8 -> DCACHE_WORD_SIZE 16 B, two groups of four lanes, one merged request per group
  per cycle (2 per cycle), D-cache 64-B lines, 16 MSHRs, one fill per new line: lines 0,1
  (cycle 1), 2 (3), 5 (4): ~Lambda. Order CVA6, Ara, FGPU, Vortex, SIMTiX; the SIMTiX-only
  issue row dropped (all three SIMT machines switch warps; said in the text). Text: Prop. 2(c)
  bound adds 16/Lambda Vortex and 2/Lambda FGPU; the (b) description covers all five.
- Fig. 2(b) window labels fixed (2026-11-27, user: "showing Fig. 3(a), 3(b), 3(c) but I can't
  find them"): the bands still marked the old full-page windows (0-23, 44-67, 96-119). The
  windows are now defined once (launch_trace.WINDOWS: 9-23, 55-69, 97-111 with their LaTeX
  labels), used by gen_wave_col_fig.py and gen_launch_fig.py; the overview reads each window's
  figure number from paper/simtix_tvlsi.aux, so the labels follow the numbering ("Fig. 3, 4,
  5" now). Text: the windows are "shaded and labelled in Fig. 2(b)". Recompile the paper
  before regenerating Fig. 2 after figures move.
- Fig. 10 (AMO) redrawn (2026-11-27, user: outdated; proper conventions, every line connected,
  nothing overlapping, a professional way to show the example's AMO instruction):
  (a) datapath in three phase columns (group RD, apply AGG, write WR) with no wire crossings:
      the word mux + data select became one lane-word crossbar (the RTL's per-lane word routing
      in both directions: operand v = a_v to the ALU, old word x = a_old to the RF); store data
      and AMO op run along the bottom; junction dots; context rows abut.
  (b) new panel, the example: the instruction (amoadd.w t5, t4, (t3)) and its per-lane
      semantics; a lane table (word, par round, returned t5); the line buffer after each round
      with the write enables.
  (c) the example traced on the RTL in the three variants (new fig_trace runs amo_lane / amo_ser
      / amo_par, KERN 3 = kernels/figs/amo_demo.S; tb_figtrace.sv gained the AM trace event and
      checks the final line AND every returned value, 16 checks, all pass): per lane 16
      requests, warp resumes 108 cycles after the issue; ser 2 requests, 8 apply cycles, 73;
      par 2 requests, 3 rounds, 68. Axis break over cycles 53-76 (the DDR4 line read).
  Text: three paragraphs, one per panel; caption says "phases". Other traces re-run unchanged.
