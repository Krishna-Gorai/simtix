// =============================================================================
// tb_divsqrt.sv  -  M14.3 standalone verification of the iterative div/sqrt core
//
// Drives fp_divsqrt with a start pulse, waits for `done`, and checks the result
// BIT-EXACT against a DPI-C reference (host float divide / sqrtf for FP32; double
// divide / sqrt then narrow for FP16) over thousands of random vectors plus
// directed inf/NaN/zero/divide-by-zero/sqrt-of-negative/FTZ corners.
// =============================================================================
`timescale 1ns/1ps

module tb_divsqrt
  import simtix_pkg::*;
;
    import "DPI-C" function int unsigned ref_div  (input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_sqrt (input int unsigned a);
    import "DPI-C" function int unsigned ref_hdiv (input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_hsqrt(input int unsigned a);

    logic        clk = 0, rst;
    logic        start, is_sqrt;
    logic [1:0]  fmt;
    logic [31:0] a, b, res;
    logic        done;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        busy;       // observed by integration; not checked here
    /* verilator lint_on UNUSEDSIGNAL */

    fp_divsqrt dut (.clk(clk), .rst(rst), .start(start), .is_sqrt(is_sqrt),
                    .fmt(fmt), .a(a), .b(b), .busy(busy), .done(done), .res(res));

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    int unsigned errors = 0, checks = 0;

    function automatic logic [31:0] boxh(input logic [15:0] h);
        return {16'hffff, h};
    endfunction
    function automatic logic [31:0] rand_fp(input int lo, input int span);
        logic s; logic [7:0] e; logic [22:0] m;
        s = 1'($random); e = 8'(lo + ($unsigned($random) % span)); m = 23'($random);
        return {s, e, m};
    endfunction
    function automatic logic [15:0] rand_hp(input int lo, input int span);
        logic s; logic [4:0] e; logic [9:0] m;
        s = 1'($random); e = 5'(lo + ($unsigned($random) % span)); m = 10'($random);
        return {s, e, m};
    endfunction

    // Issue one op and wait for done (with a guard against a hung core).
    task automatic op(input logic sq, input logic [1:0] f,
                      input logic [31:0] av, input logic [31:0] bv, input logic [31:0] exp,
                      input string tag);
        int unsigned guard;
        @(posedge clk);
        is_sqrt = sq; fmt = f; a = av; b = bv; start = 1'b1;
        @(posedge clk); start = 1'b0;
        guard = 0;
        while (!done && guard < 200) begin @(posedge clk); guard++; end
        checks++;
        if (!done) begin
            if (errors < 12) $display("  [FAIL] %-9s a=%08h b=%08h: TIMED OUT", tag, av, bv);
            errors++;
        end else if (res !== exp) begin
            if (errors < 12)
                $display("  [FAIL] %-9s a=%08h b=%08h -> %08h exp %08h", tag, av, bv, res, exp);
            errors++;
        end
    endtask

    initial begin
        rst = 1; start = 0; is_sqrt = 0; fmt = FMT_S; a = 0; b = 0;
        repeat (3) @(posedge clk);
        rst = 0;

        // ── FP32 divide, random ─────────────────────────────────────────────────
        $display("[tb_divsqrt] FP32 divide vs DPI golden");
        for (int i = 0; i < 6000; i++) begin
            logic [31:0] av, bv;
            av = rand_fp(80, 95); bv = rand_fp(80, 95);    // wide exp range, no FTZ/ovf
            op(1'b0, FMT_S, av, bv, ref_div(av, bv), "div");
        end
        // ── FP32 sqrt, random (positive) ────────────────────────────────────────
        $display("[tb_divsqrt] FP32 sqrt vs DPI golden");
        for (int i = 0; i < 6000; i++) begin
            logic [31:0] av;
            av = {1'b0, 8'(60 + ($unsigned($random) % 130)), 23'($random)};
            op(1'b1, FMT_S, av, 32'd0, ref_sqrt(av), "sqrt");
        end

        // ── FP32 directed corners ───────────────────────────────────────────────
        $display("[tb_divsqrt] FP32 directed corners");
        op(1'b0, FMT_S, 32'h40000000, 32'h40000000, 32'h3f800000, "2/2=1");
        op(1'b0, FMT_S, 32'h40400000, 32'h40000000, 32'h3fc00000, "3/2=1.5");
        op(1'b0, FMT_S, 32'h3f800000, 32'h40000000, 32'h3f000000, "1/2=0.5");
        op(1'b0, FMT_S, 32'h3f800000, 32'h40400000, ref_div(32'h3f800000,32'h40400000), "1/3");
        op(1'b0, FMT_S, 32'h3f800000, 32'h00000000, 32'h7f800000, "1/0=inf");
        op(1'b0, FMT_S, 32'hbf800000, 32'h00000000, 32'hff800000, "-1/0=-inf");
        op(1'b0, FMT_S, 32'h00000000, 32'h00000000, 32'h7fc00000, "0/0=nan");
        op(1'b0, FMT_S, 32'h7f800000, 32'h7f800000, 32'h7fc00000, "inf/inf=nan");
        op(1'b0, FMT_S, 32'h7f800000, 32'h3f800000, 32'h7f800000, "inf/1=inf");
        op(1'b0, FMT_S, 32'h3f800000, 32'h7f800000, 32'h00000000, "1/inf=0");
        op(1'b0, FMT_S, 32'h7fc00000, 32'h3f800000, 32'h7fc00000, "nan/1=nan");
        op(1'b1, FMT_S, 32'h40800000, 32'd0, 32'h40000000, "sqrt4=2");   // sqrt(4)=2 exact
        op(1'b1, FMT_S, 32'h41100000, 32'd0, 32'h40400000, "sqrt9=3");   // sqrt(9)=3 exact
        op(1'b1, FMT_S, 32'h40000000, 32'd0, ref_sqrt(32'h40000000), "sqrt2");
        op(1'b1, FMT_S, 32'h00000000, 32'd0, 32'h00000000, "sqrt+0=+0");
        op(1'b1, FMT_S, 32'h80000000, 32'd0, 32'h80000000, "sqrt-0=-0");
        op(1'b1, FMT_S, 32'hbf800000, 32'd0, 32'h7fc00000, "sqrt(-1)=nan");
        op(1'b1, FMT_S, 32'h7f800000, 32'd0, 32'h7f800000, "sqrt(inf)=inf");
        op(1'b1, FMT_S, 32'h7fc00000, 32'd0, 32'h7fc00000, "sqrt(nan)=nan");

        // ── FP16 divide / sqrt, random ──────────────────────────────────────────
        $display("[tb_divsqrt] FP16 divide / sqrt vs DPI golden");
        for (int i = 0; i < 4000; i++) begin
            logic [15:0] av, bv;
            av = rand_hp(8, 16); bv = rand_hp(8, 16);
            op(1'b0, FMT_H, boxh(av), boxh(bv), boxh(16'(ref_hdiv(32'(av), 32'(bv)))), "hdiv");
            av = {1'b0, 5'(6 + ($unsigned($random) % 22)), 10'($random)};
            op(1'b1, FMT_H, boxh(av), 32'd0, boxh(16'(ref_hsqrt(32'(av)))), "hsqrt");
        end
        // FP16 directed
        op(1'b0, FMT_H, boxh(16'h4000), boxh(16'h4000), boxh(16'h3c00), "h2/2=1");
        op(1'b0, FMT_H, boxh(16'h3c00), boxh(16'h0000), boxh(16'h7c00), "h1/0=inf");
        op(1'b1, FMT_H, boxh(16'h4400), 32'd0, boxh(16'h4000), "hsqrt4=2");
        op(1'b1, FMT_H, boxh(16'hbc00), 32'd0, boxh(16'h7e00), "hsqrt(-1)=nan");

        $display("[tb_divsqrt] total %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("[tb_divsqrt] PASS");
        else             $display("[tb_divsqrt] FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
