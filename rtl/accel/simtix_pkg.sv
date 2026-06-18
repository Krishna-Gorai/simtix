// =============================================================================
// simtix_pkg.sv  -  global parameters, MMIO register map, ISA constants
//
// This is a shared constant library imported by every block. Any given
// top-level (the accelerator shell, a standalone lane, the SoC) consumes only a
// subset of these constants, so UNUSEDPARAM is waived package-wide rather than
// per-symbol.
// =============================================================================
`timescale 1ns/1ps

// ── Design-space-exploration overrides (Part-2 DSE sweep) ─────────────────────
// NUM_LANES and NUM_WARPS may be overridden at elaboration with
//   +define+SIMTIX_NUM_LANES=<n>  +define+SIMTIX_NUM_WARPS=<n>
// (both powers of two). Absent any define the defaults below reproduce the
// committed 8-lane / 4-warp configuration exactly, so existing tests and the
// FPGA flow are byte-for-byte unaffected.
`ifndef SIMTIX_NUM_LANES
  `define SIMTIX_NUM_LANES 8
`endif
`ifndef SIMTIX_NUM_WARPS
  `define SIMTIX_NUM_WARPS 4
`endif

package simtix_pkg;

  /* verilator lint_off UNUSEDPARAM */

  // ── Accelerator configuration ──────────────────────────────────────────────
  parameter int XLEN       = 32;                  // data width
  parameter int NUM_LANES  = `SIMTIX_NUM_LANES;   // physical SIMT lanes (M2)
  parameter int WARP_SIZE  = NUM_LANES;           // one warp fills all lanes / issue
  parameter int NUM_WARPS  = `SIMTIX_NUM_WARPS;   // hardware warp slots (M3)

  // ── Coalescing cache line (M4) ───────────────────────────────────────────────
  // The data port serves a whole line per access; the memory engine groups a
  // warp's per-lane accesses by line and spends one transaction per distinct
  // line (a contiguous warp access -> 1 line; a scattered one -> up to NUM_LANES).
  parameter int LINE_WORDS = NUM_LANES;          // words per line (8 = 32-byte line)
  parameter int LINE_BITS  = LINE_WORDS * XLEN;  // 256: line read/write data width
  parameter int LINE_BE    = LINE_WORDS * 4;     // 32 : per-byte write-enable bits
  parameter int LINE_WOFFW = $clog2(LINE_WORDS); // 3  : word index within a line
  parameter int LINE_OFF   = LINE_WOFFW + 2;     // 5  : byte offset within a line

  // ── Shared-memory scratchpad (M6) ────────────────────────────────────────────
  // A small, per-warp on-chip scratchpad. Kernel data accesses whose address
  // falls in the scratchpad aperture (bits[31:30]==2'b01, i.e. SCRATCH_BASE) are
  // serviced from internal SRAM in a single cycle for the whole warp — they never
  // reach the global data port, so staging reused data here cuts global traffic.
  parameter logic [31:0] SCRATCH_BASE  = 32'h4000_0000;
  parameter int          SCRATCH_WORDS = 64;              // 32-bit words per warp
  parameter int          SCRATCH_AW    = $clog2(SCRATCH_WORDS);

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
  parameter logic [3:0] ALU_MUL   = 4'b1011;   // RV32M `mul` (low 32 bits) — M6

  // ── RV32F / Zfh floating-point ISA (M14) ────────────────────────────────────
  // SIMTiX FP support: single-precision (FP32) and half-precision (FP16, NaN-boxed
  // into the low 16 bits of a 32-bit f-register, the Zfh convention). A separate
  // f0..f31 register file holds BOTH formats — so an FP16 value occupies the low
  // half of the same physical register, and we never pay for two files. With this
  // standard layout, `-march=rv32imf` (+ Zfh) emits these instructions directly.
  //   M14.0 wires the f-regfile + decode + flw/fsw (this step).
  //   M14.1+ adds the per-lane FPU (add/sub/mul/FMA/convert/compare).
  //   M14.3  adds the shared div/sqrt SFU.
  parameter int FLEN      = 32;   // f-register width (FP32; FP16 NaN-boxed low 16)
  parameter int NUM_FREGS = 32;

  // Major opcodes (instr[6:0]).
  parameter logic [6:0] OP_LOADFP  = 7'b0000111;  // flw / flh   (funct3 = width)
  parameter logic [6:0] OP_STOREFP = 7'b0100111;  // fsw / fsh
  parameter logic [6:0] OP_FP      = 7'b1010011;  // OP-FP: fadd/fmul/fdiv/fsqrt/...
  parameter logic [6:0] OP_FMADD   = 7'b1000011;  // fmadd.{s,h}
  parameter logic [6:0] OP_FMSUB   = 7'b1000111;  // fmsub.{s,h}
  parameter logic [6:0] OP_FNMSUB  = 7'b1001011;  // fnmsub.{s,h}
  parameter logic [6:0] OP_FNMADD  = 7'b1001111;  // fnmadd.{s,h}

  // OP-FP operation select = funct5 (instr[31:27]); fmt = instr[26:25] picks the
  // format, funct3 = instr[14:12] is the rounding mode (or a sub-select for the
  // sign-inject / min-max / compare / move groups).
  parameter logic [4:0] FP_ADD    = 5'b00000;  // fadd
  parameter logic [4:0] FP_SUB    = 5'b00001;  // fsub
  parameter logic [4:0] FP_MUL    = 5'b00010;  // fmul
  parameter logic [4:0] FP_DIV    = 5'b00011;  // fdiv
  parameter logic [4:0] FP_SQRT   = 5'b01011;  // fsqrt          (rs2 = 0)
  parameter logic [4:0] FP_SGNJ   = 5'b00100;  // fsgnj/jn/jx    (funct3 picks)
  parameter logic [4:0] FP_MINMAX = 5'b00101;  // fmin/fmax      (funct3 picks)
  parameter logic [4:0] FP_CMP    = 5'b10100;  // feq/flt/fle    (funct3 picks)
  parameter logic [4:0] FP_CVT_W  = 5'b11000;  // fcvt.w.s / .wu.s  (float -> int)
  parameter logic [4:0] FP_CVT_S  = 5'b11010;  // fcvt.s.w / .s.wu  (int -> float)
  parameter logic [4:0] FP_CVT_FF = 5'b01000;  // fcvt.s.h / fcvt.h.s (format cast)
  parameter logic [4:0] FP_FMVXW  = 5'b11100;  // fmv.x.w / fclass  (funct3 picks)
  parameter logic [4:0] FP_FMVWX  = 5'b11110;  // fmv.w.x

  // FP format field fmt = instr[26:25].
  parameter logic [1:0] FMT_S = 2'b00;  // single  (FP32)
  parameter logic [1:0] FMT_H = 2'b10;  // half    (FP16)

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
