// vortex_ps_wrap.v - Verilog-2001 wrapper of vortex_ps_top for a Vivado block design (a
// module reference must have a Verilog top). Vortex 3.0, 1 core, 8 warps x 8 threads.
//
//   s_axi : AXI4-Lite slave (A53 host registers, see vortex_ps_top.sv)
//   m_axi : AXI4 master, 128-bit data, 6-bit ID (always 0), to DDR4 through S_AXI_HP0_FPD
//
// No parameters: the widths are fixed here, so the block design cannot evaluate them
// differently from synthesis (cf. the SIMTiX IDW lesson).
`timescale 1ns/1ps
module vortex_ps_wrap (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axi, ASSOCIATED_RESET aresetn" *)
    input  wire          clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          aresetn,

    input  wire [15:0]   s_axi_awaddr,
    input  wire [2:0]    s_axi_awprot,
    input  wire          s_axi_awvalid,
    output wire          s_axi_awready,
    input  wire [31:0]   s_axi_wdata,
    input  wire [3:0]    s_axi_wstrb,
    input  wire          s_axi_wvalid,
    output wire          s_axi_wready,
    output wire [1:0]    s_axi_bresp,
    output wire          s_axi_bvalid,
    input  wire          s_axi_bready,
    input  wire [15:0]   s_axi_araddr,
    input  wire [2:0]    s_axi_arprot,
    input  wire          s_axi_arvalid,
    output wire          s_axi_arready,
    output wire [31:0]   s_axi_rdata,
    output wire [1:0]    s_axi_rresp,
    output wire          s_axi_rvalid,
    input  wire          s_axi_rready,

    output wire [5:0]    m_axi_awid,
    output wire [31:0]   m_axi_awaddr,
    output wire [7:0]    m_axi_awlen,
    output wire [2:0]    m_axi_awsize,
    output wire [1:0]    m_axi_awburst,
    output wire          m_axi_awlock,
    output wire [3:0]    m_axi_awcache,
    output wire [2:0]    m_axi_awprot,
    output wire [3:0]    m_axi_awqos,
    output wire          m_axi_awvalid,
    input  wire          m_axi_awready,
    output wire [127:0]  m_axi_wdata,
    output wire [15:0]   m_axi_wstrb,
    output wire          m_axi_wlast,
    output wire          m_axi_wvalid,
    input  wire          m_axi_wready,
    input  wire [5:0]    m_axi_bid,
    input  wire [1:0]    m_axi_bresp,
    input  wire          m_axi_bvalid,
    output wire          m_axi_bready,
    output wire [5:0]    m_axi_arid,
    output wire [31:0]   m_axi_araddr,
    output wire [7:0]    m_axi_arlen,
    output wire [2:0]    m_axi_arsize,
    output wire [1:0]    m_axi_arburst,
    output wire          m_axi_arlock,
    output wire [3:0]    m_axi_arcache,
    output wire [2:0]    m_axi_arprot,
    output wire [3:0]    m_axi_arqos,
    output wire          m_axi_arvalid,
    input  wire          m_axi_arready,
    input  wire [5:0]    m_axi_rid,
    input  wire [127:0]  m_axi_rdata,
    input  wire [1:0]    m_axi_rresp,
    input  wire          m_axi_rlast,
    input  wire          m_axi_rvalid,
    output wire          m_axi_rready
  );

  vortex_ps_top #(.DW(128), .EXT_IDW(6), .DDRBase(32'h4000_0000)) i_top (
    .clk       (clk),           .aresetn   (aresetn),
    .s_awaddr  (s_axi_awaddr),  .s_awvalid (s_axi_awvalid), .s_awready (s_axi_awready),
    .s_wdata   (s_axi_wdata),   .s_wstrb   (s_axi_wstrb),   .s_wvalid  (s_axi_wvalid),
    .s_wready  (s_axi_wready),  .s_bresp   (s_axi_bresp),   .s_bvalid  (s_axi_bvalid),
    .s_bready  (s_axi_bready),  .s_araddr  (s_axi_araddr),  .s_arvalid (s_axi_arvalid),
    .s_arready (s_axi_arready), .s_rdata   (s_axi_rdata),   .s_rresp   (s_axi_rresp),
    .s_rvalid  (s_axi_rvalid),  .s_rready  (s_axi_rready),
    .m_awid    (m_axi_awid),    .m_awaddr  (m_axi_awaddr),  .m_awlen   (m_axi_awlen),
    .m_awsize  (m_axi_awsize),  .m_awburst (m_axi_awburst), .m_awlock  (m_axi_awlock),
    .m_awcache (m_axi_awcache), .m_awprot  (m_axi_awprot),  .m_awqos   (m_axi_awqos),
    .m_awvalid (m_axi_awvalid), .m_awready (m_axi_awready),
    .m_wdata   (m_axi_wdata),   .m_wstrb   (m_axi_wstrb),   .m_wlast   (m_axi_wlast),
    .m_wvalid  (m_axi_wvalid),  .m_wready  (m_axi_wready),
    .m_bid     (m_axi_bid),     .m_bresp   (m_axi_bresp),   .m_bvalid  (m_axi_bvalid),
    .m_bready  (m_axi_bready),
    .m_arid    (m_axi_arid),    .m_araddr  (m_axi_araddr),  .m_arlen   (m_axi_arlen),
    .m_arsize  (m_axi_arsize),  .m_arburst (m_axi_arburst), .m_arlock  (m_axi_arlock),
    .m_arcache (m_axi_arcache), .m_arprot  (m_axi_arprot),  .m_arqos   (m_axi_arqos),
    .m_arvalid (m_axi_arvalid), .m_arready (m_axi_arready),
    .m_rid     (m_axi_rid),     .m_rdata   (m_axi_rdata),   .m_rresp   (m_axi_rresp),
    .m_rlast   (m_axi_rlast),   .m_rvalid  (m_axi_rvalid),  .m_rready  (m_axi_rready)
  );

endmodule
