// =============================================================================
// l1_dcache.sv  -  SIMTiX v2 non-blocking L1 data cache
//
// Sits between the memory engine (upstream, s_*) and memory (downstream, m_*).
// Both sides use the line-wide, tagged, split-transaction protocol of
// mem_engine: a request is accepted when req && gnt; each request gets exactly
// one response carrying its tag, in any order.
//
// Organisation: 16 KB, 4-way set associative, 32-byte lines (= the engine's
// line), 128 sets. Tags live in distributed RAM and valid bits in flip-flops,
// both read in the request cycle; the data of each way is a separate block-RAM
// bank addressed by the set, so a hit returns its line one cycle later.
//
// Reads: a hit answers from the data bank. A miss allocates one of NMSHR miss
// registers and requests the line downstream; a later miss to the same line
// joins that register (a mask over the upstream tags). When the line returns it
// is held in the register, every waiting request is answered from it, and it
// is written into the cache (way: an invalid one, else round robin).
//
// Writes: write-through, no write-allocate. A write that hits updates the
// cached line; every write goes downstream, and it is acknowledged upstream
// only after memory acknowledges it. A write to a line with a miss in flight
// waits until that miss has completed, so a returning line never overwrites
// newer data.
//
// inv clears every valid bit (asserted at kernel launch, when nothing is in
// flight); the cache never holds dirty data, so nothing is written back.
//
// Downstream tags: {0, miss register} for reads, {1, upstream tag} for writes.
// =============================================================================
module l1_dcache
  import simtix_pkg::*;
#(
    parameter int NWAY  = 4,
    parameter int NSET  = 128,
    parameter int NMSHR = 4,
    parameter int UTW   = MEM_TAGW,              // upstream tag width
    parameter int DTW   = MEM_TAGW + 1           // downstream tag width
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  inv,           // invalidate all lines

    // Upstream (memory engine).
    input  logic                  s_req,
    output logic                  s_gnt,
    input  logic [UTW-1:0]        s_tag,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]           s_addr,        // line aligned: [4:0] unused
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                  s_we,
    input  logic [LINE_BITS-1:0]  s_wdata,
    input  logic [LINE_BE-1:0]    s_be,
    output logic                  s_rvalid,
    output logic [UTW-1:0]        s_rtag,
    output logic [LINE_BITS-1:0]  s_rdata,

    // Downstream (memory).
    output logic                  m_req,
    input  logic                  m_gnt,
    output logic [DTW-1:0]        m_tag,
    output logic [31:0]           m_addr,
    output logic                  m_we,
    output logic [LINE_BITS-1:0]  m_wdata,
    output logic [LINE_BE-1:0]    m_be,
    input  logic                  m_rvalid,
    input  logic [DTW-1:0]        m_rtag,
    input  logic [LINE_BITS-1:0]  m_rdata,

    output logic                  hit_ev,        // a read was accepted and hit
    output logic                  miss_ev        // a read was accepted and missed
);

    localparam int SW   = $clog2(NSET);          // set index bits
    localparam int WW   = (NWAY > 1) ? $clog2(NWAY) : 1;
    localparam int MW   = (NMSHR > 1) ? $clog2(NMSHR) : 1;
    localparam int NUT  = 1 << UTW;              // upstream tags
    localparam int TGW  = 32 - LINE_OFF - SW;    // address tag bits
    localparam int LA   = 32 - LINE_OFF;         // line address bits

    // ── Request decode ───────────────────────────────────────────────────────────
    logic [SW-1:0]  r_set;
    logic [TGW-1:0] r_tg;
    logic [LA-1:0]  r_line;
    assign r_set  = s_addr[LINE_OFF +: SW];
    assign r_tg   = s_addr[31 -: TGW];
    assign r_line = s_addr[31:LINE_OFF];

    // ── Tags (distributed RAM) and valid bits (flip-flops) ───────────────────────
    logic [NSET-1:0] valid [0:NWAY-1];
    logic [TGW-1:0]  tag_rd [0:NWAY-1];          // tag of each way in set r_set
    logic [NWAY-1:0] hit_w;
    logic            hit;
    logic [WW-1:0]   hit_way;
    logic            tag_we;                     // fill: write tag of way f_way, set f_set
    logic [WW-1:0]   f_way;
    logic [SW-1:0]   f_set;
    logic [TGW-1:0]  f_tg;

    genvar gw;
    generate
        for (gw = 0; gw < NWAY; gw++) begin : g_tag
            (* ram_style = "distributed" *)
            logic [TGW-1:0] tram [0:NSET-1];
            always_ff @(posedge clk)
                if (tag_we && (f_way == WW'(gw))) tram[f_set] <= f_tg;
            assign tag_rd[gw] = tram[r_set];
            assign hit_w[gw]  = valid[gw][r_set] && (tag_rd[gw] == r_tg);
        end
    endgenerate

    always_comb begin
        hit     = |hit_w;
        hit_way = '0;
        for (int w = NWAY-1; w >= 0; w--) if (hit_w[w]) hit_way = WW'(w);
    end

    // ── Miss registers ───────────────────────────────────────────────────────────
    logic [NMSHR-1:0]     q_v;                   // in use
    logic [NMSHR-1:0]     q_fill;                // line has arrived
    logic [NMSHR-1:0]     q_done;                // line written into the cache
    logic [LA-1:0]        q_line [0:NMSHR-1];
    logic [NUT-1:0]       q_wait [0:NMSHR-1];    // upstream tags still to answer
    logic [LINE_BITS-1:0] q_data [0:NMSHR-1];

    logic [NMSHR-1:0] q_match;                   // miss register for the request line
    logic             q_any;
    logic [MW-1:0]    q_hit;                     // its index
    logic             q_free;
    logic [MW-1:0]    q_new;                     // lowest free miss register
    always_comb begin
        q_any  = 1'b0;
        q_hit  = '0;
        q_free = 1'b0;
        q_new  = '0;
        for (int m = NMSHR-1; m >= 0; m--) begin
            q_match[m] = q_v[m] && (q_line[m] == r_line);
            if (q_match[m]) begin q_any = 1'b1; q_hit = MW'(m); end
            if (!q_v[m])    begin q_free = 1'b1; q_new = MW'(m); end
        end
    end

    // ── Accepting a request ──────────────────────────────────────────────────────
    //   read hit             : answered next cycle from the data bank
    //   read, line in flight : joins that miss register
    //   read miss            : new miss register + downstream read
    //   write                : downstream write (+ cache update on a hit); waits
    //                          while a miss to the same line is in flight
    logic rd_hit, rd_join, rd_miss, wr_go;
    assign rd_hit  = s_req && !s_we && hit;
    assign rd_join = s_req && !s_we && !hit && q_any;
    assign rd_miss = s_req && !s_we && !hit && !q_any && q_free;
    assign wr_go   = s_req &&  s_we && !q_any;

    assign m_req   = rd_miss || wr_go;
    assign m_tag   = wr_go ? {1'b1, s_tag} : {{(DTW-MW){1'b0}}, q_new};
    assign m_addr  = {s_addr[31:LINE_OFF], {LINE_OFF{1'b0}}};
    assign m_we    = wr_go;
    assign m_wdata = s_wdata;
    assign m_be    = s_be;

    assign s_gnt   = rd_hit || rd_join || ((rd_miss || wr_go) && m_gnt);

    logic acc, acc_rd_hit, acc_join, acc_miss, acc_wr;
    assign acc        = s_req && s_gnt;
    assign acc_rd_hit = acc && rd_hit;
    assign acc_join   = acc && rd_join;
    assign acc_miss   = acc && rd_miss;
    assign acc_wr     = acc && wr_go;
    assign hit_ev     = acc_rd_hit;
    assign miss_ev    = acc_join || acc_miss;

    // ── Data banks: port A reads the request set, port B writes (write hit or fill)
    logic                  wr_hit;               // accepted write that hits: update line
    logic                  fill_go;              // a filled line is written this cycle
    logic [MW-1:0]         fill_m;
    assign wr_hit = acc_wr && hit;

    logic [LINE_BITS-1:0]  bank_q [0:NWAY-1];    // registered read of each way
    logic                  pb_we  [0:NWAY-1];
    logic [SW-1:0]         pb_set;
    logic [LINE_BITS-1:0]  pb_d;
    logic [LINE_BE-1:0]    pb_be;
    assign pb_set = wr_hit ? r_set : f_set;
    assign pb_d   = wr_hit ? s_wdata : q_data[fill_m];
    assign pb_be  = wr_hit ? s_be : '1;

    generate
        for (gw = 0; gw < NWAY; gw++) begin : g_data
            assign pb_we[gw] = (wr_hit && (hit_way == WW'(gw))) ||
                               (fill_go && (f_way == WW'(gw)));
            (* ram_style = "block" *)
            logic [LINE_BITS-1:0] dram [0:NSET-1];
            always_ff @(posedge clk)
                bank_q[gw] <= dram[r_set];
            always_ff @(posedge clk)
                if (pb_we[gw])
                    for (int b = 0; b < LINE_BE; b++)
                        if (pb_be[b]) dram[pb_set][b*8 +: 8] <= pb_d[b*8 +: 8];
        end
    endgenerate

    // ── Fill: write one arrived line into the cache when port B is free and no
    //    request is being accepted (so no read of that set is in flight).
    logic [WW-1:0] rr_way;                       // round-robin victim pointer
    always_comb begin
        fill_go = 1'b0;
        fill_m  = '0;
        for (int m = NMSHR-1; m >= 0; m--)
            if (q_v[m] && q_fill[m] && !q_done[m]) begin fill_go = !acc; fill_m = MW'(m); end
        f_set = q_line[fill_m][SW-1:0];
        f_tg  = q_line[fill_m][LA-1 -: TGW];
        // Victim: an invalid way of the set, else the round-robin way.
        f_way = rr_way;
        for (int w = NWAY-1; w >= 0; w--) if (!valid[w][f_set]) f_way = WW'(w);
    end
    assign tag_we = fill_go;

    // ── Upstream responses: hit (fixed timing) > miss-register drain > write ack ──
    logic          b_v;                          // a read hit answers this cycle
    logic [UTW-1:0] b_tag;
    logic [WW-1:0] b_way;
    logic [NUT-1:0] wack;                        // write acks owed upstream

    logic          dr_go;                        // drain one waiting request
    logic [MW-1:0] dr_m;
    logic [UTW-1:0] dr_t;
    always_comb begin
        dr_go = 1'b0;
        dr_m  = '0;
        dr_t  = '0;
        for (int m = NMSHR-1; m >= 0; m--)
            if (q_v[m] && q_fill[m] && (q_wait[m] != '0)) begin dr_go = !b_v; dr_m = MW'(m); end
        for (int t = NUT-1; t >= 0; t--) if (q_wait[dr_m][t]) dr_t = UTW'(t);
    end

    logic          wa_go;
    logic [UTW-1:0] wa_t;
    always_comb begin
        wa_go = 1'b0;
        wa_t  = '0;
        for (int t = NUT-1; t >= 0; t--) if (wack[t]) begin wa_go = !b_v && !dr_go; wa_t = UTW'(t); end
    end

    assign s_rvalid = b_v || dr_go || wa_go;
    assign s_rtag   = b_v ? b_tag : (dr_go ? dr_t : wa_t);
    assign s_rdata  = b_v ? bank_q[b_way] : q_data[dr_m];

    // ── Downstream responses ─────────────────────────────────────────────────────
    logic          m_isw;
    logic [MW-1:0] m_rm;
    assign m_isw = m_rtag[DTW-1];
    assign m_rm  = m_rtag[MW-1:0];

    // ── State ────────────────────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            b_v    <= 1'b0;
            wack   <= '0;
            rr_way <= '0;
            for (int w = 0; w < NWAY; w++) valid[w] <= '0;
        end else begin
            b_v   <= acc_rd_hit;
            b_tag <= s_tag;
            b_way <= hit_way;
            if (inv)
                for (int w = 0; w < NWAY; w++) valid[w] <= '0;
            else if (fill_go)
                valid[f_way][f_set] <= 1'b1;
            if (fill_go) rr_way <= rr_way + 1'b1;
            // write acks: set by the downstream ack, cleared when sent upstream
            wack <= (wack & ~(NUT'(wa_go) << wa_t)) |
                    (NUT'(m_rvalid && m_isw) << m_rtag[UTW-1:0]);
        end
    end

    genvar gm;
    generate
        for (gm = 0; gm < NMSHR; gm++) begin : g_mshr
            logic alloc, join_, arrive, drain, filled_now;
            logic [NUT-1:0] wait_n;
            assign alloc  = acc_miss && (q_new == MW'(gm));
            assign join_  = acc_join && (q_hit == MW'(gm));
            assign arrive = m_rvalid && !m_isw && (m_rm == MW'(gm));
            assign drain  = dr_go && (dr_m == MW'(gm));
            assign filled_now = fill_go && (fill_m == MW'(gm));
            always_comb begin
                wait_n = q_wait[gm];
                if (drain) wait_n[dr_t] = 1'b0;
                if (join_) wait_n[s_tag] = 1'b1;
            end
            always_ff @(posedge clk) begin
                if (rst) begin
                    q_v[gm]    <= 1'b0;
                    q_fill[gm] <= 1'b0;
                    q_done[gm] <= 1'b0;
                    q_wait[gm] <= '0;
                end else if (alloc) begin
                    q_v[gm]       <= 1'b1;
                    q_fill[gm]    <= arrive;         // a memory may answer at once
                    q_done[gm]    <= 1'b0;
                    q_line[gm]    <= r_line;
                    q_wait[gm]    <= NUT'(1) << s_tag;
                    if (arrive) q_data[gm] <= m_rdata;
                end else if (q_v[gm]) begin
                    q_wait[gm] <= wait_n;
                    if (arrive) begin
                        q_fill[gm] <= 1'b1;
                        q_data[gm] <= m_rdata;
                    end
                    if (filled_now) q_done[gm] <= 1'b1;
                    // free once the line is in the cache and every waiter is answered
                    if ((q_done[gm] || filled_now) && q_fill[gm] && (wait_n == '0))
                        q_v[gm] <= 1'b0;
                end
            end
        end
    endgenerate

endmodule : l1_dcache
