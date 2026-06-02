# SIMTiX — a GPU-inspired SIMT accelerator for RISC-V

[![CI](https://github.com/USERNAME/simtix/actions/workflows/ci.yml/badge.svg)](https://github.com/USERNAME/simtix/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**SIMTiX** is an open-source, GPU-inspired **SIMT** (Single-Instruction, Multiple-Threads)
accelerator written in SystemVerilog and attached to a 5-stage pipelined RISC-V
host processor. The host CPU offloads data-parallel kernels (vector add, matrix
multiply, image convolution) to the accelerator over a memory-mapped command
interface — exactly how a real discrete GPU is driven by its host.

This is a from-scratch teaching/research implementation built to expose every
moving part of a modern throughput machine: warps, a warp scheduler that hides
memory latency, time-multiplexed lanes, a banked vector register file, control
divergence with a reconvergence stack, and a banked shared-memory scratchpad.

> ⚠️ **Status: under active construction.** See the [roadmap](docs/roadmap.md).
> Milestone **M0 (scaffold + CI + handshake)** is complete and green; **M1**
> (single-lane kernel execution) is next.

## Why this is not "just a vector unit"

The defining feature of **SIMT** (vs plain SIMD) is **per-thread control flow**:
each thread keeps the illusion of its own program counter, and the hardware
handles data-dependent branches with a per-lane **active mask** and a
**reconvergence stack**. SIMTiX implements this explicitly (milestone M5) — it is
what separates this project from a RISC-V Vector (RVV) core.

## Architecture at a glance

```
            ┌─────────────────────┐         memory-mapped command interface
            │  5-stage RISC-V CPU │   sw kernel_pc / base_a / base_b / base_c / n
            │  (IF ID EX MEM WB)  │   sw 1 -> GO ; poll DONE
            └──────────┬──────────┘
                       │  data bus (addr-decoded: MMIO range -> accelerator)
            ┌──────────▼───────────────────────────────────────────┐
            │                  SIMTiX accelerator                   │
            │  ┌────────────┐  ┌───────────────┐                    │
            │  │ MMIO regs  │→ │ command proc  │  launches warps    │
            │  └────────────┘  └──────┬────────┘                    │
            │                  ┌──────▼────────┐                    │
            │                  │ warp scheduler│ round-robin / GTO  │
            │                  └──────┬────────┘ (hides mem latency)│
            │     ┌───────────────────▼────────────────────┐       │
            │     │ fetch / decode (RV32I subset + tid CSR)  │      │
            │     └───────────────────┬────────────────────┘       │
            │   active mask + reconvergence stack (SIMT divergence) │
            │  ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐    │
            │  │lane0│lane1│lane2│lane3│lane4│lane5│lane6│lane7│    │
            │  └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘    │
            │        banked vector register file (warp,lane)        │
            │        LSU (address coalescing) + shared memory       │
            └───────────────────────────────────────────────────────┘
```

See [docs/architecture.md](docs/architecture.md) for the detailed design and
[docs/isa.md](docs/isa.md) for the kernel ISA and command-block format.

## Programming model

Kernels are written in the **RV32I subset** the lanes implement, so they can be
assembled with the standard `riscv32-unknown-elf-gcc`/`as` toolchain. At launch
the dispatcher seeds each thread with its global thread id and the kernel
arguments by register convention (see [docs/isa.md](docs/isa.md)):

| Register | Contents at kernel entry |
|----------|--------------------------|
| `a0` (x10) | thread id (`tid`)       |
| `a1` (x11) | base address of A        |
| `a2` (x12) | base address of B        |
| `a3` (x13) | base address of C        |
| `a4` (x14) | element count `n`        |

Host side (pseudocode):

```c
ACCEL->kernel_pc = vadd_kernel;
ACCEL->base_a = A; ACCEL->base_b = B; ACCEL->base_c = C;
ACCEL->n = 1024;
ACCEL->go = 1;
while (!ACCEL->done) {}
```

## Build & test (open-source flow, no license required)

Everything runs under [Verilator](https://www.veripool.org/verilator/) — the same
flow GitHub CI uses, so a green badge means the regression passed.

```bash
# lint the whole design
make lint

# run the simulation regression
make test
```

(See [`sim/`](sim) for the Verilator harness and [`tests/`](tests) for the
testbenches.)

## Repository layout

```
rtl/cpu/      5-stage RISC-V host core (reused, synthesizable)
rtl/accel/    SIMT accelerator RTL (the project)
rtl/soc/      SoC top: CPU + accelerator + memory + MMIO address decode
sim/          Verilator build harness / Makefile
tests/        testbenches (SV / cocotb)
kernels/      data-parallel kernels (vadd, sobel, matmul, ...)
docs/         architecture, ISA, roadmap
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
