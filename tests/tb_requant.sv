// =============================================================================
// tb_requant.sv — golden test for INT32→INT8 requantization (kernels/quant/requant.S)
//
// AI Tier-2. One thread per element: acc(int32) -> clamp(round(acc*scale+zp),-128,127)
// stored as a signed byte. Runs kernels/quant/requant.S on warp_pool and checks each
// lane's output byte against a software reference. Test data spans positive/negative,
// both clamp saturations, near-zero, and the +127 edge; all values are chosen away
// from .5 rounding boundaries so the integer result is unambiguous and the check is
// exact.
//
//   Build/run:  make -C sim test-requant
// =============================================================================
`timescale 1ns/1ps
module tb_requant
    import simtix_pkg::*;
#()  ;
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

    // ── Behavioural line memory (byte-writable), identical to tb_fpkernels ───────
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

    localparam logic [31:0] A_BASE = 32'h0000_2000;   // &Acc  (int32[])
    localparam logic [31:0] B_BASE = 32'h0000_4000;   // &params: [0]=scale [1]=zp (f32)
    localparam logic [31:0] C_BASE = 32'h0000_6000;   // &Out  (int8[])

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {18'b0, byte_addr[15:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // scale = 0.05 (0x3D4CCCCD), zero_point = 2.0 (0x40000000)
    localparam logic [31:0] SCALE_F = 32'h3D4CCCCD;
    localparam logic [31:0] ZP_F    = 32'h40000000;
    localparam real         SCALE_R = 0.05;
    localparam real         ZP_R    = 2.0;

    // ── kernels/quant/requant.S, assembled (rv32imf, -Ttext=0) → 17 words ────────
    task automatic load_kernel();
        mem[ 0] = 32'h00251293; mem[ 1] = 32'h00558333; mem[ 2] = 32'h00032383;
        mem[ 3] = 32'h00062087; mem[ 4] = 32'h00462107; mem[ 5] = 32'hd003f1d3;
        mem[ 6] = 32'h1011f1c3; mem[ 7] = 32'h42fe0e37; mem[ 8] = 32'hf00e0253;
        mem[ 9] = 32'hc3000e37; mem[10] = 32'hf00e02d3; mem[11] = 32'h284181d3;
        mem[12] = 32'h285191d3; mem[13] = 32'hc0018ed3; mem[14] = 32'h00a68f33;
        mem[15] = 32'h01df0023; mem[16] = 32'h00000073;
    endtask

    // Test accumulators (span sign / both clamps / zero / +127 edge).
    function automatic int acc_in(input int i);
        case (i % 8)
            0: acc_in =  1000;  1: acc_in = -1000;  2: acc_in =  5000;  3: acc_in = -6000;
            4: acc_in =     0;  5: acc_in =  1260;  6: acc_in =  -740;  default: acc_in = 2500;
        endcase
    endfunction

    // Software reference: clamp(round_nearest(acc*scale+zp), -128, 127). Data avoids
    // .5 boundaries so double vs. the kernel's f32 give the same integer.
    function automatic int req_ref(input int acc);
        real y; int r;
        y = real'(acc) * SCALE_R + ZP_R;
        r = int'(y);                 // SV int'(real) already rounds to nearest
        if (r >  127) r =  127;
        if (r < -128) r = -128;
        return r;
    endfunction

    task automatic preload();
        for (int i = 0; i < NUM_LANES; i++)
            mem[widx(A_BASE) + i] = acc_in(i);           // int32 accumulators
        mem[widx(B_BASE) + 0] = SCALE_F;
        mem[widx(B_BASE) + 1] = ZP_F;
    endtask

    task automatic run(input logic [31:0] n);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = 0; base_a = A_BASE; base_b = B_BASE; base_c = C_BASE;
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
        $display("SIMTiX INT32->INT8 requantize golden test  (LANES=%0d WARPS=%0d)",
                 NUM_LANES, NUM_WARPS);

        run(NUM_LANES);

        for (int l = 0; l < NUM_LANES; l++) begin
            logic [7:0] gb; int got, exp;
            gb  = mem[widx(C_BASE) + l/4][(l%4)*8 +: 8];   // packed signed byte
            got = int'(signed'(gb));
            exp = req_ref(acc_in(l));
            if (got !== exp) begin
                $display("  [FAIL] lane %0d: acc=%0d got=%0d exp=%0d", l, acc_in(l), got, exp);
                errors++;
            end
        end

        if (errors == 0)
            $display("  [PASS] all %0d requantized bytes bit-exact", NUM_LANES);
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
endmodule : tb_requant
