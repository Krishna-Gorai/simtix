// =============================================================================
// tb_bench.sv  -  SIMTiX benchmark-suite harness (publication evaluation)
//
// Drives the warp_pool engine through a suite of kernels at several problem
// sizes, verifies every result against a golden model computed in the testbench,
// and reports the measured microarchitectural metrics that the paper plots:
//
//     cycles            GO..DONE latency of the launch  (throughput)
//     gmem_txns         global cache-line transactions  (DRAM traffic / coalescing)
//     scratch_txns      on-chip scratchpad transactions (data-reuse / locality)
//     divergences       divergent-branch events         (control-divergence cost)
//     issued / active   datapath instrs and Σ active lanes (SIMT/energy efficiency)
//     lane-util %       active / (NUM_LANES * issued)
//     scalar-IPC        active / cycles = scalar-equivalent instrs retired per cycle
//                       (a 1-lane in-order scalar core would need ~`active` cycles,
//                        so this is also the SIMT throughput speedup over that model;
//                        memory-latency differences are out of this first-order model
//                        — the measured host-CPU baseline is a separate study.)
//
// Each row is also printed prefixed "CSV," so a run log can be grep'd straight
// into a .csv for plotting:  make bench | grep '^CSV,' > docs/bench.csv
//
// The kernels are the assembled images in kernels/*/ (see build_kernels.sh); the
// machine words are embedded below so the harness needs no $readmemh / file path.
// =============================================================================
`timescale 1ns/1ps

module tb_bench
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

    // ── Behavioural line memory (64 KB, line-wide read + byte-enabled write) ──────
    // Wider than tb_warp_pool's 4 KB model so the suite can run up to N=1024.
    localparam int MEM_WORDS = 16384;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign imem_data = mem[imem_addr[15:2]];

    logic [31:0] lbase;                              // word index of the line base
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

    // ── Kernel placement (word address; byte kpc = 4*word) ───────────────────────
    localparam int W_VADD    = 0;     // kpc 0x000
    localparam int W_SAXPY   = 64;    // kpc 0x100
    localparam int W_FIR     = 128;   // kpc 0x200
    localparam int W_RELU    = 192;   // kpc 0x300
    localparam int W_COLLATZ = 256;   // kpc 0x400
    localparam int W_REDUCE  = 320;   // kpc 0x500
    localparam int W_MMSMEM  = 384;   // kpc 0x600
    localparam int W_MMNAIVE = 448;   // kpc 0x700

    // ── Data arrays (word indices), sized for N up to 1024, mutually clear ───────
    localparam logic [31:0] A_BASE = 32'h0000_2000;   // word 2048  (+2 halo for fir)
    localparam logic [31:0] B_BASE = 32'h0000_4000;   // word 4096
    localparam logic [31:0] C_BASE = 32'h0000_6000;   // word 6144
    // Matmul-row arrays (small; used at N=8), clear of the streaming arrays above.
    localparam logic [31:0] MM_A   = 32'h0000_1000;   // word 1024  (8 words)
    localparam logic [31:0] MM_B   = 32'h0000_1080;   // word 1056  (64 words)
    localparam logic [31:0] MM_C   = 32'h0000_1200;   // word 1152  (8 words)
    localparam int MM_K = 8, MM_NCOL = 8;

    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {18'b0, byte_addr[15:2]};
    endfunction

    // ── Embedded kernel images (from kernels/*/*.hex, see build_kernels.sh) ───────
    task automatic load_all_kernels();
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

        mem[W_REDUCE+0]=32'h00757293;  mem[W_REDUCE+1]=32'h00229313;  mem[W_REDUCE+2]=32'h400003b7;
        mem[W_REDUCE+3]=32'h006383b3;  mem[W_REDUCE+4]=32'h00251e13;  mem[W_REDUCE+5]=32'h01c58eb3;
        mem[W_REDUCE+6]=32'h000eaf03;  mem[W_REDUCE+7]=32'h01e3a023;  mem[W_REDUCE+8]=32'h04029e63;
        mem[W_REDUCE+9]=32'h400003b7;  mem[W_REDUCE+10]=32'h00000f93; mem[W_REDUCE+11]=32'h0003a303;
        mem[W_REDUCE+12]=32'h006f8fb3; mem[W_REDUCE+13]=32'h0043a303; mem[W_REDUCE+14]=32'h006f8fb3;
        mem[W_REDUCE+15]=32'h0083a303; mem[W_REDUCE+16]=32'h006f8fb3; mem[W_REDUCE+17]=32'h00c3a303;
        mem[W_REDUCE+18]=32'h006f8fb3; mem[W_REDUCE+19]=32'h0103a303; mem[W_REDUCE+20]=32'h006f8fb3;
        mem[W_REDUCE+21]=32'h0143a303; mem[W_REDUCE+22]=32'h006f8fb3; mem[W_REDUCE+23]=32'h0183a303;
        mem[W_REDUCE+24]=32'h006f8fb3; mem[W_REDUCE+25]=32'h01c3a303; mem[W_REDUCE+26]=32'h006f8fb3;
        mem[W_REDUCE+27]=32'h00355e13; mem[W_REDUCE+28]=32'h002e1e13; mem[W_REDUCE+29]=32'h01c68eb3;
        mem[W_REDUCE+30]=32'h01fea023; mem[W_REDUCE+31]=32'h00000073;

        mem[W_MMSMEM+0]=32'h00251f93;  mem[W_MMSMEM+1]=32'h01f58fb3;  mem[W_MMSMEM+2]=32'h000fa303;
        mem[W_MMSMEM+3]=32'h40000e37;  mem[W_MMSMEM+4]=32'h00251f93;  mem[W_MMSMEM+5]=32'h01fe0fb3;
        mem[W_MMSMEM+6]=32'h006fa023;  mem[W_MMSMEM+7]=32'h00000393;  mem[W_MMSMEM+8]=32'h00000293;
        mem[W_MMSMEM+9]=32'h00229f93;  mem[W_MMSMEM+10]=32'h40000e37; mem[W_MMSMEM+11]=32'h01fe0fb3;
        mem[W_MMSMEM+12]=32'h000fa303; mem[W_MMSMEM+13]=32'h02e28e33; mem[W_MMSMEM+14]=32'h00ae0e33;
        mem[W_MMSMEM+15]=32'h002e1e13; mem[W_MMSMEM+16]=32'h01c60eb3; mem[W_MMSMEM+17]=32'h000eaf03;
        mem[W_MMSMEM+18]=32'h03e30f33; mem[W_MMSMEM+19]=32'h01e383b3; mem[W_MMSMEM+20]=32'h00128293;
        mem[W_MMSMEM+21]=32'h00800f93; mem[W_MMSMEM+22]=32'hfdf2c6e3; mem[W_MMSMEM+23]=32'h00251f93;
        mem[W_MMSMEM+24]=32'h01f68fb3; mem[W_MMSMEM+25]=32'h007fa023; mem[W_MMSMEM+26]=32'h00000073;

        mem[W_MMNAIVE+0]=32'h00000393;  mem[W_MMNAIVE+1]=32'h00000293;  mem[W_MMNAIVE+2]=32'h00229f93;
        mem[W_MMNAIVE+3]=32'h01f58fb3;  mem[W_MMNAIVE+4]=32'h000fa303;  mem[W_MMNAIVE+5]=32'h02e28e33;
        mem[W_MMNAIVE+6]=32'h00ae0e33;  mem[W_MMNAIVE+7]=32'h002e1e13;  mem[W_MMNAIVE+8]=32'h01c60eb3;
        mem[W_MMNAIVE+9]=32'h000eaf03;  mem[W_MMNAIVE+10]=32'h03e30f33; mem[W_MMNAIVE+11]=32'h01e383b3;
        mem[W_MMNAIVE+12]=32'h00128293; mem[W_MMNAIVE+13]=32'h00800f93; mem[W_MMNAIVE+14]=32'hfdf2c8e3;
        mem[W_MMNAIVE+15]=32'h00251f93; mem[W_MMNAIVE+16]=32'h01f68fb3; mem[W_MMNAIVE+17]=32'h007fa023;
        mem[W_MMNAIVE+18]=32'h00000073;
    endtask

    // ── Launch one grid; capture cycles + all debug counters ──────────────────────
    int unsigned m_cyc, m_gmem, m_scr, m_div, m_insn, m_act;
    task automatic run(input logic [31:0] n, input logic [31:0] kpc,
                       input logic [31:0] ba, input logic [31:0] bb, input logic [31:0] bc);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = kpc; base_a = ba; base_b = bb; base_c = bc;
        start = 1; @(posedge clk); start = 0;
        m_cyc = 1; guard = 0;
        while (!done && guard < 400000) begin @(posedge clk); m_cyc++; guard++; end
        m_gmem = dbg_mem_txns;   m_scr = dbg_scratch_txns; m_div = dbg_divergences;
        m_insn = dbg_issued_insns; m_act = dbg_active_lanes;
    endtask

    // lane-utilisation in parts-per-thousand and scalar-IPC ×100.
    function automatic int unsigned util_pm(input int unsigned insn, input int unsigned act);
        util_pm = (insn == 0) ? 1000 : (1000 * act) / (NUM_LANES * insn);
    endfunction
    function automatic int unsigned ipc_x100(input int unsigned act, input int unsigned cyc);
        ipc_x100 = (cyc == 0) ? 0 : (100 * act) / cyc;
    endfunction

    task automatic report(input string name, input int unsigned n);
        int unsigned u, ipc;
        u   = util_pm(m_insn, m_act);
        ipc = ipc_x100(m_act, m_cyc);
        $display("  %-9s %4d | %6d %5d %6d %6d | %6d %7d  %0d.%01d%%  %0d.%02d",
                 name, n, m_cyc, m_gmem, m_scr, m_div, m_insn, m_act,
                 u/10, u%10, ipc/100, ipc%100);
        $display("CSV,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                 name, n, m_cyc, m_gmem, m_scr, m_div, m_insn, m_act, u, ipc);
    endtask

    // ── Golden model helpers ──────────────────────────────────────────────────────
    function automatic int unsigned csteps(input logic [31:0] n0);   // capped Collatz
        logic [31:0] n; int unsigned s;
        n = n0; s = 0;
        for (int it = 0; it < 32; it++)
            if (n != 32'd1) begin
                n = n[0] ? (3*n + 32'd1) : (n >> 1);
                s++;
            end
        csteps = s;
    endfunction

    task automatic chk(input int idx, input logic [31:0] exp, input string tag);
        logic [31:0] got;
        got = mem[widx(C_BASE) + idx];
        if (got !== exp) begin
            $display("  [FAIL] %-8s C[%0d] got=%0d (%08h) exp=%0d (%08h)",
                     tag, idx, $signed(got), got, $signed(exp), exp);
            errors++;
        end
    endtask

    // Preload streaming inputs.  A[i]=10+i (+2-halo), B[i]=100+2i, C=poison.
    task automatic preload_stream(input int n);
        for (int i = 0; i < n+2; i++) mem[widx(A_BASE) + i] = 32'd10  + i[31:0];
        for (int i = 0; i < n;   i++) mem[widx(B_BASE) + i] = 32'd100 + 2*i[31:0];
        for (int i = 0; i < n;   i++) mem[widx(C_BASE) + i] = 32'hdead_beef;
    endtask

    int i;
    int unsigned sizes [4] = '{8, 64, 256, 1024};

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_all_kernels();

        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX benchmark suite  (NUM_LANES=%0d  WARP_SIZE=%0d  NUM_WARPS=%0d)",
                 NUM_LANES, WARP_SIZE, NUM_WARPS);
        $display("  kernel      N  | cycles  gmem  scrat  diver |  insn active lane-u  s-IPC");
        $display("  --------------------------------------------------------------------------");

        // ── vadd : C[i]=A[i]+B[i]  (baseline streaming, coalesced) ────────────────
        foreach (sizes[s]) begin
            preload_stream(sizes[s]);
            run(sizes[s], 32'(W_VADD*4), A_BASE, B_BASE, C_BASE);
            for (i = 0; i < sizes[s]; i++) chk(i, (32'd10+i) + (32'd100+2*i), "vadd");
            report("vadd", sizes[s]);
        end

        // ── saxpy : C[i]=3*A[i]+B[i]  (mul, coalesced) ────────────────────────────
        foreach (sizes[s]) begin
            preload_stream(sizes[s]);
            run(sizes[s], 32'(W_SAXPY*4), A_BASE, B_BASE, C_BASE);
            for (i = 0; i < sizes[s]; i++) chk(i, 32'd3*(32'd10+i) + (32'd100+2*i), "saxpy");
            report("saxpy", sizes[s]);
        end

        // ── fir : C[i]=A[i]+2A[i+1]+A[i+2]  (stencil, partial coalescing) ─────────
        foreach (sizes[s]) begin
            preload_stream(sizes[s]);
            run(sizes[s], 32'(W_FIR*4), A_BASE, B_BASE, C_BASE);
            for (i = 0; i < sizes[s]; i++)
                chk(i, (32'd10+i) + 2*(32'd11+i) + (32'd12+i), "fir");
            report("fir", sizes[s]);
        end

        // ── relu : C[i]=max(0,A[i])  (data-dependent light divergence) ────────────
        foreach (sizes[s]) begin
            for (i = 0; i < sizes[s]; i++)                    // alternating sign
                mem[widx(A_BASE)+i] = (i % 2 == 1) ? (32'd1+i) : -(32'd1+i);
            for (i = 0; i < sizes[s]; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
            run(sizes[s], 32'(W_RELU*4), A_BASE, B_BASE, C_BASE);
            for (i = 0; i < sizes[s]; i++)
                chk(i, (i % 2 == 1) ? (32'd1+i) : 32'd0, "relu");
            report("relu", sizes[s]);
        end

        // ── collatz : C[i]=collatz_steps(A[i])  (heavy data-dependent divergence) ─
        for (int si = 0; si < 3; si++) begin                  // N up to 256 (heavy)
            int unsigned n = sizes[si];
            for (i = 0; i < n; i++) mem[widx(A_BASE)+i] = (i & 7) + 32'd2;   // seeds 2..9
            for (i = 0; i < n; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
            run(n, 32'(W_COLLATZ*4), A_BASE, B_BASE, C_BASE);
            for (i = 0; i < n; i++) chk(i, csteps((i & 7) + 32'd2), "collatz");
            report("collatz", n);
        end

        // ── reduce : C[w]=sum_{l=0..7} A[8w+l]  (scratchpad + divergence) ──────────
        foreach (sizes[s]) begin
            for (i = 0; i < sizes[s]; i++) mem[widx(A_BASE)+i] = 32'd10 + i[31:0];
            for (i = 0; i < sizes[s]/8; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
            run(sizes[s], 32'(W_REDUCE*4), A_BASE, B_BASE, C_BASE);
            for (i = 0; i < sizes[s]/8; i++) begin
                automatic logic [31:0] exp = 32'd0;
                for (int l = 0; l < 8; l++) exp += 32'd10 + 8*i[31:0] + l[31:0];
                chk(i, exp, "reduce");
            end
            report("reduce", sizes[s]);
        end

        // ── matmul (smem vs naive) : one 8x8 row, N=8  (compute + scratch reuse) ──
        for (i = 0; i < MM_K; i++) mem[widx(MM_A)+i] = 32'd2 + i[31:0];
        for (int k = 0; k < MM_K; k++)
            for (int c = 0; c < MM_NCOL; c++)
                mem[widx(MM_B) + k*MM_NCOL + c] = 32'd1 + c[31:0] + k[31:0];
        begin
            automatic logic [31:0] gold [8];
            for (int c = 0; c < MM_NCOL; c++) begin
                gold[c] = 32'd0;
                for (int k = 0; k < MM_K; k++) gold[c] += (32'd2+k[31:0])*(32'd1+c[31:0]+k[31:0]);
            end
            for (i = 0; i < MM_NCOL; i++) mem[widx(MM_C)+i] = 32'hdead_beef;
            run(32'd8, 32'(W_MMNAIVE*4), MM_A, MM_B, MM_C);
            for (i = 0; i < MM_NCOL; i++)
                if (mem[widx(MM_C)+i] !== gold[i]) begin
                    $display("  [FAIL] mm_naive C[%0d] got=%0d exp=%0d", i, mem[widx(MM_C)+i], gold[i]);
                    errors++;
                end
            report("mm_naive", 8);
            for (i = 0; i < MM_NCOL; i++) mem[widx(MM_C)+i] = 32'hdead_beef;
            run(32'd8, 32'(W_MMSMEM*4), MM_A, MM_B, MM_C);
            for (i = 0; i < MM_NCOL; i++)
                if (mem[widx(MM_C)+i] !== gold[i]) begin
                    $display("  [FAIL] mm_smem C[%0d] got=%0d exp=%0d", i, mem[widx(MM_C)+i], gold[i]);
                    errors++;
                end
            report("mm_smem", 8);
        end

        $display("  --------------------------------------------------------------------------");
        if (errors == 0) begin
            $display("[tb_bench] PASS — all kernels verified across all sizes");
            $finish;
        end else begin
            $display("[tb_bench] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #20000000;
        $display("[tb_bench] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_bench
