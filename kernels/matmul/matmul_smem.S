# matmul_smem.S  -  SIMTiX M6 benchmark kernel (scratchpad-staged)
#
# Same 8x8 matmul-row as matmul_naive.S, but the shared A_row is staged once in
# the per-warp scratchpad and reused across all K iterations.  The cooperative
# stage is a single coalesced global line (lane col loads A_row[col]); the loop
# then reads A_row from on-chip scratch (0 global traffic for A).
#   a0 = col (tid)      a1 = &A_row      a2 = &B      a3 = &C_row      a4 = NCOL
#   SCRATCH_BASE = 0x4000_0000   (scratch[i] at SCRATCH_BASE + i*4)
#
# Assemble: see matmul_naive.S header (identical flags).

.section .text
.globl _start
_start:
    # ── cooperative stage: scratch[col] = A_row[col] ────────────────────────────
    slli  t6, a0, 2        # col*4
    add   t6, a1, t6       # &A_row[col]
    lw    t1, 0(t6)        # A_row[col]             (one coalesced global line)
    lui   t3, 0x40000      # SCRATCH_BASE
    slli  t6, a0, 2        # col*4
    add   t6, t3, t6       # &scratch[col]
    sw    t1, 0(t6)        # scratch[col] = A_row[col]   (one scratch transaction)
    # ── main loop: read A_row from scratch ──────────────────────────────────────
    addi  t2, x0, 0        # acc = 0
    addi  t0, x0, 0        # k = 0
.Lloop:
    slli  t6, t0, 2        # k*4
    lui   t3, 0x40000      # SCRATCH_BASE
    add   t6, t3, t6       # &scratch[k]
    lw    t1, 0(t6)        # ak = scratch[k]        (scratch broadcast, no global)
    mul   t3, t0, a4       # k*NCOL
    add   t3, t3, a0       # + col
    slli  t3, t3, 2        # *4
    add   t4, a2, t3       # &B[k*NCOL + col]
    lw    t5, 0(t4)        # b = B[...]
    mul   t5, t1, t5       # ak * b
    add   t2, t2, t5       # acc += ak*b
    addi  t0, t0, 1        # k++
    addi  t6, x0, 8        # K
    blt   t0, t6, .Lloop   # if k < K, loop
    slli  t6, a0, 2        # col*4
    add   t6, a3, t6       # &C_row[col]
    sw    t2, 0(t6)        # C_row[col] = acc
    ecall
