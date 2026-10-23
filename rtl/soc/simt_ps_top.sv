// =============================================================================
// simt_ps_top.sv  -  SIMTiX v2 board top: the accelerator as a Zynq UltraScale+
//                     PS peripheral (ARM Cortex-A53 host, DDR4 data memory)
//
//   ARM (PS) --AXI4-Lite--> s_axil : command registers + kernel instruction RAM
//   simt_accel --> l1_dcache --> axi_line_master --AXI4--> m_axi : PS S_AXI_HP0
//
// AXI4-Lite map (byte offsets):
//   0x0000 - 0x00FF  command / status registers (mmio_regs, see simtix_pkg)
//   0x0100           R: L1 read hits of the last kernel
//   0x0104           R: L1 read misses of the last kernel
//   0x0108           R: bit 0 = AXI error response seen (sticky)
//   0x1000 - 0x1FFF  kernel instruction RAM, 1024 words (R/W); the kernel PC is
//                    an offset into it
//
// The host writes the kernel into the instruction RAM, places data in DDR4 (below
// 0x4000_0000: higher addresses with bits [31:30] = 01 are the accelerator's
// scratchpad apertures), writes the command registers, sets CTRL.GO and polls
// STATUS.DONE. Writing GO also invalidates the L1. The HP port is not coherent
// with the A53 caches, so the host cleans its data cache before GO and
// invalidates it before reading results.
// =============================================================================
`timescale 1ns/1ps
module simt_ps_top
  import simtix_pkg::*;
#(
    parameter int AXI_DW = 128,
    parameter int IRAM_WORDS = 1024
) (
    input  logic                clk,
    input  logic                rst,             // active-high

    // AXI4-Lite slave (host).
    input  logic [15:0]         s_axil_awaddr,
    input  logic                s_axil_awvalid,
    output logic                s_axil_awready,
    input  logic [31:0]         s_axil_wdata,
    /* verilator lint_off UNUSEDSIGNAL */   // the host writes whole words
    input  logic [3:0]          s_axil_wstrb,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                s_axil_wvalid,
    output logic                s_axil_wready,
    output logic [1:0]          s_axil_bresp,
    output logic                s_axil_bvalid,
    input  logic                s_axil_bready,
    input  logic [15:0]         s_axil_araddr,
    input  logic                s_axil_arvalid,
    output logic                s_axil_arready,
    output logic [31:0]         s_axil_rdata,
    output logic [1:0]          s_axil_rresp,
    output logic                s_axil_rvalid,
    input  logic                s_axil_rready,

    // AXI4 master (DDR4 through the PS).
    output logic [MEM_TAGW:0]   m_axi_awid,
    output logic [31:0]         m_axi_awaddr,
    output logic [7:0]          m_axi_awlen,
    output logic [2:0]          m_axi_awsize,
    output logic [1:0]          m_axi_awburst,
    output logic [3:0]          m_axi_awcache,
    output logic [2:0]          m_axi_awprot,
    output logic                m_axi_awvalid,
    input  logic                m_axi_awready,
    output logic [AXI_DW-1:0]   m_axi_wdata,
    output logic [AXI_DW/8-1:0] m_axi_wstrb,
    output logic                m_axi_wlast,
    output logic                m_axi_wvalid,
    input  logic                m_axi_wready,
    input  logic [MEM_TAGW:0]   m_axi_bid,
    input  logic [1:0]          m_axi_bresp,
    input  logic                m_axi_bvalid,
    output logic                m_axi_bready,
    output logic [MEM_TAGW:0]   m_axi_arid,
    output logic [31:0]         m_axi_araddr,
    output logic [7:0]          m_axi_arlen,
    output logic [2:0]          m_axi_arsize,
    output logic [1:0]          m_axi_arburst,
    output logic [3:0]          m_axi_arcache,
    output logic [2:0]          m_axi_arprot,
    output logic                m_axi_arvalid,
    input  logic                m_axi_arready,
    input  logic [MEM_TAGW:0]   m_axi_rid,
    input  logic [AXI_DW-1:0]   m_axi_rdata,
    input  logic [1:0]          m_axi_rresp,
    input  logic                m_axi_rlast,
    input  logic                m_axi_rvalid,
    output logic                m_axi_rready
);

    localparam int IAW = $clog2(IRAM_WORDS);

    // ── AXI4-Lite slave: one write and one read at a time; writes win a tie ─────
    logic        wr_fire, rd_fire;
    logic [15:0] rd_addr;
    assign wr_fire        = s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid;
    assign s_axil_awready = wr_fire;
    assign s_axil_wready  = wr_fire;
    assign rd_fire        = s_axil_arvalid && !s_axil_rvalid && !wr_fire;
    assign s_axil_arready = rd_fire;
    assign s_axil_bresp   = 2'b00;
    assign s_axil_rresp   = 2'b00;
    assign rd_addr        = s_axil_araddr;

    logic wr_iram, wr_regs;
    assign wr_iram = wr_fire && s_axil_awaddr[12];
    assign wr_regs = wr_fire && (s_axil_awaddr[15:8] == 8'h00);

    // Kernel instruction RAM: host writes words, the accelerator fetches
    // asynchronously (distributed RAM).
    (* ram_style = "distributed" *)
    logic [31:0] iram [0:IRAM_WORDS-1];
    /* verilator lint_off UNUSEDSIGNAL */   // only the RAM's word index is used
    logic [31:0] imem_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] imem_data;
    always_ff @(posedge clk)
        if (wr_iram) iram[s_axil_awaddr[IAW+1:2]] <= s_axil_wdata;
    assign imem_data = iram[imem_addr[IAW+1:2]];

    // ── Accelerator ─────────────────────────────────────────────────────────────
    logic [31:0]          acc_rdata;
    logic                 a_req, a_gnt, a_we, a_rvalid;
    logic [MEM_TAGW-1:0]  a_tag, a_rtag;
    logic [31:0]          a_addr;
    logic [LINE_BITS-1:0] a_wdata, a_rdata;
    logic [LINE_BE-1:0]   a_be;

    simt_accel u_accel (
        .clk        (clk),
        .rst        (rst),
        .sel        (wr_regs || (rd_fire && (rd_addr[15:8] == 8'h00))),
        .we         (wr_regs),
        .offset     (wr_regs ? s_axil_awaddr[7:0] : rd_addr[7:0]),
        .wdata      (s_axil_wdata),
        .rdata      (acc_rdata),
        .imem_addr  (imem_addr),
        .imem_data  (imem_data),
        .dmem_req   (a_req),
        .dmem_gnt   (a_gnt),
        .dmem_tag   (a_tag),
        .dmem_addr  (a_addr),
        .dmem_wdata (a_wdata),
        .dmem_we    (a_we),
        .dmem_be    (a_be),
        .dmem_rvalid(a_rvalid),
        .dmem_rtag  (a_rtag),
        .dmem_rdata (a_rdata)
    );

    // GO (CTRL bit 0) invalidates the L1 as the kernel launches.
    logic go_wr;
    assign go_wr = wr_regs && (s_axil_awaddr[7:0] == REG_CTRL) && s_axil_wdata[CTRL_GO_BIT];

    // ── L1 data cache and AXI4 master ───────────────────────────────────────────
    logic                 c_req, c_gnt, c_we, c_rvalid;
    logic [MEM_TAGW:0]    c_tag, c_rtag;
    logic [31:0]          c_addr;
    logic [LINE_BITS-1:0] c_wdata, c_rdata;
    logic [LINE_BE-1:0]   c_be;
    logic                 hit_ev, miss_ev, axi_err;

    l1_dcache u_l1 (
        .clk(clk), .rst(rst), .inv(go_wr),
        .s_req(a_req), .s_gnt(a_gnt), .s_tag(a_tag), .s_addr(a_addr),
        .s_we(a_we), .s_wdata(a_wdata), .s_be(a_be),
        .s_rvalid(a_rvalid), .s_rtag(a_rtag), .s_rdata(a_rdata),
        .m_req(c_req), .m_gnt(c_gnt), .m_tag(c_tag), .m_addr(c_addr),
        .m_we(c_we), .m_wdata(c_wdata), .m_be(c_be),
        .m_rvalid(c_rvalid), .m_rtag(c_rtag), .m_rdata(c_rdata),
        .hit_ev(hit_ev), .miss_ev(miss_ev)
    );

    axi_line_master #(.IDW(MEM_TAGW + 1), .DW(AXI_DW)) u_axi (
        .clk(clk), .rst(rst),
        .s_req(c_req), .s_gnt(c_gnt), .s_tag(c_tag), .s_addr(c_addr),
        .s_we(c_we), .s_wdata(c_wdata), .s_be(c_be),
        .s_rvalid(c_rvalid), .s_rtag(c_rtag), .s_rdata(c_rdata), .err(axi_err),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    // L1 counters of the last kernel (cleared by GO).
    logic [31:0] n_hits, n_misses;
    always_ff @(posedge clk) begin
        if (rst || go_wr) begin
            n_hits   <= '0;
            n_misses <= '0;
        end else begin
            if (hit_ev)  n_hits   <= n_hits + 32'd1;
            if (miss_ev) n_misses <= n_misses + 32'd1;
        end
    end

    // ── Read data / write response ──────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            s_axil_bvalid <= 1'b0;
            s_axil_rvalid <= 1'b0;
        end else begin
            if (wr_fire)                        s_axil_bvalid <= 1'b1;
            else if (s_axil_bready)             s_axil_bvalid <= 1'b0;
            if (rd_fire)                        s_axil_rvalid <= 1'b1;
            else if (s_axil_rready)             s_axil_rvalid <= 1'b0;
        end
    end
    always_ff @(posedge clk)
        if (rd_fire) begin
            if (rd_addr[12])                    s_axil_rdata <= iram[rd_addr[IAW+1:2]];
            else if (rd_addr[15:8] == 8'h00)    s_axil_rdata <= acc_rdata;
            else if (rd_addr[7:0] == 8'h00)     s_axil_rdata <= n_hits;
            else if (rd_addr[7:0] == 8'h04)     s_axil_rdata <= n_misses;
            else if (rd_addr[7:0] == 8'h08)     s_axil_rdata <= {31'd0, axi_err};
            else                                s_axil_rdata <= 32'd0;
        end

endmodule : simt_ps_top
