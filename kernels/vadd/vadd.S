# vadd.S  -  SIMTiX reference kernel: element-wise vector add
#
#   C[i] = A[i] + B[i]
#
# The canonical SIMT demo kernel (one thread per element, fully contiguous, no
# divergence). Previously only existed hand-assembled inside the testbenches and
# the on-chip ROM; this is its assembler source of record.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C   a4 = N
#
# Assemble (rv32im, no compressed):
#   riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o vadd.elf vadd.S
#   riscv-none-elf-objcopy -O binary vadd.elf vadd.bin

.section .text
.globl _start
_start:
    slli  t0, a0, 2        # i*4
    add   t1, a1, t0       # &A[i]
    lw    t2, 0(t1)        # A[i]
    add   t3, a2, t0       # &B[i]
    lw    t4, 0(t3)        # B[i]
    add   t2, t2, t4       # A[i] + B[i]
    add   t5, a3, t0       # &C[i]
    sw    t2, 0(t5)        # C[i]
    ecall
