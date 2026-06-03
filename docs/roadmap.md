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
| **M7** | Divergence-aware lane clock-gating energy study + FPGA/PPA | The novel/research contribution + real numbers | ⏳ |

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
