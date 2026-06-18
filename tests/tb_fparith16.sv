// =============================================================================
// tb_fparith16.sv  -  M14.2 end-to-end FP16 (half) arithmetic verification
//
// Drives the fparith16 kernel (C[i] = A[i]*B[i] + B[i], in half precision) across
// a thread grid and checks the result bit-exact against a DPI-C half reference
// (ref_hmul then ref_hadd — matching the engine's single-cycle, separately-rounded
// half mul/add). The FP16 operands ride through memory and the f-file as NaN-boxed
// 32-bit words (flw/fsw), so this also exercises NaN-boxing end-to-end. Proves the
// per-lane FP16 datapath + f-file + FP issue/writeback through warp_pool — the
// M14.2 integration gate. Inputs are well-behaved (no FTZ/overflow corner; those
// are covered by tb_fpu).
// =============================================================================
`timescale 1ns/1ps

module tb_fparith16
  import simtix_pkg::*;
;
    import "DPI-C" function int unsigned ref_hmul(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_hadd(input int unsigned a, input int unsigned b);

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

    // ── Shared line memory (same model as tb_fparith) ────────────────────────────
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

    // NaN-box a half into a 32-bit memory/register word.
    function automatic logic [31:0] boxh(input logic [15:0] h);
        return {16'hffff, h};
    endfunction

    // fparith16 kernel at word 0. Assembled by kernels/build_kernels.sh (rv32imf_zfh).
    task automatic load_kernel;
        mem[0] = 32'h00251293;  // slli   t0,a0,2
        mem[1] = 32'h00558333;  // add    t1,a1,t0
        mem[2] = 32'h00032087;  // flw    f1,0(t1)
        mem[3] = 32'h005603b3;  // add    t2,a2,t0
        mem[4] = 32'h0003a107;  // flw    f2,0(t2)
        mem[5] = 32'h1420f1d3;  // fmul.h f3,f1,f2
        mem[6] = 32'h0421f1d3;  // fadd.h f3,f3,f2
        mem[7] = 32'h00568e33;  // add    t3,a3,t0
        mem[8] = 32'h003e2027;  // fsw    f3,0(t3)
        mem[9] = 32'h00000073;  // ecall
    endtask

    // Well-behaved FP16 patterns (products + sums stay normal, no FTZ/overflow).
    function automatic logic [15:0] ha(input int i);
        case (i % 8)
            0: ha = 16'h3c00;   //  1.0
            1: ha = 16'h4100;   //  2.5
            2: ha = 16'h4248;   //  pi ~ 3.140625
            3: ha = 16'h3800;   //  0.5
            4: ha = 16'hc000;   // -2.0
            5: ha = 16'h4900;   //  10.0
            6: ha = 16'hb4cd;   // -0.3 ~
            default: ha = 16'h4700; // 7.0
        endcase
    endfunction
    function automatic logic [15:0] hb(input int i);
        case (i % 8)
            0: hb = 16'h4000;   //  2.0
            1: hb = 16'hbe00;   // -1.5
            2: hb = 16'h3c00;   //  1.0
            3: hb = 16'h4400;   //  4.0
            4: hb = 16'h3400;   //  0.25
            5: hb = 16'hc200;   // -3.0
            6: hb = 16'h4800;   //  8.0
            default: hb = 16'hb800; // -0.5
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
            mem[widx(BASE_A) + i] = boxh(ha(i));
            mem[widx(BASE_B) + i] = boxh(hb(i));
            mem[widx(BASE_C) + i] = 32'hdead_beef;
        end

        for (int ni = 0; ni < 4; ni++) begin
            int unsigned N;
            int unsigned phase_err;
            N = (8 << ni);            // 8, 16, 32, 64
            phase_err = 0;
            for (int i = 0; i < 64; i++) mem[widx(BASE_C) + i] = 32'hdead_beef;
            $display("[tb_fparith16] M14.2 half C=A*B+B, N=%0d", N);
            run_grid(N);
            for (int i = 0; i < N; i++) begin
                logic [31:0] got;
                logic [15:0] exp;
                got = mem[widx(BASE_C) + i];
                exp = 16'(ref_hadd(ref_hmul(32'(ha(i)), 32'(hb(i))), 32'(hb(i))));
                if (got !== boxh(exp)) begin
                    if (phase_err < 8)
                        $display("  [FAIL] C[%0d] = %08h, expected %08h (A=%04h B=%04h)",
                                 i, got, boxh(exp), ha(i), hb(i));
                    phase_err++;
                end
            end
            if (phase_err == 0) $display("  [ ok ] N=%0d bit-exact vs DPI half", N);
            else                $display("  [FAIL] N=%0d: %0d mismatches", N, phase_err);
            errors += phase_err;
        end

        if (errors == 0) $display("[tb_fparith16] PASS");
        else             $display("[tb_fparith16] FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
