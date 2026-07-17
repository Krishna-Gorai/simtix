// =============================================================================
// tb_pdot8.sv — bit-exact golden test for the INT8 packed dot-product (`pdot8`)
//
// AI extension, Tier 1. Drives warp_pool directly (same harness style as
// tb_fpkernels): a behavioural line memory holds the kernel + operands, one warp
// of NUM_LANES threads runs kernels/dotprod/pdot8.S, and each lane's three
// results (signed×signed, unsigned×unsigned, signed×unsigned) are read back from
// memory and checked against a SystemVerilog reference. Integer arithmetic, so
// the check is EXACT (no tolerance).
//
// The kernel gives every lane distinct packed bytes (loaded from A[tid], B[tid]),
// so the test exercises per-lane independence and all three signedness variants,
// including the signed edge values 0x80 (-128) and 0xFF (-1 / 255).
//
//   Build/run:  make -C sim test-pdot8
// =============================================================================
`timescale 1ns/1ps
module tb_pdot8
    import simtix_pkg::*;
#()  ;
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

    // ── kernels/dotprod/pdot8.S, assembled (rv32im, -Ttext=0) → 13 words ─────────
    // Kept inline (as the other kernel testbenches do) so the test is hermetic.
    task automatic load_kernel();
        mem[0]  = 32'h00251293;   // slli t0, a0, 2
        mem[1]  = 32'h00558333;   // add  t1, a1, t0
        mem[2]  = 32'h00032403;   // lw   s0, 0(t1)
        mem[3]  = 32'h00560e33;   // add  t3, a2, t0
        mem[4]  = 32'h000e2483;   // lw   s1, 0(t3)
        mem[5]  = 32'h0094090b;   // pdot8   s2, s0, s1   (funct3=0, SS)
        mem[6]  = 32'h0094198b;   // pdot8u  s3, s0, s1   (funct3=1, UU)
        mem[7]  = 32'h00942a0b;   // pdot8su s4, s0, s1   (funct3=2, SU)
        mem[8]  = 32'h00568fb3;   // add  t6, a3, t0
        mem[9]  = 32'h012fa023;   // sw   s2,  0(t6)
        mem[10] = 32'h033fa023;   // sw   s3, 32(t6)
        mem[11] = 32'h054fa023;   // sw   s4, 64(t6)
        mem[12] = 32'h00000073;   // ecall
    endtask

    // ── Per-lane packed-INT8 test operands (distinct per lane; cover 0x80/0xFF) ──
    function automatic logic [31:0] avec(input int i);
        case (i % 8)
            0: avec = 32'h01020304;   1: avec = 32'h7f7f7f7f;
            2: avec = 32'h80808080;   3: avec = 32'hfffefdfc;
            4: avec = 32'h11223344;   5: avec = 32'h807f01ff;
            6: avec = 32'h00000000;   default: avec = 32'hdeadbeef;
        endcase
    endfunction
    function automatic logic [31:0] bvec(input int i);
        case (i % 8)
            0: bvec = 32'h04030201;   1: bvec = 32'h01010101;
            2: bvec = 32'h7fff017f;   3: bvec = 32'h01020304;
            4: bvec = 32'hffffffff;   5: bvec = 32'h7f80ff01;
            6: bvec = 32'h12345678;   default: bvec = 32'hcafebabe;
        endcase
    endfunction

    // ── Software reference dot products (bit-exact) ──────────────────────────────
    function automatic logic [31:0] dot_ss(input logic [31:0] a, input logic [31:0] b);
        int s; s = 0;
        for (int i = 0; i < 4; i++)
            s += int'(signed'(a[8*i +: 8])) * int'(signed'(b[8*i +: 8]));
        return s;
    endfunction
    function automatic logic [31:0] dot_uu(input logic [31:0] a, input logic [31:0] b);
        int s; s = 0;
        for (int i = 0; i < 4; i++)
            s += int'({24'b0, a[8*i +: 8]}) * int'({24'b0, b[8*i +: 8]});
        return s;
    endfunction
    function automatic logic [31:0] dot_su(input logic [31:0] a, input logic [31:0] b);
        int s; s = 0;   // rs1 signed, rs2 unsigned
        for (int i = 0; i < 4; i++)
            s += int'(signed'(a[8*i +: 8])) * int'({24'b0, b[8*i +: 8]});
        return s;
    endfunction

    task automatic preload(input int n);
        for (int i = 0; i < n; i++) begin
            mem[widx(A_BASE) + i] = avec(i);
            mem[widx(B_BASE) + i] = bvec(i);
        end
    endtask

    task automatic run(input logic [31:0] n);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = 0; base_a = A_BASE; base_b = B_BASE; base_c = C_BASE;
        start = 1; @(posedge clk); start = 0;
        guard = 0;
        while (!done && guard < 200000) begin @(posedge clk); guard++; end
        if (!done) begin $display("  [FAIL] timeout (guard=%0d)", guard); errors++; end
    endtask

    task automatic chk(input string tag, input int lane, input int woff,
                       input logic [31:0] exp);
        logic [31:0] got;
        got = mem[widx(C_BASE) + woff + lane];
        if (got !== exp) begin
            $display("  [FAIL] %-8s lane %0d: got=%08h exp=%08h", tag, lane, got, exp);
            errors++;
        end
    endtask

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_kernel();
        preload(NUM_LANES);
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX INT8 pdot8 golden test  (NUM_LANES=%0d  NUM_WARPS=%0d)", NUM_LANES, NUM_WARPS);

        run(NUM_LANES);

        for (int l = 0; l < NUM_LANES; l++) begin
            chk("pdot8  ", l,  0, dot_ss(avec(l), bvec(l)));   // SS region, word[l]
            chk("pdot8u ", l,  8, dot_uu(avec(l), bvec(l)));   // UU region, word[8+l]
            chk("pdot8su", l, 16, dot_su(avec(l), bvec(l)));   // SU region, word[16+l]
        end

        if (errors == 0)
            $display("  [PASS] all %0d lanes × 3 variants bit-exact", NUM_LANES);
        $display("=============================================================================");
        if (errors != 0) begin $display("RESULT: FAIL (%0d errors)", errors); $fatal(1); end
        else          $display("RESULT: PASS");
        $finish;
    end

    // Global watchdog.
    initial begin
        #4_000_000;
        $display("RESULT: FAIL (global timeout)");
        $fatal(1);
    end
endmodule : tb_pdot8
