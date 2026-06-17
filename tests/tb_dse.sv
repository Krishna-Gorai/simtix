// =============================================================================
// tb_dse.sv  -  design-space-exploration harness (Part-2 lanes/warps sweep)
//
// Runs the lane-count-agnostic kernels (vadd, saxpy, fir, relu, collatz) on the
// warp_pool engine at whatever NUM_LANES / NUM_WARPS the package was elaborated
// with (override via +define+SIMTIX_NUM_LANES / SIMTIX_NUM_WARPS), verifies the
// results bit-exact, and emits one "DSE," CSV row per kernel so a sweep over
// configurations can be aggregated for throughput / Pareto analysis:
//
//   make dse LANES=16 WARPS=4 | grep '^DSE,' >> docs/dse_perf.csv
//
// reduce/matmul are intentionally excluded: they hardcode 8 lanes per warp.
// The memory model is fully parameterized in LINE_WORDS/LINE_OFF/LINE_BITS, so
// it tracks the (lane-sized) coalescing line at every configuration.
// =============================================================================
`timescale 1ns/1ps

module tb_dse
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */
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
    logic [31:0]          dbg_retire_a0, dbg_mem_txns, dbg_divergences, dbg_scratch_txns;
    logic [31:0]          dbg_issued_insns, dbg_active_lanes;

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

    // ── Parameterized line memory (tracks LINE_WORDS at every config) ─────────────
    localparam int MEM_WORDS = 16384;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign imem_data = mem[imem_addr[15:2]];

    logic [31:0] lbase;                                       // word index of line base
    assign lbase = (dmem_addr >> LINE_OFF) << LINE_WOFFW;     // general (any line size)

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

    // ── Kernel placement + data arrays (8 KB-aligned, line-aligned for any size) ──
    localparam int W_VADD=0, W_SAXPY=64, W_FIR=128, W_RELU=192, W_COLLATZ=256;
    localparam logic [31:0] A_BASE = 32'h0000_2000;   // +2 halo for fir
    localparam logic [31:0] B_BASE = 32'h0000_4000;
    localparam logic [31:0] C_BASE = 32'h0000_6000;

    function automatic int unsigned widx(input logic [31:0] b);
        widx = {18'b0, b[15:2]};
    endfunction

    task automatic load_kernels();
        mem[W_VADD+0]=32'h00251293; mem[W_VADD+1]=32'h00558333; mem[W_VADD+2]=32'h00032383;
        mem[W_VADD+3]=32'h00560e33; mem[W_VADD+4]=32'h000e2e83; mem[W_VADD+5]=32'h01d383b3;
        mem[W_VADD+6]=32'h00568f33; mem[W_VADD+7]=32'h007f2023; mem[W_VADD+8]=32'h00000073;

        mem[W_SAXPY+0]=32'h00251293; mem[W_SAXPY+1]=32'h00558333; mem[W_SAXPY+2]=32'h00032383;
        mem[W_SAXPY+3]=32'h00560e33; mem[W_SAXPY+4]=32'h000e2e83; mem[W_SAXPY+5]=32'h00300f13;
        mem[W_SAXPY+6]=32'h03e383b3; mem[W_SAXPY+7]=32'h01d383b3; mem[W_SAXPY+8]=32'h00568fb3;
        mem[W_SAXPY+9]=32'h007fa023; mem[W_SAXPY+10]=32'h00000073;

        mem[W_FIR+0]=32'h00251293; mem[W_FIR+1]=32'h00558333; mem[W_FIR+2]=32'h00032383;
        mem[W_FIR+3]=32'h00432e03; mem[W_FIR+4]=32'h00832e83; mem[W_FIR+5]=32'h001e1e13;
        mem[W_FIR+6]=32'h01c38f33; mem[W_FIR+7]=32'h01df0f33; mem[W_FIR+8]=32'h00568fb3;
        mem[W_FIR+9]=32'h01efa023; mem[W_FIR+10]=32'h00000073;

        mem[W_RELU+0]=32'h00251293; mem[W_RELU+1]=32'h00558333; mem[W_RELU+2]=32'h00032383;
        mem[W_RELU+3]=32'h0003d463; mem[W_RELU+4]=32'h00000393; mem[W_RELU+5]=32'h00568fb3;
        mem[W_RELU+6]=32'h007fa023; mem[W_RELU+7]=32'h00000073;

        mem[W_COLLATZ+0]=32'h00251293;  mem[W_COLLATZ+1]=32'h00558333;  mem[W_COLLATZ+2]=32'h00032383;
        mem[W_COLLATZ+3]=32'h00000e13;  mem[W_COLLATZ+4]=32'h00000413;  mem[W_COLLATZ+5]=32'h02000493;
        mem[W_COLLATZ+6]=32'h00100e93;  mem[W_COLLATZ+7]=32'h03d38263;  mem[W_COLLATZ+8]=32'h0013ff13;
        mem[W_COLLATZ+9]=32'h000f0863;  mem[W_COLLATZ+10]=32'h00139f93; mem[W_COLLATZ+11]=32'h01f383b3;
        mem[W_COLLATZ+12]=32'h00138393; mem[W_COLLATZ+13]=32'h000f1463; mem[W_COLLATZ+14]=32'h0013d393;
        mem[W_COLLATZ+15]=32'h001e0e13; mem[W_COLLATZ+16]=32'h00140413; mem[W_COLLATZ+17]=32'hfc944ae3;
        mem[W_COLLATZ+18]=32'h00568fb3; mem[W_COLLATZ+19]=32'h01cfa023; mem[W_COLLATZ+20]=32'h00000073;
    endtask

    int unsigned m_cyc, m_gmem, m_div, m_insn, m_act;
    task automatic run(input logic [31:0] n, input logic [31:0] kpc,
                       input logic [31:0] ba, input logic [31:0] bb, input logic [31:0] bc);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = kpc; base_a = ba; base_b = bb; base_c = bc;
        start = 1; @(posedge clk); start = 0;
        m_cyc = 1; guard = 0;
        while (!done && guard < 2000000) begin @(posedge clk); m_cyc++; guard++; end
        m_gmem = dbg_mem_txns; m_div = dbg_divergences;
        m_insn = dbg_issued_insns; m_act = dbg_active_lanes;
    endtask

    function automatic int unsigned csteps(input logic [31:0] n0);
        logic [31:0] n; int unsigned s;
        n = n0; s = 0;
        for (int it = 0; it < 32; it++)
            if (n != 32'd1) begin n = n[0] ? (3*n + 32'd1) : (n >> 1); s++; end
        csteps = s;
    endfunction

    task automatic chk(input int idx, input logic [31:0] exp, input string tag);
        if (mem[widx(C_BASE)+idx] !== exp) begin
            $display("  [FAIL] L=%0d W=%0d %-8s C[%0d] got=%0d exp=%0d",
                     NUM_LANES, NUM_WARPS, tag, idx, $signed(mem[widx(C_BASE)+idx]), $signed(exp));
            errors++;
        end
    endtask

    task automatic preload_stream(input int n);
        for (int i = 0; i < n+2; i++) mem[widx(A_BASE) + i] = 32'd10  + i[31:0];
        for (int i = 0; i < n;   i++) mem[widx(B_BASE) + i] = 32'd100 + 2*i[31:0];
        for (int i = 0; i < n;   i++) mem[widx(C_BASE) + i] = 32'hdead_beef;
    endtask

    task automatic emit(input string name, input int unsigned n);
        // throughput = active lane-instructions / cycle (work retired per cycle)
        $display("  L=%2d W=%0d  %-8s N=%4d | cyc %6d  act %7d  thr %0d.%02d  gmem %5d  div %5d",
                 NUM_LANES, NUM_WARPS, name, n, m_cyc, m_act,
                 (100*m_act)/m_cyc/100, (100*m_act)/m_cyc%100, m_gmem, m_div);
        $display("DSE,%0d,%0d,%s,%0d,%0d,%0d,%0d,%0d",
                 NUM_LANES, NUM_WARPS, name, n, m_cyc, m_act, m_gmem, m_div);
    endtask

    int i;

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_kernels();
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        // Streaming / divergent kernels at N=1024 (collatz at N=256 — heavy).
        preload_stream(1024);
        run(32'd1024, 32'(W_VADD*4), A_BASE, B_BASE, C_BASE);
        for (i = 0; i < 1024; i++) chk(i, (32'd10+i)+(32'd100+2*i), "vadd");
        emit("vadd", 1024);

        preload_stream(1024);
        run(32'd1024, 32'(W_SAXPY*4), A_BASE, B_BASE, C_BASE);
        for (i = 0; i < 1024; i++) chk(i, 32'd3*(32'd10+i)+(32'd100+2*i), "saxpy");
        emit("saxpy", 1024);

        preload_stream(1024);
        run(32'd1024, 32'(W_FIR*4), A_BASE, B_BASE, C_BASE);
        for (i = 0; i < 1024; i++) chk(i, (32'd10+i)+2*(32'd11+i)+(32'd12+i), "fir");
        emit("fir", 1024);

        for (i = 0; i < 1024; i++) mem[widx(A_BASE)+i] = (i % 2 == 1) ? (32'd1+i) : -(32'd1+i);
        for (i = 0; i < 1024; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
        run(32'd1024, 32'(W_RELU*4), A_BASE, B_BASE, C_BASE);
        for (i = 0; i < 1024; i++) chk(i, (i % 2 == 1) ? (32'd1+i) : 32'd0, "relu");
        emit("relu", 1024);

        for (i = 0; i < 256; i++) mem[widx(A_BASE)+i] = (i & 7) + 32'd2;
        for (i = 0; i < 256; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
        run(32'd256, 32'(W_COLLATZ*4), A_BASE, B_BASE, C_BASE);
        for (i = 0; i < 256; i++) chk(i, csteps((i & 7) + 32'd2), "collatz");
        emit("collatz", 256);

        if (errors == 0) begin
            $display("[tb_dse] PASS  (NUM_LANES=%0d NUM_WARPS=%0d)", NUM_LANES, NUM_WARPS);
            $finish;
        end else begin
            $display("[tb_dse] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #40000000;
        $display("[tb_dse] TIMEOUT (NUM_LANES=%0d NUM_WARPS=%0d)", NUM_LANES, NUM_WARPS);
        $fatal(1);
    end

endmodule : tb_dse
