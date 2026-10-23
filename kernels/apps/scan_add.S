# scan_add.S  -  second pass of a multi-block scan
#
#   out[t] += bscan[b - 1] for t in 32-thread block b > 0, where bscan is the
#   inclusive scan of the block totals written by scan.S.
#
#   a0 = tid   a1 = &P   a4 = threads
#   P[0] = &out   P[1] = &bscan
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # out
    lw      s1, 4(a1)          # bscan
    srli    t0, a0, 5          # block
    beqz    t0, 1f
    addi    t0, t0, -1
    slli    t0, t0, 2
    add     t0, s1, t0
    lw      t1, 0(t0)          # total of the blocks before this one
    slli    t2, a0, 2
    add     t2, s0, t2
    lw      t3, 0(t2)
    add     t3, t3, t1
    sw      t3, 0(t2)
1:  ecall
