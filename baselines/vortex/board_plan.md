# Vortex 3.0 on the ZCU102 (plan, 2026-11-05)

Goal: run the same applications on Vortex as a PS peripheral of the ZCU102, in the same
block design as SIMTiX (A53 host, DDR4 through S_AXI_HP0), at 4, 8 and 16 warps of 8
threads, each at the fastest PS clock it meets, with board power.

## Hardware

- Top: Vortex's `Vortex_axi` (hw/rtl/afu, staged in `C:\work\vortex_syn\*\project_1\src`).
  Ports: one AXI4 master per bank (`AXI_NUM_BANKS` = 1), the DCR request/response
  (`dcr_req_valid/rw/addr/data`, `dcr_rsp_valid/data`), `start`, `busy`.
- Memory width: `VX_CFG_PLATFORM_MEMORY_DATA_SIZE=16` (128 bits), as the `bus128` runs,
  so the master matches the 128-bit HP0 port without a width converter. Address 32 bits,
  `PLATFORM_MEMORY_NUM_BANKS=1`.
- Defines as the out-of-context builds (`sources.txt`): `XLEN_32`, `NUM_CORES=1`,
  `NUM_WARPS=4|8|16`, `NUM_THREADS=8`, `EXT_A_ENABLE`, `FPU_TYPE_DSP` (Xilinx FP IPs:
  regenerate the IP `.xci` for xczu9eg-ffvb1156-2-e), `SYNTHESIS`, `VIVADO`, `NDEBUG`.
- New wrapper `vortex_ps_wrap.v` (flat Verilog ports for a block-design module
  reference; unpacked-array ports of `Vortex_axi` are flattened inside):
  - AXI4-Lite slave registers: CTRL (bit 0 reset, bit 1 start pulse), STATUS (bit 0
    busy), DCR_ADDR, DCR_DATA (a write issues a DCR write), DCR_RDATA (read via
    `dcr_req_rw`), CYCLES (counted from start to not-busy), and a sticky AXI error bit.
  - The AXI4 master passes straight through to HP0 (the AXI ID width of
    `VX_MEM_TAG_WIDTH` must be set on the cell explicitly: see the IDW lesson of
    `simt_ps_wrap`).
- Block design: a copy of `fpga/create_bd_ps.tcl` with the Vortex wrapper in place of
  `simt_ps_wrap`; the same PS settings, `mhz<n>` and `retime` options.

## Host (bare metal on the A53)

The Vortex runtime launches through the kernel management unit (KMU): a list of DCR
writes, then `start`, then wait for `busy` low (`sw/runtime/common/queue.cpp`,
`vx_enqueue_launch`). Per launch:

| DCR | Value |
|---|---|
| `KMU_STARTUP_ADDR0/1` | program image base (`__vx_cta_entry` is linked there) |
| `KMU_KERNEL_ENTRY0/1` | the kernel function's PC (`main` in `kernel.cpp`) |
| `KMU_STARTUP_ARG0/1` | device address of the argument blob (`kernel_arg_t`) |
| `KMU_BLOCK_DIM_X/Y/Z` | block (threads), 1, 1 |
| `KMU_GRID_DIM_X/Y/Z` | grid (blocks), 1, 1 |
| `KMU_LMEM_SIZE` | local memory per block (scan: 4 bytes per warp) |
| `KMU_BLOCK_SIZE` | block_x * block_y * block_z |
| `KMU_WARP_STEP_X/Y/Z` | `NUM_THREADS % block_x`, 0, 0 |
| `KMU_CLUSTER_DIM_X/Y/Z` | 1, 1, 1 (unless the launch sets them) |

`.vxbin` (`sw/runtime/common/module.cpp`): `min_vma` (8 bytes LE), `max_vma` (8
bytes), the binary, and an optional symbol-table footer ending in the magic
`VXSYMTAB` (entries `{name_off:4, name_len:2, pad:2, pc:8}`, then `n_symbols:4`).
The host copies the binary to `min_vma` in DDR4, zero-fills up to `max_vma`, and
takes `main`'s PC from the footer (or `min_vma` without one). `min_vma` must lie in
the DDR4 range the host leaves free (the board host's arena is 0x1000_0000-0x1FFF_FFFF;
Vortex's default link address must be checked against it).

**Vortex's L1 data cache is write-back.** After a kernel the runtime issues a cache
flush (`VX_DCR_BASE_CACHE_FLUSH`, a DCR write, then wait for `busy` low) before the
host reads results; the bare-metal host must do the same, and the timed accelerator
interval should include the flush (SIMTiX writes through, so its results are in DDR4
at DONE).

Still to read: how the runtime reads `MCYCLE` / `MINSTRET` through the MPM DCRs (for
per-launch cycles and instructions; the wrapper's own cycle counter is enough for
time), and whether the MMU DCRs must be set (`VX_DCR_MMU_SATP_*`, written at device
open when the MMU is configured; bare physical addressing expected with the defaults).

Applications: the board host builds each application's input as `apps.c` does and
fills the kernel's parameter block (the same layout as the SIMTiX kernels:
`baselines/vortex/simtix_apps/kernel.cpp` reads `kernel_arg_t {app, params, threads}`),
so each output is compared against the same A53 reference. New applications (CNN,
embedding bag, hash join, Mandelbrot, Smith-Waterman) need Vortex ports in
`kernel.cpp` first, checked in rtlsim.

## Order

1. Wrapper + testbench with Vortex RTL in xsim (DCR writes, one launch of a small
   kernel from a `.vxbin` image), then Verilator; sim-before-synth.
2. Block design and build for 4 warps at 100 MHz; then the clock (PS dividers of
   1.5 GHz: 125, 136.4 or 150 MHz).
3. Host program and board run; then 8 and 16 warps.

## Status (2026-11-09)

- **Apps.** All twelve apps are now ported to Vortex.
  - New ports in `simtix_apps/kernel.cpp`: conv8, embag, hashj, mandel, swat.
  - `main.cpp` now maps the manifest's `KERNEL` lines to apps by file name. The v3 slots
    are instruction-RAM offsets, and the overlay kernels share one slot.
  - The v3 SIMTiX variants are skipped.
  - Results, small cases at 8 warps x 8 threads, all bit-exact:
    - simx: `build_vortex/vx_simx_w8.log`.
    - rtlsim at the board configuration (128-bit bus, Xilinx FP latencies):
      `build_vortex/vx_rtl_w8_bus128_ip.log`.
- **Configuration for the board.** 1 core, 8 warps x 8 threads (as SIMTiX v3), RV32IMAF + A.
  `FPU_TYPE=DSP` (Vortex's FPGA default, Xilinx FP IPs): check it in xsim before synthesis.
  The Verilator testbench uses Vortex's simulation FPU.
- **Wrapper `rtl/vortex_ps_top.sv`.** `Vortex_axi` with `AXI_DATA_WIDTH=128` (its own
  512->128 adapter). Address windows to DDR 0x4000_0000 + {0, 0x1000_0000, 0x2000_0000}:
  - Vortex 0x0xxx_xxxx: I/O and data;
  - Vortex 0x8xxx_xxxx: code;
  - Vortex 0xFxxx_xxxx: stacks.

  Host registers: CTRL reset, START, STATUS busy/dcr_rsp/addr_err, DCR address, write and
  read, read data, busy-cycle counter, INFO, AXI counters.
- **Read IDs.** Vortex's data adapter splits a 64 B line into four 128-bit reads with
  different IDs and asserts that the data returns in order. The PS interconnect does not
  promise that, so the wrapper sends every read with ARID 0 and puts the original IDs back
  from a FIFO. Writes are already all AWID 0, and `VX_mem_to_axi` holds a read to an address
  with an unanswered write.
- **Host sequence** (checked in the testbench):
  1. Write the KMU DCRs: STARTUP_ADDR = .vxbin `min_vma`, KERNEL_ENTRY = `main` from the
     VXSYMTAB footer, STARTUP_ARG = kernel_arg_t address, block/grid, LMEM, BLOCK_SIZE,
     WARP_STEP_X = threads % block, CLUSTER = 1.
  2. START, then poll STATUS.busy.
  3. Flush: DCR read of `VX_DCR_BASE_CACHE_FLUSH` with data 0 (core index), wait for
     STATUS.dcr_rsp. The L1 is write-back: `DCACHE_WRITEBACK` = 1 with one core and no L2.
- **Testbench `tb/vx_ps_tb.cpp`** (`tb/build_tb.sh`, Verilator 5.050 in WSL, built in
  `~/v2/vortex/build/sim/vxps`).
  - It talks to the wrapper only through its registers.
  - DDR model: random stalls, reads of different IDs out of order, write data committed
    only at B.
  - It replays the `gen_apps` manifests with a gold check.
  - gemm 32x32 PASSES: 56,341 cycles plus a 1,338-cycle flush.
- **Done (2026-11-09).**
  1. All cases through the wrapper with two seeds (`build_vortex/pstb_seed1.log`, `pstb_seed7.log`):
     PASS.
  2. Board-size cases (`build_vortex/pstb_board.log`): 12/12 PASS.
  3. xsim with `FPU_TYPE=DSP` (`tb/sim_xsim_vortex.tcl`, `tb/run_xsim_cases.ps1`): gemm 32x32x32
     PASS (58,427 cycles), mandel 32x16x64 PASS (138,674 cycles). The first runs hung in the
     testbench, not the design: xsim did not re-evaluate the DDR model's `always_comb` read
     channel over a queue. It is now driven from the clocked block, and the testbench prints a
     heartbeat every 10,000 cycles and stops at `+MAXCYC` (default 2M).
  4. Block design and build (`create_bd_vortex.tcl build`, 1 h 05 min): 125 MHz, setup slack
     +1.308 ns, hold +0.007 ns. 85,179 LUT / 85,577 FF / 62 BRAM / 48 DSP (Vortex_axi 84,185
     LUT); Vivado power estimate 5.020 W. Reports in `reports_ps_zcu102/`.
  5. A53 host (`host/main_vortex.c` with `sw/ps_host/apps.c -DSIMTIX_VORTEX`,
     `host/build_vitis_vortex.py`).
  6. Board run 2026-11-09 23:23 (`host/run_board_vortex.tcl`): all 24 runs (12 apps x 2 sizes)
     correct, `docs/zcu102_board_run_vortex.txt`. On the same code SIMTiX is 2.98x faster in
     time (3.23x per cycle), geometric mean at the large sizes; table in
     `docs/ara_cva6_simtix_comparison.md`.
- **Open.** Suite 2 has no Vortex ports. The board power readings (`POWER` rows) are not
  analysed yet.
