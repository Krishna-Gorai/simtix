# fir.S  -  SIMTiX benchmark kernel: 3-tap FIR / 1-D convolution
#
#   C[i] = A[i] + 2*A[i+1] + A[i+2]     (weights 1,2,1)
#
# One thread per output element (tid = i). Each lane reads three neighbouring
# inputs, so the warp's A[i+1] / A[i+2] loads straddle line boundaries -> a
# stencil access pattern that only *partially* coalesces (a good contrast to
# saxpy's perfect coalescing). The input array carries a 2-element halo so the
# last lanes can read A[N], A[N+1]. No divergence.
#   a0 = tid   a1 = &A (length N+2)   a3 = &C   a4 = N
#
# Assemble (rv32im, no compressed):
#   riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o fir.elf fir.S
#   riscv-none-elf-objcopy -O binary fir.elf fir.bin

.section .text
.globl _start
_start:
    slli  t0, a0, 2        # i*4
    add   t1, a1, t0       # &A[i]
    lw    t2, 0(t1)        # A[i]
    lw    t3, 4(t1)        # A[i+1]
    lw    t4, 8(t1)        # A[i+2]
    slli  t3, t3, 1        # 2*A[i+1]
    add   t5, t2, t3       # A[i] + 2*A[i+1]
    add   t5, t5, t4       # + A[i+2]
    add   t6, a3, t0       # &C[i]
    sw    t5, 0(t6)        # C[i]
    ecall
