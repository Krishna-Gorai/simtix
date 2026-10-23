# amo_contend.S  -  global AMOs that collide within a warp, with return values
#
#   v = A[tid], b = v & 3; warp w = tid / 8 owns 16 words K = B + 64*w:
#     C[4*tid+0] = amoadd.w (&K[b],      v)
#     C[4*tid+1] = amomax.w (&K[4 + b],  v)
#     C[4*tid+2] = amoswap.w(&K[8 + b],  tid)
#   Lanes of one warp with the same b hit the same word; no two warps share a
#   word, so every returned value is fixed by the order within the warp.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli  t0, a0, 2
    add   t1, a1, t0
    lw    s1, 0(t1)        # v
    andi  t2, s1, 3
    slli  t2, t2, 2        # 4*b
    srli  t3, a0, 3
    slli  t3, t3, 6        # 64*w
    add   t3, a2, t3
    add   s0, t3, t2       # &K[b]
    slli  t0, a0, 4
    add   s2, a3, t0       # &C[4*tid]
    amoadd.w  t4, s1, (s0)
    sw    t4, 0(s2)
    addi  s3, s0, 16
    amomax.w  t4, s1, (s3)
    sw    t4, 4(s2)
    addi  s3, s0, 32
    amoswap.w t4, a0, (s3)
    sw    t4, 8(s2)
    ecall
