// =============================================================================
// tb_fpdivsqrt.sv  -  M14.3 end-to-end divide + square-root verification
//
// Drives the fpdivsqrt kernel (C[i] = sqrt(A[i]/B[i]), via fdiv.s then fsqrt.s)
// across a thread grid and checks the result bit-exact against sqrt(div(A,B)).
// This proves the multi-cycle SFU + the stall scoreboard end-to-end: each thread
// parks the warp on the SFU TWICE (a data-dependent fdiv then fsqrt), while the
// scheduler keeps the other warps running. Inputs are positive normals.
// =============================================================================
`timescale 1ns/1ps

module tb_fpdivsqrt
  import simtix_pkg::*;
;
    import "DPI-C" function int unsigned ref_div (input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_sqrt(input int unsigned a);

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

    localparam logic [31:0] BASE_A = 32'h0000_0100;
    localparam logic [31:0] BASE_B = 32'h0000_0300;
    localparam logic [31:0] BASE_C = 32'h0000_0500;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {22'b0, byte_addr[11:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // fpdivsqrt kernel at word 0. Assembled by kernels/build_kernels.sh (rv32imf).
    task automatic load_kernel;
        mem[0] = 32'h00251293;  // slli    t0,a0,2
        mem[1] = 32'h00558333;  // add     t1,a1,t0
        mem[2] = 32'h00032087;  // flw     f1,0(t1)
        mem[3] = 32'h005603b3;  // add     t2,a2,t0
        mem[4] = 32'h0003a107;  // flw     f2,0(t2)
        mem[5] = 32'h1820f1d3;  // fdiv.s  f3,f1,f2
        mem[6] = 32'h5801f253;  // fsqrt.s f4,f3
        mem[7] = 32'h00568e33;  // add     t3,a3,t0
        mem[8] = 32'h004e2027;  // fsw     f4,0(t3)
        mem[9] = 32'h00000073;  // ecall
    endtask

    // Positive normal IEEE-754 patterns (so A/B>0 and sqrt is real).
    function automatic logic [31:0] fa(input int i);
        case (i % 8)
            0: fa = 32'h41200000; 1: fa = 32'h40a00000; 2: fa = 32'h42c80000; 3: fa = 32'h3f800000;
            4: fa = 32'h43160000; 5: fa = 32'h40000000; 6: fa = 32'h41f00000; default: fa = 32'h42480000;
        endcase
    endfunction
    function automatic logic [31:0] fb(input int i);
        case (i % 8)
            0: fb = 32'h40000000; 1: fb = 32'h40400000; 2: fb = 32'h41000000; 3: fb = 32'h3fc00000;
            4: fb = 32'h40800000; 5: fb = 32'h3f000000; 6: fb = 32'h41100000; default: fb = 32'h40a00000;
        endcase
    endfunction

    task automatic run_grid(input logic [31:0] n);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = 32'd0;
        base_a = BASE_A; base_b = BASE_B; base_c = BASE_C;
        start = 1; @(posedge clk); start = 0;
        guard = 0;
        while (!done && guard < 40000) begin @(posedge clk); guard++; end
        if (guard >= 40000) begin $display("  [FAIL] grid timed out"); errors++; end
    endtask

    initial begin
        rst = 1; start = 0;
        n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        load_kernel();

        for (int ni = 0; ni < 4; ni++) begin
            int unsigned N;
            int unsigned phase_err;
            N = (8 << ni);            // 8, 16, 32, 64
            phase_err = 0;
            for (int i = 0; i < 64; i++) begin
                mem[widx(BASE_A) + i] = fa(i);
                mem[widx(BASE_B) + i] = fb(i);
                mem[widx(BASE_C) + i] = 32'hdead_beef;
            end
            $display("[tb_fpdivsqrt] M14.3 C=sqrt(A/B), N=%0d", N);
            run_grid(N);
            for (int i = 0; i < N; i++) begin
                logic [31:0] got, exp;
                got = mem[widx(BASE_C) + i];
                exp = ref_sqrt(ref_div(fa(i), fb(i)));
                if (got !== exp) begin
                    if (phase_err < 8)
                        $display("  [FAIL] C[%0d] = %08h, expected %08h (A=%08h B=%08h)",
                                 i, got, exp, fa(i), fb(i));
                    phase_err++;
                end
            end
            if (phase_err == 0) $display("  [ ok ] N=%0d bit-exact vs DPI sqrt(div)", N);
            else                $display("  [FAIL] N=%0d: %0d mismatches", N, phase_err);
            errors += phase_err;
        end

        if (errors == 0) $display("[tb_fpdivsqrt] PASS");
        else             $display("[tb_fpdivsqrt] FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
