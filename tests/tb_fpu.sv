// =============================================================================
// tb_fpu.sv  -  M14.1 standalone verification of the per-lane FP32 unit
//
// Drives simt_fpu combinationally and checks it BIT-EXACT against a DPI-C IEEE-754
// single-precision reference (tests/fpu_ref.c, real `float` hardware) over
// thousands of random vectors, plus directed inf/NaN/zero/FTZ/overflow corners.
// Random arithmetic inputs are constrained to a normal exponent range so add/sub/
// mul results stay normal (the engine flushes subnormals to zero by design);
// subnormal/overflow behaviour is checked separately with directed expectations.
// =============================================================================
`timescale 1ns/1ps

module tb_fpu
  import simtix_pkg::*;
;
    import "DPI-C" function int unsigned ref_add(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_sub(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_mul(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_cvt_sw (input int unsigned x);
    import "DPI-C" function int unsigned ref_cvt_swu(input int unsigned x);
    import "DPI-C" function int unsigned ref_cvt_ws (input int unsigned a);

    logic [4:0]  funct5;
    logic        cvt_unsigned;
    logic [2:0]  rm;
    logic [1:0]  fmt;
    logic [31:0] a, b, xa;
    logic [31:0] res;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        int_dest;       // exercised by integration; not checked here
    /* verilator lint_on UNUSEDSIGNAL */

    simt_fpu dut (.funct5(funct5), .cvt_unsigned(cvt_unsigned), .rm(rm), .fmt(fmt),
                  .a(a), .b(b), .xa(xa), .res(res), .int_dest(int_dest));

    int unsigned errors = 0;
    int unsigned checks = 0;

    // Random FP32 with exponent in [100,154]: never subnormal/zero/inf/NaN, and
    // add/sub/mul of two such values stay comfortably inside the normal range.
    function automatic logic [31:0] rand_normal();
        logic        s;
        logic [7:0]  e;
        logic [22:0] m;
        s = 1'($random);
        e = 8'(100 + ($unsigned($random) % 55));
        m = 23'($random);
        return {s, e, m};
    endfunction

    task automatic ck(input logic [31:0] exp, input string tag);
        checks++;
        #1;
        if (res !== exp) begin
            if (errors < 12)
                $display("  [FAIL] %-10s a=%08h b=%08h xa=%08h -> %08h exp %08h",
                         tag, a, b, xa, res, exp);
            errors++;
        end
    endtask

    initial begin
        fmt = FMT_S; rm = 3'b000; cvt_unsigned = 1'b0; a = 0; b = 0; xa = 0;
        funct5 = FP_ADD;

        $display("[tb_fpu] random normal-range add/sub/mul vs DPI float golden");
        for (int i = 0; i < 8000; i++) begin
            logic [31:0] av, bv;
            av = rand_normal(); bv = rand_normal();
            funct5 = FP_ADD; a = av; b = bv; ck(ref_add(av, bv), "fadd");
            funct5 = FP_SUB; a = av; b = bv; ck(ref_sub(av, bv), "fsub");
            funct5 = FP_MUL; a = av; b = bv; ck(ref_mul(av, bv), "fmul");
        end
        $display("  %0d checks, %0d errors so far", checks, errors);

        // ── Directed special values ────────────────────────────────────────────
        $display("[tb_fpu] directed specials (inf / nan / zero / FTZ / overflow)");
        funct5 = FP_ADD; a = 32'h7f800000; b = 32'h7f800000; ck(32'h7f800000, "inf+inf");
        funct5 = FP_ADD; a = 32'h7f800000; b = 32'hff800000; ck(32'h7fc00000, "inf-inf");
        funct5 = FP_MUL; a = 32'h7fc00000; b = 32'h3f800000; ck(32'h7fc00000, "nan*1");
        funct5 = FP_MUL; a = 32'h00000000; b = 32'h7f800000; ck(32'h7fc00000, "0*inf");
        funct5 = FP_MUL; a = 32'h3f800000; b = 32'h40000000; ck(32'h40000000, "1*2");
        funct5 = FP_ADD; a = 32'h3f800000; b = 32'hbf800000; ck(32'h00000000, "1-1");
        funct5 = FP_ADD; a = 32'h3f800000; b = 32'h00000001; ck(32'h3f800000, "1+denorm(FTZ)");
        funct5 = FP_MUL; a = 32'h7f7fffff; b = 32'h40000000; ck(32'h7f800000, "ovf->inf");
        funct5 = FP_MUL; a = 32'h00800000; b = 32'h00800000; ck(32'h00000000, "unf->0(FTZ)");

        // ── Sign inject / minmax / compare / fmv ─────────────────────────────────
        $display("[tb_fpu] sgnj / minmax / compare / fmv");
        funct5 = FP_SGNJ; rm = 3'b000; a = 32'h3f800000; b = 32'hbf800000; ck(32'hbf800000, "fsgnj");
        funct5 = FP_SGNJ; rm = 3'b001; a = 32'h3f800000; b = 32'hbf800000; ck(32'h3f800000, "fsgnjn");
        funct5 = FP_SGNJ; rm = 3'b010; a = 32'hbf800000; b = 32'hbf800000; ck(32'h3f800000, "fsgnjx");
        funct5 = FP_MINMAX; rm = 3'b000; a = 32'h40000000; b = 32'h3f800000; ck(32'h3f800000, "fmin");
        funct5 = FP_MINMAX; rm = 3'b001; a = 32'h40000000; b = 32'h3f800000; ck(32'h40000000, "fmax");
        funct5 = FP_MINMAX; rm = 3'b000; a = 32'h7fc00000; b = 32'h3f800000; ck(32'h3f800000, "fmin(nan,1)");
        funct5 = FP_CMP; rm = 3'b001; a = 32'h3f800000; b = 32'h40000000; ck(32'd1, "flt");
        funct5 = FP_CMP; rm = 3'b010; a = 32'h3f800000; b = 32'h3f800000; ck(32'd1, "feq");
        funct5 = FP_CMP; rm = 3'b000; a = 32'h40000000; b = 32'h3f800000; ck(32'd0, "fle");
        funct5 = FP_CMP; rm = 3'b010; a = 32'h7fc00000; b = 32'h3f800000; ck(32'd0, "feq(nan)");
        funct5 = FP_CMP; rm = 3'b001; a = 32'hbf800000; b = 32'h3f800000; ck(32'd1, "flt(-1,1)");
        funct5 = FP_FMVXW; rm = 3'b000; a = 32'h12345678; ck(32'h12345678, "fmv.x.w");
        funct5 = FP_FMVWX; xa = 32'h89abcdef;             ck(32'h89abcdef, "fmv.w.x");

        // ── Conversions, random, vs DPI cast ────────────────────────────────────
        $display("[tb_fpu] conversions vs DPI float golden");
        rm = 3'b000;
        for (int i = 0; i < 4000; i++) begin
            logic [31:0] iv, fv;
            iv = $random;
            funct5 = FP_CVT_S; cvt_unsigned = 1'b0; xa = iv; ck(ref_cvt_sw(iv),  "cvt.s.w");
            funct5 = FP_CVT_S; cvt_unsigned = 1'b1; xa = iv; ck(ref_cvt_swu(iv), "cvt.s.wu");
            fv = rand_normal();
            funct5 = FP_CVT_W; cvt_unsigned = 1'b0; a = fv; ck(ref_cvt_ws(fv),  "cvt.w.s");
        end

        $display("[tb_fpu] total %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("[tb_fpu] PASS");
        else             $display("[tb_fpu] FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
