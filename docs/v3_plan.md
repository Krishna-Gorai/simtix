# SIMTiX v3: closing the gap to the Cortex-A53

Started 2026-10-28. Goal: raise SIMTiX's performance on the application suite
against one Cortex-A53 core at 1.2 GHz (measured on the ZCU102, best of `-O2`
and `-O3` NEON builds; `docs/zcu102_a53_run_O*.txt`), one measured change at a
time, so that every change has its own gain, area and frequency.

## Starting point (medium inputs, 8 lanes, 4 warps, 100 MHz, simulated)

| App | SIMTiX / best A53 time | IPC | Lane util. | L1 hit | Main loss |
|---|---|---|---|---|---|
| GEMM 64^3 | 5.0 | 0.71 | 100% | 93% | 7.4 warp instructions per FMA |
| Stencil 128^2 x4 | 10.1 | 0.54 | 100% | 91% | ~33 lane instructions per point |
| k-means 16384 | 4.6 | 0.72 | 100% | 96% | instruction count, clock |
| BFS 16384 | 4.1 | 0.41 | 43% | 57% | divergence, memory latency |
| SpMV 4096 | 5.6 | 0.34 | 59% | 75% | divergence, gathers |
| Scan 65536 | 47 | 0.51 | 95% | 74% | parallel algorithm, 7 launches |
| MLP b16 | 0.43 (SIMTiX faster) | 0.49 | 100% | 52% | -- |

Sources: `docs/board_sim.csv` (sim/board_sim.py --size board --lat 24) and the
A53 logs. The A53 has 32 KB L1 + 1 MB L2; SIMTiX has a 16 KB L1.

## Phases (in order; each ends with the checks below)

**A. Kernels (software).** Register-blocked GEMM (each thread a 2x4 block,
accumulation order over k unchanged, so bit-exact); stencil with reuse of loaded
neighbours; SpMV with several lanes per row (needs gold in the same summation
order); fewer scan launches; unrolled k-means. Keep the old kernels for the
ablation.

**B1. Banked scratchpad.** One bank per lane, conflicts serialised, instead of one
lane per cycle; enables tiled GEMM and stencil in shared memory.

**B2. Register scoreboard.** A warp keeps issuing independent instructions while
an FP, multiply, dot, shuffle or memory result is pending, instead of parking on
every multi-cycle unit.

**B3. Eight warps.** More latency hiding for BFS, SpMV and k-means (LUTRAM
register files grow with the warp count).

**B4. Memory hierarchy.** L1 to 64 KB in block RAM, 8-16 MSHRs, more tags,
next-line prefetch.

**B5. Clock.** 150-200 MHz: an operand-read stage and a split FPU stage 0 (the
current critical path); only together with B2 and B3.

**C. Multi-core.** Two or three 8-lane cores with a shared L2 and more HP ports
(the lane sweep showed that wider warps grow the memory engine with L^2).

**D. Domain units.** Wider INT8 dot products (two INT8 MACs per DSP), packed
FP16; extends the one application where SIMTiX already wins.

## Status (end of 2026-10-29)

| Phase | Change | State |
|---|---|---|
| A | GEMM register blocking (`gemm_rb.S`) | done 10-28 |
| A | segmented scan (`scan_seg.S`, `scan_segadd.S`) | done 10-29: 2.35x (B2) / 2.95x (B3+B4), bit-exact |
| A | stencil, SpMV, k-means kernels | not started |
| B1 | banked scratchpad | postponed 10-29: no application uses the scratchpad beyond a few words (see Findings) |
| B2 | step 1: FP/mul/dot/shuffle accept an instruction every cycle | done, simulation (xsim 28/28, Verilator, apps) |
| B2 | step 2: register scoreboard, warps sleep on a stall | done, simulation (xsim 28/28, apps); lost wake-up found by B3 and fixed 10-29 |
| B2 | step 3: non-blocking loads, 8 memory contexts | done, simulation (xsim 28/28, apps) |
| B2 | board build (Fmax, area, power on the XCZU7EV) | done 10-29: meets 100 MHz (see Findings) |
| B3 | eight warps | simulation done 10-29 (apps bit-exact, `apps_w8` test); board build to do (`warps8`) |
| B4 | memory hierarchy | sweep done 10-29: 64 KB L1, 16 MSHRs, 16 tags chosen; board build to do |
| B4 | next-line prefetch (`SIMTIX_L1_PF`) | implemented 10-29, L1 tests pass with it on and off; measurement pending |
| B5 | clock 150-200 MHz | planned 10-29 (see worklog): FPU stage 0 via retiming over the delay line; memory-engine request split |
| C | multi-core | not started |
| D | INT8/FP16 units | not started |

Every step's medium-size application results: `docs/v3_steps.csv` (column `step`).
Board builds run from a PowerShell window outside Claude Code (Claude Code stops
background jobs when the 8 GB PC runs low on memory):
`vivado -mode batch -source create_bd_ps.tcl -tclargs build zcu104 tag<name>` from
`fpga/`, after `Remove-Item Env:\NoDefaultCurrentDirectoryInExePath`.

## Findings

**2026-10-28, A (GEMM).** `gemm_rb.S` (a 4x4 block of C per thread, bit-exact
with `gemm.S`) cuts the warp instructions of GEMM 64^3 from 241,152 to 65,632
(3.7x) but its cycles only from 337,591 to 282,884 (1.19x): IPC falls from 0.71
to 0.23. The cause is in the warp pool, not the kernel: the FP unit is a
single-slot scoreboard (`fpc_state`, warp_pool.sv), so one FP warp instruction is
in flight in the whole accelerator and the 5-stage FPU holds one instruction at a
time, about one warp FMA per 7 cycles. The integer multiplier, dot-product,
shuffle and divide/sqrt units are built the same way. B2 therefore comes first
and is widened: the multi-cycle units accept a new warp instruction every cycle
(one result slot per pipeline stage), then a register scoreboard lets a warp keep
issuing independent instructions. Without it the kernel work of A cannot pay off
on FP and multiply-bound applications.

## Checks after every phase

1. xsim regression (sim/run_xsim.py, 28 configurations) and Verilator 5.020
   parity (CI).
2. Application suite bit-exact at small, board and (overnight) dram sizes;
   cycles, IPC, utilisation and L1 hit rate into docs/board_sim.csv.
3. Out-of-context synthesis and implementation on the XCZU7EV (LUT, FF, BRAM,
   DSP, Fmax, power); the board design for the ZCU104 must still close 100 MHz
   (or the new target clock).
4. A table row: phase, change, cycles per app, time at Fmax, ratio to the A53.

## Constraints

- The ZCU102's XCZU9EG needs a Vivado Enterprise license, so the accelerator
  does not run on the board: SIMTiX results come from simulation and XCZU7EV
  implementation; the A53 is measured.
- If SIMTiX becomes multi-core, the A53 comparison should include all four A53
  cores as well.
- Builds on the 8 GB PC: one Vivado run at a time, PC must not sleep.

**2026-10-29, B2 (register scoreboard) in three steps.** Medium inputs, 8 lanes,
4 warps, DDR model latency 24, all outputs bit-exact; cycles:

| App | v2 | Step 1 | Step 2 | Step 3 | Gain | SIMTiX / A53 time |
|---|---|---|---|---|---|---|
| GEMM-RB 64^3 | 282,884 | 145,067 | 96,939 | 80,443 | 3.52x | 4.19 -> 1.19 |
| GEMM 64^3 | 337,591 | 312,499 | 272,634 | 265,127 | 1.27x | 5.00 -> 3.93 |
| Stencil 128^2 x4 | 498,582 | 485,789 | 460,225 | 403,964 | 1.23x | 10.07 -> 8.16 |
| SpMV 4096 | 263,749 | 263,146 | 254,517 | 234,879 | 1.12x | 5.55 -> 4.94 |
| k-means 16384 | 993,810 | 942,594 | 913,366 | 899,601 | 1.10x | 4.63 -> 4.19 |
| Scan 65536 | 1,085,404 | 1,085,413 | 1,088,773 | 1,021,428 | 1.06x | 47.4 -> 44.6 |
| BFS 16384 | 1,771,198 | 1,771,800 | 1,770,554 | 1,724,941 | 1.03x | 4.08 -> 3.97 |
| MLP b16 | 1,973,694 | 2,012,258 | 2,152,311 | 1,936,909 | 1.02x | 0.43 -> 0.42 |

- Step 1. The FP, multiply, dot and shuffle units accept a warp instruction every
  cycle: a result queue per unit (`wp_resq`) carries the op's tag in step with the
  unit (latency FPU 6, multiply 7, dot 6, shuffle 1) and holds finished results until
  their write port is free.
- Step 2. The warp no longer parks on these units. Per-warp pending masks
  (`pend_x`, `pend_f`) hold back an instruction whose sources or destination are
  pending (decoded per opcode, so immediate fields never stall), whose unit is full
  (8 ops in flight per unit), or an ecall with results outstanding. Without more,
  MLP got 7% slower than step 1: the stalled warp was refetched every other cycle
  and took issue slots from the other warps. A stalled warp therefore sleeps until
  one of its own results is written (or, if its unit was full, any result); with
  that MLP recovered a third of the loss (`b2s2b_scoreboard_sleep` rows, measured for
  GEMM, GEMM-RB and MLP only).
- Step 3. Loads do not park the warp: rd is pending until the memory engine
  reports the load finished (`rs_ld`, `rs_rd`, `rs_fp`). Up to 2 loads per warp,
  8 memory contexts. A store, AMO, barrier or ecall waits until the warp has no load
  outstanding (a store never overtakes an earlier load of its warp; a barrier orders
  loads before it against stores after it). MLP is back below v2.
- What is left: GEMM-RB is within 1.19x of the A53 (NEON) at 100 MHz; the
  memory-bound applications (L1 hit 52-75%) gain only 2-12%, limited by the L1 and
  the request path (B4); scan needs a different algorithm (A).

**2026-10-29, B2 board build** (`create_bd_ps.tcl build zcu104 tagv3b2`,
`fpga/reports_ps_v3b2/`, against the v2 build in `fpga/reports_ps/`):

| | v2 | B2 |
|---|---|---|
| WNS at 10 ns | +0.098 ns | +0.093 ns (meets 100 MHz; Fmax 100.9 MHz) |
| LUTs | 81,060 | 84,459 (+4.2%) |
| Flip-flops | 23,910 | 32,969 (+38%) |
| CLBs | 13,703 (47.6%) | 14,640 (50.8%) |
| BRAM / DSP | 16 / 72 | 16 / 72 |
| SIMTiX power (vectorless) | 0.833 W | 1.049 W |

The flip-flops are the four result queues (4 x 8 x 256 bits, built from
flip-flops, not LUT-RAM) and the four extra memory contexts. The worst path moved
from FPU stage 0 (35 levels) to the memory engine: context pending lanes ->
coalescing / request select of the 8 contexts -> L1 input register (28 levels,
74% routing). B5 has to split both. GEMM-RB takes 3.5x fewer cycles at 1.26x the
power: about 2.8x less energy.

**2026-10-29, lost wake-up (B2) found by B3.** With 8 warps GEMM-RB hung. The issue
step decided "woken in the same cycle" with the reason of the warp's previous sleep
(`sb_wfull`); a warp whose last sleep was on a full FP unit then missed the
completion of the load it was now waiting for. Fixed (the stalling warp is judged by
this cycle's reason; the wake loop only touches sleeping warps). New regression test
`apps_w8` (medium GEMM-RB, 8 warps): fails on the old logic, passes now. With 4
warps the fix changes only GEMM-RB (80,443 -> 80,271 cycles); `b2_final` rows.

**2026-10-29, B3: eight warps** (`board_sim.py --warps 8`; 16 memory contexts,
2 per warp; `b3_8warps` rows):

| App | B2 (4 warps) | B3 (8 warps) | Gain | SIMTiX / A53 time |
|---|---|---|---|---|
| MLP b16 | 1,936,909 | 1,396,076 | 1.39x | 0.30 |
| Scan 65536 | 1,021,428 | 805,236 | 1.27x | 35.2 |
| Stencil 128^2 x4 | 403,964 | 322,010 | 1.25x | 6.51 |
| BFS 16384 | 1,724,941 | 1,444,288 | 1.19x | 3.33 |
| k-means 16384 | 899,601 | 841,946 | 1.07x | 3.92 |
| GEMM 64^3 | 265,127 | 249,518 | 1.06x | 3.70 |
| GEMM-RB 64^3 | 80,271 | 76,209 | 1.05x | 1.13 |
| SpMV 4096 | 234,879 | 237,185 | 0.99x | 4.99 |

More warps hide memory latency (MLP, stencil, scan, BFS); GEMM-RB is compute-bound;
SpMV's L1 hit rate falls (75% -> 72%) as 8 warps share the 16 KB L1, a B4 question.
Area and Fmax: board build `create_bd_ps.tcl build zcu104 tagv3b3 warps8` (the
block design is then synthesised globally so the define reaches SIMTiX).

**2026-10-29, B4: memory hierarchy sweep** (8 warps; speed-up over 8 warps with the
v2 memory system; all bit-exact; `b4_w8_*` rows):

| App | 8 MSHR | 16 tags | 16 MSHR + 16 tags | 32 KB L1 | 64 KB L1 | 64 KB + 16 MSHR + 16 tags |
|---|---|---|---|---|---|---|
| SpMV 4096 | 1.43 | 1.00 | 1.70 | 1.37 | 1.50 | 1.84 |
| BFS 16384 | 1.24 | 1.00 | 1.30 | 1.13 | 1.28 | 1.35 |
| GEMM-RB 64^3 | 1.01 | 1.01 | 1.03 | 1.08 | 1.07 | 1.08 |
| MLP b16 | 1.00 | 1.00 | 1.00 | 1.01 | 1.01 | 1.01 |
| GEMM, k-means, scan, stencil | 1.00 | 1.00 | 1.00 | 0.99-1.00 | 0.99-1.00 | 0.99-1.00 |

L1 hit rate with the combined change: SpMV 72% -> 87%, BFS 55% -> 74%, MLP 52% -> 59%
(its time does not move: the weights stream once per batch). The 4 miss registers
were the limit for the irregular applications; 16 tags help only together with more
miss registers. Stencil, scan, k-means and GEMM do not change at all, so next-line
prefetch (the remaining B4 item) has nothing to gain and is dropped. Choice: 64 KB
L1, 16 MSHRs, 16 tags. Board build for B3+B4: `create_bd_ps.tcl build zcu104
tagv3b34 warps8 l1kb64 mshr16 mtags16` (`mtags`, since `tag<name>` names the build).
16 tags widen the AXI ID to 5 bits: `simt_ps_wrap.v` had a hard-coded 4-bit ID,
now `IDW = log2(SIMTIX_MEM_TAGS) + 1` (default 4); both widths elaborate cleanly.

**2026-10-29, B1 postponed.** Of the eight applications only `scan.S` touches the
scratchpad, for the four warp totals of each block. A banked scratchpad (one bank
per lane) would speed up nothing in the suite; it pays off only for kernels that
tile through shared memory (GEMM, stencil), and B4's 64 KB L1 already serves
their reuse. B1 is reconsidered if phase A writes such a kernel.

**2026-10-29, A: segmented scan** (`scanseg` case: the same 65,536 inputs as
`scan`, seed shared). One warp scans a segment of 64 rows x 8 lanes: coalesced
row loads, a 3-step shuffle scan with the lane masks set up once, the running
total carried by one `shfl_idx`; 16 warp instructions per row. A second level scans
the 128 segment totals and `scan_segadd.S` adds them: 3 launches instead of 7.
Kernels in slots 10 and 11 (45 and 22 words); `a_scan_*` rows.

| Configuration | scan | scanseg | Gain | Warp instructions | SIMTiX / A53 time |
|---|---|---|---|---|---|
| B2, 4 warps | 1,021,751 | 433,947 | 2.35x | 549,736 -> 193,954 | 44.6 -> 19.0 |
| B3+B4 (8 warps, 64 KB, 16 MSHR, 16 tags) | 805,076 | 273,009 | 2.95x | same | 35.2 -> 11.9 |

The first pass now hits the L1 only 6% of the time (458 hits, 8,214 misses: every
line of the input is new) and the add pass misses again on the output (the L1
does not allocate on writes). That reverses the earlier conclusion on next-line
prefetch, which was drawn from kernels that reuse lines: streaming kernels such as
this one need it.
