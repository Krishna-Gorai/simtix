// =============================================================================
// simt_fpu.sv  -  M14.1 compact per-lane single-precision (FP32) execute unit
//
// A purely combinational RV32F execute datapath for the COMMON floating-point
// ops, instantiated once per SIMT lane:
//     fadd.s  fsub.s  fmul.s                       (arithmetic)
//     fsgnj.s  fsgnjn.s  fsgnjx.s                  (sign inject)
//     fmin.s  fmax.s                               (IEEE minNum/maxNum)
//     feq.s  flt.s  fle.s                          (compares  -> integer reg)
//     fcvt.w.s  fcvt.wu.s                          (float -> int, RTZ)
//     fcvt.s.w  fcvt.s.wu                          (int -> float, RNE)
//     fmv.x.w  fclass.s                            (bit move / classify -> int)
//     fmv.w.x                                      (bit move int -> float)
//
// Rounding: round-to-nearest-even (RNE) for arithmetic and int->float; float->int
// truncates toward zero (RTZ, matching a C cast). Subnormals are FLUSHED TO ZERO
// (FTZ) on both inputs and results — a deliberate GPU-style throughput choice that
// keeps the per-lane datapath small. NaN/inf/signed-zero handled per IEEE-754.
//
// NOT here (by design): fused multiply-add (M14.1b — exact single rounding), div/
// sqrt (shared SFU, M14.3), FP16 (M14.2). fmt != S returns 0. No FCSR yet, so
// exception flags are not produced.
//
// Verified standalone (tests/tb_fpu.sv) bit-exact against IEEE `shortreal` over
// tens of thousands of random vectors plus directed inf/NaN/zero/FTZ corners.
// =============================================================================
`timescale 1ns/1ps

module simt_fpu
  import simtix_pkg::*;
(
    input  logic [4:0]  funct5,       // OP-FP operation select (instr[31:27])
    input  logic        cvt_unsigned, // instr[20] — unsigned variant of fcvt
    input  logic [2:0]  rm,           // funct3 — rounding mode / group sub-select
    input  logic [1:0]  fmt,      // format (only FMT_S handled here)
    input  logic [31:0] a,        // f[rs1]
    input  logic [31:0] b,        // f[rs2]
    input  logic [31:0] xa,       // x[rs1]  (int->float, fmv.w.x)
    output logic [31:0] res,      // result bits (FP or int per int_dest)
    output logic        int_dest  // 1: result goes to the integer register file
);
    localparam logic [31:0] CANON_QNAN = 32'h7fc0_0000;  // canonical quiet NaN

    // ── Unpack + classify (FTZ: a zero exponent — incl. subnormal — reads as 0) ──
    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    assign sa = a[31]; assign ea = a[30:23]; assign ma = a[22:0];
    assign sb = b[31]; assign eb = b[30:23]; assign mb = b[22:0];

    logic a_zero, a_inf, a_nan, a_snan;
    logic b_zero, b_inf, b_nan;
    assign a_zero = (ea == 8'd0);                      // FTZ: subnormal -> zero
    assign a_inf  = (ea == 8'hff) && (ma == 23'd0);
    assign a_nan  = (ea == 8'hff) && (ma != 23'd0);
    assign a_snan = a_nan && !ma[22];
    assign b_zero = (eb == 8'd0);
    assign b_inf  = (eb == 8'hff) && (mb == 23'd0);
    assign b_nan  = (eb == 8'hff) && (mb != 23'd0);

    // 24-bit significands (hidden 1 for normals; 0 for FTZ-zero).
    logic [23:0] siga, sigb;
    assign siga = a_zero ? 24'd0 : {1'b1, ma};
    assign sigb = b_zero ? 24'd0 : {1'b1, mb};

    // ── RNE pack: build a finite FP32 from sign / biased exponent (value =
    //    1.f * 2^(exp-127)) / 24-bit significand {1.f} + guard/round/sticky. ──────
    function automatic logic [31:0] pack_round(input logic               sign,
                                               input logic signed [11:0] exp,
                                               input logic [23:0]        sig,
                                               input logic               g,
                                               input logic               r,
                                               input logic               s);
        logic [24:0]        m;
        logic signed [11:0] e;
        logic               round_up;
        m = {1'b0, sig};
        e = exp;
        round_up = g && (r || s || sig[0]);
        if (round_up) begin
            m = m + 25'd1;
            if (m[24]) begin               // mantissa carried out -> 1.0, exp++
                m = 25'h0800000;
                e = e + 12'sd1;
            end
        end
        if (e >= 12'sd255)      pack_round = {sign, 8'hff, 23'd0};  // overflow -> inf
        else if (e <= 12'sd0)   pack_round = {sign, 31'd0};        // FTZ underflow -> 0
        else                    pack_round = {sign, e[7:0], m[22:0]};
    endfunction

    // Ordered less-than for two non-NaN FP32 values (handles signed zero); callers
    // pass FTZ-canonicalised operands (zero significand) so -0 and +0 compare right.
    function automatic logic fp_lt(input logic [31:0] x, input logic [31:0] y,
                                   input logic xz, input logic yz);
        logic xs, ys;
        xs = x[31]; ys = y[31];
        if (xz && yz)      fp_lt = xs && !ys;            // -0 < +0
        else if (xs != ys) fp_lt = xs;                   // negative < positive
        else if (!xs)      fp_lt = (x[30:0] < y[30:0]);  // both positive
        else               fp_lt = (x[30:0] > y[30:0]);  // both negative
    endfunction

    // ════════════════════════════ ADD / SUB ════════════════════════════════════
    // fsub = fadd with b's sign flipped. 64-bit intermediates keep the add carry
    // and a generous guard field; the 24-bit significand sits at bits [49:26].
    logic        addsub_is_sub;
    assign addsub_is_sub = (funct5 == FP_SUB);
    logic        sb_eff;
    assign sb_eff = sb ^ addsub_is_sub;

    logic [31:0] add_res;
    always_comb begin
        logic        eff_sub, a_ge_b;
        logic        s_big;
        logic [7:0]  e_big, e_small;
        logic [23:0] sig_big, sig_small;
        logic [8:0]  ediff;
        logic [63:0] big_ext, small_ext, shifted, mag;
        logic        sticky;
        int unsigned msb;
        logic signed [11:0] e_res;
        /* verilator lint_off UNUSEDSIGNAL */  // only norm[49:0] read after normalise
        logic [63:0] norm;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [23:0] sig_f;
        logic        g, r, s;

        a_ge_b  = (ea > eb) || ((ea == eb) && (siga >= sigb));
        eff_sub = sa ^ sb_eff;

        if (a_ge_b) begin
            s_big = sa;     e_big = ea; sig_big = siga; e_small = eb; sig_small = sigb;
        end else begin
            s_big = sb_eff; e_big = eb; sig_big = sigb; e_small = ea; sig_small = siga;
        end

        big_ext   = {40'd0, sig_big}   << 26;   // 24-bit significand -> bits [49:26]
        small_ext = {40'd0, sig_small} << 26;
        ediff     = {1'b0, e_big} - {1'b0, e_small};

        if (ediff > 9'd50) begin
            sticky     = (small_ext != 64'd0);
            shifted    = {63'd0, sticky};
        end else begin
            shifted    = small_ext >> ediff[5:0];
            sticky     = |(small_ext & ((64'd1 << ediff[5:0]) - 64'd1));
            shifted[0] = shifted[0] | sticky;
        end

        if (!eff_sub) mag = big_ext + shifted;     // same sign: add magnitudes
        else          mag = big_ext - shifted;     // diff sign: subtract (big>=small)

        // normalise: place the most-significant set bit at position 49 (1.f@[49:26])
        msb = 0;
        for (int i = 0; i < 64; i++) if (mag[i]) msb = i;
        e_res = $signed({4'd0, e_big}) + $signed({6'd0, msb[5:0]}) - 12'sd49;
        if (msb >= 49) norm = mag >> (msb - 49);
        else           norm = mag << (49 - msb);
        sig_f = norm[49:26];
        g = norm[25];
        r = norm[24];
        s = |norm[23:0];

        if (a_nan || b_nan)        add_res = CANON_QNAN;
        else if (a_inf && b_inf)   add_res = (sa == sb_eff) ? {sa, 8'hff, 23'd0}
                                                            : CANON_QNAN;
        else if (a_inf)            add_res = {sa,     8'hff, 23'd0};
        else if (b_inf)            add_res = {sb_eff, 8'hff, 23'd0};
        else if (mag == 64'd0)     add_res = 32'd0;           // exact cancellation -> +0
        else                       add_res = pack_round(s_big, e_res, sig_f, g, r, s);
    end

    // ════════════════════════════════ MUL ══════════════════════════════════════
    logic [31:0] mul_res;
    always_comb begin
        logic               rsign;
        logic [47:0]        prod;
        logic signed [11:0] e_res;
        logic [23:0]        sig_f;
        logic               g, r, s;
        rsign = sa ^ sb;
        prod  = siga * sigb;                 // 24x24 -> 48 bits, in [1,4) for normals
        e_res = 12'sd0; sig_f = 24'd0; g = 1'b0; r = 1'b0; s = 1'b0;

        if (a_nan || b_nan)                       mul_res = CANON_QNAN;
        else if ((a_inf && b_zero) || (b_inf && a_zero)) mul_res = CANON_QNAN; // 0*inf
        else if (a_inf || b_inf)                  mul_res = {rsign, 8'hff, 23'd0};
        else if (a_zero || b_zero)                mul_res = {rsign, 31'd0};
        else begin
            if (prod[47]) begin                  // 2 <= product < 4
                e_res = $signed({4'd0, ea}) + $signed({4'd0, eb}) - 12'sd126;
                sig_f = prod[47:24]; g = prod[23]; r = prod[22]; s = |prod[21:0];
            end else begin                       // 1 <= product < 2
                e_res = $signed({4'd0, ea}) + $signed({4'd0, eb}) - 12'sd127;
                sig_f = prod[46:23]; g = prod[22]; r = prod[21]; s = |prod[20:0];
            end
            mul_res = pack_round(rsign, e_res, sig_f, g, r, s);
        end
    end

    // ═══════════════════════════ SGNJ / MINMAX / CMP ════════════════════════════
    logic [31:0] sgnj_res;
    always_comb begin
        logic newsign;
        unique case (rm)
            3'b000:  newsign = sb;          // fsgnj
            3'b001:  newsign = ~sb;         // fsgnjn
            default: newsign = sa ^ sb;     // fsgnjx
        endcase
        sgnj_res = {newsign, a[30:0]};
    end

    // canonicalised (FTZ) operands for the ordered comparisons / min-max
    logic [31:0] acan, bcan;
    assign acan = a_zero ? {sa, 31'd0} : a;
    assign bcan = b_zero ? {sb, 31'd0} : b;

    logic [31:0] minmax_res;
    always_comb begin
        logic less;
        less = fp_lt(acan, bcan, a_zero, b_zero);
        if      (a_nan && b_nan) minmax_res = CANON_QNAN;
        else if (a_nan)          minmax_res = bcan;
        else if (b_nan)          minmax_res = acan;
        else if (rm == 3'b000)   minmax_res = less ? acan : bcan;   // fmin
        else                     minmax_res = less ? bcan : acan;   // fmax
    end

    logic [31:0] cmp_res;
    always_comb begin
        logic eq, lt, le, unordered;
        unordered = a_nan || b_nan;
        eq = !unordered && ( (a_zero && b_zero) ? 1'b1 :
                             (!a_zero && !b_zero) ? (a == b) : 1'b0 );
        lt = !unordered && fp_lt(acan, bcan, a_zero, b_zero);
        le = lt || eq;
        unique case (rm)
            3'b010:  cmp_res = {31'd0, eq};   // feq
            3'b001:  cmp_res = {31'd0, lt};   // flt
            default: cmp_res = {31'd0, le};   // fle
        endcase
    end

    // ═══════════════════════ CONVERSIONS  +  MOVES ══════════════════════════════
    // float -> int (truncate toward zero, RISC-V saturation; NaN -> max).
    logic [31:0] cvt_w_res;
    always_comb begin
        logic               is_unsigned;
        logic signed [11:0] uexp;             // unbiased exponent
        logic [31:0]        mag, sig32;
        is_unsigned = cvt_unsigned;
        sig32 = {8'd0, siga};
        uexp = $signed({4'd0, ea}) - 12'sd127;
        // integer magnitude = siga * 2^(uexp-23)  (RTZ drops the fraction)
        if (uexp < 0)        mag = 32'd0;
        else if (uexp >= 31) mag = 32'hffffffff;          // clamp; range-checked below
        else if (uexp >= 23) mag = sig32 << 5'(uexp - 12'sd23);
        else                 mag = sig32 >> 5'(12'sd23 - uexp);

        if (a_nan) begin
            cvt_w_res = is_unsigned ? 32'hffffffff : 32'h7fffffff;
        end else if (is_unsigned) begin
            if (sa && !a_zero)    cvt_w_res = 32'd0;             // negative -> 0
            else if (a_inf)       cvt_w_res = 32'hffffffff;
            else if (uexp >= 32)  cvt_w_res = 32'hffffffff;      // overflow
            else                  cvt_w_res = mag;
        end else begin
            if (a_inf)                  cvt_w_res = sa ? 32'h80000000 : 32'h7fffffff;
            else if (!sa && uexp >= 31) cvt_w_res = 32'h7fffffff;
            else if ( sa && uexp >= 31) cvt_w_res = 32'h80000000;
            else                        cvt_w_res = sa ? (~mag + 32'd1) : mag;
        end
    end

    // int -> float (RNE).
    logic [31:0] cvt_s_res;
    always_comb begin
        logic               is_unsigned, sign;
        logic [31:0]        mag, lost;
        int unsigned        msb, sh;
        /* verilator lint_off UNUSEDSIGNAL */  // only shifted[23:0] read after align
        logic [31:0]        shifted;
        /* verilator lint_on UNUSEDSIGNAL */
        logic signed [11:0] e_res;
        logic [23:0]        sig_f;
        logic               g, r, s;
        is_unsigned = cvt_unsigned;
        sign = (!is_unsigned) && xa[31];
        mag  = sign ? (~xa + 32'd1) : xa;
        g = 1'b0; r = 1'b0; s = 1'b0; sig_f = 24'd0; e_res = 12'sd0;
        msb = 0; sh = 0; shifted = 32'd0; lost = 32'd0;
        if (mag == 32'd0) begin
            cvt_s_res = 32'd0;
        end else begin
            msb = 0;
            for (int i = 0; i < 32; i++) if (mag[i]) msb = i;
            if (msb >= 23) begin
                sh      = msb - 23;
                shifted = mag >> sh;
                g       = (sh >= 1) ? mag[sh-1] : 1'b0;
                lost    = (sh >= 1) ? (mag & ((32'd1 << (sh-1)) - 32'd1)) : 32'd0;
                s       = |lost;
            end else begin
                shifted = mag << (23 - msb);
            end
            sig_f = shifted[23:0];
            e_res = $signed({6'd0, msb[5:0]}) + 12'sd127;
            cvt_s_res = pack_round(sign, e_res, sig_f, g, r, s);
        end
    end

    // fclass.s -> 10-bit one-hot mask (FTZ: the subnormal bits never set).
    logic [31:0] class_res;
    always_comb begin
        logic [9:0] c;
        c = 10'd0;
        if      (a_inf && sa)                                  c[0] = 1'b1;  // -inf
        else if (sa && !a_zero && !a_nan && !a_inf)            c[1] = 1'b1;  // -normal
        else if (a_zero && sa)                                 c[3] = 1'b1;  // -0
        else if (a_zero && !sa)                                c[4] = 1'b1;  // +0
        else if (!sa && !a_zero && !a_nan && !a_inf)           c[6] = 1'b1;  // +normal
        else if (a_inf && !sa)                                 c[7] = 1'b1;  // +inf
        if (a_snan)            c[8] = 1'b1;                                   // sNaN
        if (a_nan && !a_snan)  c[9] = 1'b1;                                   // qNaN
        class_res = {22'd0, c};
    end

    // ════════════════════════════ Final result mux ═════════════════════════════
    always_comb begin
        int_dest = 1'b0;
        res      = 32'd0;
        if (fmt != FMT_S) begin
            res      = 32'd0;                  // M14.1: only single precision
            int_dest = (funct5 == FP_CMP) || (funct5 == FP_CVT_W) ||
                       (funct5 == FP_FMVXW);
        end else begin
            unique case (funct5)
                FP_ADD, FP_SUB: res = add_res;
                FP_MUL:         res = mul_res;
                FP_SGNJ:        res = sgnj_res;
                FP_MINMAX:      res = minmax_res;
                FP_CMP:    begin res = cmp_res;   int_dest = 1'b1; end
                FP_CVT_W:  begin res = cvt_w_res; int_dest = 1'b1; end
                FP_CVT_S:       res = cvt_s_res;
                FP_FMVXW:  begin res = (rm == 3'b000) ? a : class_res; int_dest = 1'b1; end
                FP_FMVWX:       res = xa;
                default:        res = 32'd0;
            endcase
        end
    end

endmodule : simt_fpu
