// =============================================================================
// soc_top.sv  -  M1.3 system: host CPU + memory-mapped SIMTiX accelerator
//
// Wires the reused 5-stage RISC-V pipeline to the accelerator over the CPU's
// data bus. A trivial address decode splits data accesses:
//
//     addr >= MMIO_BASE (0x8000_0000)  -> accelerator command/status registers
//     addr <  MMIO_BASE                -> the CPU's local data RAM
//
// So a normal RISC-V program running on the host can launch a kernel purely by
// storing to / loading from the MMIO aperture (write the command block, set GO,
// poll DONE) — no special instructions. The host I-fetch port and the
// accelerator's shared-memory master ports (kernel code + data arrays) are
// exposed at the boundary so the testbench (and, later, a real loader) own the
// memory images.
// =============================================================================
`timescale 1ns/1ps

module soc_top
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,            // active-high
    input  logic [31:0] reset_vector,   // host CPU entry PC

    // Host CPU instruction fetch (driver program ROM lives outside).
    output logic [31:0] cpu_imem_addr,
    input  logic [31:0] cpu_imem_data,

    // Accelerator shared-memory master: kernel instruction fetch.
    output logic [31:0] accel_imem_addr,
    input  logic [31:0] accel_imem_data,

    // Accelerator shared-memory master: data — line-wide for coalesced transfers
    // (async read, synchronous per-byte-enabled write).
    output logic [31:0]          accel_dmem_addr,
    output logic [LINE_BITS-1:0] accel_dmem_wdata,
    output logic                 accel_dmem_we,
    output logic [LINE_BE-1:0]   accel_dmem_be,
    input  logic [LINE_BITS-1:0] accel_dmem_rdata
);

    // ── Host CPU data-bus wires ───────────────────────────────────────────────────
    logic [31:0] PCF, InstrF;
    logic [31:0] ALUResultM, WriteDataM, ReadDataM;
    logic        MemWriteM;
    logic [2:0]  Funct3M;
    logic        mem_ready;

    assign cpu_imem_addr = PCF;
    assign InstrF        = cpu_imem_data;

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

    // ── Address decode ────────────────────────────────────────────────────────────
    logic        is_mmio;
    assign is_mmio = (ALUResultM >= MMIO_BASE);

    // ── CPU local data RAM (non-MMIO accesses) ────────────────────────────────────
    logic [31:0] dram_rd;
    data_mem dmem (
        .clk       (clk),
        .rst       (rst),
        .we        (MemWriteM & ~is_mmio),
        .funct3    (Funct3M),
        .addr      (ALUResultM),
        .wd        (WriteDataM),
        .rd        (dram_rd),
        .mem_ready (mem_ready)
    );

    // ── Accelerator (MMIO target + shared-memory master) ──────────────────────────
    logic [31:0] accel_rdata;
    simt_accel accel (
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

    // ── Read-data return mux ──────────────────────────────────────────────────────
    assign ReadDataM = is_mmio ? accel_rdata : dram_rd;

endmodule : soc_top
