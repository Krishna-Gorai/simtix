# =============================================================================
# qgemv.S — INT8 matrix-vector product (AI-4; the MLP-layer primitive)
#
# Computes  out[n] = sum_{k=0..K-1} x[k] * W[k][n]   for one input vector x,
# one thread (lane) per output element n. This is a fully-connected layer's
# core: x is the activation vector, W the weight matrix, out the INT32
# pre-activation. K is reduced four elements at a time with `pdot8`.
#
# Generalizes qgemm to M=1 and arbitrary N,K (tiled across warps by launching
# N threads). K is per-layer, so Kp = K/4 is read from a config word; N (the W
# column stride) is the seeded thread count a4.
#
# Layouts (both loads coalesce, as in qgemm):
#   x : int8[K], packed 4/word.  x[4*kk..] is one word, shared by all lanes
#       (same vector) -> one broadcast line per kk.
#   W : PRE-PACKED [Kp][N] words.  Wpacked[kk][n] packs W[4*kk+0..3][n]
#       little-endian at word (kk*N + n); for a fixed kk the N columns are
#       contiguous -> coalesced loads across a warp's lanes.
#   out : int32[N].
#
#   ABI:  a0 = tid(=n)  a1 = &x  a2 = &Wpacked  a3 = &out   a4 = N (seeded)
#   Config: word at byte address 0x100 holds Kp = K/4.
#   pdot8 (funct3=0, signed x signed): rd = sum_i s8(rs1.b[i]) * s8(rs2.b[i])
#
# Assemble:  riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 ... qgemv.S
# =============================================================================
    .text
    .globl _start
_start:
    li      t0, 0x100          # config address
    lw      t1, 0(t0)          # t1 = Kp  (= K/4)
    slli    t2, a0, 2          # n*4
    add     t2, a2, t2         # &Wpacked[0][n]
    slli    t3, a4, 2          # N*4  = W column-stride (bytes) per kk
    mv      t4, a1             # &x[0]  (advances +4 per kk)
    li      t5, 0              # acc = 0
    li      t6, 0              # kk  = 0
.Lk:
    lw      s0, 0(t4)          # x[4kk..4kk+3]        (broadcast)
    lw      s1, 0(t2)          # W[4kk..4kk+3][n]     (coalesced)
    .insn r 0x0B, 0, 0, s2, s0, s1   # pdot8 s2 = sum_i x_i * W_i  (4 MACs)
    add     t5, t5, s2         # acc += partial dot
    addi    t4, t4, 4          # x  += 1 word
    add     t2, t2, t3         # W  += N words
    addi    t6, t6, 1          # kk++
    blt     t6, t1, .Lk        # uniform loop (no divergence)
    slli    s3, a0, 2          # n*4
    add     s3, a3, s3         # &out[n]
    sw      t5, 0(s3)          # out[n] = acc (int32)
    ecall
