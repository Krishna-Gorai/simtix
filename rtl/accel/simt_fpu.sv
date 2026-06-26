// =============================================================================
// simt_fpu.sv  -  per-lane floating-point execute unit (FP32 + FP16), 3-stage
//
// A pipelined RV32F + Zfh execute datapath for the COMMON floating-point ops,
// instantiated once per SIMT lane. Single (S, FP32) and half (H, FP16) precision
// share ONE datapath:
//     fadd  fsub  fmul                          (arithmetic)
//     fsgnj  fsgnjn  fsgnjx                      (sign inject)
//     fmin  fmax                                 (IEEE minNum/maxNum)
//     feq  flt  fle                              (compares  -> integer reg)
//     fcvt.w / fcvt.wu  (float -> int, RTZ),  fcvt.w/wu -> float (RNE)
//     fcvt.s.h / fcvt.h.s                        (format convert, S<->H)
//     fmv.x  fclass  (-> int),  fmv.*.x          (bit move int -> float)
//     fmadd  fmsub  fnmsub  fnmadd               (fused multiply-add, 1 rounding)
//
// PIPELINING (M15 -> M17): the fused-multiply-add cone is the design's critical
// path (an FPGA DSE showed it is intra-lane, independent of lane count), so the
// unit is split into THREE cycles. For the FMA: stage 1 forms the 48-bit product,
// the alignment amount, and the special cases; stage 2 does the 128-bit align +
// add; stage 3 does the leading-zero normalize + round. ADD/SUB and the shallow
// ops compute fully in stage 1 and ride two registers to the stage-3 format mux,
// so every op has uniform 3-cycle latency. Operands sampled in cycle T produce
// `res` in cycle T+2. The arithmetic is IDENTICAL to the single-cycle unit (same
// bit-exact results); only the register boundaries are new.
//
// HALF PRECISION via WIDEN-COMPUTE-NARROW: FP16 operands are NaN-box-checked,
// widened to FP32 (exact), run through the FP32 datapath, then the FP-result is
// rounded back to FP16 (RNE) and NaN-boxed. Bit-exact single-rounding because the
// FP32 intermediate carries 24 significand bits and 24 >= 2*11+2 (Figueroa). Sign-
// inject / min-max / fmv / fclass are done natively at 16-bit.
//
// Rounding RNE for arithmetic and int->float; float->int truncates (RTZ).
// Subnormals are FLUSHED TO ZERO (FTZ), both formats. NaN/inf/signed-zero per
// IEEE-754; a mis-NaN-boxed FP16 operand reads as the canonical FP16 NaN.
//
// NOT here (by design): div/sqrt (shared multi-cycle SFU, M14.3). No FCSR yet.
//
// Verified (tests/tb_fpu.sv) bit-exact against a DPI-C IEEE reference over tens of
// thousands of random vectors plus directed corners, for both FP32 and FP16.
// =============================================================================
`timescale 1ns/1ps

module simt_fpu
  import simtix_pkg::*;
(
    input  logic        clk,
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
    output logic [31:0] res,      // result bits (FP or int per int_dest) — 2 cycles late
    output logic        int_dest  // 1: result goes to the integer register file
);
    localparam logic [31:0] CANON_QNAN   = 32'h7fc0_0000;  // canonical quiet NaN (FP32)
    localparam logic [15:0] CANON_QNAN_H = 16'h7e00;        // canonical quiet NaN (FP16)

    // ════════════════════════════ Helper functions ═════════════════════════════
    function automatic logic [31:0] widen_h(input logic [15:0] h);
        logic s; logic [4:0] e; logic [9:0] m;
        s = h[15]; e = h[14:10]; m = h[9:0];
        if (e == 5'h1f)     widen_h = (m == 10'd0) ? {s, 8'hff, 23'd0} : CANON_QNAN;
        else if (e == 5'd0) widen_h = {s, 31'd0};                  // zero / subnormal (FTZ)
        else                widen_h = {s, 8'(8'(e) + 8'd112), m, 13'd0}; // exp += (127-15)
    endfunction
    function automatic logic [15:0] narrow_h(input logic [31:0] x);
        logic s; logic [7:0] e32; logic [22:0] m32;
        logic signed [9:0] e_unb, e16; logic [10:0] sig; logic g, r, st;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [11:0] rounded;
        /* verilator lint_on UNUSEDSIGNAL */
        s = x[31]; e32 = x[30:23]; m32 = x[22:0];
        if (e32 == 8'hff)      narrow_h = (m32 == 23'd0) ? {s, 5'h1f, 10'd0} : CANON_QNAN_H;
        else if (e32 == 8'd0)  narrow_h = {s, 15'd0};
        else begin
            e_unb = $signed({2'b0, e32}) - 10'sd127;
            if (e_unb > 10'sd15)       narrow_h = {s, 5'h1f, 10'd0};
            else if (e_unb < -10'sd14) narrow_h = {s, 15'd0};
            else begin
                sig = {1'b1, m32[22:13]}; g = m32[12]; r = m32[11]; st = |m32[10:0];
                rounded = {1'b0, sig} + ((g && (r || st || sig[0])) ? 12'd1 : 12'd0);
                e16 = e_unb + 10'sd15;
                if (rounded[11]) begin
                    e16 = e16 + 10'sd1;
                    narrow_h = (e16 > 10'sd30) ? {s, 5'h1f, 10'd0} : {s, e16[4:0], 10'd0};
                end else narrow_h = {s, e16[4:0], rounded[9:0]};
            end
        end
    endfunction
    function automatic logic [31:0] boxH(input logic [15:0] h);
        boxH = {16'hffff, h};
    endfunction
    // RNE pack of a finite FP32 from sign / biased exp / 24-bit sig / g,r,s.
    function automatic logic [31:0] pack_round(input logic sign, input logic signed [11:0] exp,
                                               input logic [23:0] sig,
                                               input logic g, input logic r, input logic s);
        logic [24:0] m; logic signed [11:0] e; logic round_up;
        m = {1'b0, sig}; e = exp;
        round_up = g && (r || s || sig[0]);
        if (round_up) begin
            m = m + 25'd1;
            if (m[24]) begin m = 25'h0800000; e = e + 12'sd1; end
        end
        if (e >= 12'sd255)    pack_round = {sign, 8'hff, 23'd0};
        else if (e <= 12'sd0) pack_round = {sign, 31'd0};
        else                  pack_round = {sign, e[7:0], m[22:0]};
    endfunction
    function automatic logic fp_lt(input logic [31:0] x, input logic [31:0] y,
                                   input logic xz, input logic yz);
        logic xs, ys;
        xs = x[31]; ys = y[31];
        if (xz && yz)      fp_lt = xs && !ys;
        else if (xs != ys) fp_lt = xs;
        else if (!xs)      fp_lt = (x[30:0] < y[30:0]);
        else               fp_lt = (x[30:0] > y[30:0]);
    endfunction
    function automatic logic sgn_sel(input logic [2:0] mode,
                                     input logic sgn_a, input logic sgn_b);
        unique case (mode)
            3'b000:  sgn_sel = sgn_b;          // fsgnj
            3'b001:  sgn_sel = ~sgn_b;         // fsgnjn
            default: sgn_sel = sgn_a ^ sgn_b;  // fsgnjx
        endcase
    endfunction

    // ════════════════════════════ STAGE 1: unpack ══════════════════════════════
    logic op_is_h, dst_is_h;
    assign op_is_h  = (!is_fma && funct5 == FP_CVT_FF) ? cvt_src_h : (fmt == FMT_H);
    assign dst_is_h = (fmt == FMT_H);

    logic [15:0] a16, b16, c16;
    assign a16 = (a[31:16] == 16'hffff) ? a[15:0] : CANON_QNAN_H;
    assign b16 = (b[31:16] == 16'hffff) ? b[15:0] : CANON_QNAN_H;
    assign c16 = (c[31:16] == 16'hffff) ? c[15:0] : CANON_QNAN_H;

    logic        hsa, hsb;
    logic [4:0]  hea, heb;
    logic [9:0]  hma;
    assign hsa = a16[15]; assign hea = a16[14:10]; assign hma = a16[9:0];
    assign hsb = b16[15]; assign heb = b16[14:10];
    logic ha_zero, ha_inf, ha_nan, ha_snan, hb_zero;
    assign ha_zero = (hea == 5'd0);
    assign ha_inf  = (hea == 5'h1f) && (hma == 10'd0);
    assign ha_nan  = (hea == 5'h1f) && (hma != 10'd0);
    assign ha_snan = ha_nan && !hma[9];
    assign hb_zero = (heb == 5'd0);
    logic [15:0] a16can, b16can;
    assign a16can = ha_zero ? {hsa, 15'd0} : a16;
    assign b16can = hb_zero ? {hsb, 15'd0} : b16;

    logic [31:0] opa, opb, opc;
    assign opa = op_is_h ? widen_h(a16) : a;
    assign opb = op_is_h ? widen_h(b16) : b;
    assign opc = op_is_h ? widen_h(c16) : c;

    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] ma, mb;
    assign sa = opa[31]; assign ea = opa[30:23]; assign ma = opa[22:0];
    assign sb = opb[31]; assign eb = opb[30:23]; assign mb = opb[22:0];
    logic a_zero, a_inf, a_nan, a_snan, b_zero, b_inf, b_nan;
    assign a_zero = (ea == 8'd0);
    assign a_inf  = (ea == 8'hff) && (ma == 23'd0);
    assign a_nan  = (ea == 8'hff) && (ma != 23'd0);
    assign a_snan = a_nan && !ma[22];
    assign b_zero = (eb == 8'd0);
    assign b_inf  = (eb == 8'hff) && (mb == 23'd0);
    assign b_nan  = (eb == 8'hff) && (mb != 23'd0);
    logic [23:0] siga, sigb;
    assign siga = a_zero ? 24'd0 : {1'b1, ma};
    assign sigb = b_zero ? 24'd0 : {1'b1, mb};

    // ── STAGE 1: ADD/SUB front — aligned magnitude (normalize deferred to stage 2) ──
    logic        addsub_is_sub, sb_eff;
    assign addsub_is_sub = (funct5 == FP_SUB);
    assign sb_eff = sb ^ addsub_is_sub;

    logic [63:0] s1_add_mag;
    logic        s1_add_sbig, s1_add_spec;
    logic [7:0]  s1_add_ebig;
    logic [31:0] s1_add_specval;
    always_comb begin
        logic        eff_sub, a_ge_b;
        logic [7:0]  e_big, e_small;
        logic [23:0] sig_big, sig_small;
        logic [8:0]  ediff;
        logic [63:0] big_ext, small_ext, shifted, mag;
        logic        sticky;
        a_ge_b  = (ea > eb) || ((ea == eb) && (siga >= sigb));
        eff_sub = sa ^ sb_eff;
        if (a_ge_b) begin
            s1_add_sbig = sa;     e_big = ea; sig_big = siga; e_small = eb; sig_small = sigb;
        end else begin
            s1_add_sbig = sb_eff; e_big = eb; sig_big = sigb; e_small = ea; sig_small = siga;
        end
        big_ext   = {40'd0, sig_big}   << 26;
        small_ext = {40'd0, sig_small} << 26;
        ediff     = {1'b0, e_big} - {1'b0, e_small};
        if (ediff > 9'd50) begin
            sticky = (small_ext != 64'd0); shifted = {63'd0, sticky};
        end else begin
            shifted    = small_ext >> ediff[5:0];
            sticky     = |(small_ext & ((64'd1 << ediff[5:0]) - 64'd1));
            shifted[0] = shifted[0] | sticky;
        end
        if (!eff_sub) mag = big_ext + shifted;
        else          mag = big_ext - shifted;
        s1_add_mag  = mag;
        s1_add_ebig = e_big;
        // Special cases resolve here (no normalize needed).
        if      (a_nan || b_nan) begin s1_add_spec = 1'b1; s1_add_specval = CANON_QNAN; end
        else if (a_inf && b_inf) begin s1_add_spec = 1'b1;
                 s1_add_specval = (sa == sb_eff) ? {sa, 8'hff, 23'd0} : CANON_QNAN; end
        else if (a_inf)          begin s1_add_spec = 1'b1; s1_add_specval = {sa,     8'hff, 23'd0}; end
        else if (b_inf)          begin s1_add_spec = 1'b1; s1_add_specval = {sb_eff, 8'hff, 23'd0}; end
        else if (mag == 64'd0)   begin s1_add_spec = 1'b1; s1_add_specval = 32'd0; end // cancellation
        else                     begin s1_add_spec = 1'b0; s1_add_specval = 32'd0; end
    end

    // ── STAGE 1: MUL front — exact product + specials (normalize/round deferred to S2) ─
    // A2: the standalone fmul used to do multiply + normalize + round ALL in stage 1 —
    // the one op carrying a full combinational 24x24 multiply AND rounding cone into a
    // single stage (the FMA already spreads its work across S1/S2/S3). We now isolate the
    // significand multiply in stage 1 (so it registers cleanly into a DSP output reg) and
    // defer the prod[47] select + exponent + round to stage 2. Bit-IDENTICAL result; only
    // the register boundary moves, balancing what was the design's critical path.
    logic [47:0] s1_mul_prod;       // exact 48-bit significand product
    logic [8:0]  s1_mul_esum;       // ea + eb (stage-2 applies the -126/-127 bias)
    logic        s1_mul_rsign, s1_mul_spec;
    logic [31:0] s1_mul_specval;
    always_comb begin
        s1_mul_rsign = sa ^ sb;
        s1_mul_prod  = siga * sigb;
        s1_mul_esum  = {1'b0, ea} + {1'b0, eb};
        if      (a_nan || b_nan)                          begin s1_mul_spec = 1'b1; s1_mul_specval = CANON_QNAN; end
        else if ((a_inf && b_zero) || (b_inf && a_zero))  begin s1_mul_spec = 1'b1; s1_mul_specval = CANON_QNAN; end
        else if (a_inf || b_inf)                          begin s1_mul_spec = 1'b1; s1_mul_specval = {s1_mul_rsign, 8'hff, 23'd0}; end
        else if (a_zero || b_zero)                        begin s1_mul_spec = 1'b1; s1_mul_specval = {s1_mul_rsign, 31'd0}; end
        else                                              begin s1_mul_spec = 1'b0; s1_mul_specval = 32'd0; end
    end

    // ── STAGE 1: FMA front-A — exact product, alignment amount, and specials ────────
    // M17: the FMA is split across THREE pipeline stages, since the per-lane FMA cone
    // was the design's critical path. Stage-1 forms the 48-bit product and the addend
    // alignment position and resolves the special cases; stage-2 (below) does the
    // 128-bit align + add; stage-3 normalizes + rounds. Each stage is shallow.
    logic [47:0]        s1f_P;          // exact 48-bit significand product
    logic signed [11:0] s1f_pos0;       // addend anchor in the 128-bit accumulator
    logic [23:0]        s1f_sigc;       // addend significand
    logic               s1f_psign, s1f_csign, s1f_c_zero;
    logic [8:0]         s1f_eab;        // ea + eb (for the final exponent)
    logic               s1f_fma_spec;   // 1: an early special is ready (skip align/add)
    logic [31:0]        s1f_fma_specval;
    always_comb begin
        logic               sc;
        logic [7:0]         ec;
        logic [22:0]        mc;
        logic               c_inf, c_nan;
        logic               prod_zero, prod_inf, prod_nan;
        logic signed [11:0] d;
        sc = opc[31]; ec = opc[30:23]; mc = opc[22:0];
        s1f_c_zero = (ec == 8'd0); c_inf = (ec == 8'hff) && (mc == 23'd0);
        c_nan      = (ec == 8'hff) && (mc != 23'd0);
        s1f_sigc   = s1f_c_zero ? 24'd0 : {1'b1, mc};
        s1f_P      = siga * sigb;
        prod_zero  = a_zero || b_zero; prod_inf = a_inf || b_inf; prod_nan = a_nan || b_nan;
        s1f_psign  = (sa ^ sb) ^ fma_np; s1f_csign = sc ^ fma_nc;
        d = 12'sd0; s1f_pos0 = 12'sd0;
        s1f_eab = ea + eb; s1f_fma_spec = 1'b1; s1f_fma_specval = 32'd0;
        if (prod_nan || c_nan)                                  s1f_fma_specval = CANON_QNAN;
        else if ((a_inf && b_zero) || (b_inf && a_zero))        s1f_fma_specval = CANON_QNAN;
        else if (prod_inf && c_inf && (s1f_psign != s1f_csign)) s1f_fma_specval = CANON_QNAN;
        else if (prod_inf)                                      s1f_fma_specval = {s1f_psign, 8'hff, 23'd0};
        else if (c_inf)                                         s1f_fma_specval = {s1f_csign, 8'hff, 23'd0};
        else if (prod_zero)
            s1f_fma_specval = s1f_c_zero ? ((s1f_psign == s1f_csign) ? {s1f_psign, 31'd0} : 32'd0)
                                         : {s1f_csign, opc[30:0]};
        else begin
            d        = $signed({4'd0, ec}) - $signed({4'd0, ea}) - $signed({4'd0, eb}) + 12'sd150;
            s1f_pos0 = 12'sd28 + d;
            if (s1f_pos0 >= 12'sd77 && !s1f_c_zero) begin
                s1f_fma_specval = {s1f_csign, opc[30:0]};   // addend-dominant -> exact addend
            end else begin
                s1f_fma_spec = 1'b0;                        // arithmetic: stage-2 aligns + adds
            end
        end
    end

    // ── STAGE 2: FMA front-B — 128-bit align + add (from the registered stage-1) ────
    logic [127:0] s2_fma_mag;
    logic         s2_fma_rsign, s2_fma_fs, s2_fma_spec;
    logic [8:0]   s2_fma_eab;
    logic [31:0]  s2_fma_specval;
    always_comb begin
        logic [127:0] prod_acc, add_acc, mag, cfull;
        logic         sticky_c, samesign, addend_bigger;
        logic [7:0]   rsh;
        prod_acc = '0; add_acc = '0; mag = '0; cfull = '0;
        sticky_c = 1'b0; samesign = 1'b0; addend_bigger = 1'b0; rsh = 8'd0;
        s2_fma_eab     = r1f_eab;
        s2_fma_rsign   = 1'b0; s2_fma_fs = 1'b0; s2_fma_mag = '0;
        s2_fma_spec    = r1f_fma_spec; s2_fma_specval = r1f_fma_specval;
        if (!r1f_fma_spec) begin
            prod_acc = {80'd0, r1f_P} << 28;
            cfull    = {104'd0, r1f_sigc};
            if (r1f_c_zero) begin
                add_acc = 128'd0; sticky_c = 1'b0;
            end else if (r1f_pos0 >= 0) begin
                add_acc = cfull << r1f_pos0[6:0]; sticky_c = 1'b0;
            end else begin
                rsh = (-r1f_pos0 >= 12'sd128) ? 8'd127 : 8'((-r1f_pos0));
                add_acc = cfull >> rsh;
                sticky_c = |(cfull & ((128'd1 << rsh) - 128'd1));
            end
            samesign = (r1f_psign == r1f_csign); addend_bigger = (add_acc > prod_acc);
            if (samesign)           begin mag = prod_acc + add_acc;                      s2_fma_fs = sticky_c; end
            else if (addend_bigger) begin mag = add_acc - prod_acc;                      s2_fma_fs = 1'b0; end
            else                    begin mag = prod_acc - add_acc - {127'd0, sticky_c}; s2_fma_fs = sticky_c; end
            s2_fma_rsign = samesign ? r1f_psign : (addend_bigger ? r1f_csign : r1f_psign);
            if (mag == 128'd0) begin s2_fma_spec = 1'b1; s2_fma_specval = 32'd0; end  // cancellation -> +0
            else               begin s2_fma_spec = 1'b0; s2_fma_mag = mag;        end
        end
    end

    // ── STAGE 2: MUL back — normalize + round of the registered stage-1 product ─────────
    // A2: consumes the registered raw product (r_mul_prod) + exponent sum + sign + the
    // resolved special, and produces the final fmul result. Identical arithmetic to the
    // old single-stage path; it just runs one cycle later, off a register boundary.
    logic [31:0] s2_mul_res;
    always_comb begin
        logic signed [11:0] e_res;
        logic [23:0]        sig_f;
        logic               g, r, s;
        e_res = 12'sd0; sig_f = 24'd0; g = 1'b0; r = 1'b0; s = 1'b0;
        if (r_mul_prod[47]) begin
            e_res = $signed({3'd0, r_mul_esum}) - 12'sd126;
            sig_f = r_mul_prod[47:24]; g = r_mul_prod[23]; r = r_mul_prod[22]; s = |r_mul_prod[21:0];
        end else begin
            e_res = $signed({3'd0, r_mul_esum}) - 12'sd127;
            sig_f = r_mul_prod[46:23]; g = r_mul_prod[22]; r = r_mul_prod[21]; s = |r_mul_prod[20:0];
        end
        s2_mul_res = r_mul_spec ? r_mul_specval
                                : pack_round(r_mul_rsign, e_res, sig_f, g, r, s);
    end

    // ── STAGE 1: SGNJ / MINMAX / CMP / CVT / FCLASS (shallow — full results) ────────
    logic [31:0] s1_sgnj_res; logic [15:0] s1_sgnj_res_h;
    assign s1_sgnj_res   = {sgn_sel(rm, a[31],   b[31]),   a[30:0]};
    assign s1_sgnj_res_h = {sgn_sel(rm, a16[15], b16[15]), a16[14:0]};

    logic [31:0] acan, bcan;
    assign acan = a_zero ? {sa, 31'd0} : opa;
    assign bcan = b_zero ? {sb, 31'd0} : opb;
    logic mm_less;
    assign mm_less = fp_lt(acan, bcan, a_zero, b_zero);

    logic [31:0] s1_minmax_res; logic [15:0] s1_minmax_res_h;
    always_comb begin
        if      (a_nan && b_nan) s1_minmax_res = CANON_QNAN;
        else if (a_nan)          s1_minmax_res = bcan;
        else if (b_nan)          s1_minmax_res = acan;
        else if (rm == 3'b000)   s1_minmax_res = mm_less ? acan : bcan;
        else                     s1_minmax_res = mm_less ? bcan : acan;
    end
    always_comb begin
        if      (a_nan && b_nan) s1_minmax_res_h = CANON_QNAN_H;
        else if (a_nan)          s1_minmax_res_h = b16can;
        else if (b_nan)          s1_minmax_res_h = a16can;
        else if (rm == 3'b000)   s1_minmax_res_h = mm_less ? a16can : b16can;
        else                     s1_minmax_res_h = mm_less ? b16can : a16can;
    end

    logic [31:0] s1_cmp_res;
    always_comb begin
        logic eq, lt, le, unordered;
        unordered = a_nan || b_nan;
        eq = !unordered && ( (a_zero && b_zero) ? 1'b1 :
                             (!a_zero && !b_zero) ? (opa == opb) : 1'b0 );
        lt = !unordered && fp_lt(acan, bcan, a_zero, b_zero);
        le = lt || eq;
        unique case (rm)
            3'b010:  s1_cmp_res = {31'd0, eq};
            3'b001:  s1_cmp_res = {31'd0, lt};
            default: s1_cmp_res = {31'd0, le};
        endcase
    end

    logic [31:0] s1_cvt_w_res;
    always_comb begin
        logic               is_unsigned;
        logic signed [11:0] uexp;
        logic [31:0]        mag, sig32;
        is_unsigned = cvt_unsigned;
        sig32 = {8'd0, siga};
        uexp = $signed({4'd0, ea}) - 12'sd127;
        if (uexp < 0)        mag = 32'd0;
        else if (uexp >= 31) mag = 32'hffffffff;
        else if (uexp >= 23) mag = sig32 << 5'(uexp - 12'sd23);
        else                 mag = sig32 >> 5'(12'sd23 - uexp);
        if (a_nan)              s1_cvt_w_res = is_unsigned ? 32'hffffffff : 32'h7fffffff;
        else if (is_unsigned) begin
            if (sa && !a_zero)    s1_cvt_w_res = 32'd0;
            else if (a_inf)       s1_cvt_w_res = 32'hffffffff;
            else if (uexp >= 32)  s1_cvt_w_res = 32'hffffffff;
            else                  s1_cvt_w_res = mag;
        end else begin
            if (a_inf)                  s1_cvt_w_res = sa ? 32'h80000000 : 32'h7fffffff;
            else if (!sa && uexp >= 31) s1_cvt_w_res = 32'h7fffffff;
            else if ( sa && uexp >= 31) s1_cvt_w_res = 32'h80000000;
            else                        s1_cvt_w_res = sa ? (~mag + 32'd1) : mag;
        end
    end

    logic [31:0] s1_cvt_s_res;
    always_comb begin
        logic               is_unsigned, sign;
        logic [31:0]        mag, lost;
        int unsigned        msb, sh;
        /* verilator lint_off UNUSEDSIGNAL */
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
        if (mag == 32'd0) s1_cvt_s_res = 32'd0;
        else begin
            msb = 0;
            for (int i = 0; i < 32; i++) if (mag[i]) msb = i;
            if (msb >= 23) begin
                sh = msb - 23; shifted = mag >> sh;
                g = (sh >= 1) ? mag[sh-1] : 1'b0;
                lost = (sh >= 1) ? (mag & ((32'd1 << (sh-1)) - 32'd1)) : 32'd0;
                s = |lost;
            end else shifted = mag << (23 - msb);
            sig_f = shifted[23:0];
            e_res = $signed({6'd0, msb[5:0]}) + 12'sd127;
            s1_cvt_s_res = pack_round(sign, e_res, sig_f, g, r, s);
        end
    end

    logic [31:0] s1_class_res; logic [9:0] s1_class16;
    always_comb begin
        logic [9:0] cl; cl = 10'd0;
        if      (a_inf && sa)                        cl[0] = 1'b1;
        else if (sa && !a_zero && !a_nan && !a_inf)  cl[1] = 1'b1;
        else if (a_zero && sa)                       cl[3] = 1'b1;
        else if (a_zero && !sa)                      cl[4] = 1'b1;
        else if (!sa && !a_zero && !a_nan && !a_inf) cl[6] = 1'b1;
        else if (a_inf && !sa)                       cl[7] = 1'b1;
        if (a_snan)            cl[8] = 1'b1;
        if (a_nan && !a_snan)  cl[9] = 1'b1;
        s1_class_res = {22'd0, cl};
    end
    always_comb begin
        logic [9:0] cl; cl = 10'd0;
        if      (ha_inf && hsa)                          cl[0] = 1'b1;
        else if (hsa && !ha_zero && !ha_nan && !ha_inf)  cl[1] = 1'b1;
        else if (ha_zero && hsa)                         cl[3] = 1'b1;
        else if (ha_zero && !hsa)                        cl[4] = 1'b1;
        else if (!hsa && !ha_zero && !ha_nan && !ha_inf) cl[6] = 1'b1;
        else if (ha_inf && !hsa)                         cl[7] = 1'b1;
        if (ha_snan)            cl[8] = 1'b1;
        if (ha_nan && !ha_snan) cl[9] = 1'b1;
        s1_class16 = cl;
    end

    // ════════════════════ Pipeline register 1 (stage 1 -> stage 2) ═════════════════
    // M17: FMA carries its stage-1 front-A outputs (product, alignment amount, sigc,
    // signs, specials); ADD and the shallow ops carry their full stage-1 result and
    // ride through reg2 to the stage-3 back-end so every op has uniform 3-cycle latency.
    logic [63:0]  r_add_mag;     logic r_add_sbig, r_add_spec; logic [7:0] r_add_ebig;
    logic [31:0]  r_add_specval;
    logic [47:0]  r_mul_prod;    logic [8:0] r_mul_esum; logic r_mul_rsign, r_mul_spec;
    logic [31:0]  r_mul_specval;
    logic [47:0]        r1f_P;
    logic signed [11:0] r1f_pos0;
    logic [23:0]        r1f_sigc;
    logic               r1f_psign, r1f_csign, r1f_c_zero;
    logic [8:0]         r1f_eab;
    logic               r1f_fma_spec; logic [31:0] r1f_fma_specval;
    logic [31:0]  r_sgnj_res, r_minmax_res, r_cmp_res, r_cvt_w_res, r_cvt_s_res, r_class_res;
    logic [15:0]  r_sgnj_res_h, r_minmax_res_h;
    logic [9:0]   r_class16;
    logic [31:0]  r_a, r_xa, r_opa;
    logic [4:0]   r_funct5;
    logic [2:0]   r_rm;
    logic         r_is_fma, r_dst_is_h, r_op_is_h;
    always_ff @(posedge clk) begin
        r_add_mag <= s1_add_mag; r_add_sbig <= s1_add_sbig; r_add_ebig <= s1_add_ebig;
        r_add_spec <= s1_add_spec; r_add_specval <= s1_add_specval;
        r_mul_prod <= s1_mul_prod; r_mul_esum <= s1_mul_esum;
        r_mul_rsign <= s1_mul_rsign; r_mul_spec <= s1_mul_spec; r_mul_specval <= s1_mul_specval;
        r1f_P <= s1f_P; r1f_pos0 <= s1f_pos0; r1f_sigc <= s1f_sigc;
        r1f_psign <= s1f_psign; r1f_csign <= s1f_csign; r1f_c_zero <= s1f_c_zero;
        r1f_eab <= s1f_eab; r1f_fma_spec <= s1f_fma_spec; r1f_fma_specval <= s1f_fma_specval;
        r_sgnj_res <= s1_sgnj_res; r_sgnj_res_h <= s1_sgnj_res_h;
        r_minmax_res <= s1_minmax_res; r_minmax_res_h <= s1_minmax_res_h;
        r_cmp_res <= s1_cmp_res; r_cvt_w_res <= s1_cvt_w_res; r_cvt_s_res <= s1_cvt_s_res;
        r_class_res <= s1_class_res; r_class16 <= s1_class16;
        r_a <= a; r_xa <= xa; r_opa <= opa;
        r_funct5 <= funct5; r_rm <= rm;
        r_is_fma <= is_fma; r_dst_is_h <= dst_is_h; r_op_is_h <= op_is_h;
    end

    // ════════════════════ Pipeline register 2 (stage 2 -> stage 3) ═════════════════
    // FMA now holds its post-align magnitude (s2_*); ADD and the shallow ops are simply
    // forwarded one more cycle so they reach the stage-3 back-end together with the FMA.
    logic [63:0]  r2_add_mag;    logic r2_add_sbig, r2_add_spec; logic [7:0] r2_add_ebig;
    logic [31:0]  r2_add_specval;
    logic [31:0]  r2_mul_res;
    logic [127:0] r2_fma_mag;    logic r2_fma_rsign, r2_fma_fs, r2_fma_spec; logic [8:0] r2_fma_eab;
    logic [31:0]  r2_fma_specval;
    logic [31:0]  r2_sgnj_res, r2_minmax_res, r2_cmp_res, r2_cvt_w_res, r2_cvt_s_res, r2_class_res;
    logic [15:0]  r2_sgnj_res_h, r2_minmax_res_h;
    logic [9:0]   r2_class16;
    logic [31:0]  r2_a, r2_xa, r2_opa;
    logic [4:0]   r2_funct5;
    logic [2:0]   r2_rm;
    logic         r2_is_fma, r2_dst_is_h, r2_op_is_h;
    always_ff @(posedge clk) begin
        r2_add_mag <= r_add_mag; r2_add_sbig <= r_add_sbig; r2_add_ebig <= r_add_ebig;
        r2_add_spec <= r_add_spec; r2_add_specval <= r_add_specval;
        r2_mul_res <= s2_mul_res;
        r2_fma_mag <= s2_fma_mag; r2_fma_rsign <= s2_fma_rsign; r2_fma_fs <= s2_fma_fs;
        r2_fma_eab <= s2_fma_eab; r2_fma_spec <= s2_fma_spec; r2_fma_specval <= s2_fma_specval;
        r2_sgnj_res <= r_sgnj_res; r2_sgnj_res_h <= r_sgnj_res_h;
        r2_minmax_res <= r_minmax_res; r2_minmax_res_h <= r_minmax_res_h;
        r2_cmp_res <= r_cmp_res; r2_cvt_w_res <= r_cvt_w_res; r2_cvt_s_res <= r_cvt_s_res;
        r2_class_res <= r_class_res; r2_class16 <= r_class16;
        r2_a <= r_a; r2_xa <= r_xa; r2_opa <= r_opa;
        r2_funct5 <= r_funct5; r2_rm <= r_rm;
        r2_is_fma <= r_is_fma; r2_dst_is_h <= r_dst_is_h; r2_op_is_h <= r_op_is_h;
    end

    // ════════════════════════════ STAGE 3: normalize ═══════════════════════════════
    // ADD/SUB normalize + round (or the registered special result).
    logic [31:0] add_res;
    always_comb begin
        logic [63:0] mag;
        /* verilator lint_off UNUSEDSIGNAL */  // only norm[49:0] read after normalise
        logic [63:0] norm;
        /* verilator lint_on UNUSEDSIGNAL */
        int unsigned msb;
        logic signed [11:0] e_res;
        logic [23:0] sig_f;
        logic g, r, s;
        mag = r2_add_mag;
        msb = 0;
        for (int i = 0; i < 64; i++) if (mag[i]) msb = i;
        e_res = $signed({4'd0, r2_add_ebig}) + $signed({6'd0, msb[5:0]}) - 12'sd49;
        if (msb >= 49) norm = mag >> (msb - 49);
        else           norm = mag << (49 - msb);
        sig_f = norm[49:26]; g = norm[25]; r = norm[24]; s = |norm[23:0];
        add_res = r2_add_spec ? r2_add_specval : pack_round(r2_add_sbig, e_res, sig_f, g, r, s);
    end

    // FMA normalize + round (or the registered special result).
    logic [31:0] fma_res;
    always_comb begin
        logic [127:0] mag, acc_norm;
        logic [7:0]   m;
        logic signed [11:0] biased;
        logic [23:0]  sigr;
        logic g, r, s;
        mag = r2_fma_mag;
        m = 8'd0;
        for (int i = 0; i < 128; i++) if (mag[i]) m = i[7:0];
        acc_norm = mag << (8'd127 - m);
        sigr = acc_norm[127:104]; g = acc_norm[103]; r = acc_norm[102];
        s = (|acc_norm[101:0]) | r2_fma_fs;
        biased = $signed({3'd0, r2_fma_eab}) + $signed({4'd0, m}) - 12'sd201;
        fma_res = r2_fma_spec ? r2_fma_specval : pack_round(r2_fma_rsign, biased, sigr, g, r, s);
    end

    // ── Final result mux (stage 3) ─────────────────────────────────────────────────
    always_comb begin
        int_dest = 1'b0;
        res      = 32'd0;
        if (r2_is_fma) begin
            res = r2_dst_is_h ? boxH(narrow_h(fma_res)) : fma_res;
        end else
        unique case (r2_funct5)
            FP_ADD, FP_SUB: res = r2_dst_is_h ? boxH(narrow_h(add_res))     : add_res;
            FP_MUL:         res = r2_dst_is_h ? boxH(narrow_h(r2_mul_res))   : r2_mul_res;
            FP_SGNJ:        res = r2_dst_is_h ? boxH(r2_sgnj_res_h)          : r2_sgnj_res;
            FP_MINMAX:      res = r2_dst_is_h ? boxH(r2_minmax_res_h)        : r2_minmax_res;
            FP_CVT_S:       res = r2_dst_is_h ? boxH(narrow_h(r2_cvt_s_res)) : r2_cvt_s_res;
            FP_CVT_FF:      res = r2_dst_is_h ? boxH(narrow_h(r2_opa))       : r2_opa;
            FP_FMVWX:       res = r2_dst_is_h ? boxH(r2_xa[15:0])            : r2_xa;
            FP_CMP:    begin res = r2_cmp_res;   int_dest = 1'b1; end
            FP_CVT_W:  begin res = r2_cvt_w_res; int_dest = 1'b1; end
            FP_FMVXW:  begin
                if (r2_rm == 3'b000) res = r2_op_is_h ? {{16{r2_a[15]}}, r2_a[15:0]} : r2_a;
                else                 res = r2_op_is_h ? {22'd0, r2_class16}          : r2_class_res;
                int_dest = 1'b1;
            end
            default:        res = 32'd0;
        endcase
    end

endmodule : simt_fpu
