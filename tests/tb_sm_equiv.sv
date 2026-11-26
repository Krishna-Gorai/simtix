// tb_sm_equiv.sv - the two forms of me_store_merge (mem_engine.sv) on the same random requests,
// every output bit compared: OLD = 1 (the original lane-by-lane merge) and OLD = 0 (replicate +
// one-hot, used). Complements the formal proof (sim/formal/sm_equiv, done at 4 lanes; too heavy
// for the original form at 8 and 16 lanes). The stimulus is biased to where the forms could
// differ: lanes on few words (overlaps, so the highest-lane rule matters), sparse and full masks,
// byte / half / word stores and the other size codes, every byte offset.
//   verilator --binary -sv -GNL=16 tests/tb_sm_equiv.sv rtl/accel/simtix_pkg.sv rtl/accel/mem_engine.sv
//   +N=<vectors> (default 2,000,000)
module tb_sm_equiv #(
    parameter int NL = simtix_pkg::NUM_LANES,   // the build's lane count (SIMTIX_NUM_LANES)
    parameter longint NV = 2000000     // vectors (+N=<n> overrides)
);
    localparam int LW = NL, WOFFW = $clog2(LW);
    logic [NL-1:0]    mask;
    logic [2:0]       f3;
    logic [WOFFW-1:0] woff [0:NL-1];
    logic [1:0]       bsel [0:NL-1];
    logic [31:0]      sd   [0:NL-1];
    logic [LW*32-1:0] wd_old, wd_new;
    logic [LW*4-1:0]  be_old, be_new;
    me_store_merge #(.NL(NL), .LW(LW), .WOFFW(WOFFW), .OLD(1'b1)) u_old (
        .mask, .f3, .woff, .bsel, .sd, .wdata(wd_old), .be(be_old));
    me_store_merge #(.NL(NL), .LW(LW), .WOFFW(WOFFW), .OLD(1'b0)) u_new (
        .mask, .f3, .woff, .bsel, .sd, .wdata(wd_new), .be(be_new));

    longint unsigned n, errs, overlaps;
    int unsigned     span, dens, base;
    logic            ov;
    initial begin
        if (!$value$plusargs("N=%d", n)) n = NV;
        errs = 0; overlaps = 0;
        for (longint unsigned v = 0; v < n; v++) begin
            // words the lanes fall on: 1 (all lanes on one word), a few, or the whole line
            unique case ($urandom_range(0, 3))
                0: span = 1;
                1: span = 2;
                2: span = $urandom_range(1, LW);
                default: span = LW;
            endcase
            base = $urandom_range(0, LW - span);   // the words used: base .. base + span - 1
            dens = $urandom_range(0, 4);        // mask density: 0 sparse .. 4 full
            for (int l = 0; l < NL; l++) begin
                mask[l] = (dens == 4) ? 1'b1 : ($urandom_range(0, 3) < dens);
                woff[l] = WOFFW'(base + $urandom_range(0, span - 1));
                bsel[l] = 2'($urandom);
                sd[l]   = $urandom;
            end
            f3 = ($urandom_range(0, 7) == 0) ? 3'($urandom) : 3'($urandom_range(0, 2));
            #1;
            ov = 1'b0;
            for (int a = 0; a < NL; a++)
                for (int b = a + 1; b < NL; b++)
                    if (mask[a] && mask[b] && woff[a] == woff[b]) ov = 1'b1;
            if (ov) overlaps++;
            if (wd_old !== wd_new || be_old !== be_new) begin
                if (errs < 5) $display("[tb_sm_equiv] MISMATCH vector %0d mask=%h f3=%0d be old=%h new=%h",
                                       v, mask, f3, be_old, be_new);
                errs++;
            end
        end
        $display("[tb_sm_equiv] %0d lanes: %0d vectors, %0d with overlapping lanes, %0d mismatches",
                 NL, n, overlaps, errs);
        if (errs == 0) $display("[tb_sm_equiv] PASS"); else $display("[tb_sm_equiv] FAIL");
        $finish;
    end
endmodule
