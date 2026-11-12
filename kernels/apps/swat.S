# swat.S  -  Smith-Waterman local alignment score, affine gaps, one pair per thread
#
#   DNA codes 0..3. Query q (Lq = 4*S) against target t (Lt), match +2, mismatch -1,
#   gap open 3, gap extend 1 (Gotoh):
#       E[i][j] = max(E[i][j-1] - 1, H[i][j-1] - 3)
#       F[i][j] = max(F[i-1][j] - 1, H[i-1][j] - 3)
#       H[i][j] = max(0, H[i-1][j-1] + s(q_i, t_j), E[i][j], F[i][j])
#   with H = 0 and E, F = NEG (-16384) outside the matrix; out[p] = max of H.
#   The query is done in strips of 4 rows: a strip keeps H and E of its rows in
#   registers and walks the whole target; its last row's H and F go to a per-column
#   boundary word (H << 16 | F & 0xFFFF) that the next strip reads.
#
#   Layout, P pairs, stride = 4P bytes (lanes of a warp read one line):
#     T[j][p]   target code of column j, replicated: code * 0x55
#     Q[s][p]   query codes of strip s, rows 4s..4s+3 in bits 0-1, 2-3, 4-5, 6-7
#     B[j][p]   boundary word (scratch)
#   a0 = tid   a1 = &P   a4 = P
#   P[0] = &T  P[1] = &Q  P[2] = &B  P[3] = &out  P[4] = Lt  P[5] = S  P[6] = stride
.section .text
.globl _start
_start:
    lw      s11, 24(a1)        # stride
    li      t3, 0              # strip
    li      a3, 0              # best
2:  lw      t0, 4(a1)          # Q
    sh2add  t0, a0, t0
    mul     t2, t3, s11
    add     t0, t0, t2
    lw      a2, 0(t0)          # query codes of the strip
    li      s0, 0              # H of the strip's rows
    li      s1, 0
    li      s2, 0
    li      s3, 0
    li      s4, -16384         # E
    li      s5, -16384
    li      s6, -16384
    li      s7, -16384
    li      a6, 0              # boundary H of the previous column
    lw      t0, 0(a1)
    sh2add  s8, a0, t0         # &T[0][p]
    lw      t0, 8(a1)
    sh2add  s9, a0, t0         # &B[0][p]
    lw      t0, 16(a1)
    mul     t0, t0, s11
    add     s10, s8, t0        # &T[Lt][p]
1:  lw      t0, 0(s8)
    xor     a7, t0, a2         # 2-bit field i is 0 where q_i = t_j
    lui     t0, 0xc            # H = 0, F = NEG: the row above strip 0
    beqz    t3, 3f
    lw      t0, 0(s9)          # the last row of the strip above
3:  srai    a5, t0, 16         # H above
    slli    a4, t0, 16
    srai    a4, a4, 16         # F above
    mv      t1, a6             # diagonal of row 0
    mv      a6, a5
    .macro cell h, e, up, sh
    addi    t2, \e, -1
    addi    \e, \h, -3
    max     \e, \e, t2         # E
    addi    a4, a4, -1
    addi    t2, \up, -3
    max     a4, a4, t2         # F
    .if \sh
    srli    t2, a7, \sh
    andi    t2, t2, 3
    .else
    andi    t2, a7, 3
    .endif
    seqz    t2, t2
    sh1add  t2, t2, t2
    addi    t2, t2, -1         # +2 / -1
    add     t2, t2, t1         # diagonal + score
    mv      t1, \h             # the next row's diagonal
    max     \h, t2, \e
    max     \h, \h, a4
    max     \h, \h, zero
    max     a3, a3, \h
    .endm
    cell    s0, s4, a5, 0
    cell    s1, s5, s0, 2
    cell    s2, s6, s1, 4
    cell    s3, s7, s2, 6
    slli    t0, s3, 16
    slli    t2, a4, 16
    srli    t2, t2, 16
    or      t0, t0, t2
    sw      t0, 0(s9)          # boundary for the next strip
    add     s8, s8, s11
    add     s9, s9, s11
    bne     s8, s10, 1b
    addi    t3, t3, 1
    lw      t0, 20(a1)
    blt     t3, t0, 2b
    lw      t0, 12(a1)
    sh2add  t0, a0, t0
    sw      a3, 0(t0)
    ecall
