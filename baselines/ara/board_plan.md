# Ara and CVA6 on the ZCU102 (plan, 2026-11-06)

Comparison set of the paper (decision 2026-11-05): SIMTiX against CVA6, Ara, Vortex
and the A53, all on the ZCU102 with board power. Ara is the RVV 1.0 vector unit of
pulp-platform; it runs with CVA6 (RV64GC) as its scalar core, so one integration gives
both: CVA6 alone is the same system running scalar code.

Source: `C:\work\ara` (shallow clone of github.com/pulp-platform/ara, 2026-11-06).
Dependencies come through Bender (`Bender.yml`: axi 0.39.1, common_cells 1.22.1,
cva6 `pulp-v2`, tech_cells_generic, apb), checked out into `hardware/deps`.

## Hardware

- `hardware/src/ara_soc.sv` = CVA6 + Ara (`ara_system`) + AXI crossbar + `L2` memory
  (simulation SRAM, `L2NumWords`) + UART (APB) + `ctrl_registers` (`exit_o`,
  `hw_cnt_en_o`). The wide AXI data width is `32 * NrLanes` bits: 64 at 2 lanes,
  128 at 4 lanes (the width of S_AXI_HP0).
- Board wrapper (new, `ara_ps_wrap`): keep `ara_system` and the crossbar; replace
  the `L2` slave with an AXI4 master to HP0 (address offset so that Ara's DRAM base
  maps into the host's DDR4 window); expose the control registers and CVA6's reset
  and boot address through an AXI4-Lite slave for the A53; drop or stub the UART
  (or map it into a DDR mailbox for prints).
- Lane count: decided by an out-of-context synthesis on the XCZU9EG first (each
  lane has a 64-bit FPU; 2 lanes expected to fit easily, 4 possibly). FPU support
  may be cut to single and half precision (`FPUSupport`) to match SIMTiX's FP32.
- Clock: as SIMTiX, the PS divider (1.5 GHz / n); CVA6 on FPGAs typically closes at
  50-100 MHz.

## Host

The A53 copies the CVA6 program (RV64 ELF, linked for Ara's DRAM base) into DDR4,
sets the boot address, releases reset, and polls the exit register (or a DDR
mailbox). CVA6's data cache is write-back: the program must flush it (fence) before
it signals completion; Ara's vector stores go to memory directly (`axi_inval_filter`
invalidates CVA6's cache lines). Cycles come from CVA6's `mcycle` (read by the
program and written to the mailbox) or a counter in the wrapper.

## Kernels

C versions of the applications, compiled with the RISC-V GCC/LLVM of the Ara
toolchain: scalar for CVA6, RVV 1.0 (intrinsics or auto-vectorization) for Ara;
inputs built as `sw/ps_host/apps.c` builds them, outputs checked against the same
A53 references.

## Status

- 2026-11-06: `bender checkout` (Windows `bender.exe` 0.31, from `C:\work\ara`) fetched
  8 dependencies into `hardware/deps` in 1.8 min: apb, axi, common_cells,
  common_verification, cva6 (with submodules), fpnew, fpu_div_sqrt_mvp,
  tech_cells_generic. `hardware/patches/0001-tech-cells-generic-sram.patch` applied
  (`tc_sram.sv`), as `make apply-patches` does.
- Windows checks symlinks out as text files (`config/default.mk`,
  `hardware/tb/dpi/elfloader.cc`, ...), so the simulation runs from a WSL copy,
  `~/ara_wsl/ara`: Ara and each dependency cloned from `C:\work\ara` at the commits
  Bender checked out, CVA6 submodules fetched, the patch applied. File list:
  `bender.exe script flist-plus` with the targets and defines of `hardware/Makefile`
  (2 lanes: `NR_LANES=2 VLEN=2048`), paths rewritten (`C:\work\ara\flist_2l_win.f` ->
  `~/ara_wsl/flist_2l.f`). libelf headers without root: `apt-get download
  libelf-dev` + `dpkg -x` into `~/ara_deps/root`, linked against the installed
  `libelf.so.1`. Compiler g++ 15 instead of clang.
- Verilator: use **5.020** (`~/v2/v5020`, the SIMTiX CI one): Ara verilates in 33 s
  (`--hierarchical`). The oss-cad-suite 5.053 development build took 47 min for the
  lane block and had not finished the top level after 81 min, and its hierarchical
  relaunch needs `MAKEFLAGS=VM_HIER_VERILATOR=.../bin/verilator`. Script:
  `baselines/ara/verilate_2l.sh` (setup: `wsl_setup.sh`, `flist_wsl.py`), log `C:\work\ara\verilate_2l_5020.log`.
- Programs: Ara's GCC path (`COMPILER=gcc` flags) with the Windows xPack
  `riscv-none-elf-gcc` 15.2 (`-march=rv64gcv_zfh_zvfh -mabi=lp64d -mcmodel=medany
  -O3`, `-T link.ld` = `apps/common/arch.link.ld` with `ALIGNMENT` = 4 x lanes),
  no Ara LLVM build. Output in `C:\work\ara\sw_gcc` (`fmatmul.elf`, 64x64x64 data).

- 2026-11-06, step 1 DONE: `fmatmul` (FP64, GCC build) on the 2-lane Verilator
  model of `ara_soc` passes (64x64 result verified, `Core Test *** SUCCESS ***`).
  Cycles: 4x4 458, 8x8 878, 16x16 3,409, 32x32 18,546, 64x64 140,242 =
  3.74 FLOP/cycle, 93.5% of the 2-lane FP64 peak (4 FLOP/cycle). 325,527 cycles in
  101 s (3.2 kHz). Log `C:\work\ara\sw_gcc\fmatmul_2l.log`.

- 2026-11-06, step 2 (out-of-context implementation on the XCZU9EG-2, 8.667 ns clock;
  `synth_ara_ooc.tcl`, top `ara_ooc_top.sv` = `ara_soc` with a 4096-word L2;
  reports `reports_ooc_<tag>/`, logs `ara_ooc_<tag>.log`):
  - 2 lanes, FP64/32/16 (`2l`), routed: whole design 181,685 LUT (66.3%), 62,907 FF,
    100 BRAM. `ara_system` 177,258 LUT / 59,163 FF / 92 BRAM / 130 DSP; Ara 131,698
    LUT (one lane ~53k), CVA6 44,816. WNS -3.727 ns -> Fmax 80.7 MHz; worst path in a
    lane's fpnew (conversion slice -> FMA), 47 levels, 65% routing. Power 2.032 W on
    chip, 1.403 W dynamic (`ara_system` 1.37 W).
  - 4 lanes, FP32/16 only (`4l_hs`): does NOT fit. Synthesis gives 316,580 LUT
    (placer: 315,692 LUT as logic for 274,080 sites, 115%), 89,603 FF, 140 BRAM,
    183 DSP; `place_design` refused (DRC UTLZ-1). Ara 264,472 LUT: a lane 47.5k
    (dropping FP64 saves only 10% per lane), the mask unit grows 9.8k -> 37.7k and
    the load/store unit 7.5k -> 22.6k from 2 to 4 lanes; CVA6 38,394.
  - So the board Ara has 2 lanes (the largest that fits); PS clock 1.5 GHz / 19 =
    78.9 MHz for the full-FPU build.

- 2026-11-06, step 3: board wrapper `rtl/ara_ps_top.sv` (from `ara_soc.sv`: L2 -> AXI4
  master to HP0, Ara's 0x8000_0000 -> DDR 0x4000_0000, 256 MB; UART -> 2 KB buffer;
  AXI4-Lite host registers at 0xA000_0000: run/reset, done, exit, cycle counters) and
  Verilog top `rtl/ara_ps_wrap.v` (64-bit data, 5-bit ID, fixed widths). Testbench
  `tb/ara_ps_tb.sv` + `tb/ara_ps_tb.cpp` (A53 stand-in FSM, DDR model behind
  `axi_delayer` with random stalls on every channel), `verilate_ps.sh`, `run_ps_sim.sh`.
  fmatmul (FP64) PASSES on the wrapper model: 64x64 verified, exit 0, 757,809 cycles,
  AR 6,959 / AW 1,948 / B 1,948, UART text read back. Log
  `C:\work\ara\sw_gcc\fmatmul_ps.log`.
  Board build: `create_bd_ara.tcl -tclargs build mhz79` (1.5 GHz / 19 = 78.95 MHz).
  Host: `host/` (gen_progs.py -> ara_progs.h, main.c, build_vitis_ara.py,
  run_board_ara.tcl -> docs/zcu102_board_run_ara.txt).

## Order

1. Bender checkout; Verilator simulation of `ara_soc` with one of Ara's own apps
   (fmatmul) to have a working baseline.
2. Out-of-context synthesis on the XCZU9EG at 2 and 4 lanes (area, Fmax).
3. Wrapper + testbench (AXI to a DDR model), simulation, then the board build.
4. Host program, kernels, board runs (CVA6 scalar and Ara vector).

- 2026-11-08, step 3 DONE on the board. Build `create_bd_ara.tcl -tclargs build mhz79`
  (07:31-11:01; synthesis 53 min, peak 9.7 GB virtual at write_bitstream): timing MET at
  78.94 MHz, WNS +0.000 ns / WHS +0.007 ns, 0 failing of 187,387 endpoints (routing ended
  at -0.25 ns, post-route phys_opt closed it). Whole design 182,331 LUT (66.5%), 63,650 FF,
  92.5 BRAM, 130 DSP; `ara_system` 177,226 LUT / 59,136 FF / 88+8 BRAM; SmartConnect 696
  LUT. Power (vectorless estimate) 4.514 W on chip: 3.785 dynamic, 0.729 static; ara_0
  1.045 W, PS 2.735 W. Reports `reports_ps_zcu102/`, XSA `ara_ps_zcu102.xsa`.
  Host: Vitis build OK (`ara_host.elf`). Board run 11:18 (`docs/zcu102_board_run_ara.txt`):
  fmatmul FP64 PASS, exit 0, 401,879 cycles = 5,090.5 us. Per size: 4x4 938, 8x8 1,479,
  16x16 5,103, 32x32 21,600, 64x64 164,396 cycles = 3.19 FLOP/cycle (79.7% of the 2-lane
  FP64 peak; ideal-L2 Verilator 140,242 = 93.5%; random-stall wrapper sim 387,418).
  64x64 = 2.08 ms at 78.95 MHz = 252 MFLOP/s.

- 2026-11-08 (later): step 4 run on the board.
  - Kernels: `kernels/` (see `ak_vector.c` header for the Ara restrictions that shape them).
  - Host: `host/apps_ara.c` (ARAK rows).
  - Board run 19:04, output `docs/zcu102_board_run_ara.txt`; the fmatmul-only log is now
    `docs/zcu102_board_run_ara_fmatmul.txt`.
  - CVA6: 24/24 runs correct.
  - Ara: 18/22 runs correct. Wrong: mlp (all logits) and swat (half the pairs), both sizes.
    They pass in the wrapper sim even at vl = 256; check the host's vector-layout inputs.
  - Ara mandel: skipped (deadlocks Ara in simulation; user decision).
  - Comparison with SIMTiX: `docs/ara_cva6_simtix_comparison.md` (`compare_simtix.py`).
