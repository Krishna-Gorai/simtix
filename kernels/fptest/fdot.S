# fdot.S  -  M14.4 per-warp single-precision dot product (the MLP-neuron primitive).
#   C[w] = sum_{l=0..7} A[8*w+l] * B[8*w+l]    (one output per warp of 8 threads)
#
# Each lane forms its product A[tid]*B[tid] (fmul.s) and stages it in the on-chip
# scratchpad; lane 0 then accumulates the eight products left-to-right (fadd.s) and
# writes the warp's result. This is a fused-free dot/reduction over the scratchpad
# (the building block of a fully-connected layer), exercising fmul + scratchpad +
# an FP cross-lane reduction with divergence (only lane 0 stays active).
#   a0 = tid   a1 = &A   a2 = &B   a3 = &C     SCRATCH_BASE = 0x40000000
.section .text
.globl _start
_start:
    andi    t0, a0, 7          # lane = tid & 7
    slli    t1, t0, 2          # lane*4
    lui     t2, 0x40000        # SCRATCH_BASE
    add     t2, t2, t1         # &scratch[lane]
    slli    t3, a0, 2          # tid*4
    add     t4, a1, t3
    flw     f1, 0(t4)          # A[tid]
    add     t5, a2, t3
    flw     f2, 0(t5)          # B[tid]
    fmul.s  f3, f1, f2         # p = A[tid] * B[tid]
    fsw     f3, 0(t2)          # scratch[lane] = p
    bne     t0, x0, .Ldone     # lanes 1..7 idle (clock-gated)
    # ── lane 0 accumulates scratch[0..7] left-to-right ───────────────────────────
    lui     t2, 0x40000        # &scratch[0]
    fmv.w.x f6, x0             # acc = +0.0
    flw     f4, 0(t2)
    fadd.s  f6, f6, f4         # + scratch[0]
    flw     f4, 4(t2)
    fadd.s  f6, f6, f4         # + scratch[1]
    flw     f4, 8(t2)
    fadd.s  f6, f6, f4         # + scratch[2]
    flw     f4, 12(t2)
    fadd.s  f6, f6, f4         # + scratch[3]
    flw     f4, 16(t2)
    fadd.s  f6, f6, f4         # + scratch[4]
    flw     f4, 20(t2)
    fadd.s  f6, f6, f4         # + scratch[5]
    flw     f4, 24(t2)
    fadd.s  f6, f6, f4         # + scratch[6]
    flw     f4, 28(t2)
    fadd.s  f6, f6, f4         # + scratch[7]
    srli    t3, a0, 3          # warp = tid >> 3
    slli    t3, t3, 2          # warp*4
    add     t4, a3, t3         # &C[warp]
    fsw     f6, 0(t4)          # C[warp] = dot
.Ldone:
    ecall
