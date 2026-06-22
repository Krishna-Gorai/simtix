// =============================================================================
// fp_divsqrt.sv  -  per-lane iterative floating-point divide / square-root (M14.3)
//
// A genuinely MULTI-CYCLE FP32 (+ FP16) divide and square-root unit. Unlike the
// single-cycle add/mul/FMA in simt_fpu, divide and square-root are produced one
// result bit (div) or one root bit (sqrt) per cycle by a digit-recurrence, so the
// unit is iterative: a `start` pulse latches the operands, `busy` is high while it
// iterates, and a one-cycle `done` pulse presents the result. warp_pool runs one
// such unit per lane behind a stall scoreboard (the issuing warp parks while the
// scheduler keeps issuing other warps — exactly like the background memory engine).
//
//   divide : restoring division of the 24-bit significands. One initial compare
//            sets the integer quotient bit (siga/sigb is in [0.5,2)), then 26
//            fractional iterations keep the running remainder < sigb. Quotient is
//            {Qint, 26 frac bits}; the final remainder gives the sticky bit.
//   sqrt   : restoring integer square root of the radicand shifted up by 48, two
//            radicand bits per cycle, 37 root bits + remainder for sticky.
//
// Rounding RNE; float results flush subnormals to zero (FTZ), matching simt_fpu.
// Half precision reuses the FP32 datapath via widen->FP32->narrow: 24 >= 2*11+2,
// so by Figueroa's double-rounding theorem the FP16 quotient / root is correctly
// single-rounded. NaN/inf/zero/divide-by-zero/sqrt-of-negative per IEEE-754.
//
// Verified standalone (tests/tb_divsqrt.sv) bit-exact against a DPI-C reference
// (host float divide and sqrtf) over random vectors plus directed corners.
// =============================================================================
`timescale 1ns/1ps

module fp_divsqrt
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,            // active-high
    input  logic        start,          // 1-cycle: begin a new op (ignored while busy)
    input  logic        is_sqrt,        // 0 = divide (a/b), 1 = square root (sqrt a)
    input  logic [1:0]  fmt,            // FMT_S (FP32) / FMT_H (FP16)
    input  logic [31:0] a,              // dividend / radicand (NaN-boxed if half)
    input  logic [31:0] b,              // divisor (unused for sqrt)
    output logic        busy,
    output logic        done,           // 1-cycle pulse: res valid this cycle
    output logic [31:0] res
);
    localparam logic [31:0] CANON_QNAN   = 32'h7fc0_0000;
    localparam logic [15:0] CANON_QNAN_H = 16'h7e00;
    localparam int DIV_ITERS  = 26;     // fractional quotient bits
    localparam int SQRT_ITERS = 37;     // root bits (2 radicand bits each)

    // ── FP16 <-> FP32 (copied from simt_fpu; FTZ subnormals) ─────────────────────
    function automatic logic [31:0] widen_h(input logic [15:0] h);
        logic s; logic [4:0] e; logic [9:0] m;
        s = h[15]; e = h[14:10]; m = h[9:0];
        if (e == 5'h1f)     widen_h = (m == 10'd0) ? {s, 8'hff, 23'd0} : CANON_QNAN;
        else if (e == 5'd0) widen_h = {s, 31'd0};
        else                widen_h = {s, 8'(8'(e) + 8'd112), m, 13'd0};
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

    // ── RNE pack of an FP32 from sign / biased exp / 24-bit sig / g,r,s ───────────
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

    // ── Operand widening + unpack (FP32 domain) ──────────────────────────────────
    logic        op_is_h;
    assign op_is_h = (fmt == FMT_H);
    logic [15:0] a16, b16;
    assign a16 = (a[31:16] == 16'hffff) ? a[15:0] : CANON_QNAN_H;
    assign b16 = (b[31:16] == 16'hffff) ? b[15:0] : CANON_QNAN_H;
    logic [31:0] opa, opb;
    assign opa = op_is_h ? widen_h(a16) : a;
    assign opb = op_is_h ? widen_h(b16) : b;

    logic       sa, sb;
    logic [7:0] ea, eb;
    logic [22:0] ma, mb;
    assign sa = opa[31]; assign ea = opa[30:23]; assign ma = opa[22:0];
    assign sb = opb[31]; assign eb = opb[30:23]; assign mb = opb[22:0];
    logic a_zero, a_inf, a_nan, b_zero, b_inf, b_nan;
    assign a_zero = (ea == 8'd0);
    assign a_inf  = (ea == 8'hff) && (ma == 23'd0);
    assign a_nan  = (ea == 8'hff) && (ma != 23'd0);
    assign b_zero = (eb == 8'd0);
    assign b_inf  = (eb == 8'hff) && (mb == 23'd0);
    assign b_nan  = (eb == 8'hff) && (mb != 23'd0);
    logic [23:0] siga, sigb;
    assign siga = a_zero ? 24'd0 : {1'b1, ma};
    assign sigb = b_zero ? 24'd0 : {1'b1, mb};

    // ── Latched request + iteration state ────────────────────────────────────────
    logic         r_sqrt, r_is_h, r_special, r_sign, r_qint, r_p;
    logic [31:0]  r_specval;
    logic [7:0]   r_ea, r_eb;
    logic [5:0]   iter;
    typedef enum logic [1:0] { S_IDLE, S_RUN, S_DONE } st_e;
    st_e          state;

    // Divider: 25-bit running remainder P (< sigb), 26 fractional quotient bits Qf.
    logic [24:0]  P;
    logic [25:0]  Qf;
    logic [23:0]  div_d;

    // Sqrt: 74-bit radicand shifter, remainder, 37-bit root.
    logic [73:0]  radsh;
    logic [41:0]  srem;
    logic [36:0]  root;

    assign busy = (state != S_IDLE);

    // ── Combinational step datapath ──────────────────────────────────────────────
    logic [24:0] P_sh, P_next;
    logic        q_bit;
    assign P_sh   = P << 1;
    assign q_bit  = (P_sh >= {1'b0, div_d});
    assign P_next = q_bit ? (P_sh - {1'b0, div_d}) : P_sh;

    logic [1:0]  sq_pair;
    logic [41:0] srem_sh, sq_test, srem_next;
    logic        root_bit;
    assign sq_pair   = radsh[73:72];
    assign srem_sh   = {srem[39:0], sq_pair};
    assign sq_test   = {3'b0, root, 2'b01};           // (root<<2)|1, zero-extended
    assign root_bit  = (srem_sh >= sq_test);
    assign srem_next = root_bit ? (srem_sh - sq_test) : srem_sh;

    // ── Final normalize + round (combinational, used in S_DONE) ───────────────────
    logic [31:0] div_result, sqrt_result, computed;
    always_comb begin
        logic [26:0]        Q, Qn;
        logic [4:0]         msbQ;
        logic signed [11:0] dbiased;
        logic               dg, dr, ds;
        Q    = {r_qint, Qf};                 // 27-bit: integer bit + 26 frac bits
        msbQ = r_qint ? 5'd26 : 5'd25;       // ratio in [1,2) -> 26, in [0.5,1) -> 25
        Qn   = Q << (5'd26 - msbQ);          // MSB -> bit 26
        dg   = Qn[2]; dr = Qn[1]; ds = Qn[0] | (P != 25'd0);
        // value = Q * 2^(ea-eb-26); MSB exp = msbQ+ea-eb-26; biased +127.
        dbiased = $signed({4'd0, r_ea}) - $signed({4'd0, r_eb})
                  + $signed({7'd0, msbQ}) + 12'sd101;   // -26+127
        div_result = pack_round(r_sign, dbiased, Qn[26:3], dg, dr, ds);
    end
    always_comb begin
        logic [36:0]        Sn;
        logic [5:0]         msbR;
        logic signed [11:0] sbiased, q_exp;
        logic               sg, sr, ss;
        msbR = root[36] ? 6'd36 : 6'd35;
        Sn   = root << (6'd36 - msbR);       // MSB -> bit 36
        sg   = Sn[12]; sr = Sn[11]; ss = (|Sn[10:0]) | (srem != 42'd0);
        // value = sqrt(M)*2^q, q=((ea-150)-p)/2 ; root=floor(sqrt(M)*2^24).
        q_exp   = ($signed({4'd0, r_ea}) - 12'sd150 - $signed({11'd0, r_p})) >>> 1;
        sbiased = $signed({6'd0, msbR}) + q_exp + 12'sd103;  // -24+127
        sqrt_result = pack_round(1'b0, sbiased, Sn[36:13], sg, sr, ss);
    end
    assign computed = r_sqrt ? sqrt_result : div_result;

    // Full result select as a single combinational cone: pick the FP32 result
    // (special value or computed), then narrow + NaN-box for half. Half SPECIALS
    // narrow too (inf/NaN/zero map to their FP16 forms). Registering this wire
    // (rather than calling narrow_h on `computed` inside the clocked block) keeps
    // the narrow in the combinational schedule so it sees a settled `computed`.
    logic [31:0] fp32_res, final_res;
    assign fp32_res  = r_special ? r_specval : computed;
    assign final_res = r_is_h ? {16'hffff, narrow_h(fp32_res)} : fp32_res;

    // ── FSM ──────────────────────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0; res <= 32'd0;
        end else begin
            done <= 1'b0;
            unique case (state)
                S_IDLE: if (start) begin
                    r_sqrt <= is_sqrt;
                    r_is_h <= op_is_h;
                    r_ea   <= ea;
                    r_eb   <= eb;
                    r_sign <= is_sqrt ? (a_zero ? sa : 1'b0) : (sa ^ sb);
                    r_p    <= ea[0];                            // sqrt radicand parity
                    if (is_sqrt) begin
                        if (a_nan || (sa && !a_zero)) begin r_special<=1'b1; r_specval<=CANON_QNAN; end
                        else if (a_inf)               begin r_special<=1'b1; r_specval<={sa,8'hff,23'd0}; end
                        else if (a_zero)              begin r_special<=1'b1; r_specval<={sa,31'd0}; end
                        else                          r_special<=1'b0;
                    end else begin
                        if (a_nan || b_nan)           begin r_special<=1'b1; r_specval<=CANON_QNAN; end
                        else if (a_inf && b_inf)      begin r_special<=1'b1; r_specval<=CANON_QNAN; end
                        else if (a_inf)               begin r_special<=1'b1; r_specval<={sa^sb,8'hff,23'd0}; end
                        else if (b_inf)               begin r_special<=1'b1; r_specval<={sa^sb,31'd0}; end
                        else if (b_zero)              begin r_special<=1'b1;
                            r_specval <= a_zero ? CANON_QNAN : {sa^sb,8'hff,23'd0}; end // 0/0 vs x/0
                        else if (a_zero)              begin r_special<=1'b1; r_specval<={sa^sb,31'd0}; end
                        else                          r_special<=1'b0;
                    end
                    // seed divider: integer bit from the siga>=sigb compare, rem<sigb.
                    r_qint <= (siga >= sigb);
                    div_d  <= sigb;
                    P      <= (siga >= sigb) ? {1'b0, (siga - sigb)} : {1'b0, siga};
                    Qf     <= 26'd0;
                    // seed sqrt: radicand M = siga<<p (25-bit), then <<48 -> bits
                    // [72:48] of the 74-bit shifter.
                    radsh  <= {1'b0, (ea[0] ? {siga, 1'b0} : {1'b0, siga}), 48'd0};
                    srem   <= 42'd0;
                    root   <= 37'd0;
                    iter   <= is_sqrt ? 6'(SQRT_ITERS) : 6'(DIV_ITERS);
                    state  <= S_RUN;
                end
                S_RUN: begin
                    // Always run the full (uniform) iteration count — even special
                    // cases — so that every lane's core in a warp completes on the
                    // SAME cycle (the integration uses one lane as the done witness).
                    // The special result is selected at the end regardless of the
                    // iterated datapath, so the wasted iterations are harmless.
                    if (iter == 6'd0) begin
                        state <= S_DONE;
                    end else begin
                        if (r_sqrt) begin
                            srem  <= srem_next;
                            root  <= {root[35:0], root_bit};
                            radsh <= radsh << 2;
                        end else begin
                            P  <= P_next;
                            Qf <= {Qf[24:0], q_bit};
                        end
                        iter <= iter - 6'd1;
                    end
                end
                S_DONE: begin
                    res  <= final_res;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule : fp_divsqrt
