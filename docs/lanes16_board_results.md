# SIMTiX with 16 lanes on the ZCU102: board results (2026-11-17)

Design: 16 lanes x 8 warps, store-merge rewrite (me_store_merge), two divide/sqrt cores
(SFU_CORES = 2), 128 KB L1, 16 MSHRs, 16 memory tags (docs/lanes16_plan.md). Board build
fpga/build_staged.ps1 `tagl16 lanes16 warps8 l1kb128 mshr16 mtags16 mhz100 lowmem`:
**WNS +0.041 ns at 100.00 MHz**, 202,660 LUT (73.9 %), 93,351 FF, 144 DSP, 32 BRAM tiles,
5.28 W (Vivado estimate). Routed netlist simulated cycle-exact against the RTL before the board.

Baseline: the v3 8-lane board design (8 lanes x 8 warps, 64 KB L1, 115.37 MHz) on the same
board with the same inputs (docs/zcu102_board_run_v3_s2.txt, rodinia_results.csv,
rivec_results.csv). A53: Cortex-A53 at 1.2 GHz, -O2, measured in each run.

All three sessions: **RESULT: PASS (0 errors)**, every output checked by the A53; the host read
the configuration register as 16 lanes, 8 warps, 128 KB L1.

| Session | Log |
|---|---|
| sync kernels + 17 applications + suite 2 (two sizes each) | docs/zcu102_board_run_l16_main.txt |
| Rodinia (9 rows) | docs/zcu102_board_run_l16_rodinia.txt |
| RiVEC batch 1 (7) | docs/zcu102_board_run_l16_rivec.txt |

## Summary (measured times; speed-up = baseline time / time; geometric means)

| Suite (kernel x size rows) | 16L @100 vs 8L @115 | 16L faster than 8L | 8L vs A53 | 16L vs A53 | faster than A53 (8L -> 16L) |
|---|---|---|---|---|---|
| Sync kernels (12) | 1.34x | 12/12 | 0.17x | 0.23x | 0 -> 0 |
| Applications (34) | 1.55x | 34/34 | 0.79x | 1.23x | 15 -> 19 |
| Suite 2 (20) | 1.26x | 14/20 | 0.56x | 0.71x | 2 -> 6 |
| Rodinia (9) | 1.64x | 9/9 | 0.56x | 0.92x | 1 -> 6 |
| RiVEC (7) | 1.57x | 6/7 | 0.88x | 1.37x | 2 -> 3 |
| **All (82)** | **1.45x** | **75/82** | 0.56x | **0.82x** | **20 -> 34** |

The measured 8L/16L cycle ratios match the board-size simulations (docs/lanes16_cycles.csv):
e.g. GEMM 2.04 (sim 2.04), Black-Scholes 2.00 (2.00, the second divide/sqrt core), hotspot 2.00
(2.00), Rodinia kmeans 2.02 at the full board size, SpMV-Z 1.28 (1.27).

## The 7 rows slower than 8 lanes

| Row | 16L vs 8L (time) | 8L/16L cycles | Cause |
|---|---|---|---|
| suite2/sort 65,536 and 1,048,576 | 0.65x | 0.75 | scatter stores move 64-B lines (line = 16 words) instead of 32-B: ~2x the DRAM bytes |
| suite2/atax 4096, bicg 4096 | 0.89x, 0.88x | 1.03, 1.01 | DRAM-size column walks: no cycle gain, so the 100 vs 115 MHz clock decides |
| suite2/pagerank 262,144, cc 262,144 | 0.77x, 0.83x | 0.89, 0.96 | large random gathers: 64-B lines on scattered reads |
| rivec/spmv 85,623 | 0.94x | 1.09 | L1-port-bound gathers (one line per cycle) |

The medium-size rows of atax, bicg, PageRank and cc are 1.06-1.39x faster; only the DRAM-size
rows lose. The common cause is the line size tied to the lane count (64-B lines at 16 lanes);
decoupling it (32-B lines, two requests for a full-width access) is the next improvement.

## Files (all regenerated from the board logs by `python sim/compare_board_l16.py`)

| File | Content |
|---|---|
| docs/lanes16_board_table.md | every benchmark (82 rows): A53, 8-lane and 16-lane times, 16L/8L time and cycle ratios, both vs the A53 |
| docs/lanes16_board_results.csv | the same rows as data (cycles, times, ratios) |
| docs/paper/tab_lanes16_board.tex | paper table (per suite), `\label{tab:lanes16_board}`; IEEEtran column width, compiles clean |
| docs/paper/supp_lanes16_board.tex | supplement tables, every row, `tab:lanes16_board_all1`/`_all2` (table* [p]) |
| docs/zcu102_board_run_l16_{main,rodinia,rivec}.txt | the raw board logs (BOARD rows, CONFIG line, RESULT) |
| docs/lanes16_cycles.csv, docs/lanes16_vs_a53.csv | the board-size simulations that predicted these numbers |

Not yet in the paper: the tables are standalone `\input` files; the text that explains them
(design, the two fixes, the store-merge rewrite, the 64-B line limitation) is to be written.
