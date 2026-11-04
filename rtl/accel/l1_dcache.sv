// =============================================================================
// l1_dcache.sv  -  SIMTiX v2 non-blocking L1 data cache
//
// Sits between the memory engine (upstream, s_*) and memory (downstream, m_*).
// Both sides use the line-wide, tagged, split-transaction protocol of
// mem_engine: a request is accepted when req && gnt; each request gets exactly
// one response carrying its tag, in any order.
//
// Input stage: an accepted request first goes into an input register (with one
// skid entry behind it), and the cache works on it in the next cycle. s_gnt is
// therefore a flip-flop, and nothing the cache decides about a request reaches
// back into the memory engine in the same cycle.
//
// Organisation: 16 KB, 4-way set associative, lines of the engine's width
// (NUM_LANES words: 32 bytes and 128 sets at 8 lanes; the set count keeps 16 KB at
// other lane counts). Tags live in distributed RAM and valid bits in flip-flops,
// both read in the cycle the request leaves the input register; the data of
// each way is a separate block-RAM bank addressed by the set, so a hit returns
// its line one cycle after that (two cycles after s_req && s_gnt).
//
// Reads: a hit answers from the data bank. A miss allocates one of NMSHR miss
// registers and requests the line downstream; a later miss to the same line
// joins that register (a mask over the upstream tags). A miss to a line with a
// write in flight downstream waits until memory has acknowledged that write: AXI
// lets a read pass a write, and the read would return the line without it. When the line returns it
// is held in the register, every waiting request is answered from it, and it
// is written into the cache (way: an invalid one, else round robin).
//
// Writes: write-through, no write-allocate. A write that hits updates the
// cached line; every write goes downstream, and it is acknowledged upstream
// only after memory acknowledges it. A write to a line with a miss in flight
// waits until that miss has completed, so a returning line never overwrites
// newer data.
//
// inv clears every valid bit (asserted at kernel launch); the cache never holds
// dirty data, so nothing is written back. A miss register still in flight at inv
// (only a prefetch can be) is marked stale: its line is not written into the cache
// and no request joins it.
//
// Prefetch (PF = 1, v3): a read that misses line L arms a prefetch of line L+1. It
// enters the input register like a read with no requester, when that register is
// free and no upstream request arrives, and goes through the same tag check: on a
// hit, or if the line is already in flight, or with no free miss register, it is
// dropped; otherwise it takes a miss register with no waiting tag and the line is
// filled into the cache when it returns. A later read of the line joins that miss
// register. No prefetch is sent while a write is in flight downstream (the read
// could pass the write and bring an old copy of the line into the cache).
//
// Downstream tags: {0, miss register} for reads, {1, upstream tag} for writes.
// =============================================================================
module l1_dcache
  import simtix_pkg::*;
#(
    parameter int NWAY  = 4,
    parameter int NSET  = L1_BYTES / (NWAY * LINE_BITS / 8),
    parameter int NMSHR = L1_MSHR,
    parameter bit PF    = L1_PF,                 // next-line prefetch
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
    output logic                  miss_ev,       // a read was accepted and missed

    // State for the board's debug window (simt_ps_top, 0x0200): DBG_L1 words.
    output logic [31:0]           dbg_state [0:DBG_L1-1]
);

    localparam int SW   = $clog2(NSET);          // set index bits
    localparam int WW   = (NWAY > 1) ? $clog2(NWAY) : 1;
    localparam int MW   = (NMSHR > 1) ? $clog2(NMSHR) : 1;
    localparam int NUT  = 1 << UTW;              // upstream tags
    localparam int TGW  = 32 - LINE_OFF - SW;    // address tag bits
    localparam int LA   = 32 - LINE_OFF;         // line address bits

    // ── Input stage: input register i_*, skid entry k_* ──────────────────────────
    // The cache takes the input register when i_gnt. A request accepted while the
    // input register is held waits in the skid entry, and s_gnt drops until the
    // skid entry has moved on.
    typedef struct packed {
        logic [UTW-1:0]       tag;
        logic [LA-1:0]        line;
        logic                 we;
        logic [LINE_BITS-1:0] wdata;
        logic [LINE_BE-1:0]   be;
        logic                 pf;                // a prefetch (no requester)
    } req_t;
    req_t s_in, i_r, k_r, pf_in;
    logic i_v, k_v, i_gnt, s_acc;
    logic pf_v, pf_go;                           // armed prefetch, injected this cycle
    logic [LA-1:0] pf_line;
    assign s_in  = '{tag: s_tag, line: s_addr[31:LINE_OFF], we: s_we, wdata: s_wdata, be: s_be,
                     pf: 1'b0};
    assign pf_in = '{tag: '0, line: pf_line, we: 1'b0, wdata: '0, be: '0, pf: 1'b1};
    assign s_gnt = !k_v;
    assign s_acc = s_req && s_gnt;
    always_ff @(posedge clk) begin
        if (rst) begin
            i_v <= 1'b0;
            k_v <= 1'b0;
        end else if (!i_v || i_gnt) begin           // the input register frees up
            if (k_v) begin
                i_r <= k_r;
                k_v <= 1'b0;
            end else begin
                i_v <= s_acc || pf_go;
                if (s_acc)      i_r <= s_in;
                else if (pf_go) i_r <= pf_in;
            end
        end else if (s_acc) begin                   // held: park the new request
            k_r <= s_in;
            k_v <= 1'b1;
        end
    end

    // ── Request decode ───────────────────────────────────────────────────────────
    logic [SW-1:0]  r_set;
    logic [TGW-1:0] r_tg;
    logic [LA-1:0]  r_line;
    assign r_set  = i_r.line[SW-1:0];
    assign r_tg   = i_r.line[LA-1 -: TGW];
    assign r_line = i_r.line;

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
    logic [NMSHR-1:0]     q_stale;               // in flight at inv: do not fill
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
            q_match[m] = q_v[m] && !q_stale[m] && (q_line[m] == r_line);
            if (q_match[m]) begin q_any = 1'b1; q_hit = MW'(m); end
            if (!q_v[m])    begin q_free = 1'b1; q_new = MW'(m); end
        end
    end

    // ── Writes in flight downstream, by upstream tag, with their lines ──────────
    // AXI does not order a read after a write to the same address, so a read that
    // misses a line with a write in flight could fetch the line from before the
    // write; such a read waits until memory has acknowledged the write. (The memory
    // engine ends an AMO's lock when its write is sent, and the next AMO of the line
    // reads it.) Two writes stay in order through axi_line_master's single write ID.
    logic [NUT-1:0] w_v;
    logic [LA-1:0]  w_line [0:NUT-1];
    logic           w_any;                       // a write to the request line is in flight
    always_comb begin
        w_any = 1'b0;
        for (int t = 0; t < NUT; t++) if (w_v[t] && (w_line[t] == r_line)) w_any = 1'b1;
    end

    // ── Accepting a request ──────────────────────────────────────────────────────
    //   read hit             : answered next cycle from the data bank
    //   read, line in flight : joins that miss register
    //   read miss            : new miss register + downstream read; waits while a
    //                          write to the same line is in flight downstream
    //   write                : downstream write (+ cache update on a hit); waits
    //                          while a miss to the same line is in flight
    //   prefetch             : dropped on a hit, a line in flight, a write to the
    //                          line in flight or no free miss register; else a
    //                          miss register with no waiter
    logic rd_hit, rd_join, rd_miss, wr_go, pf_drop;
    assign rd_hit  = i_v && !i_r.we && !i_r.pf && hit;
    assign rd_join = i_v && !i_r.we && !i_r.pf && !hit && q_any;
    assign rd_miss = i_v && !i_r.we && !hit && !q_any && q_free && !w_any;
    assign wr_go   = i_v &&  i_r.we && !q_any;
    assign pf_drop = i_v &&  i_r.pf && (hit || q_any || !q_free || w_any);

    assign m_req   = rd_miss || wr_go;
    assign m_tag   = wr_go ? {1'b1, i_r.tag} : {{(DTW-MW){1'b0}}, q_new};
    assign m_addr  = {i_r.line, {LINE_OFF{1'b0}}};
    assign m_we    = wr_go;
    assign m_wdata = i_r.wdata;
    assign m_be    = i_r.be;

    assign i_gnt   = rd_hit || rd_join || pf_drop || ((rd_miss || wr_go) && m_gnt);

    logic acc, acc_rd_hit, acc_join, acc_miss, acc_wr;
    assign acc        = i_v && i_gnt;
    assign acc_rd_hit = acc && rd_hit;
    assign acc_join   = acc && rd_join;
    assign acc_miss   = acc && rd_miss;
    assign acc_wr     = acc && wr_go;
    assign hit_ev     = acc_rd_hit;
    assign miss_ev    = acc_join || (acc_miss && !i_r.pf);


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
    assign pb_d   = wr_hit ? i_r.wdata : q_data[fill_m];
    assign pb_be  = wr_hit ? i_r.be : '1;

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
            if (q_v[m] && q_fill[m] && !q_done[m] && !q_stale[m]) begin fill_go = !acc; fill_m = MW'(m); end
        f_set = q_line[fill_m][SW-1:0];
        f_tg  = q_line[fill_m][LA-1 -: TGW];
        // Victim: an invalid way of the set, else the round-robin way.
        f_way = rr_way;
        for (int w = NWAY-1; w >= 0; w--) if (!valid[w][f_set]) f_way = WW'(w);
    end
    assign tag_we = fill_go;

    // ── Downstream responses ─────────────────────────────────────────────────────
    logic          m_isw;
    logic [MW-1:0] m_rm;
    assign m_isw = m_rtag[DTW-1];
    assign m_rm  = m_rtag[MW-1:0];

    // Prefetch arming and injection. wr_out counts writes in flight downstream.
    logic [UTW:0] wr_out;
    assign pf_go = PF && pf_v && !k_v && !s_acc && (!i_v || i_gnt) && (wr_out == '0);
    always_ff @(posedge clk) begin
        if (rst || inv) begin
            pf_v <= 1'b0;
        end else begin
            if (pf_go) pf_v <= 1'b0;
            if (PF && acc_miss && !i_r.pf) begin       // a demand miss arms its next line
                pf_v    <= 1'b1;
                pf_line <= i_r.line + 1'b1;
            end
        end
        if (rst) wr_out <= '0;
        else     wr_out <= wr_out + (UTW+1)'(acc_wr) - (UTW+1)'(m_rvalid && m_isw);
    end
    // An upstream tag is reused only after its response, so a write's entry is free
    // when the write is accepted.
    always_ff @(posedge clk) begin
        if (rst) begin
            w_v <= '0;
        end else begin
            if (m_rvalid && m_isw) w_v[m_rtag[UTW-1:0]] <= 1'b0;
            if (acc_wr)            w_v[i_r.tag]         <= 1'b1;
        end
        if (acc_wr) w_line[i_r.tag] <= r_line;
    end

    // ── Upstream responses: hit (fixed timing) > miss-register drain > write ack ──
    logic          b_v;                          // a read hit answers this cycle
    logic [UTW-1:0] b_tag;
    logic [WW-1:0] b_way;
    logic [NUT-1:0] wack;                        // write acks owed upstream

    // Drains are chosen one cycle ahead: d_v/d_m/d_t, a flip-flop, names the
    // waiting request (miss register d_m, upstream tag d_t) to answer this cycle
    // if no hit does. The next choice is the lowest waiting tag of the lowest
    // miss register whose line is in (or arrives this cycle), leaving out the
    // request drained this cycle; requests that join this cycle wait for a later
    // choice.
    logic           d_v;
    logic [MW-1:0]  d_m;
    logic [UTW-1:0] d_t;
    logic          dr_go;                        // drain one waiting request
    logic [MW-1:0] dr_m;
    logic [UTW-1:0] dr_t;
    assign dr_go = d_v && !b_v;
    assign dr_m  = d_m;
    assign dr_t  = d_t;

    logic           nd_v;
    logic [MW-1:0]  nd_m;
    logic [UTW-1:0] nd_t;
    logic [NUT-1:0] nd_wait [0:NMSHR-1];         // still waiting after this cycle's drain
    always_comb begin
        nd_v = 1'b0;
        nd_m = '0;
        nd_t = '0;
        for (int m = NMSHR-1; m >= 0; m--) begin
            nd_wait[m] = q_wait[m] & ~((dr_go && (dr_m == MW'(m))) ? (NUT'(1) << dr_t) : '0);
            if (q_v[m] && (q_fill[m] || (m_rvalid && !m_isw && (m_rm == MW'(m)))) &&
                (nd_wait[m] != '0)) begin
                nd_v = 1'b1;
                nd_m = MW'(m);
            end
        end
        for (int t = NUT-1; t >= 0; t--) if (nd_wait[nd_m][t]) nd_t = UTW'(t);
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

    // ── State ────────────────────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            b_v    <= 1'b0;
            d_v    <= 1'b0;
            wack   <= '0;
            rr_way <= '0;
            for (int w = 0; w < NWAY; w++) valid[w] <= '0;
        end else begin
            b_v   <= acc_rd_hit;
            b_tag <= i_r.tag;
            b_way <= hit_way;
            d_v   <= nd_v;
            d_m   <= nd_m;
            d_t   <= nd_t;
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
                if (join_) wait_n[i_r.tag] = 1'b1;
            end
            always_ff @(posedge clk) begin
                if (rst) begin
                    q_v[gm]    <= 1'b0;
                    q_fill[gm] <= 1'b0;
                    q_done[gm] <= 1'b0;
                    q_wait[gm] <= '0;
                    q_stale[gm] <= 1'b0;
                end else if (alloc) begin
                    q_v[gm]       <= 1'b1;
                    q_fill[gm]    <= arrive;         // a memory may answer at once
                    q_done[gm]    <= 1'b0;
                    q_stale[gm]   <= 1'b0;
                    q_line[gm]    <= r_line;
                    q_wait[gm]    <= i_r.pf ? '0 : NUT'(1) << i_r.tag;
                    if (arrive) q_data[gm] <= m_rdata;
                end else if (q_v[gm]) begin
                    if (inv) q_stale[gm] <= 1'b1;
                    q_wait[gm] <= wait_n;
                    if (arrive) begin
                        q_fill[gm] <= 1'b1;
                        q_data[gm] <= m_rdata;
                    end
                    if (filled_now) q_done[gm] <= 1'b1;
                    // free once the line is in the cache (or stale) and every waiter
                    // is answered
                    if ((q_done[gm] || filled_now || q_stale[gm]) && q_fill[gm] && (wait_n == '0))
                        q_v[gm] <= 1'b0;
                end
            end
        end
    endgenerate

    // ── Debug window ─────────────────────────────────────────────────────────────
    //   0-3: miss registers in use / line arrived / line written / stale
    //   4: write acks owed upstream    5: writes in flight downstream << 16 |
    //   {input valid, skid valid, drain chosen, hit answer, prefetch armed,
    //    input is a write, input is a prefetch}
    //   6: line address of the input request    7: its upstream tag
    //   8-11: upstream tags waiting on miss registers 0-3
    always_comb begin
        for (int i = 0; i < DBG_L1; i++) dbg_state[i] = '0;
        dbg_state[0] = 32'(q_v);
        dbg_state[1] = 32'(q_fill);
        dbg_state[2] = 32'(q_done);
        dbg_state[3] = 32'(q_stale);
        dbg_state[4] = 32'(wack);
        dbg_state[5] = {16'(wr_out), 9'd0, i_v, k_v, d_v, b_v, pf_v, i_r.we, i_r.pf};
        dbg_state[6] = 32'(i_r.line);
        dbg_state[7] = 32'(i_r.tag);
        for (int m = 0; m < NMSHR && m < 4; m++) dbg_state[8 + m] = 32'(q_wait[m]);
    end

endmodule : l1_dcache
