// =============================================================================
// axi_line_master.sv  -  SIMTiX v2: tagged line port -> AXI4 master
//
// Turns the line-wide, tagged, split-transaction port (the memory side of
// l1_dcache) into AXI4 transactions for a DW-bit slave such as the Zynq
// UltraScale+ S_AXI_HP ports into DDR4. A line (LINE_BITS) is one INCR burst of
// NB = LINE_BITS / DW beats; the request tag is the AXI ID, so reads with
// different tags may complete in any order (as the line protocol allows).
//
//   read  : AR (ARID = tag) -> NB beats on R -> one line response, tag = RID
//   write : AW + NB beats on W (WSTRB from the byte enables) -> B -> response,
//           tag = BID
//
// One read and one write may wait in staging registers for their address
// channel; a new request of the same kind is granted once its stage is free.
// AXI4 allows read beats of different IDs to interleave, so beats are
// collected per ID. A line response goes up on the last read beat or on a write
// response; when both arrive together the read goes first and BREADY holds the
// write response for a cycle. err is set on any SLVERR / DECERR response.
// =============================================================================
module axi_line_master
  import simtix_pkg::*;
#(
    parameter int IDW = MEM_TAGW + 1,           // tag / AXI ID width
    parameter int DW  = 128                     // AXI data width
) (
    input  logic                  clk,
    input  logic                  rst,

    // Line side (from the L1).
    input  logic                  s_req,
    output logic                  s_gnt,
    input  logic [IDW-1:0]        s_tag,
    input  logic [31:0]           s_addr,
    input  logic                  s_we,
    input  logic [LINE_BITS-1:0]  s_wdata,
    input  logic [LINE_BE-1:0]    s_be,
    output logic                  s_rvalid,
    output logic [IDW-1:0]        s_rtag,
    output logic [LINE_BITS-1:0]  s_rdata,
    output logic                  err,

    // AXI4 master.
    output logic [IDW-1:0]        m_axi_awid,
    output logic [31:0]           m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic [3:0]            m_axi_awcache,
    output logic [2:0]            m_axi_awprot,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [DW-1:0]         m_axi_wdata,
    output logic [DW/8-1:0]       m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    input  logic [IDW-1:0]        m_axi_bid,
    /* verilator lint_off UNUSEDSIGNAL */   // bit 0 (EXOKAY) does not matter
    input  logic [1:0]            m_axi_bresp,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    output logic [IDW-1:0]        m_axi_arid,
    output logic [31:0]           m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic [3:0]            m_axi_arcache,
    output logic [2:0]            m_axi_arprot,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    input  logic [IDW-1:0]        m_axi_rid,
    input  logic [DW-1:0]         m_axi_rdata,
    /* verilator lint_off UNUSEDSIGNAL */   // bit 0 (EXOKAY) does not matter
    input  logic [1:0]            m_axi_rresp,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready
);

    localparam int NB  = LINE_BITS / DW;         // beats per line
    localparam int BW  = (NB > 1) ? $clog2(NB) : 1;
    localparam int NID = 1 << IDW;

    // Fixed burst attributes: INCR bursts of NB beats of DW bits, normal
    // non-cacheable bufferable memory, unprivileged secure data access.
    assign m_axi_awlen   = 8'(NB - 1);
    assign m_axi_arlen   = 8'(NB - 1);
    assign m_axi_awsize  = 3'($clog2(DW / 8));
    assign m_axi_arsize  = 3'($clog2(DW / 8));
    assign m_axi_awburst = 2'b01;
    assign m_axi_arburst = 2'b01;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_arprot  = 3'b000;

    // ── Staging ──────────────────────────────────────────────────────────────────
    logic                 ar_v;                  // read waiting for AR
    logic                 aw_v, w_v;             // write waiting for AW / its W beats
    logic [BW-1:0]        w_beat;
    logic [LINE_BITS-1:0] w_data;
    logic [LINE_BE-1:0]   w_be;

    assign s_gnt = s_we ? (!aw_v && !w_v) : !ar_v;

    assign m_axi_arvalid = ar_v;
    assign m_axi_awvalid = aw_v;
    assign m_axi_wvalid  = w_v;
    assign m_axi_wdata   = w_data[w_beat*DW +: DW];
    assign m_axi_wstrb   = w_be[w_beat*(DW/8) +: DW/8];
    assign m_axi_wlast   = (w_beat == BW'(NB - 1));

    always_ff @(posedge clk) begin
        if (rst) begin
            ar_v   <= 1'b0;
            aw_v   <= 1'b0;
            w_v    <= 1'b0;
            w_beat <= '0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) ar_v <= 1'b0;
            if (m_axi_awvalid && m_axi_awready) aw_v <= 1'b0;
            if (m_axi_wvalid && m_axi_wready) begin
                w_beat <= w_beat + 1'b1;
                if (m_axi_wlast) begin w_v <= 1'b0; w_beat <= '0; end
            end
            if (s_req && s_gnt) begin
                if (s_we) begin
                    aw_v   <= 1'b1;
                    w_v    <= 1'b1;
                    w_beat <= '0;
                end else begin
                    ar_v   <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk)
        if (s_req && s_gnt) begin
            if (s_we) begin
                m_axi_awid   <= s_tag;
                m_axi_awaddr <= s_addr;
                w_data       <= s_wdata;
                w_be         <= s_be;
            end else begin
                m_axi_arid   <= s_tag;
                m_axi_araddr <= s_addr;
            end
        end

    // ── Responses ────────────────────────────────────────────────────────────────
    // Earlier beats of each ID's burst wait here; the last beat completes the line.
    logic [LINE_BITS-1:0] rbuf [0:NID-1];
    logic [BW-1:0]        rcnt [0:NID-1];
    logic                 r_done;
    assign m_axi_rready = 1'b1;
    assign r_done       = m_axi_rvalid && m_axi_rlast;
    assign m_axi_bready = !r_done;

    always_comb begin
        s_rdata = rbuf[m_axi_rid];
        s_rdata[(NB-1)*DW +: DW] = m_axi_rdata;
    end
    assign s_rvalid = r_done || m_axi_bvalid;
    assign s_rtag   = r_done ? m_axi_rid : m_axi_bid;

    always_ff @(posedge clk) begin
        if (rst) begin
            err <= 1'b0;
            for (int i = 0; i < NID; i++) rcnt[i] <= '0;
        end else begin
            if (m_axi_rvalid) begin
                rbuf[m_axi_rid][rcnt[m_axi_rid]*DW +: DW] <= m_axi_rdata;
                rcnt[m_axi_rid] <= m_axi_rlast ? '0 : rcnt[m_axi_rid] + 1'b1;
                if (m_axi_rresp[1]) err <= 1'b1;
            end
            if (m_axi_bvalid && m_axi_bready && m_axi_bresp[1]) err <= 1'b1;
        end
    end

endmodule : axi_line_master
