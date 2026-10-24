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
    import "DPI-C" function int unsigned ref_cvt_ws (input int unsigned a, input int rm, input int uns);
    // FP16 references (tests/fpu_ref.c): operate on 16-bit half patterns.
    import "DPI-C" function int unsigned ref_hadd(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_hsub(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_hmul(input int unsigned a, input int unsigned b);
    import "DPI-C" function int unsigned ref_cvt_sh(input int unsigned h);  // half -> FP32
    import "DPI-C" function int unsigned ref_cvt_hs(input int unsigned a);  // FP32 -> half
    import "DPI-C" function int unsigned ref_cvt_wh(input int unsigned h, input int rm, input int uns);  // half -> int
    import "DPI-C" function int unsigned ref_cvt_hw(input int unsigned x);  // int32 -> half
    // Fused multiply-add (single rounding): np/nc select the four variants.
    import "DPI-C" function int unsigned ref_fmaf(input int unsigned a, input int unsigned b,
                                                  input int unsigned c, input int np, input int nc);
    import "DPI-C" function int unsigned ref_hfma(input int unsigned a, input int unsigned b,
                                                  input int unsigned c, input int np, input int nc);

    logic        clk = 0;
    logic [4:0]  funct5;
    logic        cvt_unsigned;
    logic        cvt_src_h;
    logic        is_fma, fma_np, fma_nc;
    logic [2:0]  rm;
    logic [1:0]  fmt;
    logic [31:0] a, b, c, xa;
    logic [31:0] res;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        int_dest;       // exercised by integration; not checked here
    /* verilator lint_on UNUSEDSIGNAL */

    // simt_fpu is a 3-stage pipeline (M17): inputs presented in a cycle yield `res`
    // two clocks later.  ck() holds the operands and drives two posedges per check.
    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    simt_fpu dut (.clk(clk), .funct5(funct5), .cvt_unsigned(cvt_unsigned), .cvt_src_h(cvt_src_h),
                  .rm(rm), .fmt(fmt),
                  .is_fma(is_fma), .fma_np(fma_np), .fma_nc(fma_nc),
                  .a(a), .b(b), .c(c), .xa(xa), .res(res), .int_dest(int_dest));

    // NaN-box a 16-bit half into a 32-bit f-register value.
    function automatic logic [31:0] boxh(input logic [15:0] h);
        return {16'hffff, h};
    endfunction
    // Random FP16 with exponent in [11,19]: add/sub/mul of two such stay normal
    // (never subnormal/zero/inf/NaN), so results never hit the FTZ/overflow corners.
    function automatic logic [15:0] rand_half_normal();
        logic       s;
        logic [4:0] e;
        logic [9:0] m;
        s = 1'($random);
        e = 5'(11 + ($unsigned($random) % 9));
        m = 10'($random);
        return {s, e, m};
    endfunction

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

    // Random FP32 with the biased exponent in [lo, lo+span). A wide, separately
    // chosen exponent for each FMA operand exercises the aligner across product-
    // dominant, balanced (cancellation), and addend-dominant regimes.
    function automatic logic [31:0] rand_fp(input int lo, input int span);
        logic        s;
        logic [7:0]  e;
        logic [22:0] m;
        s = 1'($random);
        e = 8'(lo + ($unsigned($random) % span));
        m = 23'($random);
        return {s, e, m};
    endfunction
    // Random FP16 with biased exponent in [lo, lo+span).
    function automatic logic [15:0] rand_hp(input int lo, input int span);
        logic       s;
        logic [4:0] e;
        logic [9:0] m;
        s = 1'($random);
        e = 5'(lo + ($unsigned($random) % span));
        m = 10'($random);
        return {s, e, m};
    endfunction

    // Rounding-mode codes a float -> int convert can carry: RNE RTZ RDN RUP RMM dyn.
    localparam logic [2:0] RMS [6] = '{3'b000, 3'b001, 3'b010, 3'b011, 3'b100, 3'b111};
    // Directed float -> int inputs: ties and their neighbours, the int32 / uint32
    // bounds, zeros, subnormals (FTZ), infinities and NaNs.
    localparam int NDIR = 49;
    localparam logic [31:0] CVT_DIR [NDIR] = '{
        32'h3f000000, 32'hbf000000, 32'h3fc00000, 32'hbfc00000,   // +-0.5   +-1.5
        32'h40200000, 32'hc0200000, 32'h40600000, 32'hc0600000,   // +-2.5   +-3.5
        32'h3e800000, 32'hbe800000, 32'h3f400000, 32'hbf400000,   // +-0.25  +-0.75
        32'h3fa00000, 32'hbfa00000, 32'h3fe00000, 32'hbfe00000,   // +-1.25  +-1.75
        32'h3effffff, 32'hbeffffff, 32'h3f000001, 32'hbf000001,   // just below / above 0.5
        32'h3f800000, 32'hbf800000, 32'h42c90000, 32'hc2c90000,   // +-1     +-100.5
        32'h42cb0000, 32'hc2cb0000, 32'h4a800001, 32'h4a800003,   // +-101.5, 2^22 + 0.5 / 1.5
        32'hcaffffff, 32'h4affffff, 32'h4b000000, 32'h4effffff,   // +-(2^23 - 0.5), 2^23, < 2^31
        32'h4f000000, 32'hcf000000, 32'hcf000001, 32'h4f32d05e,   // 2^31, -2^31, below, ~3e9
        32'h4f7fffff, 32'h4f800000, 32'h00000000, 32'h80000000,   // < 2^32, 2^32, +-0
        32'h00000001, 32'h807fffff, 32'h00800000, 32'h80800000,   // subnormals, +-min normal
        32'h7f800000, 32'hff800000, 32'h7fc00000, 32'hffc00000,   // +-inf, +-qNaN
        32'h7f800001 };                                           // sNaN
    localparam int NDIR_H = 19;
    localparam logic [15:0] CVT_DIR_H [NDIR_H] = '{
        16'h3800, 16'hb800, 16'h3e00, 16'hbe00, 16'h4100, 16'hc100,   // +-0.5 +-1.5 +-2.5
        16'h3400, 16'hb400, 16'h3a00, 16'hba00,                       // +-0.25 +-0.75
        16'h7bff, 16'hfbff, 16'h0001, 16'h8001,                       // +-65504, subnormals
        16'h7c00, 16'hfc00, 16'h7e00, 16'h0000, 16'h8000 };           // +-inf, NaN, +-0

    // The caller sets the operands/controls (held stable here), then ck() clocks the FPU
    // pipeline latency so `res` reflects them. simt_fpu is a 5-stage pipeline (B2): the
    // significand multiply is a fully-pipelined DSP (input reg + 3 output regs), so the
    // result is presented FPU_LAT clocks after the operands. Operands are held stable
    // across all the edges, so the pipeline flushes to this vector's result.
    localparam int FPU_LAT = 5;
    task automatic ck(input logic [31:0] exp, input string tag);
        logic [31:0] sa, sb, sc, sxa;
        checks++;
        sa = a; sb = b; sc = c; sxa = xa;   // remember inputs for the message
        for (int k = 0; k < FPU_LAT; k++) @(posedge clk);   // drain the 5-stage pipeline
        #1;                                 // stage-3 combinational settles
        if (res !== exp) begin
            if (errors < 12)
                $display("  [FAIL] %-10s a=%08h b=%08h c=%08h xa=%08h rm=%0d -> %08h exp %08h",
                         tag, sa, sb, sc, sxa, rm, res, exp);
            errors++;
        end
    endtask

    initial begin
        fmt = FMT_S; rm = 3'b000; cvt_unsigned = 1'b0; cvt_src_h = 1'b0;
        is_fma = 1'b0; fma_np = 1'b0; fma_nc = 1'b0;
        a = 0; b = 0; c = 0; xa = 0; funct5 = FP_ADD;

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
            logic [31:0] iv;
            iv = $random;
            funct5 = FP_CVT_S; cvt_unsigned = 1'b0; xa = iv; ck(ref_cvt_sw(iv),  "cvt.s.w");
            funct5 = FP_CVT_S; cvt_unsigned = 1'b1; xa = iv; ck(ref_cvt_swu(iv), "cvt.s.wu");
        end

        // float -> int under every rounding mode, signed and unsigned: random values
        // with |x| from 2^-8 to 2^34 (fractions, ties, saturation), then directed ones.
        $display("[tb_fpu] float -> int, all rounding modes, vs DPI golden");
        funct5 = FP_CVT_W;
        for (int i = 0; i < 8000; i++) begin
            logic [31:0] fv;
            fv = rand_fp(119, 42);
            rm = RMS[$unsigned($random) % 6]; cvt_unsigned = 1'($random); a = fv;
            if (cvt_unsigned) ck(ref_cvt_ws(fv, int'(rm), 1), "cvt.wu.s");
            else              ck(ref_cvt_ws(fv, int'(rm), 0), "cvt.w.s");
        end
        for (int j = 0; j < NDIR; j++)
            for (int k = 0; k < 6; k++) begin
                rm = RMS[k]; a = CVT_DIR[j];
                cvt_unsigned = 1'b0; ck(ref_cvt_ws(CVT_DIR[j], int'(rm), 0), "cvt.w.s");
                cvt_unsigned = 1'b1; ck(ref_cvt_ws(CVT_DIR[j], int'(rm), 1), "cvt.wu.s");
            end
        rm = 3'b000; cvt_unsigned = 1'b0;
        $display("  %0d checks, %0d errors so far", checks, errors);

        // ── Fused multiply-add (FP32), all four variants, vs single-rounded fmaf ──
        $display("[tb_fpu] FP32 fused FMA vs DPI fmaf golden (all 4 variants)");
        is_fma = 1'b1; fmt = FMT_S; rm = 3'b000; cvt_unsigned = 1'b0;
        for (int i = 0; i < 12000; i++) begin
            logic [31:0] av, bv, cv;
            logic [1:0]  v;
            av = rand_fp(115, 26);          // a,b: exp [115,140]
            bv = rand_fp(115, 26);
            cv = rand_fp(95, 66);           // c : exp [95,160] -> wide alignment range
            v  = 2'($unsigned($random));    // 0:fmadd 1:fmsub 2:fnmsub 3:fnmadd
            fma_np = v[1]; fma_nc = v[0];
            a = av; b = bv; c = cv;
            ck(ref_fmaf(av, bv, cv, {31'd0, v[1]}, {31'd0, v[0]}), "fma");
        end
        // Directed FMA corners: exact products, cancellation, inf/nan, FTZ-ish.
        fma_np = 1'b0; fma_nc = 1'b0;
        a = 32'h3f800000; b = 32'h40000000; c = 32'h3f800000; ck(ref_fmaf(a,b,c,0,0), "1*2+1");   // 3
        a = 32'h40000000; b = 32'h40000000; c = 32'hc0800000; ck(ref_fmaf(a,b,c,0,0), "2*2-4=0"); // exact cancel
        a = 32'h3f800000; b = 32'h3f800000; c = 32'hbf800000; ck(ref_fmaf(a,b,c,0,0), "1*1-1=0");
        a = 32'h4b800000; b = 32'h4b800000; c = 32'h3f800000; ck(ref_fmaf(a,b,c,0,0), "big*big+1"); // c tiny vs prod
        a = 32'h3f800000; b = 32'h3f800000; c = 32'h4b800000; ck(ref_fmaf(a,b,c,0,0), "1+big");     // c dom
        a = 32'h7f800000; b = 32'h3f800000; c = 32'h3f800000; ck(ref_fmaf(a,b,c,0,0), "inf*1+1");
        a = 32'h00000000; b = 32'h7f800000; c = 32'h3f800000; ck(ref_fmaf(a,b,c,0,0), "0*inf+1=nan");
        a = 32'h7f800000; b = 32'h3f800000; c = 32'hff800000; ck(ref_fmaf(a,b,c,0,0), "inf-inf=nan");
        a = 32'h7fc00000; b = 32'h3f800000; c = 32'h3f800000; ck(ref_fmaf(a,b,c,0,0), "nan*1+1");
        a = 32'h00000000; b = 32'h3f800000; c = 32'h40000000; ck(ref_fmaf(a,b,c,0,0), "0*1+2=2");
        a = 32'h3f800000; b = 32'h3f800000; c = 32'h00000000; ck(ref_fmaf(a,b,c,0,0), "1*1+0=1");
        fma_nc = 1'b1;  // fmsub: a*b - c
        a = 32'h40000000; b = 32'h40000000; c = 32'h40800000; ck(ref_fmaf(a,b,c,0,1), "2*2-4=0(sub)");
        fma_np = 1'b1; fma_nc = 1'b0;  // fnmsub: -(a*b) + c
        a = 32'h3f800000; b = 32'h40000000; c = 32'h40000000; ck(ref_fmaf(a,b,c,1,0), "-(1*2)+2=0");
        fma_np = 1'b1; fma_nc = 1'b1;  // fnmadd: -(a*b) - c
        a = 32'h3f800000; b = 32'h40000000; c = 32'h3f800000; ck(ref_fmaf(a,b,c,1,1), "-(2)-1=-3");
        is_fma = 1'b0; fma_np = 1'b0; fma_nc = 1'b0;
        $display("  %0d checks, %0d errors so far", checks, errors);

        // ══════════════════════════ FP16 (HALF) ═══════════════════════════════════
        fmt = FMT_H; rm = 3'b000; cvt_unsigned = 1'b0; cvt_src_h = 1'b0;

        $display("[tb_fpu] FP16 random normal-range add/sub/mul vs DPI half golden");
        for (int i = 0; i < 8000; i++) begin
            logic [15:0] av, bv;
            av = rand_half_normal(); bv = rand_half_normal();
            funct5 = FP_ADD; a = boxh(av); b = boxh(bv); ck(boxh(16'(ref_hadd(32'(av), 32'(bv)))), "hadd");
            funct5 = FP_SUB; a = boxh(av); b = boxh(bv); ck(boxh(16'(ref_hsub(32'(av), 32'(bv)))), "hsub");
            funct5 = FP_MUL; a = boxh(av); b = boxh(bv); ck(boxh(16'(ref_hmul(32'(av), 32'(bv)))), "hmul");
        end
        $display("  %0d checks, %0d errors so far", checks, errors);

        $display("[tb_fpu] FP16 directed specials + NaN-boxing");
        funct5 = FP_ADD; a = boxh(16'h7c00); b = boxh(16'h7c00); ck(boxh(16'h7c00), "hinf+inf");
        funct5 = FP_ADD; a = boxh(16'h7c00); b = boxh(16'hfc00); ck(boxh(16'h7e00), "hinf-inf");
        funct5 = FP_MUL; a = boxh(16'h0000); b = boxh(16'h7c00); ck(boxh(16'h7e00), "h0*inf");
        funct5 = FP_MUL; a = boxh(16'h3c00); b = boxh(16'h4000); ck(boxh(16'h4000), "h1*2");
        funct5 = FP_ADD; a = boxh(16'h3c00); b = boxh(16'hbc00); ck(boxh(16'h0000), "h1-1");
        funct5 = FP_ADD; a = boxh(16'h3c00); b = boxh(16'h0001); ck(boxh(16'h3c00), "h1+denorm(FTZ)");
        funct5 = FP_MUL; a = boxh(16'h7bff); b = boxh(16'h4000); ck(boxh(16'h7c00), "hovf->inf");
        funct5 = FP_MUL; a = boxh(16'h0400); b = boxh(16'h0400); ck(boxh(16'h0000), "hunf->0(FTZ)");
        // mis-NaN-boxed operand (upper bits not all ones) must read as canonical NaN
        funct5 = FP_ADD; a = 32'h0000_3c00; b = boxh(16'h3c00); ck(boxh(16'h7e00), "unboxed->nan");

        $display("[tb_fpu] FP16 sgnj / minmax / compare / fmv");
        funct5 = FP_SGNJ; rm = 3'b000; a = boxh(16'h3c00); b = boxh(16'hbc00); ck(boxh(16'hbc00), "hsgnj");
        funct5 = FP_SGNJ; rm = 3'b001; a = boxh(16'h3c00); b = boxh(16'hbc00); ck(boxh(16'h3c00), "hsgnjn");
        funct5 = FP_SGNJ; rm = 3'b010; a = boxh(16'hbc00); b = boxh(16'hbc00); ck(boxh(16'h3c00), "hsgnjx");
        funct5 = FP_MINMAX; rm = 3'b000; a = boxh(16'h4000); b = boxh(16'h3c00); ck(boxh(16'h3c00), "hmin");
        funct5 = FP_MINMAX; rm = 3'b001; a = boxh(16'h4000); b = boxh(16'h3c00); ck(boxh(16'h4000), "hmax");
        funct5 = FP_MINMAX; rm = 3'b000; a = boxh(16'h7e00); b = boxh(16'h3c00); ck(boxh(16'h3c00), "hmin(nan,1)");
        funct5 = FP_CMP; rm = 3'b001; a = boxh(16'h3c00); b = boxh(16'h4000); ck(32'd1, "hlt");
        funct5 = FP_CMP; rm = 3'b010; a = boxh(16'h3c00); b = boxh(16'h3c00); ck(32'd1, "heq");
        funct5 = FP_CMP; rm = 3'b000; a = boxh(16'h4000); b = boxh(16'h3c00); ck(32'd0, "hle");
        funct5 = FP_CMP; rm = 3'b010; a = boxh(16'h7e00); b = boxh(16'h3c00); ck(32'd0, "heq(nan)");
        // fmv.x.h sign-extends the 16-bit value; fmv.h.x NaN-boxes the low 16 bits
        funct5 = FP_FMVXW; rm = 3'b000; a = boxh(16'hbc00); ck(32'hffff_bc00, "fmv.x.h(neg)");
        funct5 = FP_FMVXW; rm = 3'b000; a = boxh(16'h3c00); ck(32'h0000_3c00, "fmv.x.h(pos)");
        funct5 = FP_FMVWX; xa = 32'h1234_abcd;              ck(boxh(16'habcd), "fmv.h.x");
        // fclass.h: -normal (bit1), +0 (bit4), +inf (bit7), qNaN (bit9)
        funct5 = FP_FMVXW; rm = 3'b001; a = boxh(16'hbc00); ck(32'h0000_0002, "fclass.h(-norm)");
        funct5 = FP_FMVXW; rm = 3'b001; a = boxh(16'h0000); ck(32'h0000_0010, "fclass.h(+0)");
        funct5 = FP_FMVXW; rm = 3'b001; a = boxh(16'h7c00); ck(32'h0000_0080, "fclass.h(+inf)");
        funct5 = FP_FMVXW; rm = 3'b001; a = boxh(16'h7e00); ck(32'h0000_0200, "fclass.h(qnan)");

        $display("[tb_fpu] FP16 conversions vs DPI golden");
        rm = 3'b000; cvt_unsigned = 1'b0;
        for (int i = 0; i < 4000; i++) begin
            logic [15:0] hv;
            logic [31:0] fv, iv;
            hv = rand_half_normal();
            // fcvt.s.h : half -> FP32 (source is half)
            funct5 = FP_CVT_FF; fmt = FMT_S; cvt_src_h = 1'b1; a = boxh(hv);
            ck(ref_cvt_sh(32'(hv)), "cvt.s.h");
            // fcvt.h.s : FP32 (in FP16's normal range) -> half
            fv = {1'($random), 8'(115 + ($unsigned($random) % 26)), 23'($random)};
            funct5 = FP_CVT_FF; fmt = FMT_H; cvt_src_h = 1'b0; a = fv;
            ck(boxh(16'(ref_cvt_hs(fv))), "cvt.h.s");
            // fcvt.w.h / fcvt.wu.h : half -> int, a random rounding mode
            funct5 = FP_CVT_W; fmt = FMT_H; cvt_src_h = 1'b0; a = boxh(hv);
            rm = RMS[$unsigned($random) % 6]; cvt_unsigned = 1'($random);
            if (cvt_unsigned) ck(ref_cvt_wh(32'(hv), int'(rm), 1), "cvt.wu.h");
            else              ck(ref_cvt_wh(32'(hv), int'(rm), 0), "cvt.w.h");
            rm = 3'b000; cvt_unsigned = 1'b0;
            // fcvt.h.w : int32 -> half (RNE)
            iv = $random;
            funct5 = FP_CVT_S; fmt = FMT_H; cvt_src_h = 1'b0; xa = iv;
            ck(boxh(16'(ref_cvt_hw(iv))), "cvt.h.w");
        end
        funct5 = FP_CVT_W; fmt = FMT_H; cvt_src_h = 1'b0;
        for (int j = 0; j < NDIR_H; j++)
            for (int k = 0; k < 6; k++) begin
                rm = RMS[k]; a = boxh(CVT_DIR_H[j]);
                cvt_unsigned = 1'b0; ck(ref_cvt_wh(32'(CVT_DIR_H[j]), int'(rm), 0), "cvt.w.h");
                cvt_unsigned = 1'b1; ck(ref_cvt_wh(32'(CVT_DIR_H[j]), int'(rm), 1), "cvt.wu.h");
            end
        rm = 3'b000; cvt_unsigned = 1'b0;

        // ── Fused multiply-add (FP16), all four variants, vs single-rounded fma ──
        $display("[tb_fpu] FP16 fused FMA vs DPI half-fma golden (all 4 variants)");
        is_fma = 1'b1; fmt = FMT_H; rm = 3'b000; cvt_unsigned = 1'b0; cvt_src_h = 1'b0;
        for (int i = 0; i < 8000; i++) begin
            logic [15:0] av, bv, cv;
            logic [1:0]  v;
            av = rand_hp(12, 8);            // a,b: exp [12,19]
            bv = rand_hp(12, 8);
            cv = rand_hp(5, 22);           // c : exp [5,26] -> wide alignment range
            v  = 2'($unsigned($random));
            fma_np = v[1]; fma_nc = v[0];
            a = boxh(av); b = boxh(bv); c = boxh(cv);
            ck(boxh(16'(ref_hfma(32'(av), 32'(bv), 32'(cv), {31'd0, v[1]}, {31'd0, v[0]}))), "hfma");
        end
        // Directed FP16 FMA corners.
        fma_np = 1'b0; fma_nc = 1'b0;
        a = boxh(16'h3c00); b = boxh(16'h4000); c = boxh(16'h3c00); ck(boxh(16'(ref_hfma(32'h3c00,32'h4000,32'h3c00,0,0))), "h1*2+1");
        a = boxh(16'h4000); b = boxh(16'h4000); c = boxh(16'hc400); ck(boxh(16'(ref_hfma(32'h4000,32'h4000,32'hc400,0,0))), "h2*2-4=0");
        a = boxh(16'h7c00); b = boxh(16'h3c00); c = boxh(16'hfc00); ck(boxh(16'h7e00), "hinf-inf=nan");
        a = boxh(16'h0000); b = boxh(16'h7c00); c = boxh(16'h3c00); ck(boxh(16'h7e00), "h0*inf=nan");
        // Double-rounding trap: the exact result -1426.50006 rounds to the FP32 tie
        // -1426.5 under RNE, which then narrows to -1426 (e592). Correct is -1427.
        a = boxh(16'h3620); b = boxh(16'h4b2f); c = boxh(16'he598); ck(boxh(16'he593), "hfma-dblrnd");
        fma_np = 1'b1;
        a = boxh(16'h3620); b = boxh(16'h4b2f); c = boxh(16'h6598); ck(boxh(16'h6593), "hfma-dblrnd-n");
        fma_np = 1'b0;
        is_fma = 1'b0; fma_np = 1'b0; fma_nc = 1'b0;
        $display("  %0d checks, %0d errors so far", checks, errors);

        $display("[tb_fpu] total %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("[tb_fpu] PASS");
        else             $display("[tb_fpu] FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
