# M10 — Complete chip integration (host CPU + accelerator + shared memory)

Through M9 the accelerator was synthesized **out of context** and the host CPU was
only ever exercised by a testbench that *faked* the memory system — preloading the
kernel and inputs, and reading the results back itself. M10 turns that into a real,
self-contained **system-on-chip**: the reused 5-stage RISC-V host, the SIMTiX SIMT
accelerator, an on-chip **shared memory**, and the CPU **driver program** in ROM,
wired into one top with only `clk`/`rst` and two observable outputs. The chip boots,
offloads a kernel, and reports an answer with no external help.

## What the chip does

On reset the host runs `cpu_driver_rom` and exercises the full offload loop:

1. program the accelerator command block over MMIO (`0x8000_0000`): `kernel_pc`,
   `base_a/b/c`, `N`;
2. set `GO`, poll `STATUS.DONE`;
3. read the `C[0..7]` results **back from shared memory** and sum them;
4. store the sum to the chip result register (`0x9000_0000`), which latches
   `result` and raises `done` at the chip boundary.

For the bundled vector-add kernel the answer is `Σ(A[i]+B[i]) = Σ(110+3i) = 964`,
which the chip produces in ~114 cycles — proving the entire
**CPU ↔ MMIO ↔ accelerator ↔ shared-memory** path in hardware
(`tb_chip_top` drives only clk/rst).

## New modules (`rtl/soc/`)

- **`shared_mem.sv`** — the on-chip replacement for the testbench's fake memory.
  4 KB, split into **8 distributed-RAM (LUTRAM) banks** (bank *b* holds word
  `line*8+b`), so an accelerator *line* access reads one word from each bank in
  parallel without replicating the array — the canonical banked-shared-memory
  layout. It serves three access points: the accelerator data (line R/W), the
  accelerator instruction fetch (word read), and the CPU data port (word R/W).
  Each bank has a single muxed write port (accelerator wins; the masters are
  temporally separated anyway). Contents are preloaded with a synthesizable
  `initial` (Vivado honours distributed-RAM init values), so the memory is always
  ready. **It synthesizes to 0 flip-flops** — the whole 4 KB is LUTRAM.
- **`cpu_driver_rom.sv`** — the host's driver program (29 hand-assembled,
  bit-verified RV32I instructions) as a combinational LUT ROM.
- **`chip_top.sv`** — the integration: RISC-V pipeline + driver ROM + `simt_accel`
  + `shared_mem`, with the data-bus address decode (`0x9..` = result reg,
  `0x8..` = accelerator MMIO, else shared memory) and the result/done register.
  `mem_ready` is tied high (the preloaded RAM never stalls).

## Result — OOC, timing-driven synthesis on xczu7ev (ZCU104), Vivado 2025.1

| Instance | Module | LUTs | LUTRAM | FFs | DSP |
|---|---|---:|---:|---:|---:|
| **chip_top** | whole chip | **34,340 (14.9%)** | 3,348 | **6,171 (1.3%)** | 24 |
| `cpu` | riscv_pipeline | 1,451 | 0 | 1,555 | 0 |
| `u_accel` | simt_accel | 29,892 | 1,428 | 4,583 | 24 |
| `u_mem` | shared_mem | 2,934 | 1,920 | **0** | 0 |

- **Timing: MET at 100 MHz with +0.253 ns** (critical path 9.747 ns → Fmax
  102.6 MHz). Block RAM / URAM: 0 / 0. Power: 0.964 W (0.370 dynamic + 0.594
  static, vectorless).
- The host CPU is small (1.5k LUT / 1.6k FF; the register file alone is 1,024 of
  those FFs). The accelerator dominates (~87 % of LUTs), as expected.
- The **critical path is the accelerator's own** single-cycle compute path
  (`warp-state → 32-bit ALU incl. a DSP multiply → VRF LUTRAM writeback`) — the
  CPU and shared memory are *not* on it. It tightened from the accelerator's
  standalone 7.75 ns (M9) to 9.75 ns, but that delta is routing pessimism in the
  larger netlist (route is 56 % of the path), not a new logic path. The chip still
  meets 100 MHz, which is the target the datapath was designed for.

## Reproduce

```
make -C sim test-chip                                  # full-chip functional test (result=964)
cd fpga && vivado -mode batch -source synth_chip.tcl   # timing-driven OOC PPA of the whole chip
```
