// =============================================================================
// tb_requant.sv — golden test for INT32→INT8 requantization (kernels/quant/requant.S)
//
// AI Tier-2. One thread per element: acc(int32) -> clamp(round(acc*scale+zp),-128,127)
// stored as a signed byte. Runs kernels/quant/requant.S on warp_pool and checks each
// lane's output byte against a software reference, for two parameter sets: one whose
// results fall either side of .5 (both signs, both clamps, near zero), and one with
// exact ties, which round to the even neighbour. Every set has values that
// truncation, round-half-up and round-half-away would get wrong.
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
    logic [MEM_TAGW-1:0]  dmem_tag;
    logic                 dmem_req;          // zero-latency memory: rvalid = req
    logic [LINE_BE-1:0]   dmem_be;
    logic                 busy, done;
    logic [31:0]          dbg_retire_a0, dbg_mem_txns, dbg_divergences, dbg_scratch_txns;
    logic [31:0]          dbg_issued_insns, dbg_active_lanes;
    /* verilator lint_on UNUSEDSIGNAL */

    int unsigned errors = 0;

    warp_pool dut (
        .clk(clk), .rst(rst), .start(start),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc), .block_log2(3'd0),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_req(dmem_req), .dmem_gnt(1'b1), .dmem_tag(dmem_tag), .dmem_rtag(dmem_tag), .dmem_we(dmem_we), .dmem_be(dmem_be),
        .dmem_rvalid(dmem_req), .dmem_rdata(dmem_rdata),
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

    // Set 0: scale = 0.05 (0x3D4CCCCD), zero_point = 2.0 (0x40000000).
    // Set 1: scale = 0.125 (0x3E000000, exact), zero_point = 0, so x.5 is an exact tie.
    function automatic logic [31:0] scale_f(input int set);
        return (set == 0) ? 32'h3D4CCCCD : 32'h3E000000;
    endfunction
    function automatic logic [31:0] zp_f(input int set);
        return (set == 0) ? 32'h40000000 : 32'h00000000;
    endfunction
    function automatic real scale_r(input int set);
        return (set == 0) ? 0.05 : 0.125;
    endfunction
    function automatic real zp_r(input int set);
        return (set == 0) ? 2.0 : 0.0;
    endfunction

    // ── kernels/quant/requant.S, assembled (rv32imf, -Ttext=0) → 17 words ────────
    task automatic load_kernel();
        mem[ 0] = 32'h00251293; mem[ 1] = 32'h00558333; mem[ 2] = 32'h00032383;
        mem[ 3] = 32'h00062087; mem[ 4] = 32'h00462107; mem[ 5] = 32'hd003f1d3;
        mem[ 6] = 32'h1011f1c3; mem[ 7] = 32'h42fe0e37; mem[ 8] = 32'hf00e0253;
        mem[ 9] = 32'hc3000e37; mem[10] = 32'hf00e02d3; mem[11] = 32'h284181d3;
        mem[12] = 32'h285191d3; mem[13] = 32'hc0018ed3; mem[14] = 32'h00a68f33;
        mem[15] = 32'h01df0023; mem[16] = 32'h00000073;
    endtask

    // Accumulators and the y = acc*scale + zp they give. Set 0: 52.65, -48.65, 52.35,
    // -48.35, -0.85, 126.95, 252 (clamps), -298 (clamps). Set 1: ties 0.5, 1.5, 2.5,
    // -0.5, -1.5, -2.5, then 0.75 and 127.5 (clamps to 127 before the convert).
    function automatic int acc_in(input int set, input int i);
        if (set == 0)
            case (i % 8)
                0: acc_in =  1013;  1: acc_in = -1013;  2: acc_in =  1007;  3: acc_in = -1007;
                4: acc_in =   -57;  5: acc_in =  2499;  6: acc_in =  5000;  default: acc_in = -6000;
            endcase
        else
            case (i % 8)
                0: acc_in =     4;  1: acc_in =    12;  2: acc_in =    20;  3: acc_in =    -4;
                4: acc_in =   -12;  5: acc_in =   -20;  6: acc_in =     6;  default: acc_in =  1020;
            endcase
    endfunction

    // Software reference: clamp(round_half_even(acc*scale + zp), -128, 127), clamping
    // first as the kernel does. The kernel forms y in FP32 with one rounding (fmadd);
    // set 0 keeps y away from .5 and set 1 is exact, so a double y gives the same integer.
    function automatic int req_ref(input int set, input int acc);
        real y, f; int r;
        y = real'(acc) * scale_r(set) + zp_r(set);
        if (y >  127.0) y =  127.0;
        if (y < -128.0) y = -128.0;
        f = $floor(y);
        r = int'(f);
        if ((y - f > 0.5) || ((y - f == 0.5) && (r % 2 != 0))) r = r + 1;
        return r;
    endfunction

    task automatic preload(input int set);
        for (int i = 0; i < NUM_LANES; i++)
            begin logic [31:0] v; v = acc_in(set, i); mem[widx(A_BASE)+i] = v; end      // int32 accumulators
        mem[widx(B_BASE) + 0] = scale_f(set);
        mem[widx(B_BASE) + 1] = zp_f(set);
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
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX INT32->INT8 requantize golden test  (LANES=%0d WARPS=%0d)",
                 NUM_LANES, NUM_WARPS);

        for (int set = 0; set < 2; set++) begin
            preload(set);
            run(NUM_LANES);
            for (int l = 0; l < NUM_LANES; l++) begin
                logic [7:0] gb; int got, exp;
                gb  = mem[widx(C_BASE) + l/4][(l%4)*8 +: 8];   // packed signed byte
                got = int'(signed'(gb));
                exp = req_ref(set, acc_in(set, l));
                if (got !== exp) begin
                    $display("  [FAIL] set %0d lane %0d: acc=%0d got=%0d exp=%0d",
                             set, l, acc_in(set, l), got, exp);
                    errors++;
                end
            end
        end

        if (errors == 0)
            $display("  [PASS] all %0d requantized bytes bit-exact (2 sets)", 2 * NUM_LANES);
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
