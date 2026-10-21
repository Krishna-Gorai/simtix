# simtix_v2.inc  -  assembler macros for the SIMTiX v2 synchronisation instructions
#
# The warp shuffle and the block barrier live on the RISC-V custom-0 opcode
# (0x0B, R-type); funct7 selects the family (1 = shuffle, 2 = barrier) and, for
# the shuffle, funct3 selects the mode. See rtl/accel/simtix_pkg.sv.
#   shfl_idx  rd, rs1, rs2   rd = rs1 of lane (rs2 mod 8)
#   shfl_up   rd, rs1, rs2   rd = rs1 of lane (l - rs2), own rs1 if out of range
#   shfl_down rd, rs1, rs2   rd = rs1 of lane (l + rs2), own rs1 if out of range
#   shfl_xor  rd, rs1, rs2   rd = rs1 of lane (l ^ rs2), own rs1 if out of range
#   bar                      wait for every live warp of the thread block
# RV32A atomics (amoadd.w etc.) use the standard encoding: assemble with rv32ima.

.macro shfl_idx rd, rs1, rs2
    .insn r 0x0B, 0, 1, \rd, \rs1, \rs2
.endm
.macro shfl_up rd, rs1, rs2
    .insn r 0x0B, 1, 1, \rd, \rs1, \rs2
.endm
.macro shfl_down rd, rs1, rs2
    .insn r 0x0B, 2, 1, \rd, \rs1, \rs2
.endm
.macro shfl_xor rd, rs1, rs2
    .insn r 0x0B, 3, 1, \rd, \rs1, \rs2
.endm
.macro bar
    .insn r 0x0B, 0, 2, x0, x0, x0
.endm
