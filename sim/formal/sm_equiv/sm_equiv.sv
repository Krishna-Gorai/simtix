// sm_equiv.sv - combinational equivalence of the two forms of me_store_merge (mem_engine.sv):
// the original lane-by-lane merge (OLD = 1) and the replicate + one-hot form (OLD = 0).
// Every input is free; run.ps1 proves ok == 1 for all inputs with yosys sat, at 4, 8 and 16 lanes.
module sm_equiv #(
    parameter int NL = 8,
    parameter int LW = NL,
    parameter int WOFFW = $clog2(LW)
) (
    input  logic [NL-1:0]          mask,
    input  logic [2:0]             f3,
    input  logic [NL*WOFFW-1:0]    woff_f,
    input  logic [NL*2-1:0]        bsel_f,
    input  logic [NL*32-1:0]       sd_f,
    output logic                   ok,
    output logic                   bad      // = !ok: the miter output ABC proves constant 0
);
    logic [WOFFW-1:0] woff [0:NL-1];
    logic [1:0]       bsel [0:NL-1];
    logic [31:0]      sd   [0:NL-1];
    for (genvar l = 0; l < NL; l++) begin : g_unpack
        assign woff[l] = woff_f[l*WOFFW +: WOFFW];
        assign bsel[l] = bsel_f[l*2 +: 2];
        assign sd[l]   = sd_f[l*32 +: 32];
    end
    logic [LW*32-1:0] wd_old, wd_new;
    logic [LW*4-1:0]  be_old, be_new;
    me_store_merge #(.NL(NL), .LW(LW), .WOFFW(WOFFW), .OLD(1'b1)) u_old (
        .mask, .f3, .woff, .bsel, .sd, .wdata(wd_old), .be(be_old));
    me_store_merge #(.NL(NL), .LW(LW), .WOFFW(WOFFW), .OLD(1'b0)) u_new (
        .mask, .f3, .woff, .bsel, .sd, .wdata(wd_new), .be(be_new));
    assign ok  = (wd_old == wd_new) && (be_old == be_new);
    assign bad = !ok;
endmodule

// sm_wrap - one form of me_store_merge behind flat packed ports (top-level unpacked array
// ports are not ports to the yosys frontends), for the ABC cec check in run.ps1.
module sm_wrap #(
    parameter int NL = 8,
    parameter int LW = NL,
    parameter int WOFFW = $clog2(LW),
    parameter bit OLD = 1'b0
) (
    input  logic [NL-1:0]          mask,
    input  logic [2:0]             f3,
    input  logic [NL*WOFFW-1:0]    woff_f,
    input  logic [NL*2-1:0]        bsel_f,
    input  logic [NL*32-1:0]       sd_f,
    output logic [LW*32-1:0]       wdata,
    output logic [LW*4-1:0]        be
);
    logic [WOFFW-1:0] woff [0:NL-1];
    logic [1:0]       bsel [0:NL-1];
    logic [31:0]      sd   [0:NL-1];
    for (genvar l = 0; l < NL; l++) begin : g_unpack
        assign woff[l] = woff_f[l*WOFFW +: WOFFW];
        assign bsel[l] = bsel_f[l*2 +: 2];
        assign sd[l]   = sd_f[l*32 +: 32];
    end
    me_store_merge #(.NL(NL), .LW(LW), .WOFFW(WOFFW), .OLD(OLD)) u_sm (
        .mask, .f3, .woff, .bsel, .sd, .wdata, .be);
endmodule
