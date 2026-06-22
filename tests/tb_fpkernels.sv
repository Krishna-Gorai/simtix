// =============================================================================
// tb_fpkernels.sv  -  M14.4 realistic floating-point kernel verification
//
// Runs the toolchain-assembled FP application kernels through warp_pool and checks
// every output bit-exact against a DPI-C reference, at several problem sizes:
//     fsaxpy    C[i] = 3*A[i] + B[i]          (FP32, fused multiply-add; streaming)
//     fsaxpy16  C[i] = 3*A[i] + B[i]          (FP16, fmadd.h; NaN-boxed operands)
//     fnorm     C[i] = A[i] / sqrt(B[i])      (FP32, fsqrt + fdiv; SFU-heavy)
//     fdot      C[w] = sum_l A[8w+l]*B[8w+l]  (FP32, fmul + scratchpad reduction)
//
// Each row is also printed "FPKCSV," so a run can be captured for the M14.5 study:
//     make fp-kernels | grep '^FPKCSV,' > docs/fp_kernels.csv
// =============================================================================
`timescale 1ns/1ps

module tb_fpkernels
  import simtix_pkg::*;
;
    import "DPI-C" function int unsigned ref_add (input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_mul (input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_div (input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_sqrt(input int unsigned a);
    import "DPI-C" function int unsigned ref_fmaf(input int unsigned a, input int unsigned b,
                                                  input int unsigned c, input int np, input int nc);
    import "DPI-C" function int unsigned ref_hfma(input int unsigned a, input int unsigned b,
                                                  input int unsigned c, input int np, input int nc);

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

    // ── Behavioural line memory (64 KB) ──────────────────────────────────────────
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

    localparam int W_FSAXPY   = 0;     // kpc 0x000
    localparam int W_FSAXPY16 = 16;    // kpc 0x040
    localparam int W_FNORM    = 32;    // kpc 0x080
    localparam int W_FDOT     = 48;    // kpc 0x0C0

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
        mem[W_FSAXPY+0]=32'h00251293; mem[W_FSAXPY+1]=32'h40400f37; mem[W_FSAXPY+2]=32'hf00f02d3;
        mem[W_FSAXPY+3]=32'h00558333; mem[W_FSAXPY+4]=32'h00032087; mem[W_FSAXPY+5]=32'h005603b3;
        mem[W_FSAXPY+6]=32'h0003a107; mem[W_FSAXPY+7]=32'h1012f1c3; mem[W_FSAXPY+8]=32'h00568e33;
        mem[W_FSAXPY+9]=32'h003e2027; mem[W_FSAXPY+10]=32'h00000073;

        mem[W_FSAXPY16+0]=32'h00251293; mem[W_FSAXPY16+1]=32'hffff4f37; mem[W_FSAXPY16+2]=32'h200f0f13;
        mem[W_FSAXPY16+3]=32'hf00f02d3; mem[W_FSAXPY16+4]=32'h00558333; mem[W_FSAXPY16+5]=32'h00032087;
        mem[W_FSAXPY16+6]=32'h005603b3; mem[W_FSAXPY16+7]=32'h0003a107; mem[W_FSAXPY16+8]=32'h1412f1c3;
        mem[W_FSAXPY16+9]=32'h00568e33; mem[W_FSAXPY16+10]=32'h003e2027; mem[W_FSAXPY16+11]=32'h00000073;

        mem[W_FNORM+0]=32'h00251293; mem[W_FNORM+1]=32'h00558333; mem[W_FNORM+2]=32'h00032087;
        mem[W_FNORM+3]=32'h005603b3; mem[W_FNORM+4]=32'h0003a107; mem[W_FNORM+5]=32'h580171d3;
        mem[W_FNORM+6]=32'h1830f253; mem[W_FNORM+7]=32'h00568e33; mem[W_FNORM+8]=32'h004e2027;
        mem[W_FNORM+9]=32'h00000073;

        mem[W_FDOT+0]=32'h00757293;  mem[W_FDOT+1]=32'h00229313;  mem[W_FDOT+2]=32'h400003b7;
        mem[W_FDOT+3]=32'h006383b3;  mem[W_FDOT+4]=32'h00251e13;  mem[W_FDOT+5]=32'h01c58eb3;
        mem[W_FDOT+6]=32'h000ea087;  mem[W_FDOT+7]=32'h01c60f33;  mem[W_FDOT+8]=32'h000f2107;
        mem[W_FDOT+9]=32'h1020f1d3;  mem[W_FDOT+10]=32'h0033a027; mem[W_FDOT+11]=32'h04029e63;
        mem[W_FDOT+12]=32'h400003b7; mem[W_FDOT+13]=32'hf0000353; mem[W_FDOT+14]=32'h0003a207;
        mem[W_FDOT+15]=32'h00437353; mem[W_FDOT+16]=32'h0043a207; mem[W_FDOT+17]=32'h00437353;
        mem[W_FDOT+18]=32'h0083a207; mem[W_FDOT+19]=32'h00437353; mem[W_FDOT+20]=32'h00c3a207;
        mem[W_FDOT+21]=32'h00437353; mem[W_FDOT+22]=32'h0103a207; mem[W_FDOT+23]=32'h00437353;
        mem[W_FDOT+24]=32'h0143a207; mem[W_FDOT+25]=32'h00437353; mem[W_FDOT+26]=32'h0183a207;
        mem[W_FDOT+27]=32'h00437353; mem[W_FDOT+28]=32'h01c3a207; mem[W_FDOT+29]=32'h00437353;
        mem[W_FDOT+30]=32'h00355e13; mem[W_FDOT+31]=32'h002e1e13; mem[W_FDOT+32]=32'h01c68eb3;
        mem[W_FDOT+33]=32'h006ea027; mem[W_FDOT+34]=32'h00000073;
    endtask

    int unsigned m_cyc, m_gmem, m_scr, m_insn, m_act;
    task automatic run(input logic [31:0] n, input logic [31:0] kpc);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = kpc; base_a = A_BASE; base_b = B_BASE; base_c = C_BASE;
        start = 1; @(posedge clk); start = 0;
        m_cyc = 1; guard = 0;
        while (!done && guard < 400000) begin @(posedge clk); m_cyc++; guard++; end
        m_gmem = dbg_mem_txns; m_scr = dbg_scratch_txns;
        m_insn = dbg_issued_insns; m_act = dbg_active_lanes;
    endtask

    function automatic int unsigned util_pm(input int unsigned insn, input int unsigned act);
        util_pm = (insn == 0) ? 1000 : (1000 * act) / (NUM_LANES * insn);
    endfunction

    task automatic report(input string name, input int unsigned n);
        int unsigned u;
        u = util_pm(m_insn, m_act);
        $display("  %-9s %4d | %6d %5d %5d | %6d %7d  %0d.%01d%%",
                 name, n, m_cyc, m_gmem, m_scr, m_insn, m_act, u/10, u%10);
        $display("FPKCSV,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                 name, n, m_cyc, m_gmem, m_scr, m_insn, m_act, u);
    endtask

    // FP32 / FP16 input patterns (B positive for fnorm's sqrt).
    function automatic logic [31:0] fa(input int i);
        case (i % 8)
            0: fa=32'h3f800000; 1: fa=32'h40200000; 2: fa=32'h40490fdb; 3: fa=32'h3f000000;
            4: fa=32'hc0000000; 5: fa=32'h41200000; 6: fa=32'hbe99999a; default: fa=32'h40e00000;
        endcase
    endfunction
    function automatic logic [31:0] fbpos(input int i);    // strictly positive
        case (i % 8)
            0: fbpos=32'h40000000; 1: fbpos=32'h40400000; 2: fbpos=32'h3f800000; 3: fbpos=32'h40800000;
            4: fbpos=32'h3e800000; 5: fbpos=32'h41000000; 6: fbpos=32'h40a00000; default: fbpos=32'h3fc00000;
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
        for (int i = 0; i < n; i++) mem[widx(B_BASE)+i] = fbpos(i);
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

    int unsigned sizes [3] = '{8, 64, 256};

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_all_kernels();
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX FP application kernels  (NUM_LANES=%0d  NUM_WARPS=%0d)", NUM_LANES, NUM_WARPS);
        $display("  kernel      N | cycles  gmem  scrat |   insn  active  lane-u");
        $display("  ------------------------------------------------------------");

        // fsaxpy : C = 3*A + B  (fmadd.s)
        foreach (sizes[s]) begin
            preload32(sizes[s]);
            run(sizes[s], 32'(W_FSAXPY*4));
            for (int i = 0; i < sizes[s]; i++)
                chk(i, ref_fmaf(32'h40400000, fa(i), fbpos(i), 0, 0), "fsaxpy");
            report("fsaxpy", sizes[s]);
        end
        // fsaxpy16 : C = 3*A + B  (fmadd.h)
        foreach (sizes[s]) begin
            preload16(sizes[s]);
            run(sizes[s], 32'(W_FSAXPY16*4));
            for (int i = 0; i < sizes[s]; i++)
                chk(i, boxh(16'(ref_hfma(32'h4200, 32'(ha(i)), 32'(hb(i)), 0, 0))), "fsaxpy16");
            report("fsaxpy16", sizes[s]);
        end
        // fnorm : C = A / sqrt(B)  (fsqrt + fdiv)
        foreach (sizes[s]) begin
            preload32(sizes[s]);
            run(sizes[s], 32'(W_FNORM*4));
            for (int i = 0; i < sizes[s]; i++)
                chk(i, ref_div(fa(i), ref_sqrt(fbpos(i))), "fnorm");
            report("fnorm", sizes[s]);
        end
        // fdot : C[w] = sum_l A[8w+l]*B[8w+l]  (fmul + scratchpad reduction)
        foreach (sizes[s]) begin
            preload32(sizes[s]);
            run(sizes[s], 32'(W_FDOT*4));
            for (int w = 0; w < sizes[s]/8; w++) begin
                logic [31:0] acc;
                acc = 32'h0000_0000;                 // +0.0
                for (int l = 0; l < 8; l++)
                    acc = ref_add(acc, ref_mul(fa(8*w+l), fbpos(8*w+l)));
                chk(w, acc, "fdot");
            end
            report("fdot", sizes[s]);
        end

        $display("  ------------------------------------------------------------");
        if (errors == 0) begin
            $display("[tb_fpkernels] PASS - all FP kernels verified across all sizes");
            $finish;
        end else begin
            $display("[tb_fpkernels] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #40000000;
        $display("[tb_fpkernels] TIMEOUT");
        $fatal(1);
    end
endmodule : tb_fpkernels
