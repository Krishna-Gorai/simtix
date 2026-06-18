// =============================================================================
// tb_fpbench.sv  -  SIMTiX floating-point benchmark harness (M14 evaluation)
//
// Drives the warp_pool engine through streaming FP kernels in BOTH precisions
// (FP32 and FP16) at several problem sizes, verifies every result bit-exact
// against a DPI-C IEEE reference (tests/fpu_ref.c), and reports the same
// microarchitectural metrics the paper plots for the integer suite:
//     cycles  gmem_txns  issued  active  lane-util%  throughput(work/cycle)
//
// Kernels:  vadd  (C=A+B)   and   mac (C=A*B+B)   in each precision.
// FP16 operands ride through memory and the f-file as NaN-boxed 32-bit words.
//
// Each row is also printed prefixed "FPCSV," so a run log can be grep'd into a
// .csv:   make fp-bench | grep '^FPCSV,' > docs/fp_bench.csv
// Kernel machine words are embedded (no toolchain / file path needed at sim time).
// =============================================================================
`timescale 1ns/1ps

module tb_fpbench
  import simtix_pkg::*;
;
    import "DPI-C" function int unsigned ref_add(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_mul(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_hadd(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_hmul(input int unsigned a, input int unsigned b);

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

    // ── Behavioural line memory (64 KB, line-wide read + byte-enabled write) ──────
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

    // ── Kernel placement (word address) ──────────────────────────────────────────
    localparam int W_VADD32 = 0;    // kpc 0x000  fadd.s
    localparam int W_MAC32  = 16;   // kpc 0x040  fmul.s + fadd.s
    localparam int W_VADD16 = 32;   // kpc 0x080  fadd.h
    localparam int W_MAC16  = 48;   // kpc 0x0C0  fmul.h + fadd.h

    localparam logic [31:0] A_BASE = 32'h0000_2000;
    localparam logic [31:0] B_BASE = 32'h0000_4000;
    localparam logic [31:0] C_BASE = 32'h0000_6000;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {18'b0, byte_addr[15:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    function automatic logic [31:0] boxh(input logic [15:0] h);
        return {16'hffff, h};
    endfunction

    task automatic load_all_kernels();
        // fpvadd (rv32imf): C=A+B (fadd.s)
        mem[W_VADD32+0]=32'h00251293; mem[W_VADD32+1]=32'h00558333; mem[W_VADD32+2]=32'h00032087;
        mem[W_VADD32+3]=32'h005603b3; mem[W_VADD32+4]=32'h0003a107; mem[W_VADD32+5]=32'h0020f1d3;
        mem[W_VADD32+6]=32'h00568e33; mem[W_VADD32+7]=32'h003e2027; mem[W_VADD32+8]=32'h00000073;
        // fparith (rv32imf): C=A*B+B (fmul.s, fadd.s)
        mem[W_MAC32+0]=32'h00251293; mem[W_MAC32+1]=32'h00558333; mem[W_MAC32+2]=32'h00032087;
        mem[W_MAC32+3]=32'h005603b3; mem[W_MAC32+4]=32'h0003a107; mem[W_MAC32+5]=32'h1020f1d3;
        mem[W_MAC32+6]=32'h0021f1d3; mem[W_MAC32+7]=32'h00568e33; mem[W_MAC32+8]=32'h003e2027;
        mem[W_MAC32+9]=32'h00000073;
        // fpvadd16 (rv32imf_zfh): C=A+B (fadd.h)
        mem[W_VADD16+0]=32'h00251293; mem[W_VADD16+1]=32'h00558333; mem[W_VADD16+2]=32'h00032087;
        mem[W_VADD16+3]=32'h005603b3; mem[W_VADD16+4]=32'h0003a107; mem[W_VADD16+5]=32'h0420f1d3;
        mem[W_VADD16+6]=32'h00568e33; mem[W_VADD16+7]=32'h003e2027; mem[W_VADD16+8]=32'h00000073;
        // fparith16 (rv32imf_zfh): C=A*B+B (fmul.h, fadd.h)
        mem[W_MAC16+0]=32'h00251293; mem[W_MAC16+1]=32'h00558333; mem[W_MAC16+2]=32'h00032087;
        mem[W_MAC16+3]=32'h005603b3; mem[W_MAC16+4]=32'h0003a107; mem[W_MAC16+5]=32'h1420f1d3;
        mem[W_MAC16+6]=32'h0421f1d3; mem[W_MAC16+7]=32'h00568e33; mem[W_MAC16+8]=32'h003e2027;
        mem[W_MAC16+9]=32'h00000073;
    endtask

    int unsigned m_cyc, m_gmem, m_insn, m_act;
    task automatic run(input logic [31:0] n, input logic [31:0] kpc);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = kpc; base_a = A_BASE; base_b = B_BASE; base_c = C_BASE;
        start = 1; @(posedge clk); start = 0;
        m_cyc = 1; guard = 0;
        while (!done && guard < 400000) begin @(posedge clk); m_cyc++; guard++; end
        m_gmem = dbg_mem_txns; m_insn = dbg_issued_insns; m_act = dbg_active_lanes;
    endtask

    function automatic int unsigned util_pm(input int unsigned insn, input int unsigned act);
        util_pm = (insn == 0) ? 1000 : (1000 * act) / (NUM_LANES * insn);
    endfunction
    function automatic int unsigned ipc_x100(input int unsigned act, input int unsigned cyc);
        ipc_x100 = (cyc == 0) ? 0 : (100 * act) / cyc;
    endfunction

    task automatic report(input string fmt, input string kern, input int unsigned n);
        int unsigned u, ipc;
        u = util_pm(m_insn, m_act); ipc = ipc_x100(m_act, m_cyc);
        $display("  %-4s %-5s %4d | %6d %5d | %6d %7d  %0d.%01d%%  %0d.%02d",
                 fmt, kern, n, m_cyc, m_gmem, m_insn, m_act, u/10, u%10, ipc/100, ipc%100);
        $display("FPCSV,%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                 fmt, kern, n, m_cyc, m_gmem, m_insn, m_act, u, ipc);
    endtask

    // ── FP32 / FP16 data patterns (well-behaved normals; no FTZ/overflow) ─────────
    function automatic logic [31:0] fa(input int i);
        case (i % 8)
            0: fa=32'h3f800000; 1: fa=32'h40200000; 2: fa=32'h40490fdb; 3: fa=32'h3f000000;
            4: fa=32'hc0000000; 5: fa=32'h41200000; 6: fa=32'hbe99999a; default: fa=32'h40e00000;
        endcase
    endfunction
    function automatic logic [31:0] fb(input int i);
        case (i % 8)
            0: fb=32'h40000000; 1: fb=32'hbfc00000; 2: fb=32'h3f800000; 3: fb=32'h40800000;
            4: fb=32'h3e800000; 5: fb=32'hc0400000; 6: fb=32'h41000000; default: fb=32'hbf000000;
        endcase
    endfunction
    function automatic logic [15:0] ha(input int i);
        case (i % 8)
            0: ha=16'h3c00; 1: ha=16'h4100; 2: ha=16'h4248; 3: ha=16'h3800;
            4: ha=16'hc000; 5: ha=16'h4900; 6: ha=16'hb4cd; default: ha=16'h4700;
        endcase
    endfunction
    function automatic logic [15:0] hb(input int i);
        case (i % 8)
            0: hb=16'h4000; 1: hb=16'hbe00; 2: hb=16'h3c00; 3: hb=16'h4400;
            4: hb=16'h3400; 5: hb=16'hc200; 6: hb=16'h4800; default: hb=16'hb800;
        endcase
    endfunction

    task automatic preload32(input int n);
        for (int i = 0; i < n; i++) mem[widx(A_BASE)+i] = fa(i);
        for (int i = 0; i < n; i++) mem[widx(B_BASE)+i] = fb(i);
        for (int i = 0; i < n; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
    endtask
    task automatic preload16(input int n);
        for (int i = 0; i < n; i++) mem[widx(A_BASE)+i] = boxh(ha(i));
        for (int i = 0; i < n; i++) mem[widx(B_BASE)+i] = boxh(hb(i));
        for (int i = 0; i < n; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
    endtask

    task automatic chk(input int idx, input logic [31:0] exp, input string tag);
        logic [31:0] got;
        got = mem[widx(C_BASE) + idx];
        if (got !== exp) begin
            $display("  [FAIL] %-9s C[%0d] got=%08h exp=%08h", tag, idx, got, exp);
            errors++;
        end
    endtask

    int unsigned sizes [4] = '{8, 64, 256, 1024};

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_all_kernels();
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX FP benchmark  (NUM_LANES=%0d  NUM_WARPS=%0d)", NUM_LANES, NUM_WARPS);
        $display("  fmt kern     N | cycles  gmem |   insn  active  lane-u  work/cyc");
        $display("  --------------------------------------------------------------------");

        foreach (sizes[s]) begin
            preload32(sizes[s]);
            run(sizes[s], 32'(W_VADD32*4));
            for (int i = 0; i < sizes[s]; i++) chk(i, ref_add(fa(i), fb(i)), "f32-vadd");
            report("f32", "vadd", sizes[s]);
        end
        foreach (sizes[s]) begin
            preload32(sizes[s]);
            run(sizes[s], 32'(W_MAC32*4));
            for (int i = 0; i < sizes[s]; i++) chk(i, ref_add(ref_mul(fa(i), fb(i)), fb(i)), "f32-mac");
            report("f32", "mac", sizes[s]);
        end
        foreach (sizes[s]) begin
            preload16(sizes[s]);
            run(sizes[s], 32'(W_VADD16*4));
            for (int i = 0; i < sizes[s]; i++) chk(i, boxh(16'(ref_hadd(32'(ha(i)), 32'(hb(i))))), "f16-vadd");
            report("f16", "vadd", sizes[s]);
        end
        foreach (sizes[s]) begin
            preload16(sizes[s]);
            run(sizes[s], 32'(W_MAC16*4));
            for (int i = 0; i < sizes[s]; i++)
                chk(i, boxh(16'(ref_hadd(ref_hmul(32'(ha(i)), 32'(hb(i))), 32'(hb(i))))), "f16-mac");
            report("f16", "mac", sizes[s]);
        end

        $display("  --------------------------------------------------------------------");
        if (errors == 0) begin
            $display("[tb_fpbench] PASS - all FP kernels verified across all sizes");
            $finish;
        end else begin
            $display("[tb_fpbench] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #20000000;
        $display("[tb_fpbench] TIMEOUT");
        $fatal(1);
    end
endmodule : tb_fpbench
