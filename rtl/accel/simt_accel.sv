// =============================================================================
// simt_accel.sv  -  SIMTiX accelerator top
//
// M0: wires the MMIO registers to a PLACEHOLDER execution engine that models
// the launch/done handshake. The stub "executes" one thread per cycle (i.e. as
// if it were a 1-lane scalar machine), so STATUS.DONE and CYCLES behave
// realistically and the host handshake is fully testable.
//
// Milestones replace `u_engine` with the real datapath:
//   M1 fetch/decode + single lane    M2 8 lanes + VRF    M3 warp scheduler
//   M4 LSU/coalescing                 M5 divergence       M6 shared mem
// The MMIO contract below does NOT change as the engine grows.
// =============================================================================
`timescale 1ns/1ps

module simt_accel
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,            // active-high

    // Host data-bus access port (address-decoded into the MMIO page upstream).
    input  logic        sel,
    input  logic        we,
    input  logic [7:0]  offset,
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);

    // ── Command / status registers ──────────────────────────────────────────────
    logic [31:0] kernel_pc, base_a, base_b, base_c, n_threads;
    logic        go_pulse;
    logic        busy, done;
    logic [31:0] cycles;

    mmio_regs u_regs (
        .clk      (clk),
        .rst      (rst),
        .sel      (sel),
        .we       (we),
        .offset   (offset),
        .wdata    (wdata),
        .rdata    (rdata),
        .kernel_pc(kernel_pc),
        .base_a   (base_a),
        .base_b   (base_b),
        .base_c   (base_c),
        .n_threads(n_threads),
        .go_pulse (go_pulse),
        .busy     (busy),
        .done     (done),
        .cycles   (cycles)
    );

    // ── Placeholder execution engine (replaced from M1 onward) ───────────────────
    typedef enum logic [1:0] { S_IDLE, S_RUN, S_DONE } state_e;
    state_e      state;
    logic [31:0] threads_left;
    logic [31:0] cyc_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            threads_left <= '0;
            cyc_count    <= '0;
            cycles       <= '0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    if (go_pulse) begin
                        threads_left <= n_threads;
                        cyc_count    <= '0;
                        state        <= (n_threads == 0) ? S_DONE : S_RUN;
                    end
                end
                S_RUN: begin
                    cyc_count <= cyc_count + 32'd1;
                    // STUB: retire one thread per cycle.
                    if (threads_left <= 32'd1) begin
                        cycles <= cyc_count + 32'd1;
                        state  <= S_DONE;
                    end else begin
                        threads_left <= threads_left - 32'd1;
                    end
                end
                S_DONE: begin
                    // Stay DONE until a fresh launch is requested.
                    if (go_pulse) begin
                        threads_left <= n_threads;
                        cyc_count    <= '0;
                        state        <= (n_threads == 0) ? S_DONE : S_RUN;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    assign busy = (state == S_RUN);
    assign done = (state == S_DONE);

    // Silence unused-signal lint until the real engine consumes these (M1+).
    logic _unused;
    assign _unused = &{1'b0, kernel_pc, base_a, base_b, base_c};

endmodule : simt_accel
