# heavy_div.S  -  SIMTiX M7 energy-study kernel (heavy control divergence)
#
# Three independent single-sided `if`s keyed on the low bits of tid, each with a
# multi-instruction body. Different lane subsets mask off in each region, so a
# large fraction of lane-cycles are masked — the worst case for a non-gated SIMT
# datapath and the best case for divergence-aware lane clock-gating.
#
#   acc = 0
#   (tid & 1) ?  acc += 11; acc += 11; acc += 11    -- 4 of 8 lanes active
#   (tid & 2) ?  acc += 22; acc += 22; acc += 22    -- 4 of 8 lanes active
#   (tid & 4) ?  acc += 44; acc += 44; acc += 44    -- 4 of 8 lanes active
#   C[tid] = acc
#
# => C[tid] = 33*(tid&1) + 66*((tid>>1)&1) + 132*((tid>>2)&1)
#   a0 = tid     a3 = &C
# Each `if` is a forward branch that reconverges at its join (M5 single-sided
# convention), so nesting depth stays at 1 — no stack pressure.
#
# Assemble (rv32i, no compressed):
#   riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o heavy_div.elf heavy_div.S
#   riscv64-unknown-elf-objcopy -O binary heavy_div.elf heavy_div.bin

.section .text
.globl _start
_start:
    addi  t2, x0, 0        # acc = 0
    # ── if (tid & 1) ────────────────────────────────────────────────────────────
    andi  t5, a0, 1
    beq   t5, x0, .L1
    addi  t2, t2, 11
    addi  t2, t2, 11
    addi  t2, t2, 11
.L1:
    # ── if (tid & 2) ────────────────────────────────────────────────────────────
    andi  t5, a0, 2
    beq   t5, x0, .L2
    addi  t2, t2, 22
    addi  t2, t2, 22
    addi  t2, t2, 22
.L2:
    # ── if (tid & 4) ────────────────────────────────────────────────────────────
    andi  t5, a0, 4
    beq   t5, x0, .L3
    addi  t2, t2, 44
    addi  t2, t2, 44
    addi  t2, t2, 44
.L3:
    slli  t6, a0, 2        # tid*4
    add   t6, a3, t6       # &C[tid]
    sw    t2, 0(t6)        # C[tid] = acc
    ecall
