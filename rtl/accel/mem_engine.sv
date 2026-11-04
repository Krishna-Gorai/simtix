// =============================================================================
// mem_engine.sv  -  SIMTiX v2 memory engine: NC concurrent memory contexts
//
// A warp that issues a load, store or AMO hands it to a free CONTEXT; for a store
// or AMO it parks (W_MEM) while the scheduler keeps issuing other warps, for a load
// it continues (v3) and only the load's destination register waits for the
// completion (rs_ld). Each context holds the
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
// engine of v1 cycle for cycle. Such a same-cycle answer needs BYP = 1. With
// BYP = 0 (a memory that answers no request before the next cycle, such as the
// L1) a context's completion no longer depends on this cycle's grant, which
// removes the path from the grant to the warp resume; the timing is the same.
// With BYP = 0 the request also takes two stages (v3, for the clock): the context,
// its lanes and its line are chosen and registered (o_*), and the next cycle the
// address, write data and byte enables are built from those registers and the
// context's (unchanging) addresses and data. A new choice is made when the stage
// is empty or its request is granted, so requests leave in the order chosen.
// Likewise an issued memory op first waits in an input register (i_*) and takes a
// context in the next cycle, which takes the warp pool's operand read and address
// adder out of the context registers' input path. in_ready then means "the input
// register is free or drains this cycle", decided from registers only. The warp
// resume (rs_*) is registered too: the warp pool sees a finished op one cycle after
// its context is freed, which takes the L1 response -> completion -> resume select
// path out of the warp pool's stack registers.
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
    parameter bit BYP  = 1'b1,        // memory may answer a request in its own cycle
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

    // Warp resume: warp rs_w continues at rs_pc. rs_rd / rs_fp name the op's
    // destination and rs_ld marks a load (not a store or AMO), which lets the warp
    // pool run loads without parking the warp (it then only clears rd's pending bit).
    output logic                  rs_valid,
    output logic [WIDXW-1:0]      rs_w,
    output logic [31:0]           rs_pc,
    output logic [4:0]            rs_rd,
    output logic                  rs_fp,
    output logic                  rs_ld,
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
    output logic                  stxn,        // a scratch lane was served

    // State for the board's debug window (simt_ps_top, 0x0200), DBG_ME words.
    output logic [31:0]           dbg_state [0:DBG_ME-1]
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
    logic [31:LINE_OFF]  c_ltag   [0:NC-1];     // the lead's line address
    // Per-iteration values of the combinational loops live in module-level arrays,
    // not in variables declared inside the loop bodies.
    always_comb begin
        for (int c = 0; c < NC; c++) begin
            c_lead[c] = '0;
            for (int l = NL-1; l >= 0; l--)
                if (c_pend[c][l]) c_lead[c] = l[LIDXW-1:0];
            c_ltag[c] = c_addr[c][c_lead[c]*32 + LINE_OFF +: 32-LINE_OFF];
            for (int l = 0; l < NL; l++)
                c_grp[c][l] = c_pend[c][l] &&
                              (c_addr[c][l*32 + LINE_OFF +: 32-LINE_OFF] == c_ltag[c]);
        end
    end

    // ── Input register (BYP = 0): the issued op, one cycle before it takes a context ──
    logic                 i_v, i_take;
    logic [WIDXW-1:0]     i_w;
    logic [NL-1:0]        i_mask;
    logic                 i_store, i_scratch, i_shared, i_fp, i_amo;
    logic [4:0]           i_amo_op, i_rd;
    logic [2:0]           i_f3;
    logic [31:0]          i_npc;
    logic [31:0]          i_addr  [0:NL-1];
    logic [31:0]          i_sdata [0:NL-1];

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
    if (!BYP) begin : g_ireg
        assign i_take   = i_v && free_ok && !(i_scratch && scr_busy);
        assign in_ready = !i_v || i_take;
        always_ff @(posedge clk) begin
            if (rst)                      i_v <= 1'b0;
            else if (in_valid && in_ready) i_v <= 1'b1;
            else if (i_take)              i_v <= 1'b0;
            if (in_valid && in_ready) begin
                i_w <= in_w;  i_mask <= in_mask;  i_store <= in_store;  i_scratch <= in_scratch;
                i_shared <= in_shared;  i_fp <= in_fp;  i_amo <= in_amo;  i_amo_op <= in_amo_op;
                i_f3 <= in_funct3;  i_rd <= in_rd;  i_npc <= in_next_pc;
                i_addr <= in_addr;  i_sdata <= in_sdata;
            end
        end
    end else begin : g_noireg
        assign i_v = in_valid;  assign i_w = in_w;  assign i_mask = in_mask;
        assign i_store = in_store;  assign i_scratch = in_scratch;  assign i_shared = in_shared;
        assign i_fp = in_fp;  assign i_amo = in_amo;  assign i_amo_op = in_amo_op;
        assign i_f3 = in_funct3;  assign i_rd = in_rd;  assign i_npc = in_next_pc;
        assign i_addr = in_addr;  assign i_sdata = in_sdata;
        assign in_ready = free_ok && !(in_scratch && scr_busy);
        assign i_take   = in_valid && in_ready;
    end
    assign in_fire  = i_take;
    assign busy     = (|c_busy) || (!BYP && (i_v || rs_valid));
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

    // Request stage (BYP = 0): the chosen request waits here for the grant.
    localparam bit PIPE = !BYP;
    logic            o_v, o_free;
    logic [CW-1:0]   o_sel;
    logic [NL-1:0]   o_mask;
    mkind_e          o_kind;
    logic [TW-1:0]   o_tag;
    logic [31:LINE_OFF] o_line;
    assign o_free    = !o_v || dmem_gnt;
    assign mreq_fire = mreq_valid && (PIPE ? o_free : dmem_gnt);

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

    if (PIPE) begin : g_oreg
        always_ff @(posedge clk) begin
            if (rst) begin
                o_v <= 1'b0;
            end else begin
                if (o_v && dmem_gnt) o_v <= 1'b0;
                if (mreq_fire)       o_v <= 1'b1;
            end
            if (mreq_fire) begin
                o_sel  <= sel;
                o_mask <= mreq_mask;
                o_kind <= mreq_kind;
                o_tag  <= alloc_t;
                o_line <= c_addr[sel][sel_lead*32 + LINE_OFF +: 32-LINE_OFF];
            end
        end
    end else begin : g_nooreg
        assign o_v    = 1'b0;
        assign o_sel  = '0;
        assign o_mask = '0;
        assign o_kind = MK_LOAD;
        assign o_tag  = '0;
        assign o_line = '0;
    end

    // The request on the port: the registered stage, or (BYP = 1) this cycle's choice.
    logic               q_v;
    logic [CW-1:0]      q_sel;
    logic [NL-1:0]      q_mask;
    mkind_e             q_kind;
    assign q_v    = PIPE ? o_v    : mreq_valid;
    assign q_sel  = PIPE ? o_sel  : sel;
    assign q_mask = PIPE ? o_mask : mreq_mask;
    assign q_kind = PIPE ? o_kind : mreq_kind;

    assign dmem_req  = q_v;
    assign dmem_tag  = PIPE ? o_tag : alloc_t;
    assign dmem_addr = !q_v ? 32'd0 :
                       PIPE ? {o_line, {LINE_OFF{1'b0}}}
                            : {c_addr[sel][sel_lead*32 + LINE_OFF +: 32-LINE_OFF], {LINE_OFF{1'b0}}};
    // Per lane of the request's context: word in the line, byte in the word, data.
    logic [LINE_WOFFW-1:0] s_woff [0:NL-1];
    logic [1:0]            s_bsel [0:NL-1];
    logic [31:0]           s_sd   [0:NL-1];
    always_comb
        for (int l = 0; l < NL; l++) begin
            s_woff[l] = c_addr[q_sel][l*32 + 2 +: LINE_WOFFW];
            s_bsel[l] = c_addr[q_sel][l*32 +: 2];
            s_sd[l]   = c_sdata[q_sel][l*32 +: 32];
        end
    always_comb begin
        dmem_wdata = '0;
        dmem_we    = 1'b0;
        dmem_be    = '0;
        if (q_v && (q_kind == MK_WRITE)) begin
            dmem_we = 1'b1;
            if (c_amo[q_sel]) begin
                dmem_wdata = a_line;
                for (int w = 0; w < LINE_WORDS; w++) dmem_be[w*4 +: 4] = {4{a_touch[w]}};
            end else begin
                for (int l = 0; l < NL; l++) begin
                    if (q_mask[l]) begin
                        unique case (c_f3[q_sel])
                            3'b000: begin  // sb
                                dmem_wdata[s_woff[l]*32 + s_bsel[l]*8 +: 8] = s_sd[l][7:0];
                                dmem_be[s_woff[l]*4 + s_bsel[l]]            = 1'b1;
                            end
                            3'b001: begin  // sh
                                if (s_bsel[l][1]) begin
                                    dmem_wdata[s_woff[l]*32 + 16 +: 16] = s_sd[l][15:0];
                                    dmem_be[s_woff[l]*4 + 2 +: 2]       = 2'b11;
                                end else begin
                                    dmem_wdata[s_woff[l]*32 +: 16] = s_sd[l][15:0];
                                    dmem_be[s_woff[l]*4 +: 2]      = 2'b11;
                                end
                            end
                            default: begin  // sw
                                dmem_wdata[s_woff[l]*32 +: 32] = s_sd[l];
                                dmem_be[s_woff[l]*4 +: 4]      = 4'b1111;
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
    assign rsp_byp = BYP && dmem_rvalid && !t_valid[dmem_rtag];
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
        logic [31:0] a_v [0:LINE_WORDS-1];   // operand of each word this round
        always_comb begin
            for (int l = 0; l < NL; l++) a_old[l] = a_line[a_off[l]*32 +: 32];
            for (int l = 0; l < NL; l++) begin
                a_rnd[l] = a_left[l];
                for (int j = 0; j < l; j++)
                    if (a_left[j] && (a_off[j] == a_off[l])) a_rnd[l] = 1'b0;
            end
            for (int w = 0; w < LINE_WORDS; w++) begin
                a_v[w]    = '0;
                a_whit[w] = 1'b0;
                for (int l = 0; l < NL; l++)
                    if (a_rnd[l] && (a_off[l] == LINE_WOFFW'(w))) begin
                        a_whit[w] = 1'b1;
                        a_v[w]    = a_v[w] | c_sdata[lock_c][l*32 +: 32];
                    end
                a_wnew[w] = amo_alu(c_amo_op[lock_c], a_line[w*32 +: 32], a_v[w]);
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
    //    With BYP = 0 a request sent this cycle is answered in a later cycle, so a
    //    context that sends cannot finish this cycle: it finishes when no lane is
    //    left to send (registered) and this cycle answers its last request.
    logic [NC-1:0] c_fin;            // finished this cycle or earlier
    logic [NL-1:0] c_sent [0:NC-1];  // lanes that leave c_pend this cycle
    logic [TW:0]   c_cnt_n [0:NC-1];
    logic [NC-1:0] c_here, c_rhere;  // request sent / answered for the context this cycle
    logic [NL-1:0] c_scs  [0:NC-1];  // the scratch lane served this cycle
    always_comb begin
        for (int c = 0; c < NC; c++) begin
            c_here[c]  = mreq_fire && (sel == CW'(c));
            c_rhere[c] = dmem_rvalid && (rc == CW'(c));
            c_scs[c]   = '0;
            if (sc_step && (sc_c == CW'(c))) c_scs[c][c_lead[c]] = 1'b1;
            c_sent[c] = '0;
            if (c_scratch[c])
                c_sent[c] = c_scs[c];
            else if (c_here[c] && !(c_amo[c] && (c_ph[c] != AP_WR)))
                c_sent[c] = mreq_mask;
            // c_cnt_n: per context in g_ctx below
            if (BYP)
                c_fin[c] = c_busy[c] &&
                           (c_done[c] || (((c_pend[c] & ~c_sent[c]) == '0) && (c_cnt_n[c] == '0)));
            else
                c_fin[c] = c_busy[c] &&
                           (c_done[c] || (((c_pend[c] & ~c_scs[c]) == '0) &&
                                          (c_rhere[c] ? (c_cnt[c] == 1) : (c_cnt[c] == 0))));
        end
    end

    logic [CW-1:0] rs_c;
    logic          rs_any;           // a context finishes (and is freed) this cycle
    always_comb begin
        rs_any = 1'b0;
        rs_c   = '0;
        for (int c = NC-1; c >= 0; c--)
            if (c_fin[c]) begin rs_any = 1'b1; rs_c = CW'(c); end
    end
    if (!BYP) begin : g_rsreg
        always_ff @(posedge clk) begin
            if (rst) rs_valid <= 1'b0;
            else     rs_valid <= rs_any;
            rs_w  <= c_w[rs_c];
            rs_pc <= c_pc[rs_c];
            rs_rd <= c_rd[rs_c];
            rs_fp <= c_fp[rs_c];
            rs_ld <= !c_store[rs_c] && !c_amo[rs_c];
        end
    end else begin : g_rscomb
        assign rs_valid = rs_any;
        assign rs_w  = c_w[rs_c];
        assign rs_pc = c_pc[rs_c];
        assign rs_rd = c_rd[rs_c];
        assign rs_fp = c_fp[rs_c];
        assign rs_ld = !c_store[rs_c] && !c_amo[rs_c];
    end

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
            assign last  = rs_any && (rs_c == CW'(gc));
            // Requests outstanding after this cycle. Written as two increments: Vivado
            // 2025.1 built c_cnt[c] + (TW+1)'(c_here[c] && !rsp_byp) - ... in a loop
            // over c as c_cnt[0] + c_here (all contexts' bits) for context 0, which no
            // simulator does, and context 0 then never finished (board hang).
            always_comb begin
                c_cnt_n[gc] = c_cnt[gc];
                if (here  && !rsp_byp) c_cnt_n[gc] = c_cnt_n[gc] + 1'b1;
                if (rhere && !rsp_byp) c_cnt_n[gc] = c_cnt_n[gc] - 1'b1;
            end
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
                    c_w[gc]        <= i_w;
                    c_pend[gc]     <= i_mask;
                    c_store[gc]    <= i_store;
                    c_scratch[gc]  <= i_scratch;
                    c_shared[gc]   <= i_shared;
                    c_fp[gc]       <= i_fp;
                    c_amo[gc]      <= i_amo;
                    c_amo_op[gc]   <= i_amo_op;
                    c_f3[gc]       <= i_f3;
                    c_rd[gc]       <= i_rd;
                    c_pc[gc]       <= i_npc;
                    c_cnt[gc]      <= '0;
                    c_ph[gc]       <= AP_RD;
                    for (int l = 0; l < NL; l++) c_addr[gc][l*32 +: 32]  <= i_addr[l];
                    for (int l = 0; l < NL; l++) c_sdata[gc][l*32 +: 32] <= i_sdata[l];
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

    // ── Debug window: contexts and tags (up to 16 contexts, 32 tags) ─────────────
    //   0: busy | done << 16      1: tags in use           2: lanes left | store << 16
    //   3: AMO | scratch << 16    4-7: requests outstanding per context (nibbles)
    //   8-11: warp per context (nibbles)    12: AMO phase per context (2 bits)
    //   13: {dmem_gnt, tag_ok, mreq_valid, rr}
    always_comb begin
        for (int i = 0; i < DBG_ME; i++) dbg_state[i] = '0;
        for (int c = 0; c < NC && c < 16; c++) begin
            dbg_state[0][c]      = c_busy[c];
            dbg_state[0][16 + c] = c_done[c];
            dbg_state[2][c]      = (c_pend[c] != '0);
            dbg_state[2][16 + c] = c_store[c];
            dbg_state[3][c]      = c_amo[c];
            dbg_state[3][16 + c] = c_scratch[c];
            dbg_state[4 + c/8][(c%8)*4 +: 4] = 4'(c_cnt[c]);
            dbg_state[8 + c/8][(c%8)*4 +: 4] = 4'(c_w[c]);
            dbg_state[12][c*2 +: 2]          = c_ph[c];
        end
        for (int t = 0; t < MQD && t < 32; t++) dbg_state[1][t] = t_valid[t];
        dbg_state[13] = {dmem_gnt, tag_ok, mreq_valid, 13'd0, 16'(rr)};
    end

`ifndef SYNTHESIS
    // BYP = 0 is only valid if every response belongs to an earlier request.
    always_ff @(posedge clk)
        if (!rst && !BYP && dmem_rvalid && !t_valid[dmem_rtag])
            $fatal(1, "mem_engine: response with tag %0d answers no outstanding request (BYP = 0)",
                   dmem_rtag);
`endif

endmodule : mem_engine
