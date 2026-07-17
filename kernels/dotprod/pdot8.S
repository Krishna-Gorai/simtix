# =============================================================================
# pdot8.S — INT8 packed dot-product self-test kernel (AI extension, Tier 1)
#
# One thread (lane) per column. Each lane loads its own packed word A[tid] and
# B[tid] (four INT8 values each) and computes the 4-way dot product three ways —
# signed×signed, unsigned×unsigned, signed×unsigned — via the custom `pdot8`
# instruction (custom-0, funct7=0; funct3 = signedness variant). Results are
# stored to three contiguous output regions so the testbench can check each
# variant bit-exact against a software reference.
#
#   ABI (SIMTiX launch): a0 = tid, a1 = &A, a2 = &B, a3 = &C
#   Output layout at &C:  word[tid]      = SS dot   (bytes  0..31)
#                         word[8+tid]    = UU dot   (bytes 32..63)
#                         word[16+tid]   = SU dot   (bytes 64..95)
#
#   pdot8 encoding:  .insn r 0x0B, funct3, funct7, rd, rs1, rs2
#                    funct3: 0 = SS, 1 = UU, 2 = SU     funct7 = 0
# =============================================================================
    .text
    .globl _start
_start:
    slli t0, a0, 2            # t0 = tid * 4  (per-lane word byte-offset)
    add  t1, a1, t0          # &A[tid]
    lw   s0, 0(t1)           # s0 = A[tid]  (4 packed int8)
    add  t3, a2, t0          # &B[tid]
    lw   s1, 0(t3)           # s1 = B[tid]  (4 packed int8)

    .insn r 0x0B, 0, 0, s2, s0, s1    # pdot8   s2, s0, s1   (signed  × signed )
    .insn r 0x0B, 1, 0, s3, s0, s1    # pdot8u  s3, s0, s1   (unsigned× unsigned)
    .insn r 0x0B, 2, 0, s4, s0, s1    # pdot8su s4, s0, s1   (signed  × unsigned)

    add  t6, a3, t0          # &C[tid]
    sw   s2,  0(t6)          # SS result region  (word[tid])
    sw   s3, 32(t6)          # UU result region  (word[8+tid])
    sw   s4, 64(t6)          # SU result region  (word[16+tid])
    ecall                    # signal this warp done
