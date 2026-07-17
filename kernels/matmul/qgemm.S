# =============================================================================
# qgemm.S — INT8 quantized GEMM tile (AI Tier-2; the pdot8 twin of fgemm.S)
#
# One warp (8 lanes) computes one output row of an 8x8 INT8 matmul; each lane
# produces one INT32 output column:
#     C[row][col] = sum_{k=0..K-1} A[row][k] * B[k][col]            (K = 16)
# The K reduction runs FOUR elements at a time with the custom INT8 packed
# dot-product `pdot8` (custom-0), so the inner loop issues one pdot8 (4 MACs)
# per iteration instead of four scalar mul/add pairs.
#
# SIMT mapping (full 8x8 tile, launch with N = 64 threads):
#     row = tid >> 3     col = tid & 7
#
# Operand layouts (chosen so BOTH loads coalesce):
#   A : 8 x 16 INT8, row-major.  A[row][4*kk..] is ONE word; identical for all
#       lanes of the warp (same row) -> the 8 lane loads hit one address = one
#       broadcast line transaction.
#   B : PRE-PACKED [Kp=4][N=8] words (the standard inference weight layout).
#       Bpacked[kk][col] packs B[4*kk+0..3][col] little-endian into one word.
#       For a fixed kk the 8 columns (lanes) are contiguous -> one coalesced line.
#   C : 8 x 8 INT32, row-major.  C[tid] = C[row][col].
#
#   ABI:  a0 = tid   a1 = &A   a2 = &Bpacked   a3 = &C
#   pdot8 rd,rs1,rs2 (funct3=0, signed x signed):  rd = sum_i s8(rs1.b[i])*s8(rs2.b[i])
#
# Assemble (custom-0 via .insn; M only for the index multiplies):
#   riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o qgemm.elf qgemm.S
# =============================================================================
    .text
    .globl _start
_start:
    srli    t0, a0, 3          # row = tid >> 3
    andi    t1, a0, 7          # col = tid & 7
    slli    t0, t0, 4          # row * 16          (K = 16 bytes per A row)
    add     t0, a1, t0         # &A[row][0]
    slli    t1, t1, 2          # col * 4
    add     t1, a2, t1         # &Bpacked[0][col]
    li      t2, 0              # acc = 0
    li      t3, 0              # kk  = 0
    li      t4, 4              # Kp  = K/4
.Lk:
    slli    t5, t3, 2          # kk * 4            (A word stride = 4 bytes)
    add     t5, t0, t5         # &A[row][4*kk]
    lw      t5, 0(t5)          # a_word = A[row][4kk .. 4kk+3]  (broadcast)
    slli    t6, t3, 5          # kk * 32           (B word stride = N*4 bytes)
    add     t6, t1, t6         # &Bpacked[kk][col]
    lw      t6, 0(t6)          # b_word = B[4kk .. 4kk+3][col]  (coalesced)
    .insn r 0x0B, 0, 0, s0, t5, t6   # pdot8 s0 = sum_i a_i * b_i   (4 INT8 MACs)
    add     t2, t2, s0         # acc += partial dot
    addi    t3, t3, 1          # kk++
    blt     t3, t4, .Lk        # uniform branch (no divergence)
    slli    t5, a0, 2          # tid * 4
    add     t5, a3, t5         # &C[tid]
    sw      t2, 0(t5)          # C[row][col] = acc
    ecall
