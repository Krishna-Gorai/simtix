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

## Next (2026-11-02)

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
