# saxpy.S  -  SIMTiX benchmark kernel: single-precision-style AXPY (integer)
#
#   C[i] = ALPHA * A[i] + B[i]          (ALPHA = 3, hardcoded)
#
# One thread per element (tid = i). Fully contiguous, so each warp's 8 lane
# loads/stores coalesce into one line transaction apiece (memory-bound, the
# canonical streaming kernel). Uses RV32M `mul`. No divergence.
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C   a4 = N
#
# Assemble (rv32im, no compressed):
#   riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o saxpy.elf saxpy.S
#   riscv-none-elf-objcopy -O binary saxpy.elf saxpy.bin

.section .text
.globl _start
_start:
    slli  t0, a0, 2        # i*4 (byte offset)
    add   t1, a1, t0       # &A[i]
    lw    t2, 0(t1)        # A[i]
    add   t3, a2, t0       # &B[i]
    lw    t4, 0(t3)        # B[i]
    addi  t5, x0, 3        # alpha = 3
    mul   t2, t2, t5       # alpha*A[i]
    add   t2, t2, t4       # + B[i]
    add   t6, a3, t0       # &C[i]
    sw    t2, 0(t6)        # C[i] = alpha*A[i] + B[i]
    ecall
