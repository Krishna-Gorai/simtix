// =============================================================================
// riscv_soc.v  -  RISC-V SoC: 5-stage pipeline + instruction ROM + data SRAM
//
// This is the reusable, fully-synthesizable system. It exposes a plain
// single-ended clock and a run-time-selectable reset_vector so that:
//   * the simulation testbench can drive clk directly and pick any of the
//     hardcoded programs in instr_mem, and
//   * the FPGA top-level (top.v) can wrap it with clock buffers and a fixed
//     reset_vector for synthesis / utilization reporting.
//
//   mem_ready_out is exported so an FPGA pin (LED) can anchor the design and
//   stop opt_design from optimising the whole netlist away.
// =============================================================================
`timescale 1ns/1ps

(* dont_touch = "true" *)
module riscv_soc (
    input  wire        clk,
    input  wire        rst,            // active-high reset
    input  wire [31:0] reset_vector,   // PC start address
    output wire        mem_ready_out,  // data-memory ready (anchor / status)
    // Boundary-observable debug taps: let a post-implementation functional
    // simulation verify the program result at the netlist boundary (internal
    // signals like the register file do not survive flattening).
    output wire        dbg_store_we,   // a store is committing this cycle
    output wire [31:0] dbg_store_data, // data being written to memory
    output wire [31:0] dbg_store_addr  // byte address of the store
);

    // ── Internal wires ────────────────────────────────────────────────────────
    wire [31:0] PCF, InstrF;
    wire [31:0] ALUResultM, WriteDataM, ReadDataM;
    wire        MemWriteM;
    wire [ 2:0] Funct3M;
    wire        mem_ready;

    // ── Pipeline ───────────────────────────────────────────────────────────────
    (* dont_touch = "true" *)
    riscv_pipeline cpu (
        .clk          (clk),
        .rst          (rst),
        .reset_vector (reset_vector),
        .PCF          (PCF),
        .InstrF       (InstrF),
        .ALUResultM   (ALUResultM),
        .WriteDataM   (WriteDataM),
        .ReadDataM    (ReadDataM),
        .MemWriteM    (MemWriteM),
        .Funct3M      (Funct3M),
        .mem_ready    (mem_ready)
    );

    // ── Instruction ROM ──────────────────────────────────────────────────────
    (* dont_touch = "true" *)
    instr_mem imem (
        .addr  (PCF),
        .instr (InstrF)
    );

    // ── Data SRAM ────────────────────────────────────────────────────────────
    (* dont_touch = "true" *)
    data_mem dmem (
        .clk       (clk),
        .rst       (rst),
        .we        (MemWriteM),
        .funct3    (Funct3M),
        .addr      (ALUResultM),
        .wd        (WriteDataM),
        .rd        (ReadDataM),
        .mem_ready (mem_ready)
    );

    assign mem_ready_out = mem_ready;

    // Debug taps (drive the data-memory write interface to the boundary)
    assign dbg_store_we   = MemWriteM;
    assign dbg_store_data = WriteDataM;
    assign dbg_store_addr = ALUResultM;

endmodule
