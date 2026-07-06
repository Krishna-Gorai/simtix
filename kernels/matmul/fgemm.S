# fgemm.S  -  FP32 GEMM row  (the floating-point twin of matmul_smem.S)  [DRAFT]
#
# One warp (8 lanes) computes one output row of an 8x8 single-precision matmul;
# each lane produces one output column:
#     C_row[col] = sum_{k=0..7} A_row[k] * B[k*8 + col]      (NCOL = 8, hardcoded)
# A_row is staged once in the per-warp scratchpad (one coalesced global line) and
# reused across the K loop; the accumulation is a real fused multiply-add (fmadd.s),
# so this is the MLP/conv inner product the integer matmul kernels only approximate.
# NCOL is fixed at 8 (like matmul_naive's K=8) so the kernel needs only the three
# base pointers the launch ABI provides (a0=tid, a1/a2/a3).
#   a0 = col (tid)   a1 = &A_row (8 words)   a2 = &B (8x8 row-major)   a3 = &C_row
#   SCRATCH_BASE = 0x4000_0000
#   fmadd.s rd, rs1, rs2, rs3  ==  rd = rs1*rs2 + rs3
#
# Assemble (needs the F extension for flw/fsw/fmadd, M for the address multiply):
#   riscv64-unknown-elf-gcc -march=rv32imf -mabi=ilp32f -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o fgemm.elf fgemm.S
#   riscv64-unknown-elf-objcopy -O binary fgemm.elf fgemm.bin

.section .text
.globl _start
_start:
    # ── cooperative stage: scratch[col] = A_row[col]  (one coalesced global line) ──
    slli    t6, a0, 2          # col*4
    add     t6, a1, t6         # &A_row[col]
    flw     f1, 0(t6)          # A_row[col]
    lui     t3, 0x40000        # SCRATCH_BASE
    slli    t6, a0, 2          # col*4
    add     t6, t3, t6         # &scratch[col]
    fsw     f1, 0(t6)          # scratch[col] = A_row[col]
    # ── main loop: acc += scratch[k] * B[k*NCOL+col] ──────────────────────────────
    fmv.w.x f6, x0             # acc = +0.0
    addi    t0, x0, 0          # k = 0
.Lloop:
    slli    t6, t0, 2          # k*4
    lui     t3, 0x40000        # SCRATCH_BASE
    add     t6, t3, t6         # &scratch[k]
    flw     f1, 0(t6)          # ak = A_row[k]   (on-chip broadcast, 0 global)
    slli    t3, t0, 3          # k*8   (NCOL = 8)
    add     t3, t3, a0         # + col
    slli    t3, t3, 2          # *4
    add     t4, a2, t3         # &B[k*NCOL + col]
    flw     f2, 0(t4)          # b = B[...]
    fmadd.s f6, f1, f2, f6     # acc = ak*b + acc   (fused)
    addi    t0, t0, 1          # k++
    addi    t6, x0, 8          # K
    blt     t0, t6, .Lloop     # if k < K, loop
    slli    t6, a0, 2          # col*4
    add     t6, a3, t6         # &C_row[col]
    fsw     f6, 0(t6)          # C_row[col] = acc
    ecall
