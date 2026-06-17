# s_collatz.S  -  scalar RV32I baseline for collatz:  C[i] = Collatz steps of A[i]
#
# The natural scalar version: an inner while(n != 1) loop with a two-sided
# odd/even branch (a scalar core can branch freely, unlike the SIMT engine which
# must mask). 3n+1 via (n<<1)+n; n/2 via >>1 (no `mul`/`div` on RV32I). Seeds in
# A converge well within the accelerator's 32-iter cap, so results match exactly.
#   A @ 0x2000   C @ 0x6000   N @ 0x1000

.section .text
.globl _start
_start:
    lui   a1, 0x2
    lui   a3, 0x6
    lui   t6, 0x1
    lw    a4, 0(t6)        # N
    li    t0, 0            # i = 0
.Lloop:
    slli  t1, t0, 2
    add   t2, a1, t1
    lw    t3, 0(t2)        # n = A[i]
    li    t4, 0            # steps = 0
.Lwhile:
    li    t5, 1
    beq   t3, t5, .Ldone   # while (n != 1)
    andi  t5, t3, 1
    beq   t5, x0, .Leven
    slli  t5, t3, 1        # 2n
    add   t3, t3, t5       # 3n
    addi  t3, t3, 1        # 3n+1
    j     .Lstep
.Leven:
    srli  t3, t3, 1        # n/2
.Lstep:
    addi  t4, t4, 1        # steps++
    j     .Lwhile
.Ldone:
    add   t2, a3, t1
    sw    t4, 0(t2)        # C[i] = steps
    addi  t0, t0, 1
    blt   t0, a4, .Lloop
    lui   t1, 0x90000
    sw    t0, 0(t1)
.Lhalt:
    j     .Lhalt
