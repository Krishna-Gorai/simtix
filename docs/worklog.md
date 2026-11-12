# SIMTiX v2/v3 work log

Dated record of what was done, measured and decided. Nothing below 2026-10-26
is committed yet (see "Uncommitted at the end of 2026-10-28").

## 2026-10-27

**16-lane build.** Stopped on request. The PC had slept 13:45-08:58 in the middle
of routing. Placed result: 190,401 LUTs (83% of the XCZU7EV), 61,432 flip-flops,
96% of the CLBs used; routing reached WNS -1.83 ns before it was stopped. Restart
later from `C:\work\vortex_syn\simtix_ps_top_l16\project_1\project_1.runs\impl_1\simt_ps_top_physopt.dcp`
(routing only, 2-3 h; the PC must not sleep).

**Memory engine re-measured** (`fpga/impl_mem_engine.tcl`, now taking
`lanes<n>` and `byp0`; cmd.exe splits arguments at '='). Current RTL, out of
context, routed at 100 MHz: *ser* 13,256 LUTs and *par* 16,628 (unchanged from
Table II); board configuration (BYP = 0) 4,645 / 12,576 / 42,474 LUTs at 4 / 8 /
16 lanes (2.7x, then 3.4x per doubling), all meeting 100 MHz. These replace the
Vortex-flow figures (13.7k / 30.3k / 78.7k) in the lane section.

**Lane utilisation.** `tests/tb_apps.sv` prints the active lanes; sweep CSVs gained
an `active` column. Utilisation at 4/8/16 lanes: SpMV 66/59/57%, BFS 55/43/34%,
scan 95%, the others 100%. SpMV's L1 accesses fall only from 12,100 to 9,625 when
the warp doubles; its IPC drops from 0.43 to 0.33.

**Paper** (`docs/paper/simtix_tvlsi.tex`):
- checked against the original VLSID reviews point by point;
- frequency rule (routed, Fmax = 1/(10 ns - WNS)); AXI4-has-no-atomics motivation;
  2g-vs-2k AMO request model; Ventus does not fit the device; hand-written
  assembly vs LLVM as a limitation;
- abstract to 240 words; acronyms defined at first use;
- Section III rewritten block by block for the new Fig. 1; then the whole paper
  rewritten in the register of the eGPU paper (first person, short, design
  rationale);
- new Fig. 1 in the style of the Vortex and eGPU figures
  (`docs/figs/arch_v2_tikz/gen_arch_v3.py` -> `docs/figs/simtix_arch_v3.pdf`);
- new Fig. 2: line-aggregated AMO datapath and timeline drawn from
  `mem_engine.sv` (`gen_amo_fig.py` -> `docs/figs/simtix_amo.pdf`), with a proper
  word multiplexer; text corrected: the serial variant applies lanes in lane
  order, not round order;
- graphs redone (`docs/plot_style.py`, validated ordinal blue ramp, Times):
  Fig. 3 bars grow from parity with a geometric-mean group, Fig. 4 grouped bars
  at 8 and 16 lanes with ideal 2x/4x;
- board-results section and Table VI skeleton; 9 pages.

## 2026-10-28

**Board change.** The lab's board is a ZCU102 (XCZU9EG, rev 1.1). Vivado ML
Standard cannot target the XCZU9EG (no license, no voucher, no licensed machine),
so no SIMTiX bitstream. Ported for when one exists: `fpga/create_bd_ps.tcl
-tclargs [build] [zcu102|zcu104]`, `sw/ps_host/power.c` (per-board monitor
table; ZCU102: I2C0, PCA9544 at 0x75, 18 INA226), `sw/ps_host/build_vitis.py
[zcu102|zcu104]`, `sw/ps_host/run_board.tcl [zcu104]`.

**Board bring-up without a license** (`sw/a53_zcu102/`, see its README): the
laptop's SD reader could not read the kit's SD card; the card's image lit DONE
but left the PS uninitialised; JTAG needed Vivado's Digilent runtime; the UART
needed the CP210x driver. The PS is now brought up over JTAG with U-Boot's
ZCU102 rev 1.1 psu_init (A53 1200 MHz, DDR4 test passed), and the A53 references
run from DDR with their console read back over JTAG.

**Measurements** (`docs/zcu102_a53.md`): A53 times for both input sets, `-O2`
and `-O3` NEON builds (same results, proven by arena hashes), PS power on all 18
rails. SIMTiX medium inputs simulated (`sim/board_sim.py`, `gen_apps.py --size
board|dram`, `tb_apps` parameter `WORDS_LG`): the A53 is 4-10x faster on six
applications and 47x on the scan; SIMTiX is 2.3x faster on the MLP.

**v3 started** (`docs/v3_plan.md`; all of A, B, C, D chosen). Phase A, GEMM:
`kernels/apps/gemm_rb.S` (4x4 block per thread, bit-exact) cuts warp
instructions 3.7x but cycles only 1.19x, because the FP unit is a single-slot
scoreboard (one FP warp instruction in flight in the whole accelerator). B2
(pipelined multi-cycle units, then a register scoreboard) moves first.

## 2026-10-29

**Baseline.** The uncommitted work of 10-26 to 10-28 with the committed
`warp_pool.sv` passes the xsim regression 28/28 (run in a separate worktree,
`C:\work\simtix_base`, because the first run overlapped an RTL edit and 13 tests
compiled a half-edited file).

**v3 B2 step 1: multi-cycle units accept an instruction every cycle.** The FP,
integer-multiply, INT8-dot and shuffle units were single-slot scoreboards: one warp
instruction in each unit at a time, its result captured by a countdown. `simt_fpu`
already carries its control down its own delay line, and the multiply, dot and
shuffle datapaths are plain pipelines, so only the scoreboards limited them. Each
unit now has a result queue (`wp_resq`, a helper module at the end of
`warp_pool.sv`, so no file lists change): the op's tag (warp, rd, destination file,
lane enables, resume PC) rides a delay line in step with the unit and is pushed
with the per-lane results into an NW-entry queue whose head writes back when its
port is free. A warp still parks until its own result is written, so a queue
never holds more than NW entries. Latencies issue to result, from the RTL: FPU 6,
multiply 7, dot 6 (the old countdown read the dot result one cycle late, which only
worked with held operands), shuffle 1.
Checks: xsim 28/28; Verilator 5.020 lint and tests pass; medium-size applications
bit-exact (`python sim/board_sim.py --size board --lat 24 --out <csv>`;
`board_sim.py` gained `--out`; all steps' rows are in `docs/v3_steps.csv`).

| App | Cycles before | Cycles after | Speed-up | IPC | SIMTiX / A53 time |
|---|---|---|---|---|---|
| GEMM-RB 64^3 | 282,884 | 145,067 | 1.95x | 0.23 -> 0.45 | 4.19 -> 2.15 |
| GEMM 64^3 | 337,591 | 312,499 | 1.08x | 0.71 -> 0.77 | 5.00 -> 4.63 |
| k-means 16384 | 993,810 | 942,594 | 1.05x | 0.72 -> 0.76 | 4.63 -> 4.39 |
| Stencil 128^2 x4 | 498,582 | 485,789 | 1.03x | 0.54 -> 0.56 | 10.07 -> 9.81 |
| SpMV 4096 | 263,749 | 263,146 | 1.00x | 0.34 | 5.55 -> 5.54 |
| BFS 16384 | 1,771,198 | 1,771,800 | 1.00x | 0.41 | 4.08 |
| Scan 65536 | 1,085,404 | 1,085,413 | 1.00x | 0.51 | 47.4 |
| MLP b16 | 1,973,694 | 2,012,258 | 0.98x | 0.49 -> 0.48 | 0.43 -> 0.44 |

MLP layer 0 is 2.9% slower: its L1 misses rise from 101,640 to 103,953 because the
dot results return sooner and the warps' loads bunch together; layers 1 and 2 are
faster. BFS's instruction count moves by 2 in one launch (vertex-claim races depend
on timing); its result is checked.

**Board build.** `fpga/create_bd_ps.tcl` takes `tag<name>`, so the v3 build goes to
`simtix_ps_v3b2/`, `reports_ps_v3b2/`, `simtix_ps_v3b2.xsa` and the v2 ZCU104
project stays. The first attempt stopped in Vivado's own IP Integrator start-up
("couldn't read .../scripts/ipintegrator/clkrst.tcl"; the file exists and reads
fine, so a transient lock), retried. Needs >= 3 GB available: `wsl --shutdown`
after a Verilator run frees about 1.3 GB.

**Board build stopped.** The retry got past the block design, then Claude Code's
low-memory guard stopped it (and a watcher) while Vivado synthesised the PS IP; no
Vivado process was left. Board builds now run from the user's own PowerShell
window (the guard only applies to Claude Code's background jobs). Not rerun for
step 1 alone: one build of the finished B2 instead.

**B2 step 2: register scoreboard** (developed in the worktree `C:\work\simtix_base`
so the main tree stayed at step 1 for that build). Warps no longer park on the FP,
multiply, dot or shuffle unit; `pend_x`/`pend_f` per warp; the hazard check decodes
which registers each opcode really reads; units take 8 ops in flight (`rdy`
credit in `wp_resq`); ecall waits for outstanding results. First compile failed
(`sb_stall` used before its declaration; moved up). xsim 28/28, applications
bit-exact. MLP 7% slower than step 1 because a stalled warp was refetched every
other cycle; fix: stalled warps sleep until a writeback can unblock them
(`sb_wait`, `sb_wfull`, `sb_wake`); xsim 28/28 with it.

**B2 step 3: non-blocking loads.** `mem_engine` reports the finished op's rd, file
and kind (`rs_rd`, `rs_fp`, `rs_ld`); loads advance the PC at issue and keep rd
pending; 2 loads per warp (`LD_MAX`), `MEM_CTX` default 2 x warps = 8; stores,
AMOs, barriers and ecall wait for the warp's loads. An application run started
while these edits were being made was stopped and discarded. xsim 28/28,
applications bit-exact. Results and the per-step table: `docs/v3_plan.md`
(Findings, 10-29); GEMM-RB 3.52x over v2 and within 1.19x of the A53; MLP back
below v2.

**Merged into the main tree** (`warp_pool.sv`, `mem_engine.sv`, CRLF like the
checkout; the other RTL files of the worktree differ from the main tree only in
line endings). Step-1 and v2 copies kept in the session scratchpad.

**B2 board build** (run by hand, 09:57-11:25): meets 100 MHz, +4.2% LUTs, +38%
flip-flops, SIMTiX 1.049 W vs 0.833 W; details in `docs/v3_plan.md`. The build used
the B2 RTL before the wake-up fix below (a one-line logic change; not rebuilt).

**Bug found by B3: lost wake-up.** With 8 warps, GEMM-RB hung (7 other applications
passed). Bisect at 8 warps (second worktree `C:\work\simtix_bisect`): v2, step 1
and step 2 without sleeping pass; the final version with sleeping disabled passes;
so the sleep fix. A testbench dump at the timeout showed three warps runnable but
asleep with nothing pending, and a trace of stalls and wake-ups showed the cause:
the issue step judged "wake in the same cycle" with `sb_wfull`, the reason of the
warp's PREVIOUS sleep. Warp 3 had last slept on a full FP unit (wake on any unit
writeback, which does not include load completions); it then stalled on the load of
f20 in the very cycle that load finished, fell asleep, and nothing could wake it.
Fix: the stalling warp's sleep is decided from this cycle's reason
(`sb_wait <= !(sb_haz ? sb_own : sb_any)`), and the wake loop only touches warps
already asleep. 8-warp GEMM-RB then passes (76,248 cycles). With 4 warps the FP unit
rarely fills, which is why the regression and the 4-warp runs never hit it.

**B3 measured** (all applications bit-exact at 8 warps; table in `docs/v3_plan.md`).
**Regression test `apps_w8`** added to `sim/run_xsim.py` (medium GEMM-RB at 8 warps,
input generated on first use into `build_apps_w8/`; per-test `DEFINES`/`PLUSARGS`);
it fails on the old wake-up logic and passes with the fix. **Board build options**:
`create_bd_ps.tcl ... warps<n>` sets `SIMTIX_NUM_WARPS` and synthesises the block
design globally so the define reaches SIMTiX. **New defines merged** (defaults
unchanged): `SIMTIX_MEM_CTX_PER_WARP` (2), `SIMTIX_MEM_TAGS` (8), `SIMTIX_L1_KB`
(16), `SIMTIX_L1_MSHR` (4); `board_sim.py --define`. The bisect worktree
`C:\work\simtix_bisect` holds a testbench hang dump and the old wake-up logic;
remove it with `git worktree remove --force C:/work/simtix_bisect`.

**Phase A: segmented scan** (`kernels/apps/scan_seg.S`, `scan_segadd.S`, slots
10-11; `scanseg` case in the board and dram sets, the inputs of `scan`): 2.35x at
B2 / 2.95x at B3+B4 over the v2 scan, bit-exact; it streams (6% L1 hits), so
next-line prefetch went back on the B4 list. **B1 postponed** (no application uses
the scratchpad beyond a few words).

**B4 next-line prefetch implemented** in `l1_dcache.sv` (`PF`, define
`SIMTIX_L1_PF`, default 0): a demand miss arms line+1, injected into the input
stage when it is idle, dropped on a hit / line in flight / no free miss register,
filled with no waiter; no prefetch while a write is in flight downstream; miss
registers in flight at `inv` are marked stale (no fill, no join). First compile
failed (`m_isw` used before its declaration; block moved). The six L1 tests
(`sync_l1`, `sync_l1s`, `sync_apar`, `sync_axi`, `ps`, `apps`) pass with PF off
and with PF on. The measurement (all applications at B3+B4 without and with PF)
was still running at the end of the day; its CSVs go to the session scratchpad
(`.../scratchpad/b34.csv`, `b34pf.csv`). If they are missing, rerun:
`python sim/board_sim.py --size board --lat 24 --warps 8 --define SIMTIX_L1_KB=64
SIMTIX_L1_MSHR=16 SIMTIX_MEM_TAGS=16 [SIMTIX_L1_PF=1] --out <csv>`.

**B5 not started.** The timing analysis of the B2 build (`fpga/paths_at.tcl`: every
path that would fail at 150 MHz, grouped by block) was stopped by Claude Code's
low-memory guard; run it from a PowerShell window:
`vivado -mode batch -source paths_at.tcl -tclargs
simtix_ps_v3b2/simtix_ps.runs/impl_1/system_wrapper_routed.dcp 6.667
reports_ps_v3b2/paths_150mhz.csv` (from `fpga/`). Plan: (1) FPU stage 0: the
delay line `e[1..4]` became LUT shift registers (the worst path ends in
`e_reg[4][add_spec]_srl4`); with `shreg_extract = "no"` and retiming, stage-0 logic
can spread over the four cycles it already waits for the DSP product, at no extra
latency; (2) memory engine: split the context select + coalescing (28 levels) over
two cycles.

**End of 2026-10-29.** Main tree checks: xsim 29/29 (with `apps_w8`), Verilator
5.020 lint + tests (before the prefetch edit; rerun), the six L1 tests with PF on
and off.

**Evening: Vivado Enterprise license and ZCU102 devices.** The guide gave the lab's
floating license, `2100@14.139.1.126` (`XILINXD_LICENSE_FILE`, `LM_LICENSE_FILE`,
set for the user with setx): Vivado ML Enterprise, 49 seats, version limit 2025.10,
expires 07-aug-2027, reachable from the campus network. The server names itself
`localhost.localdomain`, so the laptop's hosts file maps that name to the server.
The installation was ML Standard (WEBPACK devices only); Enterprise added through
Help > Add Design Tools or Devices (XCZU9EG and the other larger Zynq UltraScale+
devices; XCZU7EV kept). Disk freed first: old installers in Downloads, hibernation
off, MATLAB R2025b uninstalled (`C:\Program Files\MATLAB` still needs an admin
delete). Verified: `synth_design` for `xczu9eg-ffvb1156-2-e` checks out the license.
SIMTiX can now be built for the ZCU102 and run on the board.

## 2026-10-30

**The ZCU102 is the target from now on** (Enterprise license, board in hand).

**First ZCU102 build: block design fixed.**
- The PS of the ZCU102 makes PL clock 0 = 99.990005 MHz (33.333 MHz reference),
  and `simt_ps_wrap.v` declared `FREQ_HZ 100000000`, so `validate_bd_design` failed
  (BD 41-237/238). The wrapper no longer declares a frequency; the block design
  propagates the PS clock's (ZCU104: 100 MHz). Setting FREQ_HZ from the script does
  not work: on a module reference it is read-only (BD 41-737).
- Block-design flows started from Claude's shell failed at random IP configuration
  steps ("Failed to create TCL scope ... for IP GUI", "couldn't read file
  .../ipintegrator/utils.tcl", empty `Common 17-232`), while the same script ran
  from the user's PowerShell window. Not memory, not environment variables, not
  Defender (an exclusion for `C:\Xilinx` was added and changed nothing). Starting
  the build in a new console window (`Start-Process powershell ... -EncodedCommand`)
  works: the block design validated at once.
- Build started 09:53 in its own window (`build_ps_zcu102.log`,
  `simtix_ps_zcu102/`, `reports_ps_zcu102/`, `simtix_ps_zcu102.xsa`); the tree
  passed the full regression (29/29) before.

**Host program for the board run** (`sw/ps_host/apps.c`): GEMM-RB
(`app_gemm(n, 1)`, 0xA00) and the segmented scan (`app_scan(n, 1)`, `scan_seg` at
0xC00, `scan_segadd` at 0xD00, as `gen_apps.py scanseg`) added at the end of the run
list and the power pass, so the earlier cases keep their inputs; `gen_kernels.py`
writes the three new kernels into `kernels.h`. Compiles (A53 build).

**ZCU102 build (B2, default design) done 11:14.** WNS +0.413 ns at the PS clock
(99.99 MHz; Fmax about 104.3 MHz), worst path the same as on the ZCU104 (memory
engine `c_pend` -> L1 `i_r`, 29 levels). SIMTiX 82,998 LUTs (30.3% of the XCZU9EG),
33,016 FFs, 16 BRAM tiles, 72 DSPs; Vivado power estimate SIMTiX 1.134 W, PS 2.74 W.
`check_timing` clean (one clock, no unconstrained endpoints). Host program built
from the new XSA (Vitis, own console window; only BSP warnings).

**First board run of the v2/v3 RTL: a kernel hangs, at random.** The board run
(`run_board.tcl`) stopped after the CSV header. Read over JTAG while it hung:
STATUS busy, L1 misses 128 (as in simulation), no AXI error, and in DDR all 128
results of reduce_shfl (N = 1024) correct except one, `C[123] = 0`. Two reruns:
once `C[124]` missing, once reduce passed and histogram hung (252 L1 hits where
simulation has 254). So one warp near the END of a kernel never finishes, about
one launch in three. Not reproduced in simulation:
- `tests/axi_mem_model.sv` gained `RJW` (random latency 0..2^RJW-1), `BLAT`
  (write-response latency), `SEED`, and `LATE` (a write takes effect at its B
  response, so writes of different IDs complete in any order and a read sees a
  write only after its response, as AXI allows); defaults keep the old behaviour
  (same cycle counts). `tb_ps_top` and `tb_apps` pass them through (`MEM_*`).
- `tb_ps_top` at 15 settings (latency 2..60 plus 0..127 jitter, B latency 1..30,
  seeds), one with LATE: all pass. `tb_apps` with LATE and jitter: 7679 checks pass.
- A gate-level simulation of the board's netlist (`system_simt_0_0_sim_netlist.v`)
  made no memory request in 30,000 cycles (an artefact of X-initialised flip-flops,
  most likely; the same netlist runs on the board), so it was dropped.
**Debug window added** to see the hang on the board: `simt_ps_top` 0x0200-0x02FC,
64 read-only words (warp_pool: state, sleep flags, loads in flight, pending
registers, base tid, PC per warp; mem_engine: contexts, tags, AMO phase; L1: miss
registers, write acks, input request; AXI: valid/ready, reads/writes outstanding,
handshake counts since GO). New `dbg_state` ports on mem_engine, warp_pool,
simt_accel, l1_dcache; sizes `DBG_ME`, `DBG_POOL`, `DBG_L1` in simtix_pkg.
`tb_ps_top` reads the window after each kernel and checks it is idle (275 checks).
Debug build started (`tagdbg`: `simtix_ps_zcu102_dbg/`, `build_ps_zcu102_dbg.log`).

## 2026-10-31 and 2026-11-02

**Debug build on the board** (WNS +0.497 ns, 86,162 LUTs): five launches, five hangs,
all in the first kernel (reduce_shfl, N = 1024). The window showed the same state
each time: memory-engine context 0 busy with every lane sent, no tag in use, the L1
idle, AXI balanced (AR = R = 128, AW = B = 128 or 127, the store in DDR correct),
but its count of outstanding requests `c_cnt[0]` = 2 or 6 instead of 0, so the
context never finished.

**Gate-level simulation of the board netlist reproduces it.** `tb_ps_top` on
`system_simt_0_0_sim_netlist.v` behind a shim with the RTL top's ports. Three
testbench changes were needed before the netlist ran at all: hold reset past the
100 ns global set/reset of `glbl`; wait a few cycles after reset, because
`simt_ps_wrap` synchronises the reset release (2 flip-flops) and the first AXI-Lite
write was otherwise lost; and delay every netlist output by 0.5 ns, so that the
testbench (which drives and samples 1 ns after the edge) sees the values the RTL
gives (1 ns made each write response one cycle late, shifted the run by 133 cycles
and, through the memory model's per-cycle random stalls, changed the cycle counts).
The netlist then hangs like the board (AR 128, AW 127) while the RTL passes.

**Cause: Vivado 2025.1 builds the context counter wrongly.** A trace of the
memory-engine debug words on every change, in the RTL and in the netlist (the
OOC netlist keeps the hierarchy and the `acc_dbg` nets), differs from the first
requests on: in the netlist `c_cnt[0]` goes 1, 3, 7, F as contexts 0-3 send, i.e.
bit k toggles with context k's request. `c_cnt_n[c] = c_cnt[c] + (TW+1)'(c_here[c]
&& !rsp_byp) - (TW+1)'(c_rhere[c] && !rsp_byp)`, in a loop over the contexts with
`rsp_byp` constant 0 (BYP = 0 on the board), is built for c = 0 as
`c_cnt[0] + c_here - c_rhere` with the whole vector of all contexts' bits. Other
contexts are correct; xsim and Verilator simulate the line as written.
A first fix (no variables declared inside loop bodies) changed nothing.
**Fix** (`mem_engine.sv`): `c_cnt_n` is computed per context in the `g_ctx`
generate block with two `if` increments, and the BYP = 0 finish test is written
`c_rhere[c] ? c_cnt[c] == 1 : c_cnt[c] == 0`, without width casts. The loop-local
variables stay hoisted into module-level arrays.

**Netlist of the fixed RTL** (OOC synthesis of `simt_ps_wrap`, the IP's settings):
`tb_ps_top` passes (275 checks) with cycle counts equal to the RTL (reduce 4045,
histogram 3845, rerun 4050) and a trace identical to the RTL's.

**ZCU102 build of the fix** (`tagfix`, keeps the debug window): WNS +0.235 ns at
100 MHz, 84,007 LUTs (30.7%), 33,226 FFs, 16 BRAM tiles, 72 DSPs, 4.597 W (Vivado
estimate, whole device). Host program built from `simtix_ps_zcu102_fix.xsa`.

**First complete board run** (`docs/zcu102_board_run.txt`): RESULT PASS, 0 errors,
24 kernel/size rows and the power pass of 9 applications (18 rails, idle / SIMTiX /
A53 phases). Run time A53 / SIMTiX (> 1: SIMTiX faster), small / large input:
GEMM-RB 3.59 / 3.42, MLP 2.64 / 2.62, GEMM 1.04 / 0.79, BFS 0.31 / 0.75, SpMV
0.24 / 0.39, stencil 0.35 / 0.36, k-means 0.29 / 0.30, histogram 0.24 / 0.25,
segmented scan 0.08 / 0.08, scan 0.03 / 0.03, reduce 0.06 / 0.05. Sum of the 18
rails: idle 3.03 W, SIMTiX phase 3.33-3.90 W, A53 phase 3.06-3.26 W; the energy
above idle is lower on the A53 for every application (GEMM-RB 43.3 mJ on SIMTiX,
8.3 mJ on the A53; MLP 150.7 and 26.3 mJ), because the idle phase already has the
A53 running and the PL adds 0.3-0.9 W.

## 2026-11-03 and 2026-11-04

Details and tables: `docs/v3_plan.md` (sections of 11-04). Committed and pushed as
`b5a9d98`: the AXI write-order fix, the v3 low-cost speed-up and its board run.

- **11-03.** The B3+B4 board build ran, but the histogram lost atomic updates:
  writes with different AXI IDs, and a read after a write to the same line, completed
  out of order. Fix: one write ID with an in-order tag FIFO in `axi_line_master`, and
  the L1 holds a read miss while a write to its line is in flight; the test slaves
  keep per-ID in-order write responses; `MEM_LATE=1` tests reproduce the bug.
- **11-04 morning.** Kernels `stencil_rb`, `kmeans_u`, `spmv_z`; Zba/Zbb min-max/
  Zicond; memory-engine request/input/resume registers and branch stage B. Build at
  115.37 MHz (`mhz116 retime`): WNS +0.406 ns, 107,658 LUTs. Board: all bit-exact,
  1.2-3.1x faster than B2.
- **11-04 afternoon.** Paper retargeted to v3, everything on the board (user's
  decision). Table I (GPU instruction sets, after Vortex's Table 1, with SIMTiX) added
  to the paper. Build options `lanes/agg/apar`. Host and simulation for five new
  kernels (`conv8`, `embag`, `hashj`, `mandel`, `swat`) with A53 references in CPU
  layouts, an IRAM overlay window, and a fair MLP reference. Board runs: `ser` with
  the new applications, A53 `-O2`/`-O3` runs, the `agg0` bitstream (built, 115.37
  MHz, run). Findings: SIMTiX beats the best A53 on hash join 1.97x, CNN 1.31x,
  GEMM-RB 1.25x, embedding bag 1.21x, BFS 1.19x; the old MLP win (3.85x) came from an
  unvectorizable A53 reference (fair: 0.29x); aggregation gives 2.48x on the histogram
  and 1.80x on contention on the board.
- Pre-build checks for `agg0` and `apar1` (board-size `tb_ps_top` and `tb_apps`
  with late writes, 4/4; regression 38/38; Verilator 5.020 clean) passed before the
  `simt_ps_top` macro change was synthesized.
- `tb_apps` status-poll limit raised from 2M to 20M (Mandelbrot and Smith-Waterman
  at board size run longer than 10M cycles).

## Next (2026-11-05)

1. DONE 11-05: the board-size Mandelbrot / Smith-Waterman simulation passed (67,584
   checks; Mandelbrot 7,885,990 cycles, Smith-Waterman 23,294,046), and the host is
   rebuilt against `fpga/simtix_ps_zcu102_v3b34.xsa` (the workspace holds the `ser`
   bitstream again). DONE 11-06: board run `docs/zcu102_board_run_v3_apps3.txt`,
   Mandelbrot 0.83x and Smith-Waterman 0.57x of the best A53 (v3_plan.md).
2. `apar1` bitstream: build started 11-06 07:23 (log `fpga/build_ps_zcu102_v3apar1.log`);
   then host build against its XSA and a board run. Command, from `fpga/`,
   `vivado -mode batch -nojournal -log build_ps_zcu102_v3apar1.log -source
   create_bd_ps.tcl -tclargs build zcu102 tagv3apar1 warps8 l1kb64 mshr16 mtags16
   apar1 mhz116 retime`, at least 3 GB free first (`wsl --shutdown` frees ~1.2 GB);
   host build against its XSA; board run.
   DONE 11-06: routed 09:14, WNS +0.244 ns (Fmax 118.7 MHz), 114,446 LUT / 50,053 FF /
   16 BRAM / 72 DSP, SIMTiX 1.35 W (Vivado); board run 09:44
   `docs/zcu102_board_run_v3_apar1.txt` PASS, 0 errors. At 262,144 threads, base ->
   ser / par: histogram 2.47x / 3.17x, contention 1.80x / 2.06x, block-shared
   histogram 1.16x / 1.18x, k-means-U 1.07x / 1.08x, k-means 1.02x, BFS 1.00x;
   par/ser at most 1.28x (histogram). Paper: `tab:impl` par row, Sec. AMO text.
   The host workspace `sw/ps_host/ws_zcu102` now holds the apar1 bitstream.
   Ara: `bender checkout` done 11-06 (`baselines/ara/board_plan.md`, Status).
3. Full xsim regression and Verilator after today's `gen_apps.py` (overlay) and
   `tb_apps.sv` (poll limit) changes, before committing.
4. Lane variants (4 and 16 lanes) on the board: kernels per lane count
   (`kernels/apps/build.py --lanes L`), host kernels and `LANES` per build
   (`amo_contend` assumes 8 lanes), simulation in the exact build configuration first.
5. Vortex 3.0 on the ZCU102: `Vortex_axi` in the block design with an AXI-Lite
   control block (DCR writes, reset, busy), a bare-metal host that loads the kernel
   binary into DDR4; 4, 8 and 16 warps, each at the fastest PS clock it meets.
6. Optional: a register-blocked MLP kernel.
7. Paper rewrite for v3 with board data only; both A53 builds; the AMO table from the
   agg0/ser/apar1 boards; the new applications; the A53-reference caveat.
7b. Comparison set for the paper (user's decision 2026-11-05): SIMTiX against
   **CVA6** (RV64GC application core), **Ara** (RVV 1.0 vector unit, which runs
   with CVA6 as its scalar core, so the two share one integration), **Vortex** and
   the **A53**, all on the ZCU102 with board power. CVA6 and Ara: start from the
   pulp-platform/ara system (Ara + CVA6 + AXI), check which lane count fits the
   XCZU9EG (2 or 4 lanes), host control from the A53 as for SIMTiX, kernels in C
   (scalar for CVA6, RVV for Ara) checked against the same A53 references. The
   HetRV work already ran CVA6 under Verilator (`project_hetrv_*` notes).
8. After the paper (user's decision 2026-11-05): a two-core SIMTiX (phase C of
   `docs/v3_plan.md`) rather than a higher clock. The board design uses 39% of the
   LUTs, so two 8-lane cores fit; a higher clock (150 MHz needs an operand-read stage
   across the issue logic, 200+ MHz a redesign) helps compute-bound kernels only,
   not the memory-latency-bound ones.
9. Commit when asked (not `docs/v2_plan.md`; `git add -f` the new `.hex` files:
   `conv8 embag hashj mandel swat`). Redundant run copies that need not be committed:
   `docs/zcu102_board_run_v3b34_prev.txt` (= `_awid`), `_nospmvz.txt`.

## Next (2026-11-02, superseded)

1. Full regression (29) and Verilator 5.020 on the fixed `mem_engine.sv`; commit
   when asked.
2. Board builds, one at a time:
   - B3+B4: `create_bd_ps.tcl -tclargs build zcu102 tagv3b34 warps8 l1kb64 mshr16
     mtags16`, host program, board run;
   - the B5 path list (`paths_at.tcl`, above).
3. Compare the board cycle counts with `sim/board_sim.py` on the current RTL; read
   the prefetch measurement and decide PF.
4. B5: FPU shift-register/retiming, memory-engine request split; then C (multi-core)
   and D (INT8/FP16), and the remaining phase-A kernels (stencil, SpMV, k-means).
5. Commit when asked: the work of 10-26 to 10-29 (not `docs/v2_plan.md`;
   `git add -f kernels/apps/gemm_rb.hex kernels/apps/scan_seg.hex
   kernels/apps/scan_segadd.hex`). Remove the bisect worktree first
   (`git worktree remove --force C:/work/simtix_bisect`); the worktree
   `C:/work/simtix_base` (baseline + B4 sweep) can go too.
6. Paper: the A53 comparison and the v3 results, to discuss with the co-author.

## Uncommitted at the end of 2026-10-29

Everything since commit 2c412d2. Modified: `.gitignore`, `docs/board_zcu104.md`,
`docs/figs/{lanes_speedup,vortex_ratio}.pdf`, `docs/lanes_apps.csv`,
`docs/paper/simtix_tvlsi.tex`, `docs/plot_{lanes,vortex}.py`,
`fpga/{create_bd_ps,impl_mem_engine}.tcl`, `fpga/reports_mem_engine/{ser,par}/*`,
`kernels/apps/build.py`, `rtl/accel/{l1_dcache,mem_engine,simtix_pkg,warp_pool}.sv`,
`rtl/soc/simt_ps_wrap.v`, `sim/{app_sweep,gen_apps,lane_sweep,run_xsim}.py`,
`sw/ps_host/{apps.c,build_vitis.py,power.c,power.h,run_board.tcl}`,
`tests/tb_apps.sv`.

New: `docs/{board_sim.csv,plot_style.py,v3_plan.md,v3_steps.csv,worklog.md,zcu102_a53.md}`,
`docs/zcu102_a53_run*.txt`, `docs/figs/arch_v2_tikz/`,
`docs/figs/{simtix_arch_v2,simtix_arch_v3,simtix_amo}.pdf`, `docs/figs/*.png`,
`docs/paper/simtix_tvlsi.pdf`, `fpga/paths_at.tcl`,
`fpga/reports_mem_engine/ser_{byp0,l4_byp0,l16_byp0}/`, `fpga/reports_ps_v3b2/`,
`kernels/apps/{gemm_rb,scan_seg,scan_segadd}.S` (+ `.hex`, ignored by `*.hex`),
`sim/board_sim.py`, `sw/a53_zcu102/`.

Private, never committed: `docs/v2_plan.md`.

## Uncommitted at the end of 2026-10-28

Modified: `.gitignore`, `docs/figs/lanes_speedup.pdf`, `docs/figs/vortex_ratio.pdf`,
`docs/lanes_apps.csv`, `docs/paper/simtix_tvlsi.tex`, `docs/plot_lanes.py`,
`docs/plot_vortex.py`, `fpga/create_bd_ps.tcl`, `fpga/impl_mem_engine.tcl`,
`fpga/reports_mem_engine/{ser,par}/*`, `kernels/apps/build.py`, `sim/app_sweep.py`,
`sim/gen_apps.py`, `sim/lane_sweep.py`, `sw/ps_host/{apps.c,build_vitis.py,power.c,power.h,run_board.tcl}`,
`tests/tb_apps.sv`.

New: `docs/board_sim.csv`, `docs/figs/arch_v2_tikz/` (generators),
`docs/figs/{simtix_arch_v2,simtix_arch_v3,simtix_amo}.pdf`, `docs/figs/*.png`,
`docs/plot_style.py`, `docs/v3_plan.md`, `docs/worklog.md`, `docs/zcu102_a53.md`,
`docs/zcu102_a53_run*.txt`, `fpga/reports_mem_engine/ser_{byp0,l4_byp0,l16_byp0}/`,
`kernels/apps/gemm_rb.S` (+ `.hex`, ignored by `*.hex`), `sim/board_sim.py`,
`sw/a53_zcu102/`.

Private, never committed: `docs/v2_plan.md`.

## End of 2026-11-06

- apar1 bitstream built and run on the board (PASS); paper AMO text and `tab:impl` par row updated.
- Ara: Bender checkout, Verilator 2-lane `fmatmul` PASS, out-of-context implementation on the
  XCZU9EG: 2 lanes full FPU 177k LUT / 80.7 MHz; 4 lanes FP32/16 does not fit (316.6k LUT, 115%).
  Details in `baselines/ara/board_plan.md` (Status).
- Open decision: board Ara = 2 lanes, full FPU (78.9 MHz) or a 2-lane FP32/16 build first
  (`vivado ... -source synth_ara_ooc.tcl -tclargs 2 hs`, ~1.5 h; may raise the clock).
- Still to do before any commit: xsim regression + Verilator (gen_apps overlay, tb_apps poll
  limit); `git add -f` the new app `.hex` files. Then the `ara_ps_wrap` board wrapper.
- Board host workspace `sw/ps_host/ws_zcu102` holds the apar1 build; rebuild against the ser
  XSA before the next ser run.

## 2026-11-06 evening: Ara board build

- Wrapper `baselines/ara/rtl/ara_ps_top.sv` + `ara_ps_wrap.v`, testbench `tb/ara_ps_tb.*`;
  fmatmul PASSES on the wrapper model (details in `baselines/ara/board_plan.md`, step 3).
- Board build launched 19:08 in its own window: `create_bd_ara.tcl -tclargs build mhz79`
  (78.94 MHz, 2 lanes, full FPU). Block design OK (ara_0 at 0xA000_0000, HP0 64-bit).
  Finish mark: `baselines/ara/create_bd_ara_done.txt`; log `create_bd_ara.log`; reports
  `reports_ps_zcu102/`; XSA `ara_ps_zcu102.xsa`.
- Next: check WNS (if negative: rebuild at mhz75 = 1.5 GHz / 20); then
  `vitis -s baselines/ara/host/build_vitis_ara.py`, then
  `xsdb baselines/ara/host/run_board_ara.tcl` (fmatmul in ara_progs.h; the host prints
  `ARA,<program>,<exit>,<cycles>,<hwcnt>,<us>`).
- 2026-11-06 ~19:20: user asked to turn everything off: the build was STOPPED in synthesis
  (no bitstream). Tomorrow relaunch it from scratch (same command; ~2 h).

## 2026-11-08: Ara on the board

- Ara 2-lane board build relaunched 07:31, finished 11:01: timing met at 78.94 MHz
  (WNS +0.000, WHS +0.007), 182,331 LUT / 63,650 FF / 92.5 BRAM / 130 DSP, 4.514 W est.
- Vitis host built; board run 11:18: fmatmul FP64 PASS, 64x64 in 164,396 cycles
  (3.19 FLOP/cycle, 79.7% of peak), whole program 401,879 cycles / 5.09 ms.
  Details in baselines/ara/board_plan.md; output docs/zcu102_board_run_ara.txt.
- Next: Ara/CVA6 benchmark kernels (scalar for CVA6, RVV for Ara) with the A53 inputs/checks.

## 2026-11-08 (later): Ara/CVA6 benchmark kernels on the board, comparison with SIMTiX

- Kernels in `baselines/ara/kernels/`. Interface: `ak.h`. Scalar CVA6 versions: `ak_scalar.c`
  (the A53 reference loops). RVV versions for Ara: `ak_vector.c`. Self-test and board main:
  `ak_main.c`. Build: `build.sh` (GCC 15.2; `VCC=clang` builds the vector file with
  clang 21 in WSL). Reference model: `qemu_st.sh` (QEMU 10.2 user mode, RVV 1.0). The
  `dbg_*.c` files are probes from the debugging.
- Ara executes legal GCC RVV wrongly in several ways, all found in simulation. The list
  and the workarounds are in the `ak_vector.c` header. In short:
  - compares at LMUL > 1 trap;
  - vcpop and vfirst are wrong;
  - masked operations and mask logic lose elements, hang, or give timing-dependent results;
  - widening `.vx` operations use the whole scalar register;
  - narrowing in place, and reloading spilled registers, give wrong values;
  - GCC auto-vectorization breaks.

  Every kernel passes under QEMU.
- Simulation (wrapper model): 11 of 12 kernels pass. The Mandelbrot kernel deadlocks Ara in
  every form. User decision: go to the board without Ara mandel (the host prints `ara,skip`).
- Host `apps_ara.c` and testbench (`+TMO=` timeout, UART dump on timeout). Board run 19:04,
  output `docs/zcu102_board_run_ara.txt`; the earlier fmatmul-only log is now
  `docs/zcu102_board_run_ara_fmatmul.txt`.
  - CVA6: 24/24 runs correct.
  - Ara: 18 of 22 runs correct.
  - Ara mlp: all logits wrong. Ara swat: half the pairs wrong.
  - These two pass in simulation even at vl = 256. Suspect the host's vector-layout input
    preparation; to do next.
- Comparison table for the paper: `docs/ara_cva6_simtix_comparison.md`, with the CSV from
  `python baselines/ara/compare_simtix.py`.
  - SIMTiX vs Ara at the large sizes: geometric mean 5.98x in time, 4.09x per cycle, over 9 apps.
  - SIMTiX vs CVA6: 21.2x.
- Not committed.

## 2026-11-09: suite 2 on the board, CVA6/Ara divide rounding, Vortex on the board

- **Suite 2 on the ZCU102.** Host programs rebuilt with suite 2 for SIMTiX and for Ara/CVA6.
  - SIMTiX, suites 1 and 2: PASS, 0 errors (`docs/zcu102_board_run_v3_s2.txt`).
  - Ara/CVA6 (`docs/zcu102_board_run_ara_s2.txt`): Ara mandel now runs. Wrong results remain
    for Ara mlp and swat (as on 2026-11-08) and for Black-Scholes on both Ara and CVA6.
  - Large sizes, geometric mean of time against SIMTiX: Ara 4.31x and CVA6 17.2x (9 apps),
    A53 `-O2` 0.60x (10 apps). The A53 is faster than SIMTiX on 8 of the 10 suite-2 apps;
    the paper has to address this.
- **CVA6 and Ara divide and square root are not correctly rounded** (they share the FPU's
  divsqrt unit). On 4,096 random inputs (`baselines/ara/kernels/dbg_divsqrt.c`): fdiv/vfdiv
  wrong on 355 (8.7%), fsqrt/vfsqrt on 284 (6.9%), CVA6 identical to Ara on every input.
  Example: 0x3f33ee4f / 0x40366672 gives 0x3e7c88ca, correct 0x3e7c88cb. This explains the
  identical Black-Scholes failures; the timings stay valid, the paper notes the accuracy.
- **Reference fixes in `kernels/suite2/s2_ref.h`.** `s2_sqrtf` (the A53 `fsqrt` instruction,
  no libm), the Black-Scholes code compiled with `fp-contract=off` and `noinline` (GCC fused
  multiply-adds into the A53 reference). Checked natively and under QEMU aarch64 (0/131,072
  wrong).
- **Ara backprop at 2^19.** The Ara host ran out of arena; under `S2_ARA` the weights are now
  redrawn per mode from the saved RNG state instead of copied (`sw/ps_host/suite2.inc`).
- **Ara mlp/swat on the board.** Still open. The host cache flush and the host layouts are ruled
  out; size is the remaining suspect. `ak_main.c` takes the self-test sizes as macros
  (`AK_ST_MLP_DIMS`, `AK_ST_MLP_BATCH`, `AK_ST_SWAT`); the board-size simulation
  (`build/brd_mlpswat.elf`, about 2 h) was stopped before it finished.
- **Vortex 3.0 on the ZCU102** (`baselines/vortex/board_plan.md`, Done section).
  - xsim of the board configuration (Xilinx FP IPs): gemm and mandel PASS after a testbench fix
    (xsim did not re-evaluate an `always_comb` read channel over a queue; the testbench now has
    a heartbeat and a `+MAXCYC` watchdog).
  - Build 1 h 05 min: 125 MHz, setup slack +1.308 ns; 85,179 LUT / 85,577 FF / 62 BRAM / 48 DSP.
  - Board run: 24/24 correct (`docs/zcu102_board_run_vortex.txt`). On the same code SIMTiX is
    2.98x faster in time and 3.23x per cycle (large sizes, 12 apps); against SIMTiX's best
    kernels 4.11x.
  - Added to the comparison table (`docs/ara_cva6_simtix_comparison.md`, CSV from
    `baselines/ara/compare_simtix.py`).
- **Next.** Paper: the comparison table with Vortex and suite 2, the divsqrt note; switch the
  Ara columns to the 2026-11-09 log; Ara mlp/swat board-size simulation; power for all cores.

## 2026-11-10 — Rodinia, the fast benchmarks (simulation done, board run next)

- **Plan and decisions** in `docs/rodinia_plan.md`: all runnable Rodinia benchmarks (19 of 23),
  FP32 everywhere, CVA6/Ara checked within an ulp or relative tolerance where a kernel divides
  or takes a square root (their divider and square root are not correctly rounded).
- **Eight benchmarks on all four machines** with Rodinia's own data (`sim/rd_data.py`, a
  100.8 MB blob loaded at DDR 0x7000_0000): pathfinder, backprop, bfs (graph65536), hotspot
  (512 and 1024, 2 iterations), nn (42,764 records), hotspot3D (512x512x8, 100 iterations),
  gaussian (`-s 1024`), kmeans (kdd_cup, k = 5, 37 iterations).
  - SIMTiX: new kernels in `kernels/rodinia/`; small and board sizes PASS in simulation.
  - Vortex: ports in `baselines/vortex/simtix_apps`; small and board sizes PASS (simx and the
    PS testbench). Fixed the launch grid, which dropped the last threads when the count was
    not a multiple of 32.
  - Ara/CVA6: `ak_vector_rd.inc`, self-tests `ak_st_rd.inc`. The five Rodinia self-tests pass
    in sequence (0 errors). Gaussian's Fan1 now runs on CVA6's scalar divider: Ara's vector
    Fan1 gave wrong multipliers, or deadlocked, when it ran after nn (`ak_vector.c` header,
    item 7).
- **Hosts built** in Rodinia-only mode (`rodinia` argument, `RD_ONLY`) for SIMTiX, Vortex and
  Ara. `baselines/ara/compare_rodinia.py` turns the three board logs into
  `docs/rodinia_results.csv` (tested on dummy logs).
- **Board, 15:43.** SIMTiX: all nine Rodinia runs correct (`docs/zcu102_board_run_rodinia_simtix.txt`,
  kmeans 37 iterations). Against the A53 (-O2) SIMTiX is faster only on hotspot3D (1.75x); nn
  runs at 0.07x. A power cut stopped the board during the Vortex run.
- **Vortex hang on the board, fixed in the host.** `s2_load_all`/`rd_load_all` wrote SIMTiX's
  kernels to IRAM offsets 0x1000+; Vortex's control block decodes only the low 8 address bits,
  so the words landed on CTRL.reset, START and the DCRs and the first launch never finished.
  The Vortex build now skips both loaders (`apps.c`, `rodinia.inc`); host rebuilt, not yet run.
  (The Vortex PS testbench launches kernels itself, so simulation never ran this host path.)
- **Ara/CVA6 run lost** to a second power cut at about 17:03 (results only in board DDR). The
  three board scripts now copy the console text to `<out>.partial` whenever it grows.
- **Next.** `build_vortex/board_rd_rest.ps1` (Vortex and Ara/CVA6 only), then
  `compare_rodinia.py`, the results document, and the slow Rodinia benchmarks.

## 2026-11-11 — Rodinia on the board: all four machines done

- Ara/CVA6 (09:12), Vortex (09:50, host fix of 2026-11-10 confirmed) and the CVA6 hotspot3D
  rerun (10:06, host built with `rd_sel=0x40`, 1 h per run) all PASS:
  `docs/zcu102_board_run_rodinia_{ara,vortex,ara_hs3d}.txt`. kmeans 37 iterations everywhere.
- `python baselines/ara/compare_rodinia.py` -> `docs/rodinia_results.csv`. Geometric mean of
  time / SIMTiX time over 8 benchmarks: CVA6 14.57, Ara 2.62, Vortex 1.98, A53 0.56. nn is the
  one loss (Ara 0.58, Vortex 0.31). CVA6 hotspot3D 491.6 s (52x).
- Two counter overflows, corrected by compare_rodinia.py from the logs: CVA6 kmeans time
  (32-bit tenths of us: 726.0 s printed as 429.5 s) and Vortex kmeans cycles (8.05e9 summed
  in 32 bits). Hosts now print 64-bit values (`apps_ara.c` report, `apps.c` run_cycles);
  NOT yet rebuilt or compile-checked.
- Ara host: TIMEOUT_S 3600; `rodinia.inc` RD_SEL (bit per benchmark, `rd_sel=<mask>` to
  build_vitis_ara.py, written to src/rd_cfg.h because vitis.bat splits arguments at '=' and
  Vitis kept only the first compile define). Ara board script waits up to 2 h.
- **Documented.** `docs/rodinia_results.md` (machines, inputs, method, tables, correctness,
  observations, problems, reproduction). Paper `docs/paper/simtix_tvlsi.tex`: new Section
  VI-G "Rodinia on Four Machines" with Table VIII (`tab:rodinia`) and references rodinia,
  ara, ara2, cva6 (volume/pages of ara, ara2, cva6 marked TO CHECK). Compiles, 12 pages.
  nn explanation: SIMTiX's one shared divide/sqrt unit (41 cycles per record); Vortex has
  one sqrt unit per lane (`NUM_PES_SQRT = NUM_LANES`).
- **Figure.** `docs/plot_rodinia.py` -> `docs/figs/rodinia_ratio.pdf` (style of plot_vortex.py:
  (a) time, (b) cycles, each machine / SIMTiX, log axis, geometric mean labelled; categorical
  blue/orange/aqua/yellow plus hatching for grayscale). In the paper as Fig. 5 (`fig:rodinia`),
  next to Table VIII. Compiles, 12 pages.
- **Table VIII extended** with GEMM-RB, SpMV-Z, CNN and Mandelbrot on all four machines
  (`docs/ara_cva6_simtix_comparison.csv`; Ara's Mandelbrot from `docs/zcu102_board_run_ara_s2.txt`,
  2026-11-09, after the vid.v fix: 4,553.5 ms, 0 errors). Geometric means now for Rodinia and for
  all twelve: time CVA6 19.9, Ara 3.32, Vortex 2.63, A53 0.85; cycles 13.6, 2.27, 2.85. A53
  column is the -O2 reference (Table VII: faster of -O2/-O3). Fig. 5 stays Rodinia only.
  Still open: the comparison CSV/md read the 2026-11-08 Ara log (Mandelbrot "skip").

## 2026-11-11/12 — RiVEC batch 1 (simulation on SIMTiX, Vortex, Ara/CVA6)

- **Plan and decisions** in `docs/rivec_plan.md`: all 12 RiVEC applications, FP32 on every
  machine, Ara runs RiVEC's own vector code (changes only for Ara bugs, FP32, bare metal,
  each marked). Batch 1: axpy, matmul, spmv, jacobi-2d, pathfinder, blackscholes, lavaMD
  (streamcluster moved to batch 2: its decisions depend on rounding).
- **Reference** `kernels/rivec/rv_ref.h` (per element RiVEC's vector code, its Cephes exp/log;
  sums in serial order): bit-exact with RiVEC's vector code under QEMU
  (`kernels/rivec/qtest/run_qtest.sh`), with RiVEC's shipped results (matmul, pathfinder),
  and with the exact Python model of `sim/gen_rivec.py` (`sim/rv_xcheck.py`).
- **Two bugs in RiVEC:** blackscholes' mask-agnostic masked subtract (46,277 of 65,536 prices
  wrong as written); spmv's 1-based indices and read past the end of x (it computes A^T x;
  17 of its verification values are wrong).
- **SIMTiX:** `kernels/rivec/{axpy_rv,jacobi_rv,bs_rv,lavamd_rv}.S` (+ gemm_rb, spmv_z,
  pathfinder reused); RTL simulation small 11,283 and board 2,644,343 words, 0 errors.
  `tests/tb_apps.sv` loads kernel images up to 1,024 words (bs_rv has 274).
- **Vortex:** ports in `kernel.cpp` (calling `rv_ref.h`); simx and the wrapper testbench pass
  small (2 seeds) and board (matmul: the first 16 rows of the 512^3 product, the whole product
  exceeding the testbench's 200 M-cycle limit per launch).
- **Ara/CVA6:** `baselines/ara/kernels/ak_vector_rv.inc` (RiVEC's code, RiVEC's headers copied
  to `rivec/` with their licences), `ak_st_rv.inc`; the RiVEC self-tests pass under QEMU (spmv
  within 1.2e-7, lavaMD within 1.7e-6 of the row/force magnitude, the rest exact). The run in
  Ara's Verilator model was stopped after 1.5 h for the commit (lavaMD's scalar part is long);
  to be rerun in two parts.
- **Next:** Ara model self-test rerun, host driver `sw/ps_host/rivec.inc` and the `rivec`
  build/board arguments, board session; then batch 2.
