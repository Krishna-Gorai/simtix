# amo_test.S  -  every RV32A word AMO on a per-thread global word
#
#   M = A + 4*tid (initialised by the host), v = B[tid]
#   for op k in (swap, add, xor, and, or, min, max, minu, maxu):
#       C[16*tid + k] = amo<op>.w(M, v); v = v + 0x1234567
#   the final M is checked by the host
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C
.section .text
.globl _start
_start:
    slli  t0, a0, 2
    add   s0, a1, t0       # M
    add   t1, a2, t0
    lw    s1, 0(t1)        # v
    slli  t0, a0, 6
    add   s2, a3, t0       # &C[16*tid]
    li    s3, 0x1234567
    amoswap.w t2, s1, (s0)
    sw    t2, 0(s2)
    add   s1, s1, s3
    amoadd.w  t2, s1, (s0)
    sw    t2, 4(s2)
    add   s1, s1, s3
    amoxor.w  t2, s1, (s0)
    sw    t2, 8(s2)
    add   s1, s1, s3
    amoand.w  t2, s1, (s0)
    sw    t2, 12(s2)
    add   s1, s1, s3
    amoor.w   t2, s1, (s0)
    sw    t2, 16(s2)
    add   s1, s1, s3
    amomin.w  t2, s1, (s0)
    sw    t2, 20(s2)
    add   s1, s1, s3
    amomax.w  t2, s1, (s0)
    sw    t2, 24(s2)
    add   s1, s1, s3
    amominu.w t2, s1, (s0)
    sw    t2, 28(s2)
    add   s1, s1, s3
    amomaxu.w t2, s1, (s0)
    sw    t2, 32(s2)
    ecall
