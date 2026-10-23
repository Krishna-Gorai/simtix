// =============================================================================
// mem_engine.sv  -  SIMTiX v2 memory engine: NC concurrent memory contexts
//
// A warp that issues a load, store or AMO hands it to a free CONTEXT and parks
// (W_MEM) while the scheduler keeps issuing other warps. Each context holds the
// op's per-lane addresses and store data until every lane has been served.
//
// Global memory (everything outside the scratchpad aperture) goes out on a
// line-wide, split-transaction, TAGGED port: a request is accepted when
// dmem_req && dmem_gnt and carries dmem_tag; its single response (writes respond
// too) returns dmem_rtag on dmem_rvalid, in ANY order. A context coalesces its
// pending lanes line by line (the lowest pending lane and every pending lane in
// the same line form one request). Load data is written back when its response
// arrives. Contexts take turns on the request port (rotating priority). A memory
// that answers in the request cycle ties dmem_gnt = 1, dmem_rvalid = dmem_req,
// dmem_rtag = dmem_tag; with NC = 1 the engine then reproduces the single
// engine of v1 cycle for cycle.
//
// A global AMO is a read-modify-write of one line. The read fetches the line of
// the lead lane; with AGG = 1 it serves every pending lane whose word lies in that
// line, with AGG = 0 the lead lane only. When the line returns, the engine applies
// the group's lanes to a line buffer in ascending lane order, each lane receiving
// the word's value before its own update (the result of executing the lanes one
// after another): one lane per cycle (APAR = 0), or, with APAR = 1, every lane on
// a distinct word in the same cycle, so the group takes as many cycles as the
// most lanes on one word. The updated words go back in one write request. While one context is between that read and write no other context may
// send a request, which makes the read-modify-write atomic.
//
// The scratchpad (single-port distributed RAM, one word per lane per cycle) is
// served by at most one context at a time. A scratch lane writes the register
// file only in a cycle with no global writeback (global responses cannot wait).
//
// The engine produces at most one register writeback per cycle (wb_*), which
// the warp pool's write arbiter takes with top priority, and at most one warp
// resume per cycle (rs_*): the lowest-numbered finished context.
// =============================================================================
module mem_engine
  import simtix_pkg::*;
#(
    parameter int NC   = NUM_WARPS,   // memory contexts (outstanding memory ops)
    parameter int MQD  = MEM_TAGS,    // outstanding global requests (tags)
    parameter bit AGG  = 1'b1,        // AMO: one read-modify-write per line (0: per lane)
    parameter bit APAR = 1'b0,        // AMO lanes per cycle: 1 = all on distinct words
    parameter int WIDXW = (NUM_WARPS > 1) ? $clog2(NUM_WARPS) : 1
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic [2:0]            blk_lg,      // log2 warps per block (shared view)

    // Issue: one memory op of warp in_w. Accepted when in_valid && in_ready.
    input  logic                  in_valid,
    output logic                  in_ready,
    input  logic [WIDXW-1:0]      in_w,
    input  logic [NUM_LANES-1:0]  in_mask,
    input  logic                  in_store,
    input  logic                  in_scratch,
    input  logic                  in_shared,
    input  logic                  in_fp,
    input  logic                  in_amo,
    input  logic [4:0]            in_amo_op,
    input  logic [2:0]            in_funct3,
    input  logic [4:0]            in_rd,
    input  logic [31:0]           in_next_pc,
    input  logic [31:0]           in_addr  [0:NUM_LANES-1],
    input  logic [31:0]           in_sdata [0:NUM_LANES-1],

    // Register writeback (non-deferrable): lanes, data, destination.
    output logic [NUM_LANES-1:0]  wb_lane,
    output logic [31:0]           wb_data [0:NUM_LANES-1],
    output logic [WIDXW-1:0]      wb_w,
    output logic [4:0]            wb_rd,
    output logic                  wb_fp,

    // Warp resume: warp rs_w continues at rs_pc.
    output logic                  rs_valid,
    output logic [WIDXW-1:0]      rs_w,
    output logic [31:0]           rs_pc,
    output logic                  busy,        // any context in use
    output logic                  fp_busy,     // a context holds an FP load/store

    // Global data port (tagged, split transaction).
    output logic                  dmem_req,
    input  logic                  dmem_gnt,
    output logic [$clog2(MQD)-1:0] dmem_tag,
    output logic [31:0]           dmem_addr,
    output logic [LINE_BITS-1:0]  dmem_wdata,
    output logic                  dmem_we,
    output logic [LINE_BE-1:0]    dmem_be,
    input  logic                  dmem_rvalid,
    input  logic [$clog2(MQD)-1:0] dmem_rtag,
    input  logic [LINE_BITS-1:0]  dmem_rdata,

    output logic                  gtxn,        // a global request was accepted
    output logic                  stxn         // a scratch lane was served
);

    localparam int NL    = NUM_LANES;
    localparam int NW    = NUM_WARPS;
    localparam int LIDXW = $clog2(NL);
    localparam int LOGNW = $clog2(NW);
    localparam int CW    = (NC > 1) ? $clog2(NC) : 1;
    localparam int TW    = $clog2(MQD);
    localparam int SCAW    = WIDXW + SCRATCH_AW;
    localparam int SCDEPTH = NW * SCRATCH_WORDS;

    typedef enum logic [1:0] { MK_LOAD, MK_WRITE, MK_AMORD } mkind_e;
    // AMO phases: send the read, wait for the line, apply the lanes, send the write.
    typedef enum logic [1:0] { AP_RD, AP_WAIT, AP_AGG, AP_WR } amo_ph_e;

    function automatic logic [31:0] amo_alu(input logic [4:0]  op,
                                            input logic [31:0] m,
                                            input logic [31:0] v);
        unique case (op)
            AMO_ADD:  amo_alu = m + v;
            AMO_SWAP: amo_alu = v;
            AMO_XOR:  amo_alu = m ^ v;
            AMO_OR:   amo_alu = m | v;
            AMO_AND:  amo_alu = m & v;
            AMO_MIN:  amo_alu = ($signed(m) < $signed(v)) ? m : v;
            AMO_MAX:  amo_alu = ($signed(m) < $signed(v)) ? v : m;
            AMO_MINU: amo_alu = (m < v) ? m : v;
            AMO_MAXU: amo_alu = (m < v) ? v : m;
            default:  amo_alu = m;
        endcase
    endfunction

    // Load-data extraction of one lane from a line.
    function automatic logic [31:0] ld_extract(input logic [2:0]           f3,
                                               input logic [LINE_OFF-1:0]  off,
                                               input logic [LINE_BITS-1:0] line);
        logic [31:0] word;
        logic [7:0]  lb;
        logic [15:0] lh;
        word = line[off[LINE_OFF-1:2]*32 +: 32];
        lb   = word[8*off[1:0] +: 8];
        lh   = off[1] ? word[31:16] : word[15:0];
        unique case (f3)
            3'b000:  ld_extract = {{24{lb[7]}},  lb};
            3'b001:  ld_extract = {{16{lh[15]}}, lh};
            3'b100:  ld_extract = {24'b0, lb};
            3'b101:  ld_extract = {16'b0, lh};
            default: ld_extract = word;
        endcase
    endfunction

    // ── Context state (written only inside the per-context generate block) ─────────
    logic [NC-1:0]       c_busy, c_done;
    logic [WIDXW-1:0]    c_w      [0:NC-1];
    logic [NL-1:0]       c_pend   [0:NC-1];     // lanes not yet sent / served
    logic [NC-1:0]       c_store, c_scratch, c_shared, c_fp, c_amo;
    logic [4:0]          c_amo_op [0:NC-1];
    logic [2:0]          c_f3     [0:NC-1];
    logic [4:0]          c_rd     [0:NC-1];
    logic [31:0]         c_pc     [0:NC-1];
    logic [NL*32-1:0]    c_addr   [0:NC-1];     // lane l at [l*32 +: 32]
    logic [NL*32-1:0]    c_sdata  [0:NC-1];
    amo_ph_e             c_ph     [0:NC-1];
    logic [TW:0]         c_cnt    [0:NC-1];     // its requests still outstanding

    // Lead lane (lowest pending) and its line, per context.
    logic [LIDXW-1:0]    c_lead   [0:NC-1];
    logic [NL-1:0]       c_grp    [0:NC-1];     // pending lanes in the lead's line
    always_comb begin
        for (int c = 0; c < NC; c++) begin
            logic [31:LINE_OFF] tag;
            c_lead[c] = '0;
            for (int l = NL-1; l >= 0; l--)
                if (c_pend[c][l]) c_lead[c] = l[LIDXW-1:0];
            tag = c_addr[c][c_lead[c]*32 + LINE_OFF +: 32-LINE_OFF];
            for (int l = 0; l < NL; l++)
                c_grp[c][l] = c_pend[c][l] && (c_addr[c][l*32 + LINE_OFF +: 32-LINE_OFF] == tag);
        end
    end

    // ── Issue: allocate the lowest free context ──────────────────────────────────
    logic          free_ok, scr_busy, in_fire;
    logic [CW-1:0] alloc_c;
    always_comb begin
        free_ok = 1'b0;
        alloc_c = '0;
        for (int c = NC-1; c >= 0; c--)
            if (!c_busy[c]) begin free_ok = 1'b1; alloc_c = CW'(c); end
        scr_busy = |(c_busy & c_scratch);
    end
    assign in_ready = free_ok && !(in_scratch && scr_busy);
    assign in_fire  = in_valid && in_ready;
    assign busy     = |c_busy;
    assign fp_busy  = |(c_busy & c_fp);

    // ── Global request: one context per cycle, rotating priority ─────────────────
    logic [MQD-1:0]  t_valid;
    logic [CW-1:0]   t_ctx  [0:MQD-1];
    logic [NL-1:0]   t_mask [0:MQD-1];
    mkind_e          t_kind [0:MQD-1];
    logic            tag_ok;
    logic [TW-1:0]   alloc_t;
    always_comb begin
        tag_ok  = 1'b0;
        alloc_t = '0;
        for (int t = MQD-1; t >= 0; t--)
            if (!t_valid[t]) begin tag_ok = 1'b1; alloc_t = TW'(t); end
    end

    logic [NC-1:0] c_want;           // context has a request to send
    logic [NC-1:0] c_locked;         // context is inside an AMO read-modify-write
    always_comb begin
        for (int c = 0; c < NC; c++) begin
            c_locked[c] = c_busy[c] && !c_scratch[c] && c_amo[c] && (c_ph[c] != AP_RD);
            c_want[c]   = c_busy[c] && !c_scratch[c] && !c_done[c] && (c_pend[c] != '0) &&
                          (!c_amo[c] || (c_ph[c] == AP_RD) || (c_ph[c] == AP_WR));
        end
    end

    logic [CW-1:0] rr;               // first context to consider this cycle
    logic          mreq_valid, mreq_fire;
    logic [CW-1:0] sel;
    logic [CW-1:0]   lock_c, rot_off, rot_c;
    logic            rot_found;
    logic [2*NC-1:0] want2;          // c_want rotated so that context rr is bit 0
    assign want2 = {c_want, c_want} >> rr;
    always_comb begin
        // An AMO read-modify-write in progress owns the port.
        lock_c = '0;
        for (int c = 0; c < NC; c++) if (c_locked[c]) lock_c = CW'(c);
        // Otherwise the first wanting context at or after rr.
        rot_found = 1'b0;
        rot_off   = '0;
        for (int k = NC-1; k >= 0; k--)
            if (want2[k]) begin rot_found = 1'b1; rot_off = CW'(k); end
    end
    assign rot_c = CW'((int'(rr) + int'(rot_off)) % NC);
    assign sel        = (|c_locked) ? lock_c : rot_c;
    assign mreq_valid = ((|c_locked) ? c_want[lock_c] : rot_found) && tag_ok;
    assign mreq_fire = mreq_valid && dmem_gnt;

    logic [NL-1:0]   mreq_mask;
    mkind_e          mreq_kind;
    logic [LIDXW-1:0] sel_lead;
    assign sel_lead = c_lead[sel];
    always_comb begin
        mreq_mask = c_grp[sel];
        mreq_kind = c_store[sel] ? MK_WRITE : MK_LOAD;
        if (c_amo[sel]) begin
            if (!AGG) begin
                mreq_mask           = '0;
                mreq_mask[sel_lead] = 1'b1;
            end
            mreq_kind = (c_ph[sel] == AP_WR) ? MK_WRITE : MK_AMORD;
        end
    end

    // AMO line buffer, used by the one context inside a read-modify-write.
    logic [LINE_BITS-1:0]  a_line;   // the line, with the lanes applied so far
    logic [NL-1:0]         a_left;   // group lanes not yet applied
    logic [LINE_WORDS-1:0] a_touch;  // words updated (written back)

    assign dmem_req  = mreq_valid;
    assign dmem_tag  = alloc_t;
    assign dmem_addr = mreq_valid
                     ? {c_addr[sel][sel_lead*32 + LINE_OFF +: 32-LINE_OFF], {LINE_OFF{1'b0}}}
                     : 32'd0;
    always_comb begin
        dmem_wdata = '0;
        dmem_we    = 1'b0;
        dmem_be    = '0;
        if (mreq_valid && (mreq_kind == MK_WRITE)) begin
            dmem_we = 1'b1;
            if (c_amo[sel]) begin
                dmem_wdata = a_line;
                for (int w = 0; w < LINE_WORDS; w++) dmem_be[w*4 +: 4] = {4{a_touch[w]}};
            end else begin
                for (int l = 0; l < NL; l++) begin
                    if (mreq_mask[l]) begin
                        logic [LINE_WOFFW-1:0] woff;
                        logic [1:0]            bsel;
                        logic [31:0]           sd;
                        woff = c_addr[sel][l*32 + 2 +: LINE_WOFFW];
                        bsel = c_addr[sel][l*32 +: 2];
                        sd   = c_sdata[sel][l*32 +: 32];
                        unique case (c_f3[sel])
                            3'b000: begin  // sb
                                dmem_wdata[woff*32 + bsel*8 +: 8] = sd[7:0];
                                dmem_be[woff*4 + bsel]            = 1'b1;
                            end
                            3'b001: begin  // sh
                                if (bsel[1]) begin
                                    dmem_wdata[woff*32 + 16 +: 16] = sd[15:0];
                                    dmem_be[woff*4 + 2 +: 2]       = 2'b11;
                                end else begin
                                    dmem_wdata[woff*32 +: 16] = sd[15:0];
                                    dmem_be[woff*4 +: 2]      = 2'b11;
                                end
                            end
                            default: begin  // sw
                                dmem_wdata[woff*32 +: 32] = sd;
                                dmem_be[woff*4 +: 4]      = 4'b1111;
                            end
                        endcase
                    end
                end
            end
        end
    end

    // ── Global response ──────────────────────────────────────────────────────────
    // A response whose tag is not outstanding answers this cycle's request.
    logic          rsp_byp;
    logic [CW-1:0] rc;
    logic [NL-1:0] rmask;
    mkind_e        rkind;
    assign rsp_byp = dmem_rvalid && !t_valid[dmem_rtag];
    assign rc      = rsp_byp ? sel       : t_ctx[dmem_rtag];
    assign rmask   = rsp_byp ? mreq_mask : t_mask[dmem_rtag];
    assign rkind   = rsp_byp ? mreq_kind : t_kind[dmem_rtag];

    logic [31:0] rdata_l [0:NL-1];
    always_comb
        for (int l = 0; l < NL; l++)
            rdata_l[l] = ld_extract(c_f3[rc], c_addr[rc][l*32 +: LINE_OFF], dmem_rdata);

    logic gwb;                       // global writeback this cycle
    assign gwb = dmem_rvalid && (rkind == MK_LOAD) && (c_fp[rc] || (c_rd[rc] != 5'd0));

    // ── AMO lane application: the locked context, in rounds ──────────────────────
    // Each cycle a round applies some remaining lanes; the round's old words go to
    // the lanes' registers in a cycle with no global writeback.
    //   APAR = 1: every remaining lane whose word no lower remaining lane still has
    //             to update. Those lanes hit distinct words, so they update in
    //             parallel (one AMO ALU per word); a word hit by k lanes takes k
    //             rounds.
    //   APAR = 0: the lowest remaining lane only (one AMO ALU).
    // Either way each lane sees its word as the lower lanes left it.
    logic                  a_act, a_step, a_wb, a_last;
    logic [LINE_WOFFW-1:0] a_off   [0:NL-1];      // word of each lane in the line
    logic [NL-1:0]         a_rnd;                 // lanes applied this round
    logic [31:0]           a_old   [0:NL-1];      // word value seen by each lane
    logic [31:0]           a_wnew  [0:LINE_WORDS-1];
    logic [LINE_WORDS-1:0] a_whit;                // words updated this round
    always_comb
        for (int l = 0; l < NL; l++) a_off[l] = c_addr[lock_c][l*32 + 2 +: LINE_WOFFW];
    if (APAR) begin : g_apar
        always_comb begin
            for (int l = 0; l < NL; l++) a_old[l] = a_line[a_off[l]*32 +: 32];
            for (int l = 0; l < NL; l++) begin
                a_rnd[l] = a_left[l];
                for (int j = 0; j < l; j++)
                    if (a_left[j] && (a_off[j] == a_off[l])) a_rnd[l] = 1'b0;
            end
            for (int w = 0; w < LINE_WORDS; w++) begin
                logic [31:0] v;
                v = '0;
                a_whit[w] = 1'b0;
                for (int l = 0; l < NL; l++)
                    if (a_rnd[l] && (a_off[l] == LINE_WOFFW'(w))) begin
                        a_whit[w] = 1'b1;
                        v         = v | c_sdata[lock_c][l*32 +: 32];
                    end
                a_wnew[w] = amo_alu(c_amo_op[lock_c], a_line[w*32 +: 32], v);
            end
        end
    end else begin : g_aser
        logic [LIDXW-1:0]      lane;
        logic [LINE_WOFFW-1:0] wo;
        logic [31:0]           old, nw;
        always_comb begin
            lane = '0;
            for (int l = NL-1; l >= 0; l--)
                if (a_left[l]) lane = l[LIDXW-1:0];
            wo     = a_off[lane];
            old    = a_line[wo*32 +: 32];
            nw     = amo_alu(c_amo_op[lock_c], old, c_sdata[lock_c][lane*32 +: 32]);
            a_rnd  = a_left & (NL'(1) << lane);
            a_whit = (a_left != '0) ? (LINE_WORDS'(1) << wo) : '0;
            for (int l = 0; l < NL; l++)         a_old[l]  = old;
            for (int w = 0; w < LINE_WORDS; w++) a_wnew[w] = nw;
        end
    end
    assign a_act  = (|c_locked) && (c_ph[lock_c] == AP_AGG);
    assign a_wb   = a_act && (c_rd[lock_c] != 5'd0);
    assign a_step = a_act && !(a_wb && gwb);
    assign a_last = a_step && ((a_left & ~a_rnd) == '0);

    // ── Scratchpad: the one busy scratch context, one lane per cycle ─────────────
    logic          sc_act;           // a scratch context exists
    logic [CW-1:0] sc_c;
    always_comb begin
        sc_act = 1'b0;
        sc_c   = '0;
        for (int c = NC-1; c >= 0; c--)
            if (c_busy[c] && c_scratch[c] && !c_done[c]) begin sc_act = 1'b1; sc_c = CW'(c); end
    end
    logic             sc_step;       // serve the lead lane this cycle
    logic [LIDXW-1:0] sc_lead;
    logic [31:0]      sc_laddr;
    assign sc_step  = sc_act && !gwb && !(a_wb && a_step);
    assign sc_lead  = c_lead[sc_c];
    assign sc_laddr = c_addr[sc_c][sc_lead*32 +: 32];

    logic [SCRATCH_AW-1:0] sc_sidx;
    logic [WIDXW-1:0]      sc_wfield;
    logic [SCAW-1:0]       sc_a;
    logic [31:0]           sc_rd, sc_wd;
    logic                  sc_we;
    assign sc_sidx = sc_laddr[SCRATCH_AW+1:2];
    always_comb begin
        // Block-shared view: the low blk_lg bits of the warp field come from the
        // address, so a block's warps index one region of 2^blk_lg slots.
        sc_wfield = c_w[sc_c];
        if (c_shared[sc_c])
            for (int i = 0; i < LOGNW; i++)
                if (i < int'(blk_lg)) sc_wfield[i] = sc_laddr[SCRATCH_AW+2+i];
    end
    assign sc_a  = {sc_wfield, sc_sidx};
    assign sc_wd = c_amo[sc_c] ? amo_alu(c_amo_op[sc_c], sc_rd, c_sdata[sc_c][sc_lead*32 +: 32])
                               : c_sdata[sc_c][sc_lead*32 +: 32];
    assign sc_we = sc_step && (c_store[sc_c] || c_amo[sc_c]);

    (* ram_style = "distributed" *)
    logic [31:0] scratch [0:SCDEPTH-1];
    always_ff @(posedge clk)
        if (sc_we) scratch[sc_a] <= sc_wd;
    assign sc_rd = scratch[sc_a];

    // ── Register writeback ───────────────────────────────────────────────────────
    always_comb begin
        wb_lane = '0;
        wb_w    = c_w[rc];
        wb_rd   = c_rd[rc];
        wb_fp   = c_fp[rc];
        for (int l = 0; l < NL; l++) wb_data[l] = rdata_l[l];
        if (gwb) begin
            wb_lane = rmask;
        end else if (a_wb && a_step) begin
            wb_lane = a_rnd;
            wb_w    = c_w[lock_c];
            wb_rd   = c_rd[lock_c];
            wb_fp   = 1'b0;
            for (int l = 0; l < NL; l++) wb_data[l] = a_old[l];
        end else if (sc_step && !c_store[sc_c] && (c_fp[sc_c] || (c_rd[sc_c] != 5'd0))) begin
            wb_lane[sc_lead] = 1'b1;
            wb_w  = c_w[sc_c];
            wb_rd = c_rd[sc_c];
            wb_fp = c_fp[sc_c];
            for (int l = 0; l < NL; l++) wb_data[l] = sc_rd;
        end
    end

    // ── Completion: a context finishes when every lane is served and every one of
    //    its requests has been answered. It resumes its warp this cycle if it is the
    //    lowest-numbered finished context, else it holds (c_done) and tries again.
    logic [NC-1:0] c_fin;            // finished this cycle or earlier
    logic [NL-1:0] c_sent [0:NC-1];  // lanes that leave c_pend this cycle
    logic [TW:0]   c_cnt_n [0:NC-1];
    always_comb begin
        for (int c = 0; c < NC; c++) begin
            logic here, rhere;
            here  = mreq_fire && (sel == CW'(c));
            rhere = dmem_rvalid && (rc == CW'(c));
            c_sent[c] = '0;
            if (c_scratch[c]) begin
                if (sc_step && (sc_c == CW'(c))) c_sent[c][c_lead[c]] = 1'b1;
            end else if (here && !(c_amo[c] && (c_ph[c] != AP_WR))) begin
                c_sent[c] = mreq_mask;
            end
            c_cnt_n[c] = c_cnt[c] + (TW+1)'(here && !rsp_byp) - (TW+1)'(rhere && !rsp_byp);
            c_fin[c]   = c_busy[c] &&
                         (c_done[c] || (((c_pend[c] & ~c_sent[c]) == '0) && (c_cnt_n[c] == '0)));
        end
    end

    logic [CW-1:0] rs_c;
    always_comb begin
        rs_valid = 1'b0;
        rs_c     = '0;
        for (int c = NC-1; c >= 0; c--)
            if (c_fin[c]) begin rs_valid = 1'b1; rs_c = CW'(c); end
    end
    assign rs_w  = c_w[rs_c];
    assign rs_pc = c_pc[rs_c];

    assign gtxn = mreq_fire;
    assign stxn = sc_step;

    // ── Per-context registers ────────────────────────────────────────────────────
    genvar gc;
    generate
        for (gc = 0; gc < NC; gc++) begin : g_ctx
            logic take, here, rhere, last;
            assign take  = in_fire && (alloc_c == CW'(gc));
            assign here  = mreq_fire && (sel == CW'(gc));
            assign rhere = dmem_rvalid && (rc == CW'(gc));
            assign last  = rs_valid && (rs_c == CW'(gc));
            always_ff @(posedge clk) begin
                if (rst) begin
                    c_busy[gc] <= 1'b0;
                    c_done[gc] <= 1'b0;
                    c_pend[gc] <= '0;
                    c_cnt[gc]  <= '0;
                    c_ph[gc]   <= AP_RD;
                end else if (take) begin
                    c_busy[gc]     <= 1'b1;
                    c_done[gc]     <= 1'b0;
                    c_w[gc]        <= in_w;
                    c_pend[gc]     <= in_mask;
                    c_store[gc]    <= in_store;
                    c_scratch[gc]  <= in_scratch;
                    c_shared[gc]   <= in_shared;
                    c_fp[gc]       <= in_fp;
                    c_amo[gc]      <= in_amo;
                    c_amo_op[gc]   <= in_amo_op;
                    c_f3[gc]       <= in_funct3;
                    c_rd[gc]       <= in_rd;
                    c_pc[gc]       <= in_next_pc;
                    c_cnt[gc]      <= '0;
                    c_ph[gc]       <= AP_RD;
                    for (int l = 0; l < NL; l++) c_addr[gc][l*32 +: 32]  <= in_addr[l];
                    for (int l = 0; l < NL; l++) c_sdata[gc][l*32 +: 32] <= in_sdata[l];
                end else if (c_busy[gc]) begin
                    c_pend[gc] <= c_pend[gc] & ~c_sent[gc];
                    c_cnt[gc]  <= c_cnt_n[gc];
                    if (last)            c_busy[gc] <= 1'b0;
                    else if (c_fin[gc])  c_done[gc] <= 1'b1;
                    if (c_amo[gc] && !c_scratch[gc]) begin
                        // read sent -> wait; line back -> apply lanes; last lane
                        // applied -> write; write sent -> next line
                        if (rhere && (rkind == MK_AMORD))
                            c_ph[gc] <= AP_AGG;
                        else if (here && (c_ph[gc] == AP_RD))
                            c_ph[gc] <= AP_WAIT;
                        else if (a_last && (lock_c == CW'(gc)))
                            c_ph[gc] <= AP_WR;
                        else if (here && (c_ph[gc] == AP_WR))
                            c_ph[gc] <= AP_RD;
                    end
                end
            end
        end
    endgenerate

    // ── AMO line buffer ──────────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (dmem_rvalid && (rkind == MK_AMORD)) begin
            a_line  <= dmem_rdata;
            a_left  <= rmask;
            a_touch <= '0;
        end else if (a_step) begin
            for (int w = 0; w < LINE_WORDS; w++)
                if (a_whit[w]) a_line[w*32 +: 32] <= a_wnew[w];
            a_left  <= a_left & ~a_rnd;
            a_touch <= a_touch | a_whit;
        end
    end

    // ── Tag table and request rotation ───────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            t_valid <= '0;
            rr      <= '0;
        end else begin
            if (mreq_fire && !rsp_byp) begin
                t_valid[alloc_t] <= 1'b1;
                t_ctx[alloc_t]   <= sel;
                t_mask[alloc_t]  <= mreq_mask;
                t_kind[alloc_t]  <= mreq_kind;
            end
            if (dmem_rvalid && !rsp_byp) t_valid[dmem_rtag] <= 1'b0;
            if (mreq_fire && !c_locked[sel])
                rr <= (int'(sel) == NC-1) ? '0 : sel + 1'b1;
        end
    end

endmodule : mem_engine
