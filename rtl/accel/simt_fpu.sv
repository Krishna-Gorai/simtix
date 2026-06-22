// =============================================================================
// simt_fpu.sv  -  per-lane floating-point execute unit (FP32 + FP16)
//
// A purely combinational RV32F + Zfh execute datapath for the COMMON floating-
// point ops, instantiated once per SIMT lane. Single (S, FP32) and half (H,
// FP16) precision share ONE datapath:
//     fadd  fsub  fmul                          (arithmetic)
//     fsgnj  fsgnjn  fsgnjx                      (sign inject)
//     fmin  fmax                                 (IEEE minNum/maxNum)
//     feq  flt  fle                              (compares  -> integer reg)
//     fcvt.w / fcvt.wu  (float -> int, RTZ),  fcvt.w/wu -> float (RNE)
//     fcvt.s.h / fcvt.h.s                        (format convert, S<->H)
//     fmv.x  fclass  (-> int),  fmv.*.x          (bit move int -> float)
//     fmadd  fmsub  fnmsub  fnmadd               (fused multiply-add, 1 rounding)
//
// HALF PRECISION via WIDEN-COMPUTE-NARROW: FP16 operands are NaN-box-checked,
// widened to FP32 (exact), run through the FP32 datapath, then the FP-result is
// rounded back to FP16 (RNE) and NaN-boxed. This is bit-exact single-rounding for
// add/sub/mul/int<->float: the FP32 intermediate carries 24 significand bits and
// 24 >= 2*11+2, so by Figueroa's double-rounding theorem round-to-24 then
// round-to-11 equals direct round-to-11. Sign-inject / min-max / fmv / fclass are
// done natively at 16-bit (they are bit-select ops, not arithmetic).
//
// Rounding: round-to-nearest-even (RNE) for arithmetic and int->float; float->int
// truncates toward zero (RTZ, matching a C cast). Subnormals are FLUSHED TO ZERO
// (FTZ) on both inputs and results, for BOTH formats — a deliberate GPU-style
// throughput choice that keeps the per-lane datapath small. NaN/inf/signed-zero
// per IEEE-754; a mis-NaN-boxed FP16 operand reads as the canonical FP16 NaN.
//
// NOT here (by design): div/sqrt (shared multi-cycle SFU, M14.3). No FCSR yet, so
// exception flags are not produced.
//
// Verified standalone (tests/tb_fpu.sv) bit-exact against a DPI-C IEEE reference
// over tens of thousands of random vectors plus directed inf/NaN/zero/FTZ corners,
// for both FP32 and FP16.
// =============================================================================
`timescale 1ns/1ps

module simt_fpu
  import simtix_pkg::*;
(
    input  logic [4:0]  funct5,       // OP-FP operation select (instr[31:27])
    input  logic        cvt_unsigned, // instr[20] — unsigned variant of fcvt int
    input  logic        cvt_src_h,    // fcvt.f.f: source operand is half (rs2==H)
    input  logic [2:0]  rm,           // funct3 — rounding mode / group sub-select
    input  logic [1:0]  fmt,          // format of the op: FMT_S (FP32) / FMT_H (FP16)
    input  logic        is_fma,       // M14.1b: this is a fused multiply-add op
    input  logic        fma_np,       // FMA: negate the product (fnmsub/fnmadd)
    input  logic        fma_nc,       // FMA: negate the addend  (fmsub/fnmadd)
    input  logic [31:0] a,        // f[rs1] (NaN-boxed if half)
    input  logic [31:0] b,        // f[rs2] (NaN-boxed if half)
    input  logic [31:0] c,        // f[rs3] (NaN-boxed if half) — FMA addend
    input  logic [31:0] xa,       // x[rs1]  (int->float, fmv.*.x)
    output logic [31:0] res,      // result bits (FP or int per int_dest)
    output logic        int_dest  // 1: result goes to the integer register file
);
    localparam logic [31:0] CANON_QNAN   = 32'h7fc0_0000;  // canonical quiet NaN (FP32)
    localparam logic [15:0] CANON_QNAN_H = 16'h7e00;        // canonical quiet NaN (FP16)

    // ── Format selection ─────────────────────────────────────────────────────────
    // op_is_h : operands are interpreted as FP16 (and widened). For ordinary ops
    //   this is fmt==H; for the format-convert op it follows the SOURCE format.
    // dst_is_h: the FP result is FP16 (and narrowed + NaN-boxed) — always fmt==H.
    logic op_is_h, dst_is_h;
    // For FMA the funct5 field is actually rs3, so the FP_CVT_FF test must be gated
    // off; an FMA's format is simply fmt (and dst follows it).
    assign op_is_h  = (!is_fma && funct5 == FP_CVT_FF) ? cvt_src_h : (fmt == FMT_H);
    assign dst_is_h = (fmt == FMT_H);

    // ── FP16 operand bits, NaN-box checked (upper half must be all ones) ──────────
    logic        a_box_ok, b_box_ok, c_box_ok;
    assign a_box_ok = (a[31:16] == 16'hffff);
    assign b_box_ok = (b[31:16] == 16'hffff);
    assign c_box_ok = (c[31:16] == 16'hffff);
    logic [15:0] a16, b16, c16;
    assign a16 = a_box_ok ? a[15:0] : CANON_QNAN_H;
    assign b16 = b_box_ok ? b[15:0] : CANON_QNAN_H;
    assign c16 = c_box_ok ? c[15:0] : CANON_QNAN_H;

    // FP16 unpack + classify (FTZ: subnormal exponent reads as zero).
    logic        hsa, hsb;
    logic [4:0]  hea, heb;
    logic [9:0]  hma;
    assign hsa = a16[15]; assign hea = a16[14:10]; assign hma = a16[9:0];
    assign hsb = b16[15]; assign heb = b16[14:10];   // b's mantissa: only zero-flag needed
    logic ha_zero, ha_inf, ha_nan, ha_snan, hb_zero;
    assign ha_zero = (hea == 5'd0);
    assign ha_inf  = (hea == 5'h1f) && (hma == 10'd0);
    assign ha_nan  = (hea == 5'h1f) && (hma != 10'd0);
    assign ha_snan = ha_nan && !hma[9];
    assign hb_zero = (heb == 5'd0);
    // FTZ-canonicalised FP16 operands (for min/max signed-zero selection)
    logic [15:0] a16can, b16can;
    assign a16can = ha_zero ? {hsa, 15'd0} : a16;
    assign b16can = hb_zero ? {hsb, 15'd0} : b16;

    // ── FP16 -> FP32 widening (exact; FTZ subnormal input -> zero) ────────────────
    function automatic logic [31:0] widen_h(input logic [15:0] h);
        logic        s;
        logic [4:0]  e;
        logic [9:0]  m;
        s = h[15]; e = h[14:10]; m = h[9:0];
        if (e == 5'h1f)        widen_h = (m == 10'd0) ? {s, 8'hff, 23'd0} : CANON_QNAN;
        else if (e == 5'd0)    widen_h = {s, 31'd0};                  // zero / subnormal (FTZ)
        else                   widen_h = {s, 8'(8'(e) + 8'd112), m, 13'd0}; // exp += (127-15)
    endfunction

    // ── FP32 -> FP16 narrowing (RNE; FTZ subnormal result -> zero; over -> inf) ───
    function automatic logic [15:0] narrow_h(input logic [31:0] x);
        logic               s;
        logic [7:0]         e32;
        logic [22:0]        m32;
        logic signed [9:0]  e_unb, e16;
        logic [10:0]        sig;      // {hidden, top-10 of mantissa}
        logic               g, r, st;
        /* verilator lint_off UNUSEDSIGNAL */  // rounded[10] is the hidden bit, not stored
        logic [11:0]        rounded;
        /* verilator lint_on UNUSEDSIGNAL */
        s = x[31]; e32 = x[30:23]; m32 = x[22:0];
        if (e32 == 8'hff)      narrow_h = (m32 == 23'd0) ? {s, 5'h1f, 10'd0} : CANON_QNAN_H;
        else if (e32 == 8'd0)  narrow_h = {s, 15'd0};               // zero / subnormal (FTZ)
        else begin
            e_unb = $signed({2'b0, e32}) - 10'sd127;
            if (e_unb > 10'sd15)        narrow_h = {s, 5'h1f, 10'd0};  // overflow -> inf
            else if (e_unb < -10'sd14)  narrow_h = {s, 15'd0};         // FP16-subnormal (FTZ)
            else begin
                sig     = {1'b1, m32[22:13]};
                g       = m32[12];
                r       = m32[11];
                st      = |m32[10:0];
                rounded = {1'b0, sig} + ((g && (r || st || sig[0])) ? 12'd1 : 12'd0);
                e16     = e_unb + 10'sd15;
                if (rounded[11]) begin                 // significand carried out -> exp++
                    e16 = e16 + 10'sd1;
                    narrow_h = (e16 > 10'sd30) ? {s, 5'h1f, 10'd0}     // rounded up to inf
                                               : {s, e16[4:0], 10'd0};
                end else begin
                    narrow_h = {s, e16[4:0], rounded[9:0]};
                end
            end
        end
    endfunction
    // NaN-box an FP16 result into a 32-bit f-register value.
    function automatic logic [31:0] boxH(input logic [15:0] h);
        boxH = {16'hffff, h};
    endfunction

    // ── Effective FP32 operands feeding the shared datapath ──────────────────────
    // For FP32 ops these are a/b unchanged, so all FP32 behaviour is preserved
    // bit-for-bit; for FP16 ops they are the widened operands.
    logic [31:0] opa, opb, opc;
    assign opa = op_is_h ? widen_h(a16) : a;
    assign opb = op_is_h ? widen_h(b16) : b;
    assign opc = op_is_h ? widen_h(c16) : c;   // FMA addend (FP32 domain)

    // ── Unpack + classify the FP32-domain operands (FTZ) ─────────────────────────
    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    assign sa = opa[31]; assign ea = opa[30:23]; assign ma = opa[22:0];
    assign sb = opb[31]; assign eb = opb[30:23]; assign mb = opb[22:0];

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

    // ═══════════════════════════ FUSED MULTIPLY-ADD ═════════════════════════════
    // Computes ±(a*b) ± c with a SINGLE rounding (M14.1b). The product significand
    // P = siga*sigb is EXACT (48 bits); P is anchored in a 128-bit accumulator at
    // bits [75:28], and the addend is shifted to its true relative position d (with
    // a sticky bit capturing any addend bits driven below bit 0). One normalize +
    // pack_round gives the single rounding. When the addend out-ranges the product
    // by the full rounding window (d>=50, i.e. addend MSB >= product MSB + ~26) the
    // product is provably below half a ULP of the addend, so the result is the
    // sign-adjusted addend exactly — which also bounds the accumulator shift.
    // Effective subtraction with a non-zero addend sticky borrows one LSB and forces
    // the result sticky (true = (big-small) - frac, frac in (0,1)).
    // FP16 FMA reuses this via widen->FP32-fused->narrow: 24 >= 2*11+2, so the FP16
    // result is single-rounded (Figueroa), matching a half-precision fused FMA.
    logic [31:0] fma_res;
    always_comb begin
        logic               sc;
        logic [7:0]         ec;
        logic [22:0]        mc;
        logic               c_zero, c_inf, c_nan;
        logic [23:0]        sigc;
        logic [47:0]        P;
        logic               prod_zero, prod_inf, prod_nan;
        logic               psign, csign, samesign, addend_bigger, force_s;
        logic signed [11:0] d, pos0;
        logic [127:0]       prod_acc, add_acc, mag, acc_norm;
        logic [127:0]       cfull;
        logic               sticky_c;
        logic [7:0]         rsh;
        logic [7:0]         m;             // index of the result MSB (<= ~101)
        logic signed [11:0] biased;
        logic [23:0]        sigr;
        logic               g, r, s, rsign;

        sc = opc[31]; ec = opc[30:23]; mc = opc[22:0];
        c_zero = (ec == 8'd0);                       // FTZ subnormal -> zero
        c_inf  = (ec == 8'hff) && (mc == 23'd0);
        c_nan  = (ec == 8'hff) && (mc != 23'd0);
        sigc   = c_zero ? 24'd0 : {1'b1, mc};

        P = siga * sigb;                             // exact 48-bit product
        prod_zero = a_zero || b_zero;
        prod_inf  = a_inf  || b_inf;
        prod_nan  = a_nan  || b_nan;

        psign = (sa ^ sb) ^ fma_np;                  // effective product sign
        csign = sc ^ fma_nc;                         // effective addend  sign

        // defaults (avoid latch)
        d = 12'sd0; pos0 = 12'sd0; prod_acc = '0; add_acc = '0; cfull = '0;
        mag = '0; acc_norm = '0; sticky_c = 1'b0; rsh = 8'd0; m = 8'd0;
        biased = 12'sd0; sigr = 24'd0; g = 1'b0; r = 1'b0; s = 1'b0;
        samesign = 1'b0; addend_bigger = 1'b0; force_s = 1'b0; rsign = 1'b0;

        if (prod_nan || c_nan)                            fma_res = CANON_QNAN;
        else if ((a_inf && b_zero) || (b_inf && a_zero))  fma_res = CANON_QNAN; // 0*inf
        else if (prod_inf && c_inf && (psign != csign))   fma_res = CANON_QNAN; // inf-inf
        else if (prod_inf)                                fma_res = {psign, 8'hff, 23'd0};
        else if (c_inf)                                   fma_res = {csign, 8'hff, 23'd0};
        else if (prod_zero) begin
            // product == 0 -> result is the sign-adjusted addend (exact); signed-zero
            // rule when the addend is zero too.
            if (c_zero) fma_res = (psign == csign) ? {psign, 31'd0} : 32'd0;
            else        fma_res = {csign, opc[30:0]};
        end else begin
            // finite non-zero product. d = (addend LSB exp) - (product LSB exp).
            d    = $signed({4'd0, ec}) - $signed({4'd0, ea}) - $signed({4'd0, eb}) + 12'sd150;
            pos0 = 12'sd28 + d;                       // addend LSB index in accumulator
            prod_acc = {80'd0, P} << 28;              // P[47:0] -> bits [75:28]
            cfull    = {104'd0, sigc};                // addend at bits [23:0]

            // Addend-dominant: its LSB index pos0 is high enough that the whole
            // product (MSB at accumulator bit <=75) sits below half a ULP of the
            // addend (ULP at bit pos0, half-ULP at pos0-1): product < 2^76 <=
            // 2^(pos0-1) iff pos0 >= 77. Then the result is the addend exactly, and
            // the accumulator never has to hold an addend above bit ~99.
            if (pos0 >= 12'sd77 && !c_zero) begin
                fma_res = {csign, opc[30:0]};
            end else begin
                if (c_zero) begin
                    add_acc = 128'd0; sticky_c = 1'b0;
                end else if (pos0 >= 0) begin
                    add_acc = cfull << pos0[6:0];     // pos0 in [0,49] -> top bit <= 72
                    sticky_c = 1'b0;
                end else begin
                    rsh      = (-pos0 >= 12'sd128) ? 8'd127 : 8'((-pos0));
                    add_acc  = cfull >> rsh;
                    sticky_c = |(cfull & ((128'd1 << rsh) - 128'd1));
                end

                samesign      = (psign == csign);
                addend_bigger = (add_acc > prod_acc);
                if (samesign) begin
                    mag     = prod_acc + add_acc;     // magnitudes add
                    force_s = sticky_c;
                end else if (addend_bigger) begin
                    mag     = add_acc - prod_acc;     // (sticky_c==0 in this regime)
                    force_s = 1'b0;
                end else begin
                    // product >= truncated addend; the lost addend frac borrows 1 LSB
                    // and leaves a positive sub-LSB remainder -> force result sticky.
                    mag     = prod_acc - add_acc - {127'd0, sticky_c};
                    force_s = sticky_c;
                end
                rsign = samesign ? psign : (addend_bigger ? csign : psign);

                if (mag == 128'd0) fma_res = 32'd0;   // exact cancellation -> +0
                else begin
                    m = 8'd0;
                    for (int i = 0; i < 128; i++) if (mag[i]) m = i[7:0];
                    acc_norm = mag << (8'd127 - m);
                    sigr = acc_norm[127:104];
                    g    = acc_norm[103];
                    r    = acc_norm[102];
                    s    = (|acc_norm[101:0]) | force_s;
                    // value MSB unbiased exponent E = (ea+eb-300) - 28 + m;
                    // biased = E + 127 = ea + eb + m - 201.
                    biased = $signed({4'd0, ea}) + $signed({4'd0, eb})
                             + $signed({4'd0, m}) - 12'sd201;
                    fma_res = pack_round(rsign, biased, sigr, g, r, s);
                end
            end
        end
    end

    // ═══════════════════════════ SGNJ / MINMAX / CMP ════════════════════════════
    // Sign-inject is a bit op, done natively per format (FP32 on a/b, FP16 on a16/
    // b16) so it never canonicalises a NaN operand's payload.
    function automatic logic sgn_sel(input logic [2:0] mode,
                                     input logic sgn_a, input logic sgn_b);
        unique case (mode)
            3'b000:  sgn_sel = sgn_b;          // fsgnj
            3'b001:  sgn_sel = ~sgn_b;         // fsgnjn
            default: sgn_sel = sgn_a ^ sgn_b;  // fsgnjx
        endcase
    endfunction
    logic [31:0] sgnj_res;
    logic [15:0] sgnj_res_h;
    assign sgnj_res   = {sgn_sel(rm, a[31],   b[31]),   a[30:0]};
    assign sgnj_res_h = {sgn_sel(rm, a16[15], b16[15]), a16[14:0]};

    // canonicalised (FTZ) FP32-domain operands for ordered comparisons / min-max
    logic [31:0] acan, bcan;
    assign acan = a_zero ? {sa, 31'd0} : opa;
    assign bcan = b_zero ? {sb, 31'd0} : opb;

    // less-than on the (widened) operands — monotonic, so it gives the correct FP16
    // ordering too; min/max then SELECT the original operand of the right format.
    logic mm_less;
    assign mm_less = fp_lt(acan, bcan, a_zero, b_zero);

    logic [31:0] minmax_res;
    always_comb begin
        if      (a_nan && b_nan) minmax_res = CANON_QNAN;
        else if (a_nan)          minmax_res = bcan;
        else if (b_nan)          minmax_res = acan;
        else if (rm == 3'b000)   minmax_res = mm_less ? acan : bcan;   // fmin
        else                     minmax_res = mm_less ? bcan : acan;   // fmax
    end
    logic [15:0] minmax_res_h;
    always_comb begin
        if      (a_nan && b_nan) minmax_res_h = CANON_QNAN_H;
        else if (a_nan)          minmax_res_h = b16can;
        else if (b_nan)          minmax_res_h = a16can;
        else if (rm == 3'b000)   minmax_res_h = mm_less ? a16can : b16can;
        else                     minmax_res_h = mm_less ? b16can : a16can;
    end

    logic [31:0] cmp_res;
    always_comb begin
        logic eq, lt, le, unordered;
        unordered = a_nan || b_nan;
        eq = !unordered && ( (a_zero && b_zero) ? 1'b1 :
                             (!a_zero && !b_zero) ? (opa == opb) : 1'b0 );
        lt = !unordered && fp_lt(acan, bcan, a_zero, b_zero);
        le = lt || eq;
        unique case (rm)
            3'b010:  cmp_res = {31'd0, eq};   // feq
            3'b001:  cmp_res = {31'd0, lt};   // flt
            default: cmp_res = {31'd0, le};   // fle
        endcase
    end

    // ═══════════════════════ CONVERSIONS  +  MOVES ══════════════════════════════
    // float -> int (truncate toward zero, RISC-V saturation; NaN -> max). Operates
    // on the widened operand, so fcvt.w.h is the same path (FP16 magnitudes are well
    // within int32 range, no extra saturation needed).
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

    // int -> float (RNE). Produces FP32; narrowed to FP16 in the final mux for
    // fcvt.h.w / fcvt.h.wu (single-rounded by Figueroa: 24 >= 2*11+2).
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

    // fclass -> 10-bit one-hot mask (FTZ: the subnormal bits never set). FP32 reads
    // the widened-domain flags; FP16 classifies the native 16-bit operand so the
    // sNaN/qNaN split survives (widening canonicalises NaNs to quiet).
    logic [31:0] class_res;
    always_comb begin
        logic [9:0] cl;
        cl = 10'd0;
        if      (a_inf && sa)                                  cl[0] = 1'b1;  // -inf
        else if (sa && !a_zero && !a_nan && !a_inf)            cl[1] = 1'b1;  // -normal
        else if (a_zero && sa)                                 cl[3] = 1'b1;  // -0
        else if (a_zero && !sa)                                cl[4] = 1'b1;  // +0
        else if (!sa && !a_zero && !a_nan && !a_inf)           cl[6] = 1'b1;  // +normal
        else if (a_inf && !sa)                                 cl[7] = 1'b1;  // +inf
        if (a_snan)            cl[8] = 1'b1;                                   // sNaN
        if (a_nan && !a_snan)  cl[9] = 1'b1;                                   // qNaN
        class_res = {22'd0, cl};
    end
    logic [9:0] class16;
    always_comb begin
        logic [9:0] cl;
        cl = 10'd0;
        if      (ha_inf && hsa)                                   cl[0] = 1'b1;  // -inf
        else if (hsa && !ha_zero && !ha_nan && !ha_inf)           cl[1] = 1'b1;  // -normal
        else if (ha_zero && hsa)                                  cl[3] = 1'b1;  // -0
        else if (ha_zero && !hsa)                                 cl[4] = 1'b1;  // +0
        else if (!hsa && !ha_zero && !ha_nan && !ha_inf)          cl[6] = 1'b1;  // +normal
        else if (ha_inf && !hsa)                                  cl[7] = 1'b1;  // +inf
        if (ha_snan)            cl[8] = 1'b1;                                    // sNaN
        if (ha_nan && !ha_snan) cl[9] = 1'b1;                                    // qNaN
        class16 = cl;
    end

    // ════════════════════════════ Final result mux ═════════════════════════════
    // FP-result ops narrow + NaN-box when dst_is_h; int-result ops (cmp/cvt.w/
    // fmv.x/fclass) never narrow.
    always_comb begin
        int_dest = 1'b0;
        res      = 32'd0;
        if (is_fma) begin
            // Fused multiply-add (writes the f-file; funct5 here is actually rs3).
            res = dst_is_h ? boxH(narrow_h(fma_res)) : fma_res;
        end else
        unique case (funct5)
            FP_ADD, FP_SUB: res = dst_is_h ? boxH(narrow_h(add_res))   : add_res;
            FP_MUL:         res = dst_is_h ? boxH(narrow_h(mul_res))   : mul_res;
            FP_SGNJ:        res = dst_is_h ? boxH(sgnj_res_h)          : sgnj_res;
            FP_MINMAX:      res = dst_is_h ? boxH(minmax_res_h)        : minmax_res;
            FP_CVT_S:       res = dst_is_h ? boxH(narrow_h(cvt_s_res)) : cvt_s_res;
            FP_CVT_FF:      res = dst_is_h ? boxH(narrow_h(opa))       : opa; // S<->H convert
            FP_FMVWX:       res = dst_is_h ? boxH(xa[15:0])            : xa;
            FP_CMP:    begin res = cmp_res;   int_dest = 1'b1; end
            FP_CVT_W:  begin res = cvt_w_res; int_dest = 1'b1; end
            FP_FMVXW:  begin
                // rm==000: fmv.x.* (move bits, sign-extend the half); else fclass.
                if (rm == 3'b000) res = op_is_h ? {{16{a[15]}}, a[15:0]} : a;
                else              res = op_is_h ? {22'd0, class16}       : class_res;
                int_dest = 1'b1;
            end
            default:        res = 32'd0;
        endcase
    end

endmodule : simt_fpu
