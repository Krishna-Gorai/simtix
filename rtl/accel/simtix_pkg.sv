// =============================================================================
// simtix_pkg.sv  -  global parameters, MMIO register map, ISA constants
// =============================================================================
`timescale 1ns/1ps
package simtix_pkg;

  // ── Accelerator configuration ──────────────────────────────────────────────
  // These describe the full machine; some are consumed only in later milestones,
  // so the unused-parameter lint is waived for this forward-looking block.
  /* verilator lint_off UNUSEDPARAM */
  parameter int XLEN       = 32;   // data width
  parameter int NUM_LANES  = 8;    // physical SIMT lanes (M2)
  parameter int WARP_SIZE  = 8;    // threads per warp
  parameter int NUM_WARPS  = 4;    // hardware warp slots (M3)
  /* verilator lint_on UNUSEDPARAM */

  // ── Memory map ──────────────────────────────────────────────────────────────
  // The accelerator occupies one 4 KB page in the host physical address space.
  // soc_top.sv routes data-bus accesses with addr >= MMIO_BASE here (M1).
  /* verilator lint_off UNUSEDPARAM */
  parameter logic [31:0] MMIO_BASE = 32'h8000_0000;  // consumed by soc_top (M1)
  /* verilator lint_on UNUSEDPARAM */

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

endpackage : simtix_pkg
