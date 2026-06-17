# reduce.S  -  SIMTiX benchmark kernel: per-warp segmented sum
#
#   C[w] = sum_{l=0..7} A[8*w + l]      (one output per warp of 8 threads)
#
# This is a reduction primitive that uses the on-chip scratchpad as an inter-lane
# communication buffer and then a single-lane (lane 0) tree-collapse — exercising
# BOTH the scratchpad path and divergence (only lane 0 stays active for the sum).
# Phases:
#   1. every lane writes its element A[tid] into scratch[lane]   (lane = tid & 7)
#   2. lanes 1..7 take a forward branch to the end and idle (clock-gated)
#   3. lane 0 sums scratch[0..7] and writes C[warp]   (warp = tid >> 3)
# Scratch is per-warp in hardware (addressed by {warp,idx}), so each warp reduces
# its own 8 elements independently.
#   a0 = tid   a1 = &A   a3 = &C   a4 = N        SCRATCH_BASE = 0x40000000
#
# Assemble (rv32im, no compressed):
#   riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o reduce.elf reduce.S
#   riscv-none-elf-objcopy -O binary reduce.elf reduce.bin

.section .text
.globl _start
_start:
    andi  t0, a0, 7        # lane = tid & 7
    slli  t1, t0, 2        # lane*4
    lui   t2, 0x40000      # SCRATCH_BASE (0x4000_0000)
    add   t2, t2, t1       # &scratch[lane]
    slli  t3, a0, 2        # tid*4
    add   t4, a1, t3       # &A[tid]
    lw    t5, 0(t4)        # A[tid]
    sw    t5, 0(t2)        # scratch[lane] = A[tid]
    # ── only lane 0 reduces; lanes 1..7 jump to the end and idle ──────────────
    bne   t0, x0, .Ldone   # if (lane != 0) -> join
    lui   t2, 0x40000      # &scratch[0]
    addi  t6, x0, 0        # acc = 0
    lw    t1, 0(t2)        # scratch[0]
    add   t6, t6, t1
    lw    t1, 4(t2)        # scratch[1]
    add   t6, t6, t1
    lw    t1, 8(t2)        # scratch[2]
    add   t6, t6, t1
    lw    t1, 12(t2)       # scratch[3]
    add   t6, t6, t1
    lw    t1, 16(t2)       # scratch[4]
    add   t6, t6, t1
    lw    t1, 20(t2)       # scratch[5]
    add   t6, t6, t1
    lw    t1, 24(t2)       # scratch[6]
    add   t6, t6, t1
    lw    t1, 28(t2)       # scratch[7]
    add   t6, t6, t1
    srli  t3, a0, 3        # warp = tid >> 3
    slli  t3, t3, 2        # warp*4
    add   t4, a3, t3       # &C[warp]
    sw    t6, 0(t4)        # C[warp] = sum
.Ldone:
    ecall
