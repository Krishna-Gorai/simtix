// =============================================================================
// tb_qgemv.sv — bit-exact golden test for the INT8 GEMV kernel (kernels/matmul/qgemv.S)
//
// AI-4. Runs out[n] = sum_{k=0..K-1} x[k]*W[k][n] on warp_pool with N=16, K=32
// (2 warps, Kp=8), exercising the parameterized Kp (config word) and the
// coalesced x-broadcast / W-column layout. Outputs checked exactly against a
// signed-integer reference.  Build/run: make -C sim test-qgemv
// =============================================================================
`timescale 1ns/1ps
module tb_qgemv
    import simtix_pkg::*;
#()  ;
    localparam int N  = 16;   // outputs (= threads/lanes across warps)
    localparam int K  = 32;   // reduction length
    localparam int KP = K/4;  // packed K words (pdot8 iterations) = 8

    logic                 clk = 0;
    logic                 rst;
    logic                 start;
    logic [31:0]          base_a, base_b, base_c, n_threads, kernel_pc;
    /* verilator lint_off UNUSEDSIGNAL */
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

    localparam logic [31:0] CFG    = 32'h0000_0100;   // config word: Kp
    localparam logic [31:0] A_BASE = 32'h0000_2000;   // &x  (int8[K])
    localparam logic [31:0] B_BASE = 32'h0000_4000;   // &Wpacked [Kp][N]
    localparam logic [31:0] C_BASE = 32'h0000_6000;   // &out (int32[N])

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {18'b0, byte_addr[15:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // kernels/matmul/qgemv.S assembled → 20 words
    task automatic load_kernel();
        mem[ 0]=32'h10000293; mem[ 1]=32'h0002a303; mem[ 2]=32'h00251393; mem[ 3]=32'h007603b3;
        mem[ 4]=32'h00271e13; mem[ 5]=32'h00058e93; mem[ 6]=32'h00000f13; mem[ 7]=32'h00000f93;
        mem[ 8]=32'h000ea403; mem[ 9]=32'h0003a483; mem[10]=32'h0094090b; mem[11]=32'h012f0f33;
        mem[12]=32'h004e8e93; mem[13]=32'h01c383b3; mem[14]=32'h001f8f93; mem[15]=32'hfe6fc2e3;
        mem[16]=32'h00251993; mem[17]=32'h013689b3; mem[18]=32'h01e9a023; mem[19]=32'h00000073;
    endtask

    function automatic logic [7:0] x8(input int k);           return 8'(k*5 + 3);        endfunction
    function automatic logic [7:0] w8(input int k, input int n); return 8'(k*7 + n*11 + 1); endfunction

    task automatic preload();
        mem[widx(CFG)] = KP;                                   // config: Kp
        for (int kk = 0; kk < KP; kk++)
            mem[widx(A_BASE) + kk] =
                {x8(4*kk+3), x8(4*kk+2), x8(4*kk+1), x8(4*kk+0)};
        for (int kk = 0; kk < KP; kk++)
            for (int n = 0; n < N; n++)
                mem[widx(B_BASE) + kk*N + n] =
                    {w8(4*kk+3,n), w8(4*kk+2,n), w8(4*kk+1,n), w8(4*kk+0,n)};
    endtask

    function automatic logic [31:0] ref_out(input int n);
        int s; s = 0;
        for (int k = 0; k < K; k++)
            s += int'(signed'(x8(k))) * int'(signed'(w8(k,n)));
        return s;
    endfunction

    task automatic run(input logic [31:0] nthr);
        int unsigned guard;
        @(posedge clk);
        n_threads = nthr; kernel_pc = 0; base_a = A_BASE; base_b = B_BASE; base_c = C_BASE;
        start = 1; @(posedge clk); start = 0;
        guard = 0;
        while (!done && guard < 200000) begin @(posedge clk); guard++; end
        if (!done) begin $display("  [FAIL] timeout"); errors++; end
    endtask

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_kernel();
        preload();
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX INT8 GEMV (qgemv) golden test  N=%0d K=%0d  (LANES=%0d WARPS=%0d)",
                 N, K, NUM_LANES, NUM_WARPS);

        run(N);

        for (int n = 0; n < N; n++) begin
            logic [31:0] got, exp;
            got = mem[widx(C_BASE) + n]; exp = ref_out(n);
            if (got !== exp) begin
                $display("  [FAIL] out[%0d] got=%0d exp=%0d", n, signed'(got), signed'(exp));
                errors++;
            end
        end

        if (errors == 0) $display("  [PASS] all %0d GEMV outputs bit-exact", N);
        $display("=============================================================================");
        if (errors != 0) begin $display("RESULT: FAIL (%0d errors)", errors); $fatal(1); end
        else              $display("RESULT: PASS");
        $finish;
    end

    initial begin
        #4_000_000; $display("RESULT: FAIL (global timeout)"); $fatal(1);
    end
endmodule : tb_qgemv
