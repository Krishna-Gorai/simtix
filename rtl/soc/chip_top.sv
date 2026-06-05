// =============================================================================
// chip_top.sv  -  M10 complete SIMTiX chip (host CPU + accelerator + memory)
//
// The full, self-contained system-on-chip: the reused 5-stage RISC-V host, its
// driver instruction ROM, the SIMTiX SIMT accelerator, and one on-chip shared
// memory holding the kernel and data. Nothing is faked by a testbench any more —
// the only ports are clk/rst and two observable outputs (done, result), so this
// is a real chip that boots, offloads a kernel, and reports an answer.
//
// On reset the host runs cpu_driver_rom: it programs the accelerator command
// block over MMIO, launches the grid, polls DONE, reads the C results back from
// shared memory, sums them, and publishes the sum to the result register — which
// drives the `done`/`result` pins. Those pins also anchor the design so
// synthesis cannot optimize the logic away.
//
// Data-bus address map (host CPU view):
//     0x9xxx_xxxx  chip result register  (write: latch result + raise done)
//     0x8xxx_xxxx  accelerator MMIO command/status page
//     else         on-chip shared memory (kernel + A/B/C arrays)
// =============================================================================
`timescale 1ns/1ps

module chip_top
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,            // active-high
    output logic        done,           // kernel finished + result published
    output logic [31:0] result          // CPU-computed checksum of the C array
);

    localparam logic [31:0] RESET_VECTOR     = 32'h0000_0000;  // driver entry
    localparam logic [3:0]  HI_MMIO          = 4'h8;           // 0x8.. MMIO page
    localparam logic [3:0]  HI_RESULT        = 4'h9;           // 0x9.. result reg

    // ── Host CPU bus wires ────────────────────────────────────────────────────────
    logic [31:0] PCF, InstrF;
    logic [31:0] ALUResultM, WriteDataM, ReadDataM;
    logic        MemWriteM;
    logic [2:0]  Funct3M;

    riscv_pipeline cpu (
        .clk          (clk),
        .rst          (rst),
        .reset_vector (RESET_VECTOR),
        .PCF          (PCF),
        .InstrF       (InstrF),
        .ALUResultM   (ALUResultM),
        .WriteDataM   (WriteDataM),
        .ReadDataM    (ReadDataM),
        .MemWriteM    (MemWriteM),
        .Funct3M      (Funct3M),
        .mem_ready    (1'b1)             // preloaded RAM is always ready
    );

    // ── Driver instruction ROM ────────────────────────────────────────────────────
    cpu_driver_rom u_irom (.addr(PCF), .instr(InstrF));

    // ── Address decode ────────────────────────────────────────────────────────────
    logic is_mmio, is_result, is_shared;
    assign is_result = (ALUResultM[31:28] == HI_RESULT);
    assign is_mmio   = (ALUResultM[31:28] == HI_MMIO);
    assign is_shared = ~is_result & ~is_mmio;

    // ── Accelerator (MMIO target + shared-memory master) ──────────────────────────
    logic [31:0]          accel_rdata;
    logic [31:0]          accel_imem_addr, accel_imem_data;
    logic [31:0]          accel_dmem_addr;
    logic [LINE_BITS-1:0] accel_dmem_wdata, accel_dmem_rdata;
    logic                 accel_dmem_we;
    logic [LINE_BE-1:0]   accel_dmem_be;

    simt_accel u_accel (
        .clk        (clk),
        .rst        (rst),
        .sel        (is_mmio),
        .we         (MemWriteM & is_mmio),
        .offset     (ALUResultM[7:0]),
        .wdata      (WriteDataM),
        .rdata      (accel_rdata),
        .imem_addr  (accel_imem_addr),
        .imem_data  (accel_imem_data),
        .dmem_addr  (accel_dmem_addr),
        .dmem_wdata (accel_dmem_wdata),
        .dmem_we    (accel_dmem_we),
        .dmem_be    (accel_dmem_be),
        .dmem_rdata (accel_dmem_rdata)
    );

    // ── On-chip shared memory (kernel + data; CPU and accelerator both reach it) ──
    logic [31:0] shared_rdata;
    shared_mem u_mem (
        .clk        (clk),
        .imem_addr  (accel_imem_addr),
        .imem_data  (accel_imem_data),
        .dmem_addr  (accel_dmem_addr),
        .dmem_wdata (accel_dmem_wdata),
        .dmem_we    (accel_dmem_we),
        .dmem_be    (accel_dmem_be),
        .dmem_rdata (accel_dmem_rdata),
        .cpu_addr   (ALUResultM),
        .cpu_wdata  (WriteDataM),
        .cpu_we     (MemWriteM & is_shared),
        .cpu_funct3 (Funct3M),
        .cpu_rdata  (shared_rdata)
    );

    // ── Host read-data return mux (MMIO status vs shared memory) ──────────────────
    assign ReadDataM = is_mmio ? accel_rdata : shared_rdata;

    // ── Chip result register: a CPU store to 0x9.. publishes the answer ──────────
    always_ff @(posedge clk) begin
        if (rst) begin
            done   <= 1'b0;
            result <= 32'd0;
        end else if (MemWriteM & is_result) begin
            result <= WriteDataM;
            done   <= 1'b1;
        end
    end

endmodule : chip_top
