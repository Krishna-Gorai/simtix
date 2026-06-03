// =============================================================================
// simtix_pkg.sv  -  global parameters, MMIO register map, ISA constants
//
// This is a shared constant library imported by every block. Any given
// top-level (the accelerator shell, a standalone lane, the SoC) consumes only a
// subset of these constants, so UNUSEDPARAM is waived package-wide rather than
// per-symbol.
// =============================================================================
`timescale 1ns/1ps
package simtix_pkg;

  /* verilator lint_off UNUSEDPARAM */

  // ── Accelerator configuration ──────────────────────────────────────────────
  parameter int XLEN       = 32;   // data width
  parameter int NUM_LANES  = 8;    // physical SIMT lanes (M2)
  parameter int WARP_SIZE  = 8;    // threads per warp
  parameter int NUM_WARPS  = 4;    // hardware warp slots (M3)

  // ── Coalescing cache line (M4) ───────────────────────────────────────────────
  // The data port serves a whole line per access; the memory engine groups a
  // warp's per-lane accesses by line and spends one transaction per distinct
  // line (a contiguous warp access -> 1 line; a scattered one -> up to NUM_LANES).
  parameter int LINE_WORDS = NUM_LANES;          // words per line (8 = 32-byte line)
  parameter int LINE_BITS  = LINE_WORDS * XLEN;  // 256: line read/write data width
  parameter int LINE_BE    = LINE_WORDS * 4;     // 32 : per-byte write-enable bits
  parameter int LINE_WOFFW = $clog2(LINE_WORDS); // 3  : word index within a line
  parameter int LINE_OFF   = LINE_WOFFW + 2;     // 5  : byte offset within a line

  // ── Memory map ──────────────────────────────────────────────────────────────
  // The accelerator occupies one 4 KB page in the host physical address space.
  // soc_top.sv routes data-bus accesses with addr >= MMIO_BASE here (M1.3).
  parameter logic [31:0] MMIO_BASE = 32'h8000_0000;

  // Word-aligned byte offsets within the page (see docs/architecture.md).
  parameter logic [7:0] REG_KERNEL_PC = 8'h00;  // W: kernel entry address
  parameter logic [7:0] REG_BASE_A    = 8'h04;  // W: argument 0 base pointer
  parameter logic [7:0] REG_BASE_B    = 8'h08;  // W: argument 1 base pointer
  parameter logic [7:0] REG_BASE_C    = 8'h0C;  // W: argument 2 base pointer
  parameter logic [7:0] REG_N         = 8'h10;  // W: thread count to launch
  parameter logic [7:0] REG_CTRL      = 8'h14;  // W: bit0 = GO
  parameter logic [7:0] REG_STATUS    = 8'h18;  // R: bit0 = DONE, bit1 = BUSY
  parameter logic [7:0] REG_CYCLES    = 8'h1C;  // R: cycles of last kernel

  // CTRL bits
  parameter int CTRL_GO_BIT     = 0;
  // STATUS bits
  parameter int STATUS_DONE_BIT = 0;
  parameter int STATUS_BUSY_BIT = 1;

  // ── Kernel ISA (RV32I subset executed by a lane) ────────────────────────────
  // Opcodes (instr[6:0]).
  parameter logic [6:0] OP_LUI    = 7'b0110111;
  parameter logic [6:0] OP_AUIPC  = 7'b0010111;
  parameter logic [6:0] OP_JAL    = 7'b1101111;
  parameter logic [6:0] OP_JALR   = 7'b1100111;
  parameter logic [6:0] OP_BRANCH = 7'b1100011;
  parameter logic [6:0] OP_LOAD   = 7'b0000011;  // M1.2
  parameter logic [6:0] OP_STORE  = 7'b0100011;  // M1.2
  parameter logic [6:0] OP_OPIMM  = 7'b0010011;
  parameter logic [6:0] OP_OP     = 7'b0110011;
  parameter logic [6:0] OP_SYSTEM = 7'b1110011;  // csr / ecall

  // ALU control encoding (mirrors the reused rtl/cpu/alu.v).
  parameter logic [3:0] ALU_ADD   = 4'b0000;
  parameter logic [3:0] ALU_SUB   = 4'b0001;
  parameter logic [3:0] ALU_AND   = 4'b0010;
  parameter logic [3:0] ALU_OR    = 4'b0011;
  parameter logic [3:0] ALU_XOR   = 4'b0100;
  parameter logic [3:0] ALU_SLT   = 4'b0101;
  parameter logic [3:0] ALU_SLTU  = 4'b0110;
  parameter logic [3:0] ALU_SLL   = 4'b0111;
  parameter logic [3:0] ALU_SRL   = 4'b1000;
  parameter logic [3:0] ALU_SRA   = 4'b1001;
  parameter logic [3:0] ALU_PASSB = 4'b1010;

  // Thread-id CSR (read-only): csrr rd, TID
  parameter logic [11:0] CSR_TID = 12'hCC0;

  // Register-convention seeds at kernel entry (see docs/isa.md).
  parameter int ARG_TID = 10;  // a0
  parameter int ARG_A   = 11;  // a1
  parameter int ARG_B   = 12;  // a2
  parameter int ARG_C   = 13;  // a3
  parameter int ARG_N   = 14;  // a4

  /* verilator lint_on UNUSEDPARAM */

endpackage : simtix_pkg
