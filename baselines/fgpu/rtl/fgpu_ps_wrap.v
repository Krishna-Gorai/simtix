// fgpu_ps_wrap.v - Verilog-2001 wrapper of FGPU (github.com/malkadi/FGPU, VHDL, GPL v3; its
// sources stay outside this repository) for a ZCU102 block design, as baselines/vortex's
// vortex_ps_wrap.v. Our own code; it mirrors FGPU's IP top (HW/sources/IPs/FGPU_3.0/hdl/
// FGPU_v3_0.vhd): a 16-bit byte address of which FGPU takes bits 15:2, the master's fixed
// cache/prot/lock/qos values, and nrst = aresetn.
//
//   s_axi : AXI4-Lite slave, A53 host (FGPU's map, byte offsets):
//             0x0000 kernel descriptors (32 words per kernel), 0x4000 code RAM,
//             0x8000 STATUS (read), 0x8004 START, 0x8008 CLEAN_CACHE, 0x800C INITIATE
//   m_axi : FGPU's m0, AXI4 master, 64-bit data, 6-bit ID, 32-bit address, to DDR4 through
//           S_AXI_HP0_FPD. FGPU's m1..m3 are unused (N_AXI_W = 0) and tied off.
//
// Fixed widths, no parameters (cf. the SIMTiX IDW lesson with block-design module refs).
`timescale 1ns/1ps
module fgpu_ps_wrap (
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
    output wire [63:0]   m_axi_wdata,
    output wire [7:0]    m_axi_wstrb,
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
    input  wire [63:0]   m_axi_rdata,
    input  wire [1:0]    m_axi_rresp,
    input  wire          m_axi_rlast,
    input  wire          m_axi_rvalid,
    output wire          m_axi_rready
);
    // fixed attributes, as FGPU_v3_0.vhd
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0010;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awqos   = 4'h0;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0010;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'h0;

    FGPU u_fgpu (
        .clk          (clk),
        .nrst         (aresetn),
        .s0_awaddr    (s_axi_awaddr[15:2]),
        .s0_awprot    (s_axi_awprot),
        .s0_awvalid   (s_axi_awvalid),
        .s0_awready   (s_axi_awready),
        .s0_wdata     (s_axi_wdata),
        .s0_wstrb     (s_axi_wstrb),
        .s0_wvalid    (s_axi_wvalid),
        .s0_wready    (s_axi_wready),
        .s0_bresp     (s_axi_bresp),
        .s0_bvalid    (s_axi_bvalid),
        .s0_bready    (s_axi_bready),
        .s0_araddr    (s_axi_araddr[15:2]),
        .s0_arprot    (s_axi_arprot),
        .s0_arvalid   (s_axi_arvalid),
        .s0_arready   (s_axi_arready),
        .s0_rdata     (s_axi_rdata),
        .s0_rresp     (s_axi_rresp),
        .s0_rvalid    (s_axi_rvalid),
        .s0_rready    (s_axi_rready),

        .m0_araddr    (m_axi_araddr),
        .m0_arlen     (m_axi_arlen),
        .m0_arsize    (m_axi_arsize),
        .m0_arburst   (m_axi_arburst),
        .m0_arvalid   (m_axi_arvalid),
        .m0_arready   (m_axi_arready),
        .m0_arid      (m_axi_arid),
        .m0_rdata     (m_axi_rdata),
        .m0_rresp     (m_axi_rresp),
        .m0_rlast     (m_axi_rlast),
        .m0_rvalid    (m_axi_rvalid),
        .m0_rready    (m_axi_rready),
        .m0_rid       (m_axi_rid),
        .m0_awaddr    (m_axi_awaddr),
        .m0_awvalid   (m_axi_awvalid),
        .m0_awready   (m_axi_awready),
        .m0_awlen     (m_axi_awlen),
        .m0_awsize    (m_axi_awsize),
        .m0_awburst   (m_axi_awburst),
        .m0_awid      (m_axi_awid),
        .m0_wdata     (m_axi_wdata),
        .m0_wstrb     (m_axi_wstrb),
        .m0_wlast     (m_axi_wlast),
        .m0_wvalid    (m_axi_wvalid),
        .m0_wready    (m_axi_wready),
        .m0_bvalid    (m_axi_bvalid),
        .m0_bready    (m_axi_bready),
        .m0_bid       (m_axi_bid),

        // m1..m3: unused (N_AXI_W = 0), inputs tied off
        .m1_arready (1'b0), .m1_rdata (64'd0), .m1_rresp (2'b00), .m1_rlast (1'b0),
        .m1_rvalid (1'b0), .m1_rid (6'd0), .m1_awready (1'b0), .m1_wready (1'b0),
        .m1_bvalid (1'b0), .m1_bid (6'd0),
        .m2_arready (1'b0), .m2_rdata (64'd0), .m2_rresp (2'b00), .m2_rlast (1'b0),
        .m2_rvalid (1'b0), .m2_rid (6'd0), .m2_awready (1'b0), .m2_wready (1'b0),
        .m2_bvalid (1'b0), .m2_bid (6'd0),
        .m3_arready (1'b0), .m3_rdata (64'd0), .m3_rresp (2'b00), .m3_rlast (1'b0),
        .m3_rvalid (1'b0), .m3_rid (6'd0), .m3_awready (1'b0), .m3_wready (1'b0),
        .m3_bvalid (1'b0), .m3_bid (6'd0)
    );
endmodule
