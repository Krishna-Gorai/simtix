// =============================================================================
// simt_accel.sv  -  SIMTiX accelerator top
//
// M2: the engine is one SIMT warp (WARP_SIZE lanes in lockstep over a banked
// vector register file) driven by a sequential dispatcher. On GO the dispatcher
// launches warps 0,1,2,... — each covering WARP_SIZE threads — one at a time,
// seeding each lane with its tid and the argument base pointers, and tallies
// the kernel runtime in CYCLES. The accelerator is a master onto a shared,
// async-read memory holding both kernel code (imem port) and data (dmem port).
//
// Later milestones overlap warps and add coalescing/divergence; the MMIO
// contract and the memory-master interface below do NOT change as it grows.
//   M3 warp scheduler    M4 coalescing    M5 divergence
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
    output logic [31:0] rdata,

    // Instruction-fetch master (read-only) into shared memory.
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_data,

    // Data master (async read, synchronous byte-enabled write) into shared memory.
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic        dmem_we,
    output logic [3:0]  dmem_be,
    input  logic [31:0] dmem_rdata
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

    // ── One SIMT warp (WARP_SIZE lanes in lockstep) ──────────────────────────────
    logic        warp_start;
    logic [31:0] warp_base_tid;
    logic        warp_busy, warp_done;
    logic [31:0] warp_dbg_a0;

    warp u_warp (
        .clk        (clk),
        .rst        (rst),
        .start      (warp_start),
        .base_tid   (warp_base_tid),
        .base_a     (base_a),
        .base_b     (base_b),
        .base_c     (base_c),
        .n_threads  (n_threads),
        .kernel_pc  (kernel_pc),
        .imem_addr  (imem_addr),
        .imem_data  (imem_data),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_we    (dmem_we),
        .dmem_be    (dmem_be),
        .dmem_rdata (dmem_rdata),
        .busy       (warp_busy),
        .done       (warp_done),
        .dbg_retire_a0 (warp_dbg_a0)
    );

    // ── Sequential dispatcher ─────────────────────────────────────────────────────
    // Launches warps 0,1,2,... — each covering WARP_SIZE threads — one at a time.
    // D_LAUNCH asserts start for one cycle (the warp is idle and latches it);
    // D_RUN waits for the warp to retire, then either launches the next warp (if
    // more threads remain) or finishes. cyc_count tallies the whole kernel.
    typedef enum logic [1:0] { D_IDLE, D_LAUNCH, D_RUN, D_DONE } dstate_e;
    dstate_e     dstate;
    logic [31:0] base_tid;            // first tid of the warp in flight
    logic [31:0] n_latched;
    logic [31:0] cyc_count;

    // True once the warp currently in flight covers the final thread.
    logic        last_warp;
    assign last_warp = (base_tid + WARP_SIZE) >= n_latched;

    always_ff @(posedge clk) begin
        if (rst) begin
            dstate    <= D_IDLE;
            base_tid  <= '0;
            n_latched <= '0;
            cyc_count <= '0;
            cycles    <= '0;
        end else begin
            unique case (dstate)
                D_IDLE: begin
                    if (go_pulse) begin
                        base_tid  <= '0;
                        n_latched <= n_threads;
                        cyc_count <= '0;
                        dstate    <= (n_threads == 0) ? D_DONE : D_LAUNCH;
                    end
                end
                D_LAUNCH: begin
                    cyc_count <= cyc_count + 32'd1;   // start asserted this cycle
                    dstate    <= D_RUN;
                end
                D_RUN: begin
                    cyc_count <= cyc_count + 32'd1;
                    if (warp_done) begin
                        if (last_warp) begin
                            cycles <= cyc_count + 32'd1;
                            dstate <= D_DONE;
                        end else begin
                            base_tid <= base_tid + WARP_SIZE;
                            dstate   <= D_LAUNCH;
                        end
                    end
                end
                D_DONE: begin
                    if (go_pulse) begin
                        base_tid  <= '0;
                        n_latched <= n_threads;
                        cyc_count <= '0;
                        dstate    <= (n_threads == 0) ? D_DONE : D_LAUNCH;
                    end
                end
                default: dstate <= D_IDLE;
            endcase
        end
    end

    assign warp_start    = (dstate == D_LAUNCH);
    assign warp_base_tid = base_tid;
    assign busy          = (dstate == D_LAUNCH) || (dstate == D_RUN);
    assign done          = (dstate == D_DONE);

    // Silence unused-signal lint: warp_busy and the debug a0 tap are observability
    // only (the dispatcher sequences on warp_done; results are checked in memory).
    logic _unused;
    assign _unused = &{1'b0, warp_busy, warp_dbg_a0};

endmodule : simt_accel
