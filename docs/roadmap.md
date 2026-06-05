# SIMTiX roadmap

Each milestone is a self-contained, demoable step. The goal is that the repo is
*always green and always runnable* — every milestone ends with a passing test in
CI, so the GitHub history reads as a clean incremental build.

| # | Milestone | Proves | Status |
|---|-----------|--------|--------|
| **M0** | Repo scaffold + CI + host CPU lints/builds in Verilator | Tooling works end-to-end | ✅ done |
| **M1** | MMIO launch handshake + single-lane kernel execution | Offload + done handshake, one thread runs a real kernel | ✅ done |
| **M2** | Widen to 8 SIMT lanes + banked vector register file | Lockstep data-parallel execution within a warp | ✅ done |
| **M3** | Multiple warps + time-multiplexing + round-robin scheduler | Latency hiding by warp switching | ✅ done |
| **M4** | LSU + memory loads/stores + address coalescing | Realistic memory behaviour (the part that actually costs) | ✅ done |
| **M5** | Control divergence: active mask + reconvergence stack | **True SIMT** (per-thread control flow) | ✅ done |
| **M6** | Shared-memory scratchpad + matmul kernel + benchmark | End-to-end speedup story | ✅ done |
| **M7a** | Divergence-aware lane clock-gating **energy study** ([docs/m7_energy.md](m7_energy.md)) | The novel/research contribution: gating saves 0%→22.5% lane energy as divergence rises | ✅ done |
| **M7b** | FPGA / PPA: OOC Vivado synth of `simt_accel` (area, Fmax, power) on ZCU104 ([docs/m7_energy.md](m7_energy.md#m7b--fpga--ppa-silicon-cost-numbers)) | Real silicon-cost numbers: 170.9k LUT (74%) / 44.1k FF / 24 DSP, Fmax ≈122 MHz, 1.67 W on xczu7ev | ✅ done |
| **M8** | Register file in distributed RAM (LUTRAM) + timing closure ([docs/m8_lutram.md](m8_lutram.md)) | Banking the VRF into LUTRAM cuts LUTs −55% (170.9k→77.0k) and FFs −70% (44.1k→13.3k), and the design now **meets timing** (+2.7 ns @ 100 MHz, ceiling 137 MHz) | ✅ done |
| **M9** | Scratchpad in distributed RAM (LUTRAM) + timing-driven synthesis ([docs/m9_scratchpad.md](m9_scratchpad.md)) | Moving the shared scratchpad to LUTRAM (serialized one-lane-per-cycle engine) removes 8.2k FFs → **4.6k FF (1.0%)**; the smaller netlist lets timing-driven optimization run → **30.1k LUT (13.1%)**, still **meets timing** (+2.25 ns @ 100 MHz, also meets 125 MHz), 0.81 W | ✅ done |
| **M10** | Complete chip: host CPU + accelerator + on-chip shared memory ([docs/m10_chip.md](m10_chip.md)) | A self-contained SoC (`chip_top`) — the CPU boots, programs/launches the accelerator over MMIO, and reads results back from a banked-LUTRAM shared memory (result=964 in ~114 cyc). Whole-chip synth: **34.3k LUT / 6.2k FF / 24 DSP / 0 BRAM, meets 100 MHz** (+0.25 ns), 0.96 W | ✅ done |
| **M11** | Full implementation + bitstream: place & route the whole chip → `chip_top.bit` ([docs/m11_impl.md](m11_impl.md)) | The complete SoC taken through the real device flow (in-context synth → opt → place → phys_opt → route → bitstream) on xczu7ev. **Post-route timing-closed @ 100 MHz** (setup WNS +0.000, hold +0.005, 0 failing of 37,516; 0 errors), 34.9k LUT / 6.1k FF / 24 DSP / 0 BRAM, 1.09 W, and a real 19 MB bitstream | ✅ done |
| **M12** | CPU-side input loading: host populates the working set at runtime ([docs/m12_cpu_input_loading.md](m12_cpu_input_loading.md)) | The driver ROM gains a store-loop preamble that writes A/B into shared memory itself (the memory no longer preloads them), so the passing test **proves** the host did the data movement — the full heterogeneous-SoC flow (CPU writes inputs → launches accel → reads results). result=964 in ~198 cyc | ✅ done |

## Design decisions (locked)

- **Coupling model:** offload accelerator. CPU configures memory-mapped registers
  (kernel PC, base pointers, thread count), sets `GO`, polls `DONE`. The
  accelerator owns its warp scheduler, lanes, VRF, and (later) kernel memory.
- **Toolchain:** SystemVerilog RTL, Verilator for lint + cycle-accurate sim,
  testbenches in SV (cocotb optional later), GitHub Actions CI on every push.
- **Host CPU:** reuse the existing 5-stage pipelined RISC-V core (`rtl/cpu/`),
  attach the accelerator on its data-memory bus via address decode.
- **Kernel ISA:** RV32I subset so kernels assemble with stock `riscv32` GCC; a
  `tid` CSR (and register-convention seeding) provides thread identity.

## The research angle (M7)

Warp scheduling is over-studied; instead the contribution is **divergence-aware
lane gating**: when a branch masks off lanes, clock/power-gate them and quantify
the energy saved across kernels with varying divergence intensity. This fuses the
SIMT divergence machinery (M5) with a measurable PPA result (M7), and is
defensible as a micro-architectural energy study rather than "we re-built a GPU".

## Prior art to position against (read before claiming novelty)

- **Vortex** (Georgia Tech) — full RISC-V GPGPU, ISA extension, OpenCL, taped out.
- **Ventus** — RVV-based GPGPU.
- **Nyuzi / Cyclone** (Jeff Bush) — open SIMT GPGPU; excellent divergence write-up.
- **Simty** — minimal SIMT RISC-V, closest in scope.
- **GPGPU-Sim** (sim), **MIAOW** (AMD ISA).
