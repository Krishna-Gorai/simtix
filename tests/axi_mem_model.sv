// =============================================================================
// axi_mem_model.sv  -  behavioural AXI4 slave memory (testbench only)
//
// A word array `mem` (WORDS x 32 bit, indexed by addr[2 +: log2(WORDS)], so
// higher address bits alias) served as an AXI4 slave with INCR bursts of
// DW-bit beats. Testbenches preload and check `mem` hierarchically.
//
//   reads : the burst's data is captured at AR acceptance; it is due LAT cycles
//           later (+0..7 random if OOO), and the lowest due ID streams next, so
//           bursts of different IDs complete out of order
//   writes: W beats apply to the oldest accepted AW (AXI4 order); B is due LAT
//           (+0..7 random if OOO) cycles after the last beat
//   STALL : withholds AR/AW/W ready on about one cycle in four
// =============================================================================
`timescale 1ns/1ps
module axi_mem_model #(
    parameter int IDW   = 4,
    parameter int DW    = 128,
    parameter int WORDS = 65536,
    parameter int MAXB  = 2,            // longest burst (beats)
    parameter int LAT   = 24,
    parameter int STALL = 1,
    parameter int OOO   = 1
) (
    input  logic                clk,
    input  logic                rst,
    /* verilator lint_off UNUSEDSIGNAL */   // fixed burst attributes are not checked
    input  logic [IDW-1:0]      awid,
    input  logic [31:0]         awaddr,
    input  logic [7:0]          awlen,
    input  logic [2:0]          awsize,
    input  logic [1:0]          awburst,
    input  logic [3:0]          awcache,
    input  logic [2:0]          awprot,
    input  logic                awvalid,
    output logic                awready,
    input  logic [DW-1:0]       wdata,
    input  logic [DW/8-1:0]     wstrb,
    input  logic                wlast,
    input  logic                wvalid,
    output logic                wready,
    output logic [IDW-1:0]      bid,
    output logic [1:0]          bresp,
    output logic                bvalid,
    input  logic                bready,
    input  logic [IDW-1:0]      arid,
    input  logic [31:0]         araddr,
    input  logic [7:0]          arlen,
    input  logic [2:0]          arsize,
    input  logic [1:0]          arburst,
    input  logic [3:0]          arcache,
    input  logic [2:0]          arprot,
    input  logic                arvalid,
    output logic                arready,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [IDW-1:0]      rid,
    output logic [DW-1:0]       rdata,
    output logic [1:0]          rresp,
    output logic                rlast,
    output logic                rvalid,
    input  logic                rready
);

    localparam int NID = 1 << IDW;
    localparam int WAW = $clog2(WORDS);
    localparam int WPB = DW / 32;                // words per beat
    localparam int BBW = (MAXB > 1) ? $clog2(MAXB) : 1;

    logic [31:0] mem [0:WORDS-1];

    /* verilator lint_off UNUSEDSIGNAL */   // only the word index is used
    function automatic int unsigned widx(input logic [31:0] a);
        return int'(a[2 +: WAW]);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    logic [15:0] lfsr;
    always @(posedge clk)
        if (rst) lfsr <= 16'hBEEF;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    logic rdy;
    assign rdy   = (STALL == 0) || (lfsr[1:0] != 2'b00);
    assign bresp = 2'b00;
    assign rresp = 2'b00;

    // ── Reads ────────────────────────────────────────────────────────────────────
    int unsigned       now;
    logic              rs_v   [NID];
    int unsigned       rs_due [NID];
    logic [7:0]        rs_len [NID];
    logic [DW-1:0]     rs_data[NID][MAXB];
    logic              rb_act;
    logic [IDW-1:0]    rb_id;
    logic [7:0]        rb_beat;
    logic              r_pick;
    logic [IDW-1:0]    r_pid;

    assign arready = rdy;
    always_comb begin
        r_pick = 1'b0;
        r_pid  = '0;
        for (int t = NID-1; t >= 0; t--)
            if (rs_v[t] && (rs_due[t] <= now)) begin r_pick = 1'b1; r_pid = IDW'(t); end
    end
    assign rvalid = rb_act;
    assign rid    = rb_id;
    assign rdata  = rs_data[rb_id][rb_beat[BBW-1:0]];
    assign rlast  = (rb_beat == rs_len[rb_id]);

    // ── Writes ───────────────────────────────────────────────────────────────────
    logic [31:0]       awq_addr [16];
    logic [IDW-1:0]    awq_id   [16];
    logic [3:0]        awq_wp, awq_rp;
    logic [4:0]        awq_n;
    logic [7:0]        wb_beat;
    logic              bs_v   [NID];
    int unsigned       bs_due [NID];
    logic              b_pick;
    logic [IDW-1:0]    b_pid;

    assign awready = rdy && (awq_n != 5'd16);
    assign wready  = rdy && (awq_n != 5'd0);
    always_comb begin
        b_pick = 1'b0;
        b_pid  = '0;
        for (int t = NID-1; t >= 0; t--)
            if (bs_v[t] && (bs_due[t] <= now)) begin b_pick = 1'b1; b_pid = IDW'(t); end
    end
    assign bvalid = b_pick;
    assign bid    = b_pid;

    always @(posedge clk) begin
        if (rst) begin
            now <= 0; rb_act <= 1'b0; rb_beat <= '0; wb_beat <= '0;
            awq_wp <= '0; awq_rp <= '0; awq_n <= '0;
            for (int t = 0; t < NID; t++) rs_v[t] <= 1'b0;
            for (int t = 0; t < NID; t++) bs_v[t] <= 1'b0;
        end else begin
            now <= now + 1;
            if (arvalid && arready) begin
                rs_v[arid]   <= 1'b1;
                rs_due[arid] <= now + LAT + ((OOO != 0) ? 32'(lfsr[6:4]) : 0);
                rs_len[arid] <= arlen;
                for (int b = 0; b < MAXB; b++)
                    for (int k = 0; k < WPB; k++)
                        rs_data[arid][b][k*32 +: 32] <= mem[widx(araddr + 32'(b*(DW/8) + 4*k))];
            end
            if (rb_act) begin
                if (rready) begin
                    rb_beat <= rb_beat + 8'd1;
                    if (rlast) begin rb_act <= 1'b0; rb_beat <= '0; rs_v[rb_id] <= 1'b0; end
                end
            end else if (r_pick) begin
                rb_act <= 1'b1; rb_id <= r_pid; rb_beat <= '0;
            end
            if (awvalid && awready) begin
                awq_addr[awq_wp] <= awaddr;
                awq_id[awq_wp]   <= awid;
                awq_wp           <= awq_wp + 1'b1;
            end
            if (wvalid && wready) begin
                for (int k = 0; k < WPB; k++) begin
                    logic [31:0] a, cur;
                    a   = awq_addr[awq_rp] + 32'(int'(wb_beat) * (DW/8) + 4*k);
                    cur = mem[widx(a)];
                    for (int b = 0; b < 4; b++)
                        if (wstrb[4*k + b]) cur[b*8 +: 8] = wdata[k*32 + b*8 +: 8];
                    mem[widx(a)] <= cur;
                end
                wb_beat <= wb_beat + 8'd1;
                if (wlast) begin
                    wb_beat <= '0;
                    awq_rp  <= awq_rp + 1'b1;
                    bs_v[awq_id[awq_rp]]   <= 1'b1;
                    bs_due[awq_id[awq_rp]] <= now + LAT + ((OOO != 0) ? 32'(lfsr[9:7]) : 0);
                end
            end
            awq_n <= awq_n + 5'(awvalid && awready) - 5'(wvalid && wready && wlast);
            if (bvalid && bready) bs_v[bid] <= 1'b0;
        end
    end

endmodule : axi_mem_model
