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
//           (+0..7 random if OOO) cycles after the last beat. Up to 16 writes of
//           one ID may wait for B; they are answered in order (as AXI requires)
//   STALL : withholds AR/AW/W ready on about one cycle in four
//   RJW   : width of the random part of the latency (default 3: +0..7); with
//           RJW > 3 reads take LAT + 0..2^RJW-1 and writes BLAT + 0..2^RJW-1
//   BLAT  : write-response latency (default LAT); SEED: random-number seed
//   LATE  : a write takes effect when its B response is sent, not at its W beats.
//           Writes of different IDs then complete in any order and a read sees a
//           write only after its response, which AXI allows: the master must order
//           a read after a write (and two writes) to the same address itself.
// =============================================================================
`timescale 1ns/1ps
module axi_mem_model #(
    parameter int IDW   = 4,
    parameter int DW    = 128,
    parameter int WORDS = 65536,
    parameter int MAXB  = 2,            // longest burst (beats)
    parameter int LAT   = 24,
    parameter int STALL = 1,
    parameter int OOO   = 1,
    parameter int RJW   = 3,
    parameter int BLAT  = -1,           // -1: LAT
    parameter logic [15:0] SEED = 16'hBEEF,
    parameter int LATE  = 0
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
        if (rst) lfsr <= SEED;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

    logic rdy;
    assign rdy   = (STALL == 0) || (lfsr[1:0] != 2'b00);
    assign bresp = 2'b00;
    assign rresp = 2'b00;

    // Random latency parts: 0..7 from fixed LFSR bits, or RJW bits of a second
    // generator (so that wide jitter does not follow the ready stalls).
    localparam int BL = (BLAT < 0) ? LAT : BLAT;
    logic [31:0] rng;
    always @(posedge clk)
        if (rst) rng <= {SEED, ~SEED};
        else     rng <= rng ^ (rng << 13) ^ (rng >> 17) ^ (rng << 5);
    logic [31:0] r_jit, b_jit;
    assign r_jit = (OOO == 0) ? 0 : (RJW <= 3) ? 32'(lfsr[6:4]) : 32'(rng[RJW-1:0]);
    assign b_jit = (OOO == 0) ? 0 : (RJW <= 3) ? 32'(lfsr[9:7]) : 32'(rng[16 +: RJW]);

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
    // Writes waiting for B: per ID a FIFO of WQD, each with its due time and (LATE)
    // its beats, which take effect when its B response is sent.
    localparam int WQD = 16;
    logic [4:0]        bq_n   [NID];
    logic [3:0]        bq_wp  [NID], bq_rp [NID];
    int unsigned       bq_due [NID][WQD];
    logic              b_pick;
    logic [IDW-1:0]    b_pid;
    logic [31:0]       pw_addr [NID][WQD];
    logic [DW-1:0]     pw_data [NID][WQD][MAXB];
    logic [DW/8-1:0]   pw_strb [NID][WQD][MAXB];
    logic              w_push;
    logic [IDW-1:0]    w_pid;
    assign w_push = wvalid && wready && wlast;
    assign w_pid  = awq_id[awq_rp];
    logic [DW-1:0]     cw_data [MAXB];
    logic [DW/8-1:0]   cw_strb [MAXB];

    // The model writes its memory array at once (blocking), also from the clocked
    // block below, so that a later beat or read of the same cycle sees the data.
    /* verilator lint_off BLKSEQ */
    task automatic put(input logic [31:0] base, input int beat, input logic [DW-1:0] d,
                       input logic [DW/8-1:0] st);
        for (int k = 0; k < WPB; k++) begin
            logic [31:0] a, cur;
            a   = base + 32'(beat * (DW/8) + 4*k);
            cur = mem[widx(a)];
            for (int b = 0; b < 4; b++)
                if (st[4*k + b]) cur[b*8 +: 8] = d[k*32 + b*8 +: 8];
            mem[widx(a)] = cur;
        end
    endtask

    assign awready = rdy && (awq_n != 5'd16);
    assign wready  = rdy && (awq_n != 5'd0);
    always_comb begin
        b_pick = 1'b0;
        b_pid  = '0;
        for (int t = NID-1; t >= 0; t--)
            if ((bq_n[t] != 5'd0) && (bq_due[t][bq_rp[t]] <= now)) begin
                b_pick = 1'b1; b_pid = IDW'(t);
            end
    end
    assign bvalid = b_pick;
    assign bid    = b_pid;

    always @(posedge clk) begin
        if (rst) begin
            now <= 0; rb_act <= 1'b0; rb_beat <= '0; wb_beat <= '0;
            awq_wp <= '0; awq_rp <= '0; awq_n <= '0;
            for (int t = 0; t < NID; t++) rs_v[t] <= 1'b0;
            for (int t = 0; t < NID; t++) begin bq_n[t] <= '0; bq_wp[t] <= '0; bq_rp[t] <= '0; end
        end else begin
            now <= now + 1;
            if (arvalid && arready) begin
                rs_v[arid]   <= 1'b1;
                rs_due[arid] <= now + LAT + r_jit;
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
                if (LATE == 0) put(awq_addr[awq_rp], int'(wb_beat), wdata, wstrb);
                cw_data[wb_beat[BBW-1:0]] = wdata;
                cw_strb[wb_beat[BBW-1:0]] = wstrb;
                wb_beat <= wb_beat + 8'd1;
                if (wlast) begin
                    if (bq_n[w_pid] == 5'(WQD)) $error("axi_mem_model: over %0d writes of ID %0d", WQD, w_pid);
                    pw_addr[w_pid][bq_wp[w_pid]] <= awq_addr[awq_rp];
                    for (int b = 0; b < MAXB; b++) begin
                        pw_data[w_pid][bq_wp[w_pid]][b] <= cw_data[b];
                        pw_strb[w_pid][bq_wp[w_pid]][b] <= (b <= int'(wb_beat)) ? cw_strb[b] : '0;
                    end
                    bq_due[w_pid][bq_wp[w_pid]] <= now + BL + b_jit;
                    bq_wp[w_pid] <= bq_wp[w_pid] + 1'b1;
                    wb_beat <= '0;
                    awq_rp  <= awq_rp + 1'b1;
                end
            end
            awq_n <= awq_n + 5'(awvalid && awready) - 5'(wvalid && wready && wlast);
            if (bvalid && bready) begin
                bq_rp[bid] <= bq_rp[bid] + 1'b1;
                if (LATE != 0)
                    for (int b = 0; b < MAXB; b++)
                        put(pw_addr[bid][bq_rp[bid]], b, pw_data[bid][bq_rp[bid]][b], pw_strb[bid][bq_rp[bid]][b]);
            end
            for (int t = 0; t < NID; t++)
                bq_n[t] <= bq_n[t] + 5'(w_push && (w_pid == IDW'(t))) - 5'(bvalid && bready && (bid == IDW'(t)));
        end
    end

    /* verilator lint_on BLKSEQ */

endmodule : axi_mem_model
