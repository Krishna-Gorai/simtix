// =============================================================================
// tb_warp.sv  -  M2 unit test for an 8-lane SIMT warp
//
// Runs the vector-add kernel across a full warp and checks every lane's result
// directly in memory. Three phases exercise the new M2 machinery:
//   1. full warp     base_tid=0,  N=8   -> C[0..7] = 110 + 3i (all lanes active)
//   2. tail mask     base_tid=0,  N=5   -> C[0..4] written, C[5..7] untouched
//   3. base_tid != 0 base_tid=8,  N=16  -> C[8..15] (non-zero warp offset)
//
// The lanes share one PC / one instruction fetch; per-lane loads/stores are
// serialized onto the single data port inside the warp.
// =============================================================================
`timescale 1ns/1ps

module tb_warp
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */  // only addr[*:2] indexes the model memory
    logic        clk = 0;
    logic        rst;
    logic        start;
    logic [31:0] base_tid, base_a, base_b, base_c, n_threads, kernel_pc;
    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_we;
    logic [3:0]  dmem_be;
    logic        busy, done;
    logic [31:0] dbg_retire_a0;

    int unsigned errors = 0;

    warp dut (
        .clk(clk), .rst(rst),
        .start(start), .base_tid(base_tid),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_rdata(dmem_rdata),
        .busy(busy), .done(done), .dbg_retire_a0(dbg_retire_a0)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Shared memory (kernel + arrays) ───────────────────────────────────────────
    localparam int MEM_WORDS = 1024;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign imem_data  = mem[imem_addr[11:2]];
    assign dmem_rdata = mem[dmem_addr[11:2]];
    always @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_be[0]) mem[dmem_addr[11:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_be[1]) mem[dmem_addr[11:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_be[2]) mem[dmem_addr[11:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_be[3]) mem[dmem_addr[11:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    localparam logic [31:0] BASE_A = 32'h0000_0100;
    localparam logic [31:0] BASE_B = 32'h0000_0140;
    localparam logic [31:0] BASE_C = 32'h0000_0180;

    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {22'b0, byte_addr[11:2]};
    endfunction

    // Reload A,B and poison C for indices 0..hi-1.
    task automatic preload(input int hi);
        for (int k = 0; k < hi; k++) begin
            mem[widx(BASE_A) + k] = 32'd10  + k;
            mem[widx(BASE_B) + k] = 32'd100 + 2*k;
            mem[widx(BASE_C) + k] = 32'hdead_beef;
        end
    endtask

    task automatic run_warp(input logic [31:0] bt, input logic [31:0] n);
        int unsigned guard;
        @(posedge clk);
        base_tid = bt; n_threads = n; kernel_pc = 32'd0;
        base_a = BASE_A; base_b = BASE_B; base_c = BASE_C;
        start = 1;
        @(posedge clk);
        start = 0;
        guard = 0;
        while (!done && guard < 2000) begin @(posedge clk); guard++; end
    endtask

    task automatic expect_c(input int idx, input logic [31:0] exp, input string tag);
        logic [31:0] got;
        got = mem[widx(BASE_C) + idx];
        if (got !== exp) begin
            $display("  [FAIL] %-10s C[%0d] got=%08h exp=%08h", tag, idx, got, exp);
            errors++;
        end else begin
            $display("  [ ok ] %-10s C[%0d] = %0d", tag, idx, got);
        end
    endtask

    int i;

    initial begin
        start = 0; base_tid = 0; n_threads = 0; kernel_pc = 0;
        base_a = 0; base_b = 0; base_c = 0;

        // vector-add kernel
        mem[0] = 32'h00251293;   // slli t0, a0, 2
        mem[1] = 32'h00558333;   // add  t1, a1, t0
        mem[2] = 32'h00032383;   // lw   t2, 0(t1)
        mem[3] = 32'h00560e33;   // add  t3, a2, t0
        mem[4] = 32'h000e2e83;   // lw   t4, 0(t3)
        mem[5] = 32'h01d383b3;   // add  t2, t2, t4
        mem[6] = 32'h00568f33;   // add  t5, a3, t0
        mem[7] = 32'h007f2023;   // sw   t2, 0(t5)
        mem[8] = 32'h00000073;   // ecall

        rst = 1; repeat (3) @(posedge clk); rst = 0;

        // ── Phase 1: full warp ────────────────────────────────────────────────────
        $display("[tb_warp] phase 1: full warp (base_tid=0, N=8)");
        preload(8);
        run_warp(32'd0, 32'd8);
        for (i = 0; i < 8; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "full");

        // ── Phase 2: tail mask (lanes 5,6,7 inactive) ─────────────────────────────
        $display("[tb_warp] phase 2: tail mask (base_tid=0, N=5)");
        preload(8);
        run_warp(32'd0, 32'd5);
        for (i = 0; i < 5; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "tail");
        for (i = 5; i < 8; i++) expect_c(i, 32'hdead_beef, "tail-off");

        // ── Phase 3: non-zero base_tid ────────────────────────────────────────────
        $display("[tb_warp] phase 3: second warp (base_tid=8, N=16)");
        preload(16);
        run_warp(32'd8, 32'd16);
        for (i = 8; i < 16; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "warp1");

        if (errors == 0) begin
            $display("[tb_warp] PASS");
            $finish;
        end else begin
            $display("[tb_warp] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #500000;
        $display("[tb_warp] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_warp
