# hashj.S  -  hash-join probe (database), open addressing with linear probing
#
#   The build side is a table of 2^s slots {key, value} (8 bytes; key 0 = empty,
#   load factor at most 1/2) filled by the host. Thread t probes keys[t]:
#       h = (key * 0x9E3779B1) >> (32 - s)
#       while slot[h].key != key and slot[h].key != 0:  h = (h + 1) mod 2^s
#       out[t] = slot[h].value if slot[h].key == key, else 0xFFFFFFFF
#   Every probe is a gather from a random line. The loop has one backward branch
#   (the reconvergence stack's loop case); the hit test after it uses Zicond.
#
#   a0 = tid   a1 = &P   a4 = probes
#   P[0] = &slot  P[1] = &keys  P[2] = &out  P[3] = 32 - s  P[4] = 2^s - 1
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # slots
    lw      s1, 4(a1)          # keys
    lw      s2, 8(a1)          # out
    lw      s3, 12(a1)         # 32 - s
    lw      s4, 16(a1)         # mask
    sh2add  t0, a0, s1
    lw      t1, 0(t0)          # key
    li      t2, 0x9E3779B1
    mul     t3, t1, t2
    srl     t3, t3, s3         # h
1:  sh3add  t4, t3, s0         # &slot[h]
    lw      t6, 0(t4)          # slot key
    addi    t3, t3, 1
    and     t3, t3, s4
    xor     a2, t6, t1         # 0: found
    czero.eqz a5, a2, t6       # 0: found or empty
    bnez    a5, 1b
    lw      a6, 4(t4)          # slot value (same line)
    snez    a3, a2
    neg     a3, a3             # -1 if not found
    czero.nez a6, a6, a2
    or      t5, a6, a3
    sh2add  t0, a0, s2
    sw      t5, 0(t0)
    ecall
