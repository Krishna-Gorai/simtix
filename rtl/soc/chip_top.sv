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
#(
    // Demo selection: "vadd" = the M10 checksum driver (default, hand-assembled
    // case ROM); "mnist" = the AI-4 on-chip MNIST inference driver (assembled
    // rv32i program in driver_rom, streaming weights out of the BRAM store).
    parameter         DRIVER       = "vadd",
    parameter         MDRIVER_INIT = "../kernels/mnist/mnist_driver.hex",
    // BRAM weight/data store: init image + word capacity. The MNIST demo grows
    // it to hold the two weight matrices, images, params and golden preds.
    parameter         WSTORE_INIT  = "../ml/data/weights_rom.hex",
    parameter int     WSTORE_WORDS = 1 << 15
)(
    input  logic        clk,
    input  logic        rst,            // active-high
    output logic        done,           // kernel finished + result published
    output logic [31:0] result          // CPU-computed checksum of the C array
);

    localparam logic [31:0] RESET_VECTOR     = 32'h0000_0000;  // driver entry
    localparam logic [3:0]  HI_MMIO          = 4'h8;           // 0x8.. MMIO page
    localparam logic [3:0]  HI_RESULT        = 4'h9;           // 0x9.. result reg
    localparam logic [3:0]  HI_WEIGHT        = 4'hA;           // 0xA.. BRAM weight ROM
    localparam int          SHARED_WORDS     = 4096;           // 16 KB working memory

    // ── Host CPU bus wires ────────────────────────────────────────────────────────
    logic [31:0] PCF, InstrF;
    logic [31:0] ALUResultM, WriteDataM, ReadDataM;
    logic        MemWriteM, MemReadM;
    logic [2:0]  Funct3M;
    logic        cpu_mem_ready;         // low for one cycle on a BRAM weight read

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
        .MemReadM     (MemReadM),
        .Funct3M      (Funct3M),
        .mem_ready    (cpu_mem_ready)
    );

    // ── Driver instruction ROM (demo-selected) ───────────────────────────────────
    generate
        if (DRIVER == "mnist") begin : g_mnist_driver
            driver_rom #(.WORDS(1024), .INIT(MDRIVER_INIT))
                u_irom (.addr(PCF), .instr(InstrF));
        end else begin : g_vadd_driver
            cpu_driver_rom u_irom (.addr(PCF), .instr(InstrF));
        end
    endgenerate

    // ── Address decode ────────────────────────────────────────────────────────────
    logic is_mmio, is_result, is_weight, is_shared;
    assign is_result = (ALUResultM[31:28] == HI_RESULT);
    assign is_mmio   = (ALUResultM[31:28] == HI_MMIO);
    assign is_weight = (ALUResultM[31:28] == HI_WEIGHT);
    assign is_shared = ~is_result & ~is_mmio & ~is_weight;

    // ── BRAM weight ROM + CPU stall handshake ─────────────────────────────────────
    // A weight LOAD triggers a synchronous BRAM read: `wrom_rvalid`/`wrom_rdata`
    // arrive the cycle after `en`. We stall the CPU exactly one cycle per weight
    // read by holding mem_ready low until the read is served. `wr_pending` is set
    // the cycle a weight read is issued and cleared once served, so back-to-back
    // weight loads each get their single stall cycle.
    logic        wrom_en, wrom_rvalid, wr_pending;
    logic [31:0] wrom_rdata;
    assign wrom_en = is_weight & MemReadM;

    always_ff @(posedge clk) begin
        if (rst) wr_pending <= 1'b0;
        else     wr_pending <= wrom_en & ~wr_pending;   // high the cycle after issue
    end
    // Ready everywhere except the first cycle of a weight read (async elsewhere).
    assign cpu_mem_ready = wrom_en ? wr_pending : 1'b1;

    weight_rom #(.WORDS(WSTORE_WORDS), .INIT(WSTORE_INIT)) u_wrom (
        .clk   (clk),
        .en    (wrom_en),
        .addr  (ALUResultM),
        .rdata (wrom_rdata),
        .rvalid(wrom_rvalid)
    );

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
    shared_mem #(.WORDS(SHARED_WORDS)) u_mem (
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

    // ── Host read-data return mux (MMIO status vs BRAM weights vs shared memory) ──
    assign ReadDataM = is_mmio   ? accel_rdata :
                       is_weight ? wrom_rdata  :
                                   shared_rdata;

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
