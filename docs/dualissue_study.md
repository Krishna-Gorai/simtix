# Dual issue for SIMTiX: opportunity count and cycle model (v4 study, 2026-11-13/14)

Question (user, 2026-11-13): can the IPC exceed 1? With one issue slot per cycle it cannot, so
the study asks what a second issue slot would gain. Proposed design: the register files split
by warp parity (even warps one copy, odd warps the other), two half-schedulers each issuing one
warp instruction per cycle, a pair allowed only if the two instructions use different unit
classes (ALU, FPU, multiplier, dot unit, shuffle, memory engine, divide unit); barriers, ecalls
and CSR reads pair with nothing. No extra register-file ports.

Everything below is simulation only; the RTL design is unchanged. Board configuration: 8 lanes,
8 warps, 64 KB L1, 16 MSHRs, 16 tags, 24-cycle AXI4 memory model, board inputs.

## Tools (simulation only, compiled out of synthesis, the regression and CI)

| Define | Code | Output |
|---|---|---|
| `SIMTIX_DUALISSUE_COUNT` | `rtl/accel/warp_pool.sv` | `DUALISSUE` lines: cycles with a dual-issue opportunity (`sim/dualissue_report.py`) |
| `SIMTIX_ISSUE_TRACE` | `rtl/accel/warp_pool.sv` | `issue_trace.txt`: issued instructions, result writes, resumes, load write-backs, lost slots with reasons |

Run: `python sim/board_sim.py --size board --lat 24 --warps 8 --define SIMTIX_L1_KB=64
SIMTIX_L1_MSHR=16 SIMTIX_MEM_TAGS=16 SIMTIX_ISSUE_TRACE=1 --out <csv> --only <apps>`; then
`python sim/issue_model.py <build_xsim/...>/issue_trace.txt --log <...>/xsim.log --csv out.csv`.

## 1. Opportunity count (upper bound)

In 27-86% of cycles a warp of the other parity had an independent instruction for another
unit ready. Optimistic bound cycles / max(cycles - opportunities, issued/2): 1.36x-2.65x,
geometric mean 1.95x over 15 applications (`docs/dualissue_opportunities.csv`). Mandelbrot and
Smith-Waterman not measured (very long runs; paused).

## 2. Cycle model (`sim/issue_model.py`)

Replays each warp's instruction stream from the trace under the issue rules of warp_pool.sv,
with each instruction's measured latency: fetch then X; a warp at most every other cycle (every
third after a branch); scoreboard stalls cost the slot and the warp sleeps until its own result
is written; 8 ops per unit; 2 loads per warp; stores/AMOs/barriers/ecall wait for the warp's
loads; one memory instruction per cycle; the coalescer sends one line per cycle with at most 16
lines (tags) in flight, each tag freed when its line's response is written; a scratchpad op
holds the engine one cycle per active lane; one divide in flight; barriers release on the last
arrival of the block; the spawner places one warp per cycle (whole blocks in aligned groups);
a single-cycle integer instruction is squashed, and issues again, when the integer write port
is taken in its X cycle by a load or a queued integer result. Dual mode: two half-schedulers,
pairs of different classes, one integer write port per bank (warp parity).

Building the model found the effects that matter: the 16-tag limit (SpMV), the scratchpad's one
lane per cycle (scan) and, above all, write-port squashes, which cost 10.7% (k-means), 11.0%
(SpMV-Z) and 26.8% (hash join) of all cycles (lost-slot reasons in the trace).

**Validation:** in single-issue mode the model reproduces the RTL's cycles within 3.6% on all
15 applications (7 within 0.5%).

## 3. Result (`docs/dualissue_model.csv`)

| Application | RTL cycles | Model error | IPC now | IPC dual | Speed-up |
|---|---|---|---|---|---|
| conv8 (CNN) | 2,101,485 | -2.7% | 0.75 | 1.30 | 1.72x |
| GEMM | 253,725 | -0.0% | 0.95 | 1.46 | 1.53x |
| GEMM-RB | 71,057 | -2.1% | 0.92 | 1.34 | 1.45x |
| k-means-U | 532,710 | -0.3% | 0.84 | 1.19 | 1.42x |
| hash join | 178,805 | -3.6% | 0.65 | 0.91 | 1.39x |
| k-means | 843,817 | -0.6% | 0.85 | 1.17 | 1.38x |
| embedding bag | 149,543 | -0.0% | 0.79 | 1.09 | 1.38x |
| MLP | 1,385,162 | -0.0% | 0.70 | 0.95 | 1.36x |
| stencil | 323,387 | -0.2% | 0.84 | 1.11 | 1.33x |
| BFS | 1,097,259 | -2.3% | 0.66 | 0.86 | 1.30x |
| scan | 813,082 | -0.5% | 0.68 | 0.84 | 1.25x |
| SpMV | 130,713 | -1.1% | 0.68 | 0.82 | 1.20x |
| stencil-RB | 149,385 | -0.4% | 0.81 | 0.97 | 1.19x |
| segmented scan | 283,360 | -0.0% | 0.68 | 0.80 | 1.16x |
| SpMV-Z | 116,706 | +2.4% | 0.58 | 0.62 | 1.08x |

Geometric mean: speed-up 1.34x at the same clock; IPC 0.75 -> 1.00; IPC above 1 on 7 of 15.

Reading: the compute-bound kernels gain most (CNN 1.72x, GEMM 1.53x, GEMM-RB 1.45x); the
gather-bound ones least (SpMV-Z 1.08x, SpMV 1.20x), whose 16 line requests in flight stay the
limit. The gain is per cycle: dual issue pays off only if the clock falls by less than the
speed-up allows, i.e. stays above 115.37 / 1.34 = 86 MHz on the geometric mean (and above
115.37 / 1.08 = 107 MHz for SpMV-Z not to lose).

## Next (when resumed)

1. RTL: parity-split register files, two half-schedulers, pairing rule, second instruction-RAM
   read port, unit input multiplexers; then the full regression, Verilator and the board-size
   tests (sim-before-synth rule).
2. Out-of-context synthesis: LUTs and Fmax against the 86 MHz break-even.
3. Board build and run.
