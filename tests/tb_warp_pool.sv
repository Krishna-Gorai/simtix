// =============================================================================
// tb_warp_pool.sv  -  M3 unit test for the multi-warp pool + round-robin sched
//
// Drives the whole grid in one launch (the pool spawns/recycles every warp) and
// checks every lane's result directly in memory. Phases:
//   1. multi-warp    N=32  -> 4 warps fill all NUM_WARPS slots; C[0..31] correct
//   2. recycling     N=64  -> 8 warps > 4 slots, so slots are recycled; C[0..63]
//   3. tail mask     N=20  -> 3 warps, last partial; C[0..19] set, C[20..23] off
//   4. latency hiding: compare cycles(4 warps) against 4 x cycles(1 warp). The
//      pool overlaps one warp's serialized memory replay with another warp's
//      compute, so a multi-warp grid finishes in FEWER cycles than running the
//      warps strictly one after another would.
// =============================================================================
`timescale 1ns/1ps

module tb_warp_pool
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */  // only addr[*:2] indexes the model memory
    logic        clk = 0;
    logic        rst;
    logic        start;
    logic [31:0] base_a, base_b, base_c, n_threads, kernel_pc;
    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_we;
    logic [3:0]  dmem_be;
    logic        busy, done;
    logic [31:0] dbg_retire_a0;

    int unsigned errors = 0;

    warp_pool dut (
        .clk(clk), .rst(rst),
        .start(start),
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

    // Arrays placed clear of each other and the kernel (64 words each).
    localparam logic [31:0] BASE_A = 32'h0000_0100;   // word 64
    localparam logic [31:0] BASE_B = 32'h0000_0300;   // word 192
    localparam logic [31:0] BASE_C = 32'h0000_0500;   // word 320

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

    // Launch the whole grid; return the cycle count from GO to DONE.
    task automatic run_grid(input logic [31:0] n, output int unsigned cyc);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = 32'd0;
        base_a = BASE_A; base_b = BASE_B; base_c = BASE_C;
        start = 1;
        @(posedge clk);
        start = 0;
        cyc = 1;                       // the launch cycle counts
        guard = 0;
        while (!done && guard < 20000) begin @(posedge clk); cyc++; guard++; end
    endtask

    task automatic expect_c(input int idx, input logic [31:0] exp, input string tag);
        logic [31:0] got;
        got = mem[widx(BASE_C) + idx];
        if (got !== exp) begin
            $display("  [FAIL] %-10s C[%0d] got=%08h exp=%08h", tag, idx, got, exp);
            errors++;
        end
    endtask

    int i;
    int unsigned cyc1, cyc4;

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0;
        base_a = 0; base_b = 0; base_c = 0;

        // vector-add kernel (a0=tid, a1=&A, a2=&B, a3=&C):
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

        // ── Phase 1: 4 warps fill all slots ───────────────────────────────────────
        $display("[tb_warp_pool] phase 1: multi-warp (N=32, fills %0d slots)", NUM_WARPS);
        preload(32);
        run_grid(32'd32, cyc4);
        for (i = 0; i < 32; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "multi");
        $display("  N=32 finished in %0d cycles", cyc4);

        // ── Phase 2: more warps than slots → recycling ────────────────────────────
        $display("[tb_warp_pool] phase 2: slot recycling (N=64, %0d slots)", NUM_WARPS);
        preload(64);
        run_grid(32'd64, cyc1);
        for (i = 0; i < 64; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "recycle");

        // ── Phase 3: tail mask on the last (partial) warp ─────────────────────────
        $display("[tb_warp_pool] phase 3: tail mask (N=20)");
        preload(64);
        run_grid(32'd20, cyc1);
        for (i = 0;  i < 20; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "tail");
        for (i = 20; i < 24; i++) expect_c(i, 32'hdead_beef, "tail-off");

        // ── Phase 4: latency hiding (4 warps vs 4 x single warp) ──────────────────
        $display("[tb_warp_pool] phase 4: latency hiding");
        preload(8);
        run_grid(32'd8, cyc1);            // one warp
        $display("  1 warp  : %0d cycles  (=> 4x serial would be %0d)", cyc1, 4*cyc1);
        $display("  4 warps : %0d cycles", cyc4);
        if (cyc4 >= 4*cyc1) begin
            $display("  [FAIL] no latency hiding: 4-warp grid not faster than serial");
            errors++;
        end else begin
            $display("  [ ok ] hid %0d cycles (%0d%% of the 4x-serial cost)",
                     4*cyc1 - cyc4, (100*cyc4)/(4*cyc1));
        end

        if (errors == 0) begin
            $display("[tb_warp_pool] PASS");
            $finish;
        end else begin
            $display("[tb_warp_pool] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #2000000;
        $display("[tb_warp_pool] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_warp_pool
