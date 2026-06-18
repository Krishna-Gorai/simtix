# fpcopy.S  -  M14.0 FP load/store verification kernel.
#   Each thread copies a 32-bit float:  C[i] = A[i]  via the f-register file.
#   flw  loads A[i] into f1 (writes the FP regfile);
#   fsw  stores f1 to C[i] (reads the FP regfile).
#   Proves the M14.0 flw/fsw data path end-to-end, bit-exact, with no FPU.
#   a0 = tid   a1 = &A   a3 = &C
.section .text
.globl _start
_start:
    slli t0, a0, 2        # i*4
    add  t1, a1, t0       # &A[i]
    flw  f1, 0(t1)        # f1 = A[i]   (FP load -> f-regfile)
    add  t2, a3, t0       # &C[i]
    fsw  f1, 0(t2)        # C[i] = f1   (FP store <- f-regfile)
    ecall
