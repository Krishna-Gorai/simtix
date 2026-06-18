// =============================================================================
// tb_fparith.sv  -  M14.1 end-to-end FP arithmetic verification
//
// Drives the fparith kernel (C[i] = A[i]*B[i] + B[i]) across a thread grid and
// checks the result bit-exact against a DPI-C IEEE-754 single-precision reference
// (ref_mul then ref_add — matching the engine's single-cycle, NON-fused mul/add,
// each separately rounded RNE). This proves the per-lane simt_fpu compute path,
// the f-file read/write ports, and FP issue/writeback arbitration end-to-end
// through warp_pool — the M14.1 integration gate. Inputs are well-behaved normal
// floats so no FTZ/overflow corner is hit (those are covered by tb_fpu).
// =============================================================================
`timescale 1ns/1ps

module tb_fparith
  import simtix_pkg::*;
;
    import "DPI-C" function int unsigned ref_mul(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_add(input int unsigned a, input int unsigned b);

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
        .clk(clk), .rst(rst),
        .start(start),
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

    // ── Shared line memory (same model as tb_fp / tb_warp_pool) ──────────────────
    localparam int MEM_WORDS = 1024;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign imem_data = mem[imem_addr[11:2]];

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

    localparam logic [31:0] BASE_A = 32'h0000_0100;   // word 64
    localparam logic [31:0] BASE_B = 32'h0000_0300;   // word 192
    localparam logic [31:0] BASE_C = 32'h0000_0500;   // word 320

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {22'b0, byte_addr[11:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // fparith kernel at word 0. Assembled by kernels/build_kernels.sh (rv32imf).
    task automatic load_kernel;
        mem[0] = 32'h00251293;  // slli   t0,a0,2
        mem[1] = 32'h00558333;  // add    t1,a1,t0
        mem[2] = 32'h00032087;  // flw    f1,0(t1)
        mem[3] = 32'h005603b3;  // add    t2,a2,t0
        mem[4] = 32'h0003a107;  // flw    f2,0(t2)
        mem[5] = 32'h1020f1d3;  // fmul.s f3,f1,f2
        mem[6] = 32'h0021f1d3;  // fadd.s f3,f3,f2
        mem[7] = 32'h00568e33;  // add    t3,a3,t0
        mem[8] = 32'h003e2027;  // fsw    f3,0(t3)
        mem[9] = 32'h00000073;  // ecall
    endtask

    // Well-behaved normal-range IEEE-754 single patterns (no FTZ/overflow).
    function automatic logic [31:0] fa(input int i);
        case (i % 8)
            0: fa = 32'h3f800000;   //  1.0
            1: fa = 32'h40200000;   //  2.5
            2: fa = 32'h40490fdb;   //  pi
            3: fa = 32'h3f000000;   //  0.5
            4: fa = 32'hc0000000;   // -2.0
            5: fa = 32'h41200000;   //  10.0
            6: fa = 32'hbe99999a;   // -0.3
            default: fa = 32'h40e00000; // 7.0
        endcase
    endfunction
    function automatic logic [31:0] fb(input int i);
        case (i % 8)
            0: fb = 32'h40000000;   //  2.0
            1: fb = 32'hbfc00000;   // -1.5
            2: fb = 32'h3f800000;   //  1.0
            3: fb = 32'h40800000;   //  4.0
            4: fb = 32'h3e800000;   //  0.25
            5: fb = 32'hc0400000;   // -3.0
            6: fb = 32'h41000000;   //  8.0
            default: fb = 32'hbf000000; // -0.5
        endcase
    endfunction

    task automatic run_grid(input logic [31:0] n);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = 32'd0;
        base_a = BASE_A; base_b = BASE_B; base_c = BASE_C;
        start = 1;
        @(posedge clk);
        start = 0;
        guard = 0;
        while (!done && guard < 20000) begin @(posedge clk); guard++; end
        if (guard >= 20000) begin $display("  [FAIL] grid timed out"); errors++; end
    endtask

    initial begin
        rst = 1; start = 0;
        n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        repeat (3) @(posedge clk);
        rst = 0;

        load_kernel();
        for (int i = 0; i < 64; i++) begin
            mem[widx(BASE_A) + i] = fa(i);
            mem[widx(BASE_B) + i] = fb(i);
            mem[widx(BASE_C) + i] = 32'hdead_beef;
        end

        for (int ni = 0; ni < 4; ni++) begin
            int unsigned N;
            int unsigned phase_err;
            N = (8 << ni);            // 8, 16, 32, 64
            phase_err = 0;
            for (int i = 0; i < 64; i++) mem[widx(BASE_C) + i] = 32'hdead_beef;
            $display("[tb_fparith] M14.1 C=A*B+B, N=%0d", N);
            run_grid(N);
            for (int i = 0; i < N; i++) begin
                logic [31:0] got, exp;
                got = mem[widx(BASE_C) + i];
                exp = ref_add(ref_mul(fa(i), fb(i)), fb(i));
                if (got !== exp) begin
                    if (phase_err < 8)
                        $display("  [FAIL] C[%0d] = %08h, expected %08h (A=%08h B=%08h)",
                                 i, got, exp, fa(i), fb(i));
                    phase_err++;
                end
            end
            if (phase_err == 0) $display("  [ ok ] N=%0d bit-exact vs DPI float", N);
            else                $display("  [FAIL] N=%0d: %0d mismatches", N, phase_err);
            errors += phase_err;
        end

        if (errors == 0) $display("[tb_fparith] PASS");
        else             $display("[tb_fparith] FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
