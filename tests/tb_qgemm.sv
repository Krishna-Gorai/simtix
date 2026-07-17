// =============================================================================
// tb_qgemm.sv — bit-exact golden test for the INT8 GEMM kernel (kernels/matmul/qgemm.S)
//
// AI Tier-2. Runs a full 8x8 INT8 matmul tile with K=16 on warp_pool: one warp
// per output row, one lane per output column, the K reduction done four elements
// at a time with the custom `pdot8` instruction. A (8x16 INT8, row-major) and the
// pre-packed weights Bpacked ([Kp=4][N=8] words) are preloaded; the 64 INT32
// results are read back and checked EXACTLY against a signed-integer matmul
// reference. Also prints cycles / memory transactions for the throughput story.
//
//   Build/run:  make -C sim test-qgemm
// =============================================================================
`timescale 1ns/1ps
module tb_qgemm
    import simtix_pkg::*;
#()  ;
    localparam int M  = 8;    // output rows  (= warps)
    localparam int N  = 8;    // output cols  (= lanes)
    localparam int K  = 16;   // reduction length
    localparam int KP = K/4;  // packed K words per output (pdot8 iterations)

    logic                 clk = 0;
    logic                 rst;
    logic                 start;
    logic [31:0]          base_a, base_b, base_c, n_threads, kernel_pc;
    /* verilator lint_off UNUSEDSIGNAL */   // only address sub-fields / done are read
    logic [31:0]          imem_addr, imem_data;
    logic [31:0]          dmem_addr;
    logic [LINE_BITS-1:0] dmem_wdata, dmem_rdata;
    logic                 dmem_we;
    logic [LINE_BE-1:0]   dmem_be;
    logic                 busy, done;
    logic [31:0]          dbg_retire_a0, dbg_mem_txns, dbg_divergences, dbg_scratch_txns;
    logic [31:0]          dbg_issued_insns, dbg_active_lanes;
    /* verilator lint_on UNUSEDSIGNAL */

    int unsigned errors = 0;
    int unsigned m_cyc;

    warp_pool dut (
        .clk(clk), .rst(rst), .start(start),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_rdata(dmem_rdata),
        .busy(busy), .done(done),
        .dbg_retire_a0(dbg_retire_a0), .dbg_mem_txns(dbg_mem_txns),
        .dbg_divergences(dbg_divergences), .dbg_scratch_txns(dbg_scratch_txns),
        .dbg_issued_insns(dbg_issued_insns), .dbg_active_lanes(dbg_active_lanes)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Behavioural line memory (64 KB), identical to tb_fpkernels ───────────────
    localparam int MEM_WORDS = 16384;
    logic [31:0] mem [0:MEM_WORDS-1];
    assign imem_data = mem[imem_addr[15:2]];
    logic [31:0] lbase;
    assign lbase = {18'b0, dmem_addr[15:5], 3'b000};
    always_comb
        for (int w = 0; w < LINE_WORDS; w++)
            dmem_rdata[w*32 +: 32] = mem[lbase + w];
    always @(posedge clk)
        if (dmem_we)
            for (int w = 0; w < LINE_WORDS; w++) begin
                logic [31:0] cur;
                cur = mem[lbase + w];
                for (int b = 0; b < 4; b++)
                    if (dmem_be[w*4 + b]) cur[b*8 +: 8] = dmem_wdata[w*32 + b*8 +: 8];
                mem[lbase + w] <= cur;
            end

    localparam logic [31:0] A_BASE = 32'h0000_2000;
    localparam logic [31:0] B_BASE = 32'h0000_4000;
    localparam logic [31:0] C_BASE = 32'h0000_6000;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {18'b0, byte_addr[15:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ── kernels/matmul/qgemm.S, assembled (rv32im, -Ttext=0) → 23 words ──────────
    task automatic load_kernel();
        mem[0]  = 32'h00355293; mem[1]  = 32'h00757313; mem[2]  = 32'h00429293;
        mem[3]  = 32'h005582b3; mem[4]  = 32'h00231313; mem[5]  = 32'h00660333;
        mem[6]  = 32'h00000393; mem[7]  = 32'h00000e13; mem[8]  = 32'h00400e93;
        mem[9]  = 32'h002e1f13; mem[10] = 32'h01e28f33; mem[11] = 32'h000f2f03;
        mem[12] = 32'h005e1f93; mem[13] = 32'h01f30fb3; mem[14] = 32'h000faf83;
        mem[15] = 32'h01ff040b; mem[16] = 32'h008383b3; mem[17] = 32'h001e0e13;
        mem[18] = 32'hfdde4ee3; mem[19] = 32'h00251f13; mem[20] = 32'h01e68f33;
        mem[21] = 32'h007f2023; mem[22] = 32'h00000073;
    endtask

    // ── Test matrices (raw INT8 bytes; interpreted signed for the SS pdot8) ──────
    function automatic logic [7:0] a8(input int row, input int k);
        return 8'(row*7 + k*13 + 3);
    endfunction
    function automatic logic [7:0] b8(input int k, input int col);
        return 8'(k*11 + col*17 + 5);
    endfunction

    // A : 8x16 INT8 row-major → words {A[row][4kk+3..0]} little-endian
    // B : Bpacked[kk][col] = {B[4kk+3..0][col]} little-endian, at word (kk*N+col)
    task automatic preload();
        for (int row = 0; row < M; row++)
            for (int kk = 0; kk < KP; kk++)
                mem[widx(A_BASE) + row*KP + kk] =
                    {a8(row,4*kk+3), a8(row,4*kk+2), a8(row,4*kk+1), a8(row,4*kk+0)};
        for (int kk = 0; kk < KP; kk++)
            for (int col = 0; col < N; col++)
                mem[widx(B_BASE) + kk*N + col] =
                    {b8(4*kk+3,col), b8(4*kk+2,col), b8(4*kk+1,col), b8(4*kk+0,col)};
    endtask

    // Signed-integer matmul reference (exact).
    function automatic logic [31:0] ref_c(input int row, input int col);
        int s; s = 0;
        for (int k = 0; k < K; k++)
            s += int'(signed'(a8(row,k))) * int'(signed'(b8(k,col)));
        return s;
    endfunction

    task automatic run(input logic [31:0] n);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = 0; base_a = A_BASE; base_b = B_BASE; base_c = C_BASE;
        start = 1; @(posedge clk); start = 0;
        guard = 0; m_cyc = 0;
        while (!done && guard < 200000) begin @(posedge clk); guard++; m_cyc++; end
        if (!done) begin $display("  [FAIL] timeout (guard=%0d)", guard); errors++; end
    endtask

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_kernel();
        preload();
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX INT8 GEMM (qgemm) golden test  M=%0d N=%0d K=%0d  (LANES=%0d WARPS=%0d)",
                 M, N, K, NUM_LANES, NUM_WARPS);

        run(M*N);

        for (int row = 0; row < M; row++)
            for (int col = 0; col < N; col++) begin
                logic [31:0] got, exp;
                got = mem[widx(C_BASE) + row*N + col];
                exp = ref_c(row, col);
                if (got !== exp) begin
                    $display("  [FAIL] C[%0d][%0d] got=%0d exp=%0d", row, col,
                             signed'(got), signed'(exp));
                    errors++;
                end
            end

        if (errors == 0)
            $display("  [PASS] all %0d INT8 outputs bit-exact  (%0d cycles, %0d gmem txns)",
                     M*N, m_cyc, dbg_mem_txns);
        $display("=============================================================================");
        if (errors != 0) begin $display("RESULT: FAIL (%0d errors)", errors); $fatal(1); end
        else              $display("RESULT: PASS");
        $finish;
    end

    initial begin
        #4_000_000;
        $display("RESULT: FAIL (global timeout)");
        $fatal(1);
    end
endmodule : tb_qgemm
