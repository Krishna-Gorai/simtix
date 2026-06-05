// =============================================================================
// shared_mem.sv  -  M10 on-chip shared memory for the full SIMTiX chip
//
// A single 4 KB memory shared by the host CPU and the accelerator, holding the
// kernel code and the A/B/C data arrays. It is the on-chip replacement for the
// memory the M1.3 testbench used to fake, so the chip is self-contained.
//
// Layout: WORDS words = LINES cache lines of LINE_WORDS words each. To serve a
// whole accelerator line in one cycle *without* replicating the array, the
// memory is split into LINE_WORDS distributed-RAM (LUTRAM) banks: bank b holds
// word (line*LINE_WORDS + b), so a line access reads one word from each bank in
// parallel (the canonical banked-shared-memory layout). Three access points:
//
//   * accelerator data  : line-wide async read + sync byte-enabled write (dmem_*)
//   * accelerator fetch  : word async read (imem_*)
//   * host CPU data      : word async read + sync byte-enabled write (cpu_*)
//
// Each bank has a single physical write port (the accelerator line write wins;
// the CPU word write is the fallback). In the chip's actual schedule the two
// masters are temporally separated — the CPU loads/launches/polls/reads back,
// the accelerator runs in between — so the priority never actually arbitrates a
// real conflict; it is there for safety. Contents are preloaded with `initial`
// (Vivado honours distributed-RAM init values), so the memory is always ready.
// =============================================================================
`timescale 1ns/1ps

module shared_mem
  import simtix_pkg::*;
#(
    parameter int WORDS = 1024                       // 4 KB = 128 lines of 8 words
)(
    input  logic        clk,

    // Accelerator instruction fetch (word, async read).
    input  logic [31:0]          imem_addr,
    output logic [31:0]          imem_data,

    // Accelerator data master (line-wide: async read, sync byte-enabled write).
    input  logic [31:0]          dmem_addr,
    input  logic [LINE_BITS-1:0] dmem_wdata,
    input  logic                 dmem_we,
    input  logic [LINE_BE-1:0]   dmem_be,
    output logic [LINE_BITS-1:0] dmem_rdata,

    // Host CPU data port (word: async read, sync byte-enabled write).
    input  logic [31:0]          cpu_addr,
    input  logic [31:0]          cpu_wdata,
    input  logic                 cpu_we,
    input  logic [2:0]           cpu_funct3,
    output logic [31:0]          cpu_rdata
);

    localparam int LINES = WORDS / LINE_WORDS;        // 128
    localparam int LAW   = $clog2(LINES);             // 7  (line-index width)

    // Line / word-offset slices of a byte address.
    //   line = addr[LAW+LINE_OFF-1 : LINE_OFF]  (= addr[11:5] for the defaults)
    //   woff = addr[LINE_OFF-1 : 2]             (= addr[4:2])
    logic [LAW-1:0] dmem_line, imem_line, cpu_line;
    logic [LINE_WOFFW-1:0] imem_woff, cpu_woff;
    assign dmem_line = dmem_addr[LAW+LINE_OFF-1 : LINE_OFF];
    assign imem_line = imem_addr[LAW+LINE_OFF-1 : LINE_OFF];
    assign cpu_line  = cpu_addr [LAW+LINE_OFF-1 : LINE_OFF];
    assign imem_woff = imem_addr[LINE_OFF-1 : 2];
    assign cpu_woff  = cpu_addr [LINE_OFF-1 : 2];

    // ── CPU write: funct3 -> byte-enables + placed write word (sb/sh/sw) ──────────
    logic [3:0]  cpu_be;
    logic [31:0] cpu_wword;
    always_comb begin
        unique case (cpu_funct3[1:0])
            2'b00: begin                              // sb
                cpu_be    = 4'b0001 << cpu_addr[1:0];
                cpu_wword = cpu_wdata[7:0] << ({3'b0, cpu_addr[1:0]} << 3);
            end
            2'b01: begin                              // sh
                cpu_be    = cpu_addr[1] ? 4'b1100 : 4'b0011;
                cpu_wword = cpu_addr[1] ? {cpu_wdata[15:0], 16'b0}
                                        : {16'b0, cpu_wdata[15:0]};
            end
            default: begin                            // sw
                cpu_be    = 4'b1111;
                cpu_wword = cpu_wdata;
            end
        endcase
    end

    // ── Per-bank read fan-out (filled by the generate below) ─────────────────────
    logic [31:0] line_word [0:LINE_WORDS-1];          // bank read @ dmem_line
    logic [31:0] imem_word [0:LINE_WORDS-1];          // bank read @ imem_line
    logic [31:0] cpu_word  [0:LINE_WORDS-1];          // bank read @ cpu_line

    // ── Preload contents: kernel @0x200, C @0x380 (poison) ───────────────────────
    // The A/B operand arrays are NO LONGER preloaded — the host CPU writes them at
    // runtime (see cpu_driver_rom.sv), so anything but a working store loop leaves
    // A=B=0 and the result != 964. Only the kernel code (the accelerator's program
    // memory) and a C poison pattern (so a missed accelerator write is visible) are
    // initialised here.
    function automatic logic [31:0] init_word(input int unsigned w);
        // Vector-add kernel (a0=tid, a1=&A, a2=&B, a3=&C): C[tid]=A[tid]+B[tid].
        case (w)
            32'h080: init_word = 32'h00251293;        // slli t0, a0, 2
            32'h081: init_word = 32'h00558333;        // add  t1, a1, t0
            32'h082: init_word = 32'h00032383;        // lw   t2, 0(t1)
            32'h083: init_word = 32'h00560e33;        // add  t3, a2, t0
            32'h084: init_word = 32'h000e2e83;        // lw   t4, 0(t3)
            32'h085: init_word = 32'h01d383b3;        // add  t2, t2, t4
            32'h086: init_word = 32'h00568f33;        // add  t5, a3, t0
            32'h087: init_word = 32'h007f2023;        // sw   t2, 0(t5)
            32'h088: init_word = 32'h00000073;        // ecall
            default: begin
                if (w >= 32'h0E0 && w < 32'h0E8)      // C[i] = poison
                    init_word = 32'hdead_beef;
                else                                  // A/B (0x0C0/0x0D0) now CPU-loaded
                    init_word = 32'd0;
            end
        endcase
    endfunction

    // ── The 8 distributed-RAM banks ──────────────────────────────────────────────
    genvar b;
    generate
        for (b = 0; b < LINE_WORDS; b++) begin : g_bank
            (* ram_style = "distributed" *)
            logic [31:0] bank [0:LINES-1];

            initial
                for (int l = 0; l < LINES; l++)
                    bank[l] = init_word(l * LINE_WORDS + b);

            // Single write port: accelerator line write (this bank's word) wins,
            // else the CPU word write when it targets this bank. A blocking temp
            // merges the byte-enabled bytes, then one NBA per word (keeps the array
            // a clean single-write RAM and dodges Verilator's multi-write-NBA bug).
            always_ff @(posedge clk) begin
                logic [31:0] cur;
                if (dmem_we) begin
                    cur = bank[dmem_line];
                    for (int by = 0; by < 4; by++)
                        if (dmem_be[b*4 + by])
                            cur[by*8 +: 8] = dmem_wdata[b*32 + by*8 +: 8];
                    bank[dmem_line] <= cur;
                end else if (cpu_we && (cpu_woff == b[LINE_WOFFW-1:0])) begin
                    cur = bank[cpu_line];
                    for (int by = 0; by < 4; by++)
                        if (cpu_be[by])
                            cur[by*8 +: 8] = cpu_wword[by*8 +: 8];
                    bank[cpu_line] <= cur;
                end
            end

            assign line_word[b] = bank[dmem_line];
            assign imem_word[b] = bank[imem_line];
            assign cpu_word[b]  = bank[cpu_line];
        end
    endgenerate

    // ── Reads ─────────────────────────────────────────────────────────────────────
    genvar g;
    generate
        for (g = 0; g < LINE_WORDS; g++) begin : g_line
            assign dmem_rdata[g*32 +: 32] = line_word[g];   // whole line, parallel
        end
    endgenerate

    assign imem_data = imem_word[imem_woff];                 // word @ imem_woff

    // CPU word read with funct3 sub-word extraction (mirrors rtl/cpu/data_mem.v).
    logic [31:0] cpu_rword;
    assign cpu_rword = cpu_word[cpu_woff];
    always_comb begin
        unique case (cpu_funct3)
            3'b000: case (cpu_addr[1:0])                      // lb
                2'b00: cpu_rdata = {{24{cpu_rword[ 7]}}, cpu_rword[ 7: 0]};
                2'b01: cpu_rdata = {{24{cpu_rword[15]}}, cpu_rword[15: 8]};
                2'b10: cpu_rdata = {{24{cpu_rword[23]}}, cpu_rword[23:16]};
                2'b11: cpu_rdata = {{24{cpu_rword[31]}}, cpu_rword[31:24]};
            endcase
            3'b001: cpu_rdata = cpu_addr[1]                   // lh
                                ? {{16{cpu_rword[31]}}, cpu_rword[31:16]}
                                : {{16{cpu_rword[15]}}, cpu_rword[15: 0]};
            3'b100: case (cpu_addr[1:0])                      // lbu
                2'b00: cpu_rdata = {24'd0, cpu_rword[ 7: 0]};
                2'b01: cpu_rdata = {24'd0, cpu_rword[15: 8]};
                2'b10: cpu_rdata = {24'd0, cpu_rword[23:16]};
                2'b11: cpu_rdata = {24'd0, cpu_rword[31:24]};
            endcase
            3'b101: cpu_rdata = cpu_addr[1]                   // lhu
                                ? {16'd0, cpu_rword[31:16]}
                                : {16'd0, cpu_rword[15: 0]};
            default: cpu_rdata = cpu_rword;                   // lw
        endcase
    end

endmodule : shared_mem
