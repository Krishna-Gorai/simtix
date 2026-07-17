# SIMTiX kernel ISA & command block

## Kernel ISA

Lanes execute a **subset of RV32I** so kernels can be written and assembled with
the standard toolchain (`riscv32-unknown-elf-gcc -march=rv32i`). The subset grows
with milestones:

| Class      | Instructions                                   | Milestone |
|------------|------------------------------------------------|-----------|
| ALU reg    | `add sub and or xor sll srl sra slt sltu`      | M1        |
| ALU imm    | `addi andi ori xori slli srli srai slti sltiu` | M1        |
| Upper imm  | `lui auipc`                                    | M1        |
| Memory     | `lw sw` (then `lb lh lbu lhu sb sh`)           | M4        |
| Branch     | `beq bne blt bge bltu bgeu` (drives divergence)| M5        |
| Jump       | `jal jalr`                                     | M5        |
| Thread id  | `csrr rd, TID` (CSR 0xCC0, read-only)          | M1        |
| Terminate  | `ecall` (thread retires)                       | M1        |
| Multiply   | `mul` (RV32M, low 32; DSP engine `W_MUL`)      | M6        |
| INT8 dot   | `pdot8 pdot8u pdot8su` (custom-0; DSP `W_DOT`)  | AI-1      |

The lane ALU reuses the `alucontrol` encoding from `rtl/cpu/alu.v`.

### AI extension: INT8 packed dot-product (`pdot8`)

`pdot8` is a custom (custom-0, `opcode = 0x0B`, `funct7 = 0`) R-type instruction:
each of `rs1`/`rs2` holds four packed INT8 values and `rd` receives their 32-bit
4-way dot product, `rd = Σ(i=0..3) ext(rs1.byte[i]) × ext(rs2.byte[i])`. `funct3`
selects signedness: `000` signed×signed (`pdot8`), `001` unsigned×unsigned
(`pdot8u`), `010` signed×unsigned (`pdot8su`, the weight×activation inference
case). Like `mul` it parks on a pipelined DSP engine (`W_DOT`) so the DSP stays
off the critical path. gcc does not emit it — encode with
`.insn r 0x0B, <funct3>, 0, rd, rs1, rs2`. Full spec: [ai1_pdot8.md](ai1_pdot8.md).

### Thread identity

Each thread can read its global id from CSR `TID` (`0xCC0`). For convenience the
dispatcher *also* seeds argument registers at kernel entry by convention:

| Register | Contents at entry |
|----------|-------------------|
| `a0` (x10) | `tid`           |
| `a1` (x11) | `BASE_A`        |
| `a2` (x12) | `BASE_B`        |
| `a3` (x13) | `BASE_C`        |
| `a4` (x14) | `N`             |

### Example: vector add kernel

```asm
# C[tid] = A[tid] + B[tid]   (guarded by tid < N)
vadd_kernel:
    bge   a0, a4, done       # if (tid >= N) skip      (divergence, M5)
    slli  t0, a0, 2          # t0 = tid * 4 (byte offset)
    add   t1, a1, t0         # &A[tid]
    add   t2, a2, t0         # &B[tid]
    add   t3, a3, t0         # &C[tid]
    lw    t4, 0(t1)          # A[tid]
    lw    t5, 0(t2)          # B[tid]
    add   t6, t4, t5
    sw    t6, 0(t3)          # C[tid]
done:
    ecall                    # thread retires
```

## Command block

The host fills the MMIO registers and writes `GO`. The launched command is:

```
struct command {
    uint32_t kernel_pc;   // first instruction of the kernel
    uint32_t base_a;      // argument 0
    uint32_t base_b;      // argument 1
    uint32_t base_c;      // argument 2
    uint32_t n;           // number of threads to launch
};
```

The command processor partitions `n` threads into warps of `WARP_SIZE`, assigns
each a `tid`, and enqueues them to the warp scheduler.
