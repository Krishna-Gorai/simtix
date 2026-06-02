# SIMTiX architecture

## 1. System view

The host is the existing 5-stage RISC-V core (`rtl/cpu/`). Its data-memory
interface is the only attach point the accelerator needs:

```
cpu.MemWriteM  cpu.Funct3M  cpu.ALUResultM(addr)  cpu.WriteDataM   ->  bus
cpu.ReadDataM  <-  bus
```

`rtl/soc/soc_top.sv` performs **address decode** on `ALUResultM`:

- addresses `< MMIO_BASE`  → normal data SRAM (`rtl/cpu/data_mem.v`)
- addresses `>= MMIO_BASE` → SIMTiX accelerator MMIO registers

This is exactly how a discrete GPU is mapped into a host's physical address
space. The CPU is otherwise unmodified.

## 2. MMIO register map

Base address `MMIO_BASE = 0x8000_0000` (one 4 KB page). Word offsets:

| Offset | Name        | R/W | Description                                  |
|--------|-------------|-----|----------------------------------------------|
| 0x00   | `KERNEL_PC` | W   | byte address of the kernel's first instruction in kernel memory |
| 0x04   | `BASE_A`    | W   | base pointer, argument 0                     |
| 0x08   | `BASE_B`    | W   | base pointer, argument 1                     |
| 0x0C   | `BASE_C`    | W   | base pointer, argument 2                     |
| 0x10   | `N`         | W   | total thread count to launch                 |
| 0x14   | `CTRL`      | W   | bit0 = `GO` (write 1 to launch)              |
| 0x18   | `STATUS`    | R   | bit0 = `DONE`, bit1 = `BUSY`                 |
| 0x1C   | `CYCLES`    | R   | cycle count of the last kernel (perf)        |

The `GO` write latches the command and starts the command processor. `DONE`
rises when all threads retire; the host polls `STATUS`.

## 3. Accelerator block hierarchy

```
simt_accel
├── mmio_regs          command/status registers (this milestone, M1)
├── cmd_processor      consumes a launched command, generates warps        (M1/M3)
├── warp_scheduler     warp table {pc, mask, state}; picks a ready warp     (M3)
├── fetch_decode       reads kernel mem at warp.pc, decodes RV32I subset    (M1)
├── divergence         active mask + reconvergence (IPDOM) stack            (M5)
├── lane[0..N-1]       ALU datapath (reuses rtl/cpu/alu.v encoding)         (M1/M2)
├── vrf                banked vector register file, indexed (warp,reg,lane) (M2)
├── lsu                per-lane addr-gen, coalescing                        (M4)
└── shared_mem         banked scratchpad                                    (M6)
```

### Execution model (time-multiplexing)

`N` hardware lanes execute `WARP_SIZE` threads in lockstep. If a warp is wider
than the lane count, threads are issued across multiple cycles (time-multiplexing).
When a warp stalls (e.g. on a memory access), the warp scheduler switches to
another ready warp — this is how memory latency is hidden.

## 4. Lane datapath

Each lane is a minimal RV32I execute unit:

```
       ┌────────────┐
tid -> │  VRF slice │  (this lane's registers for the current warp)
       └─────┬──────┘
       rs1,rs2│
       ┌──────▼──────┐
       │    alu.v    │  (reused 4-bit alucontrol encoding)
       └──────┬──────┘
              │ result -> VRF write / LSU address
```

Per-lane state that varies across threads: the VRF slice and the **active mask**
bit. The PC, decoded instruction, and control signals are **shared** across all
lanes in a warp (that is the "single instruction" in SIMT).

## 5. Why the active mask + reconvergence stack matter (M5)

Consider:

```c
if (tid < n) C[tid] = A[tid] + B[tid];
```

Lanes where `tid >= n` must **not** execute the body. SIMT handles this by:

1. evaluating the branch per lane → a divergence mask,
2. pushing the reconvergence point (post-dominator) and the inactive set onto a
   per-warp stack,
3. executing the taken path with the masked subset,
4. popping at the reconvergence PC to re-merge the lanes.

Without this, the design is SIMD, not SIMT. SIMTiX implements it explicitly so
the distinction is real.
