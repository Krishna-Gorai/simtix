// =============================================================================
// tb_warp_pool.sv  -  M3/M4 unit test for the multi-warp pool + coalescing
//
// Drives the whole grid in one launch (the pool spawns/recycles every warp) and
// checks every lane's result directly in memory. The data port is line-wide
// (LINE_WORDS words) and the memory engine coalesces each warp's per-lane
// accesses into whole-line transactions. Phases:
//   1. multi-warp    N=32  -> 4 warps fill all NUM_WARPS slots; C[0..31] correct
//   2. recycling     N=64  -> 8 warps > 4 slots, so slots are recycled; C[0..63]
//   3. tail mask     N=20  -> 3 warps, last partial; C[0..19] set, C[20..23] off
//   4. coalescing    contiguous A[tid]   -> 1 line transaction per memory op
//                    scattered A[tid*8]  -> NUM_LANES transactions per memory op
//   5. latency hiding: cycles(4 warps) < 4 x cycles(1 warp)
// =============================================================================
`timescale 1ns/1ps

module tb_warp_pool
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */  // only addr[*:2] indexes the model memory
    logic                 clk = 0;
    logic                 rst;
    logic                 start;
    logic [31:0]          base_a, base_b, base_c, n_threads, kernel_pc;
    logic [31:0]          imem_addr, imem_data;
    logic [31:0]          dmem_addr;
    logic [LINE_BITS-1:0] dmem_wdata, dmem_rdata;
    logic                 dmem_we;
    logic [LINE_BE-1:0]   dmem_be;
    logic                 busy, done;
    logic [31:0]          dbg_retire_a0, dbg_mem_txns, dbg_divergences;

    int unsigned errors = 0;

    warp_pool dut (
        .clk(clk), .rst(rst),
        .start(start),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_rdata(dmem_rdata),
        .busy(busy), .done(done),
        .dbg_retire_a0(dbg_retire_a0), .dbg_mem_txns(dbg_mem_txns),
        .dbg_divergences(dbg_divergences)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Shared memory; the data port reads/writes a whole line at a time ──────────
    localparam int MEM_WORDS = 1024;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign imem_data = mem[imem_addr[11:2]];

    // The data port drives a line-aligned byte address; lbase is its word index.
    logic [31:0] lbase;
    assign lbase = {22'b0, dmem_addr[11:5], 3'b000};

    always_comb
        for (int w = 0; w < LINE_WORDS; w++)
            dmem_rdata[w*32 +: 32] = mem[lbase + w];

    always @(posedge clk) begin
        if (dmem_we)
            for (int w = 0; w < LINE_WORDS; w++) begin
                logic [31:0] cur;
                cur = mem[lbase + w];
                for (int b = 0; b < 4; b++)
                    if (dmem_be[w*4 + b]) cur[b*8 +: 8] = dmem_wdata[w*32 + b*8 +: 8];
                mem[lbase + w] <= cur;
            end
    end

    // Arrays placed clear of each other and the kernel, line-aligned (64 words).
    localparam logic [31:0] BASE_A = 32'h0000_0100;   // word 64
    localparam logic [31:0] BASE_B = 32'h0000_0300;   // word 192
    localparam logic [31:0] BASE_C = 32'h0000_0500;   // word 320

    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {22'b0, byte_addr[11:2]};
    endfunction

    // Reload A,B and poison C for the strided index set k*stride, k=0..hi-1.
    task automatic preload(input int hi, input int stride);
        for (int k = 0; k < hi; k++) begin
            int idx = k * stride;
            mem[widx(BASE_A) + idx] = 32'd10  + idx;
            mem[widx(BASE_B) + idx] = 32'd100 + 2*idx;
            mem[widx(BASE_C) + idx] = 32'hdead_beef;
        end
    endtask

    // Launch the whole grid; return cycle count (GO..DONE) and line-txn count.
    task automatic run_grid(input  logic [31:0] n, input logic [31:0] kpc,
                            output int unsigned cyc, output int unsigned txns);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = kpc;
        base_a = BASE_A; base_b = BASE_B; base_c = BASE_C;
        start = 1;
        @(posedge clk);
        start = 0;
        cyc = 1;                       // the launch cycle counts
        guard = 0;
        while (!done && guard < 20000) begin @(posedge clk); cyc++; guard++; end
        txns = dbg_mem_txns;
    endtask

    task automatic expect_c(input int idx, input logic [31:0] exp, input string tag);
        logic [31:0] got;
        got = mem[widx(BASE_C) + idx];
        if (got !== exp) begin
            $display("  [FAIL] %-10s C[%0d] got=%08h exp=%08h", tag, idx, got, exp);
            errors++;
        end
    endtask

    task automatic load_vadd_kernel(input int at, input logic [31:0] slli_shift);
        // a0=tid, a1=&A, a2=&B, a3=&C ; first instr scales tid by 2^slli_shift.
        mem[at+0] = (slli_shift == 2) ? 32'h00251293 : 32'h00551293; // slli t0,a0,sh
        mem[at+1] = 32'h00558333;   // add  t1, a1, t0
        mem[at+2] = 32'h00032383;   // lw   t2, 0(t1)
        mem[at+3] = 32'h00560e33;   // add  t3, a2, t0
        mem[at+4] = 32'h000e2e83;   // lw   t4, 0(t3)
        mem[at+5] = 32'h01d383b3;   // add  t2, t2, t4
        mem[at+6] = 32'h00568f33;   // add  t5, a3, t0
        mem[at+7] = 32'h007f2023;   // sw   t2, 0(t5)
        mem[at+8] = 32'h00000073;   // ecall
    endtask

    // Divergent vector-add: C[tid] = A[tid] + B[tid], and odd lanes add 1000.
    //   a0=tid, a1=&A, a2=&B, a3=&C
    //   andi t5, a0, 1 ; beq t5,x0,skip ; (odd:) addi t2,t2,1000 ; skip: sw ; ecall
    // The single-sided `if (tid & 1)` makes lanes diverge inside the warp; they
    // reconverge at the store. (Even lanes take the forward branch and wait.)
    task automatic load_div_kernel(input int at);
        mem[at+0]  = 32'h00251293;   // slli t0, a0, 2
        mem[at+1]  = 32'h00558333;   // add  t1, a1, t0
        mem[at+2]  = 32'h00032383;   // lw   t2, 0(t1)
        mem[at+3]  = 32'h00560e33;   // add  t3, a2, t0
        mem[at+4]  = 32'h000e2e83;   // lw   t4, 0(t3)
        mem[at+5]  = 32'h01d383b3;   // add  t2, t2, t4
        mem[at+6]  = 32'h00157f13;   // andi t5, a0, 1
        mem[at+7]  = 32'h000f0463;   // beq  t5, x0, +8  (skip the addi)
        mem[at+8]  = 32'h3e838393;   // addi t2, t2, 1000   <- divergent body
        mem[at+9]  = 32'h00568fb3;   // add  t6, a3, t0
        mem[at+10] = 32'h007fa023;   // sw   t2, 0(t6)
        mem[at+11] = 32'h00000073;   // ecall
    endtask

    int i;
    int unsigned cyc1, cyc4, txn_c, txn_s, dummy;

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0;
        base_a = 0; base_b = 0; base_c = 0;

        load_vadd_kernel(0,  32'd2);   // contiguous kernel @ word 0  (tid*4)
        load_vadd_kernel(16, 32'd5);   // scattered  kernel @ word 16 (tid*32)
        load_div_kernel(32);           // divergent  kernel @ word 32 (kpc=0x80)

        rst = 1; repeat (3) @(posedge clk); rst = 0;

        // ── Phase 1: 4 warps fill all slots ───────────────────────────────────────
        $display("[tb_warp_pool] phase 1: multi-warp (N=32, fills %0d slots)", NUM_WARPS);
        preload(32, 1);
        run_grid(32'd32, 32'd0, cyc4, dummy);
        for (i = 0; i < 32; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "multi");
        $display("  N=32 finished in %0d cycles", cyc4);

        // ── Phase 2: more warps than slots → recycling ────────────────────────────
        $display("[tb_warp_pool] phase 2: slot recycling (N=64, %0d slots)", NUM_WARPS);
        preload(64, 1);
        run_grid(32'd64, 32'd0, dummy, dummy);
        for (i = 0; i < 64; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "recycle");

        // ── Phase 3: tail mask on the last (partial) warp ─────────────────────────
        $display("[tb_warp_pool] phase 3: tail mask (N=20)");
        preload(64, 1);
        run_grid(32'd20, 32'd0, dummy, dummy);
        for (i = 0;  i < 20; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "tail");
        for (i = 20; i < 24; i++) expect_c(i, 32'hdead_beef, "tail-off");

        // ── Phase 4: coalescing — contiguous vs scattered (one warp, 3 mem ops) ───
        $display("[tb_warp_pool] phase 4: coalescing (N=8, 3 memory ops/warp)");
        preload(8, 1);
        run_grid(32'd8, 32'd0, cyc1, txn_c);          // contiguous (tid*4)
        for (i = 0; i < 8; i++) expect_c(i, (32'd10 + i) + (32'd100 + 2*i), "coal");
        preload(8, 8);
        run_grid(32'd8, 32'd64, dummy, txn_s);        // scattered  (tid*32), kpc=word16
        for (i = 0; i < 8; i++)
            expect_c(i*8, (32'd10 + i*8) + (32'd100 + 2*i*8), "scatter");
        $display("  contiguous : %0d line transactions (expect 3)", txn_c);
        $display("  scattered  : %0d line transactions (expect %0d)", txn_s, 3*NUM_LANES);
        if (txn_c != 3) begin
            $display("  [FAIL] contiguous access did not coalesce to 1 line/op");
            errors++;
        end
        if (txn_s != 3*NUM_LANES) begin
            $display("  [FAIL] scattered access did not produce 1 line/lane/op");
            errors++;
        end
        if (txn_c < txn_s)
            $display("  [ ok ] coalescing cut %0d transactions to %0d (%0dx)",
                     txn_s, txn_c, txn_s/txn_c);

        // ── Phase 5: latency hiding (4 warps vs 4 x single warp) ──────────────────
        $display("[tb_warp_pool] phase 5: latency hiding");
        $display("  1 warp  : %0d cycles  (=> 4x serial would be %0d)", cyc1, 4*cyc1);
        $display("  4 warps : %0d cycles", cyc4);
        if (cyc4 >= 4*cyc1) begin
            $display("  [FAIL] no latency hiding: 4-warp grid not faster than serial");
            errors++;
        end else begin
            $display("  [ ok ] hid %0d cycles (%0d%% of the 4x-serial cost)",
                     4*cyc1 - cyc4, (100*cyc4)/(4*cyc1));
        end

        // ── Phase 6: control divergence — single-sided if + reconvergence ─────────
        $display("[tb_warp_pool] phase 6: control divergence (odd lanes branch)");
        preload(16, 1);
        run_grid(32'd16, 32'd128, dummy, dummy);     // 2 warps, kpc = word 32
        for (i = 0; i < 16; i++) begin
            automatic logic [31:0] exp = (32'd10 + i) + (32'd100 + 2*i)
                                       + ((i % 2 == 1) ? 32'd1000 : 32'd0);
            expect_c(i, exp, "diverge");
        end
        $display("  divergent-branch events: %0d (expect 2, one per warp)",
                 dbg_divergences);
        if (dbg_divergences != 2) begin
            $display("  [FAIL] expected exactly 2 divergent branches");
            errors++;
        end else begin
            $display("  [ ok ] lanes diverged and reconverged; C correct per lane");
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
