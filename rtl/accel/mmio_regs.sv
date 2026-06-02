// =============================================================================
// mmio_regs.sv  -  memory-mapped command/status registers
//
// Presents a tiny word-addressed register file to the host data bus. Writes
// latch the command fields; a write to REG_CTRL with bit0 set emits a 1-cycle
// `go_pulse`. Reads return STATUS / CYCLES (and the command fields, for
// read-back / debug).
// =============================================================================
`timescale 1ns/1ps

module mmio_regs
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,         // active-high

    // Host access port (already address-decoded into this page by soc_top).
    input  logic        sel,         // access targets the MMIO page
    input  logic        we,          // 1 = write, 0 = read
    input  logic [7:0]  offset,      // byte offset within the page
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    // Latched command (consumed by the engine on go_pulse).
    output logic [31:0] kernel_pc,
    output logic [31:0] base_a,
    output logic [31:0] base_b,
    output logic [31:0] base_c,
    output logic [31:0] n_threads,
    output logic        go_pulse,    // 1-cycle launch strobe

    // Status from the engine.
    input  logic        busy,
    input  logic        done,
    input  logic [31:0] cycles
);

    // ── Command registers ──────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            kernel_pc <= '0;
            base_a    <= '0;
            base_b    <= '0;
            base_c    <= '0;
            n_threads <= '0;
            go_pulse  <= 1'b0;
        end else begin
            go_pulse <= 1'b0;                 // default: deassert (1-cycle pulse)
            if (sel && we) begin
                unique case (offset)
                    REG_KERNEL_PC: kernel_pc <= wdata;
                    REG_BASE_A   : base_a    <= wdata;
                    REG_BASE_B   : base_b    <= wdata;
                    REG_BASE_C   : base_c    <= wdata;
                    REG_N        : n_threads <= wdata;
                    REG_CTRL     : go_pulse  <= wdata[CTRL_GO_BIT];
                    default      : /* no-op */ ;
                endcase
            end
        end
    end

    // ── Read mux ────────────────────────────────────────────────────────────────
    logic [31:0] status_word;
    always_comb begin
        status_word                  = '0;
        status_word[STATUS_DONE_BIT] = done;
        status_word[STATUS_BUSY_BIT] = busy;
    end

    always_comb begin
        unique case (offset)
            REG_KERNEL_PC: rdata = kernel_pc;
            REG_BASE_A   : rdata = base_a;
            REG_BASE_B   : rdata = base_b;
            REG_BASE_C   : rdata = base_c;
            REG_N        : rdata = n_threads;
            REG_STATUS   : rdata = status_word;
            REG_CYCLES   : rdata = cycles;
            default      : rdata = '0;
        endcase
    end

endmodule : mmio_regs
