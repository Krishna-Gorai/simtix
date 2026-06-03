# matmul_naive.S  -  SIMTiX M6 benchmark kernel (naive, all-global)
#
# One warp (8 lanes) computes one output row of an 8x8 matmul: each lane is one
# output column.  C[col] = sum_{k=0..7} A_row[k] * B[k*NCOL + col].
#   a0 = col (tid)      a1 = &A_row (8 words)     a2 = &B (8*NCOL row-major)
#   a3 = &C_row (NCOL)  a4 = NCOL                 K = 8 (hardcoded loop bound)
#
# A_row[k] is the SAME address for all 8 lanes (a broadcast), reloaded from
# global memory on every k iteration -> K global line transactions for A.
# matmul_smem.S stages A_row in the scratchpad once and reuses it instead.
#
# Assemble (rv32im, no compressed):
#   riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o matmul_naive.elf matmul_naive.S
#   riscv64-unknown-elf-objcopy -O binary matmul_naive.elf matmul_naive.bin

.section .text
.globl _start
_start:
    addi  t2, x0, 0        # acc = 0
    addi  t0, x0, 0        # k = 0
.Lloop:
    slli  t6, t0, 2        # k*4
    add   t6, a1, t6       # &A_row[k]
    lw    t1, 0(t6)        # ak = A_row[k]          (global broadcast load)
    mul   t3, t0, a4       # k*NCOL
    add   t3, t3, a0       # + col
    slli  t3, t3, 2        # *4
    add   t4, a2, t3       # &B[k*NCOL + col]
    lw    t5, 0(t4)        # b = B[...]
    mul   t5, t1, t5       # ak * b
    add   t2, t2, t5       # acc += ak*b
    addi  t0, t0, 1        # k++
    addi  t6, x0, 8        # K
    blt   t0, t6, .Lloop   # if k < K, loop
    slli  t6, a0, 2        # col*4
    add   t6, a3, t6       # &C_row[col]
    sw    t2, 0(t6)        # C_row[col] = acc
    ecall
