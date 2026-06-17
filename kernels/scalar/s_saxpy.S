# s_saxpy.S  -  scalar RV32I baseline for saxpy:  C[i] = 3*A[i] + B[i]
#
# The host CPU is pure RV32I (no `mul`), so the constant multiply 3*A is done as
# (A<<1)+A — the natural scalar lowering.  See s_vadd.S for the harness contract.
#   A @ 0x2000   B @ 0x4000   C @ 0x6000   N @ 0x1000

.section .text
.globl _start
_start:
    lui   a1, 0x2
    lui   a2, 0x4
    lui   a3, 0x6
    lui   t6, 0x1
    lw    a4, 0(t6)        # N
    li    t0, 0
.Lloop:
    slli  t1, t0, 2
    add   t2, a1, t1
    lw    t3, 0(t2)        # A[i]
    slli  t4, t3, 1        # 2*A
    add   t3, t4, t3       # 3*A
    add   t4, a2, t1
    lw    t5, 0(t4)        # B[i]
    add   t3, t3, t5       # 3*A + B
    add   t2, a3, t1
    sw    t3, 0(t2)
    addi  t0, t0, 1
    blt   t0, a4, .Lloop
    lui   t1, 0x90000
    sw    t0, 0(t1)
.Lhalt:
    j     .Lhalt
