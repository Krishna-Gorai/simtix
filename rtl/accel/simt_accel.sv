// =============================================================================
// simt_accel.sv  -  SIMTiX accelerator top
//
// M3: the engine is a multi-warp pool (warp_pool) — NUM_WARPS hardware warp
// slots resident at once over a round-robin scheduler, hiding one warp's memory
// replay behind another warp's compute. On GO the dispatcher hands the whole
// grid (kernel_pc, base pointers, n_threads) to the pool in a single launch; the
// pool spawns/recycles all warps internally. The dispatcher just waits for the
// pool to retire the grid and tallies the runtime in CYCLES. The accelerator is
// a master onto a shared, async-read memory holding both kernel code (imem port)
// and data (dmem port).
//
// The MMIO contract and the memory-master interface below do NOT change as the
// engine grows.    M4 coalescing    M5 divergence
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

    // Data master: line-wide (async read, synchronous byte-enabled write) — the
    // memory engine coalesces a warp's lane accesses into whole-line transfers.
    output logic [31:0]          dmem_addr,
    output logic [LINE_BITS-1:0] dmem_wdata,
    output logic                 dmem_we,
    output logic [LINE_BE-1:0]   dmem_be,
    input  logic [LINE_BITS-1:0] dmem_rdata
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

    // ── Multi-warp pool (NUM_WARPS slots + round-robin scheduler) ─────────────────
    logic        pool_start;
    logic        pool_busy, pool_done;
    logic [31:0] pool_dbg_a0;
    logic [31:0] pool_dbg_txns;

    warp_pool u_pool (
        .clk        (clk),
        .rst        (rst),
        .start      (pool_start),
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
        .busy       (pool_busy),
        .done       (pool_done),
        .dbg_retire_a0 (pool_dbg_a0),
        .dbg_mem_txns  (pool_dbg_txns)
    );

    // ── Dispatcher ────────────────────────────────────────────────────────────────
    // The pool spawns/recycles every warp of the grid internally, so the
    // dispatcher just launches it once on GO and waits for the grid to retire.
    // D_LAUNCH pulses start (the pool is idle and latches the grid); D_RUN tallies
    // cycles until pool_done. An empty grid (n_threads==0) finishes immediately.
    typedef enum logic [1:0] { D_IDLE, D_LAUNCH, D_RUN, D_DONE } dstate_e;
    dstate_e     dstate;
    logic [31:0] cyc_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            dstate    <= D_IDLE;
            cyc_count <= '0;
            cycles    <= '0;
        end else begin
            unique case (dstate)
                D_IDLE: begin
                    if (go_pulse) begin
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
                    if (pool_done) begin
                        cycles <= cyc_count + 32'd1;
                        dstate <= D_DONE;
                    end
                end
                D_DONE: begin
                    if (go_pulse) begin
                        cyc_count <= '0;
                        dstate    <= (n_threads == 0) ? D_DONE : D_LAUNCH;
                    end
                end
                default: dstate <= D_IDLE;
            endcase
        end
    end

    assign pool_start = (dstate == D_LAUNCH);
    assign busy       = (dstate == D_LAUNCH) || (dstate == D_RUN);
    assign done       = (dstate == D_DONE);

    // Silence unused-signal lint: pool_busy and the debug a0 tap are observability
    // only (the dispatcher sequences on pool_done; results are checked in memory).
    logic _unused;
    assign _unused = &{1'b0, pool_busy, pool_dbg_a0, pool_dbg_txns};

endmodule : simt_accel
