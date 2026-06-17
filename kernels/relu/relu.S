# relu.S  -  SIMTiX benchmark kernel: ReLU activation (data-dependent divergence)
#
#   C[i] = max(0, A[i])
#
# One thread per element. The branch outcome depends on the *sign of the data*,
# not on tid: a warp diverges only when it straddles a sign change in A. This is
# the light, data-dependent divergence case for the energy study (contrast with
# the tid-keyed heavy_div microbench). Single-sided forward `if` (M5 convention):
# the non-negative lanes take the forward branch and wait; the negative lanes
# fall through, zero their value, and the warp reconverges at the store.
#   a0 = tid   a1 = &A   a3 = &C   a4 = N
#
# Assemble (rv32im, no compressed):
#   riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o relu.elf relu.S
#   riscv-none-elf-objcopy -O binary relu.elf relu.bin

.section .text
.globl _start
_start:
    slli  t0, a0, 2        # i*4
    add   t1, a1, t0       # &A[i]
    lw    t2, 0(t1)        # x = A[i]
    bge   t2, x0, .Lpos    # if (x >= 0) -> join (non-neg lanes wait here)
    addi  t2, x0, 0        # negative lanes: x = 0
.Lpos:
    add   t6, a3, t0       # &C[i]
    sw    t2, 0(t6)        # C[i] = max(0, A[i])
    ecall
