// dsp_pack_probe.sv — de-risking probe for the clean-DRC Part B work.
//
// Confirms the register/decomposition patterns that make EVERY inferred DSP48E2 fully
// pipelined (AREG/BREG + MREG + PREG) so report_drc emits NO DPIP-2/DPOP-3/DPOP-4.
//
// Findings so far:
//   * FP 24x24 -> 48 (full product): packs 100% clean with input reg + 3 output regs.
//   * Int 32x32 -> low 32 inferred directly: ALWAYS leaves 1-2 cascade DSPs without
//     MREG/PREG, at any pipeline depth. So we DECOMPOSE the 32x32 into 16x16 pieces,
//     each of which is a single DSP that packs cleanly:
//        a*b (low32) = aL*bL + ((aL*bH + aH*bL) << 16)   [mod 2^32]
//     (aH*bH is <<32, irrelevant to the low 32). Low 32 is sign-agnostic, so unsigned
//     16x16 sub-products are bit-correct for RV32M `mul`.
`timescale 1ns/1ps
module dsp_pack_probe (
    input  logic        clk,
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [23:0] sa,
    input  logic [23:0] sb,
    output logic [31:0] mul_lo,    // low 32 of a*b via 16x16 decomposition (RV32M mul)
    output logic [47:0] fp_prod    // 48-bit sa*sb (FP significand)
);
    // ───────── Int 32x32 -> low 32 via three pipelined 16x16 DSP multiplies ─────────
    logic [15:0] aL, aH, bL, bH;
    always_ff @(posedge clk) begin
        aL <= a[15:0];  aH <= a[31:16];
        bL <= b[15:0];  bH <= b[31:16];
    end
    // Each 16x16: input registers (AREG/BREG) -> multiply -> MREG -> PREG.
    (* use_dsp = "yes" *) logic [15:0] aL_ll, bL_ll, aL_lh, bH_lh, aH_hl, bL_hl;
    logic [31:0] m_ll, p_ll;   // aL*bL
    logic [31:0] m_lh, p_lh;   // aL*bH
    logic [31:0] m_hl, p_hl;   // aH*bL
    always_ff @(posedge clk) begin
        aL_ll <= aL; bL_ll <= bL;
        aL_lh <= aL; bH_lh <= bH;
        aH_hl <= aH; bL_hl <= bL;
        m_ll <= aL_ll * bL_ll;  p_ll <= m_ll;
        m_lh <= aL_lh * bH_lh;  p_lh <= m_lh;
        m_hl <= aH_hl * bL_hl;  p_hl <= m_hl;
    end
    // Pipelined fabric adder tree: low32 = p_ll + ((p_lh + p_hl) << 16).
    logic [31:0] cross_s, p_ll_d, lo_r;
    always_ff @(posedge clk) begin
        cross_s <= (p_lh + p_hl) << 16;   // only low 16 of (p_lh+p_hl) survives <<16 in 32b
        p_ll_d  <= p_ll;
        lo_r    <= p_ll_d + cross_s;
    end
    assign mul_lo = lo_r;

    // ───────── FP 24x24 -> 48, input reg + 3 output stages (proven clean) ─────────
    (* use_dsp = "yes" *) logic [23:0] sa_r, sb_r;
    logic [47:0] f1, f2, f3;
    always_ff @(posedge clk) begin
        sa_r <= sa;  sb_r <= sb;
        f1   <= sa_r * sb_r;
        f2   <= f1;
        f3   <= f2;
    end
    assign fp_prod = f3;
endmodule
