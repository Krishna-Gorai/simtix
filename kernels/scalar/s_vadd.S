# s_vadd.S  -  scalar RV32I baseline for vadd:  C[i] = A[i] + B[i]
#
# Runs on the host 5-stage pipeline (rtl/cpu) as a plain loop over i=0..N-1, so a
# `make cpu-bench` run measures the single-core cycle cost of the same work the
# SIMT accelerator does — the measured speedup baseline.  Pointers are hardcoded
# to the harness memory map; N is read from the parameter cell so one image
# serves every problem size.  Completion = store to 0x9000_0000 (harness sentinel).
#
#   A @ 0x2000   B @ 0x4000   C @ 0x6000   N @ 0x1000 (word)
#
# Assemble (rv32i):
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o s_vadd.elf s_vadd.S

.section .text
.globl _start
_start:
    lui   a1, 0x2          # &A = 0x2000
    lui   a2, 0x4          # &B = 0x4000
    lui   a3, 0x6          # &C = 0x6000
    lui   t6, 0x1          # &N = 0x1000
    lw    a4, 0(t6)        # N
    li    t0, 0            # i = 0
.Lloop:
    slli  t1, t0, 2        # i*4
    add   t2, a1, t1
    lw    t3, 0(t2)        # A[i]
    add   t4, a2, t1
    lw    t5, 0(t4)        # B[i]
    add   t3, t3, t5       # A[i]+B[i]
    add   t2, a3, t1
    sw    t3, 0(t2)        # C[i]
    addi  t0, t0, 1
    blt   t0, a4, .Lloop
    lui   t1, 0x90000      # sentinel: signal done to the harness
    sw    t0, 0(t1)
.Lhalt:
    j     .Lhalt
