// ara_ps_top.sv - Ara + CVA6 as a Zynq UltraScale+ PS peripheral (ZCU102)
//
// Derived from Ara's hardware/src/ara_soc.sv (pulp-platform/ara, SHL-0.51): the same
// ara_system (CVA6 + Ara), crossbar, control registers and UART path. Changes for the
// board:
//   - L2 slave (axi_to_mem + tc_sram) replaced by an AXI4 master port, m_*, to the PS
//     DDR4 through S_AXI_HP0_FPD. Ara's DRAM window [0x8000_0000, +DRAMLength) maps to
//     DDR [DDRBase, +DRAMLength); the atomic filter stays (the HP port has no ATOPs).
//   - UART: the APB side is terminated here; every byte the program writes to
//     0xC000_0000 (fake_uart) is stored in a 2 KB buffer the host can read.
//   - Host AXI4-Lite slave, s_* (A53 through M_AXI_HPM0_FPD): run/reset of the core,
//     completion, exit code, cycle counters, the UART buffer.
//
// Host registers (byte offsets, 32-bit):
//   0x00 CTRL     rw  bit 0 run: 0 holds ara_system in reset, 1 releases it (boots at
//                     0x8000_0000). Set it to 0 only after STATUS.done.
//   0x04 STATUS   ro  bit 0 done (exit written, all DDR writes answered, then 64 quiet
//                     cycles), bit 1 exit written, bit 2 running
//   0x08 EXIT     ro  value the program wrote to its exit register (0 = success)
//   0x0C/0x10     ro  CYCLES lo/hi: cycles from the reset release to the exit write
//   0x14/0x18     ro  HWCNT lo/hi: of these, cycles with hw_cnt_en[0] set
//   0x1C UARTCNT  ro  bytes written to the UART (the buffer keeps the first 2048)
//   0x20 INFO     ro  {8'hA7, NrLanes[7:0], VLEN[15:0]}
//   0x24 WROUT    ro  DDR writes issued and not yet answered
//   0x28..0x34    ro  AR, AW, R-last, B handshakes on the DDR port (debug)
//   0x1000-0x17FC ro  UART buffer, little-endian bytes
//
// CVA6's data cache is write-through (cv64a6_imafdcv_sv39), so results reach DDR
// without a flush; the 64 quiet cycles after the exit write cover stores still in its
// write buffer or in Ara's store unit.
module ara_ps_top import axi_pkg::*; import ara_pkg::*; #(
    parameter  int           unsigned NrLanes      = 2,
    parameter  int           unsigned VLEN         = 1024 * NrLanes,
    parameter  int           unsigned OSSupport    = 1,
    parameter  fpu_support_e          FPUSupport   = FPUSupportHalfSingleDouble,
    parameter  fpext_support_e        FPExtSupport = FPExtSupportEnable,
    parameter  fixpt_support_e        FixPtSupport = FixedPointEnable,
    parameter  seg_support_e          SegSupport   = SegSupportEnable,
    parameter  int           unsigned AxiDataWidth = 32*NrLanes,
    parameter  int           unsigned AxiAddrWidth = 64,
    parameter  int           unsigned AxiUserWidth = 1,
    parameter  int           unsigned AxiIdWidth   = 5,
    // DDR window seen by Ara at 0x8000_0000
    parameter  logic         [63:0]   DDRBase      = 64'h4000_0000,
    parameter  logic         [63:0]   DRAMLength   = 64'h1000_0000,
    localparam int           unsigned StrbW        = AxiDataWidth / 8
  ) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    // Host AXI4-Lite slave (16-bit address, 32-bit data)
    input  logic [15:0]             s_awaddr,
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [31:0]             s_wdata,
    input  logic [3:0]              s_wstrb,
    input  logic                    s_wvalid,
    output logic                    s_wready,
    output logic [1:0]              s_bresp,
    output logic                    s_bvalid,
    input  logic                    s_bready,
    input  logic [15:0]             s_araddr,
    input  logic                    s_arvalid,
    output logic                    s_arready,
    output logic [31:0]             s_rdata,
    output logic [1:0]              s_rresp,
    output logic                    s_rvalid,
    input  logic                    s_rready,
    // DDR AXI4 master
    output logic [AxiIdWidth-1:0]   m_awid,
    output logic [31:0]             m_awaddr,
    output logic [7:0]              m_awlen,
    output logic [2:0]              m_awsize,
    output logic [1:0]              m_awburst,
    output logic                    m_awlock,
    output logic [3:0]              m_awcache,
    output logic [2:0]              m_awprot,
    output logic [3:0]              m_awqos,
    output logic                    m_awvalid,
    input  logic                    m_awready,
    output logic [AxiDataWidth-1:0] m_wdata,
    output logic [StrbW-1:0]        m_wstrb,
    output logic                    m_wlast,
    output logic                    m_wvalid,
    input  logic                    m_wready,
    input  logic [AxiIdWidth-1:0]   m_bid,
    input  logic [1:0]              m_bresp,
    input  logic                    m_bvalid,
    output logic                    m_bready,
    output logic [AxiIdWidth-1:0]   m_arid,
    output logic [31:0]             m_araddr,
    output logic [7:0]              m_arlen,
    output logic [2:0]              m_arsize,
    output logic [1:0]              m_arburst,
    output logic                    m_arlock,
    output logic [3:0]              m_arcache,
    output logic [2:0]              m_arprot,
    output logic [3:0]              m_arqos,
    output logic                    m_arvalid,
    input  logic                    m_arready,
    input  logic [AxiIdWidth-1:0]   m_rid,
    input  logic [AxiDataWidth-1:0] m_rdata,
    input  logic [1:0]              m_rresp,
    input  logic                    m_rlast,
    input  logic                    m_rvalid,
    output logic                    m_rready
  );

  `include "axi/assign.svh"
  `include "axi/typedef.svh"
  `include "common_cells/registers.svh"
  `include "apb/typedef.svh"
  `include "ara/intf_typedef.svh"

  localparam type axi_data_t = logic [AxiDataWidth-1:0];
  localparam type axi_strb_t = logic [AxiDataWidth/8-1:0];
  localparam type axi_addr_t = logic [AxiAddrWidth-1:0];
  localparam type axi_user_t = logic [AxiUserWidth-1:0];
  localparam type axi_id_t   = logic [AxiIdWidth-1:0];

  ////////////////////////////////
  //  Host registers and reset  //
  ////////////////////////////////

  logic        run_q;          // CTRL.run
  logic        core_rst_nq;    // reset of ara_system and its interconnect
  logic [63:0] exit_o;         // from ctrl_registers: {exit, write pulse}
  logic [63:0] hw_cnt_en_o;
  logic        exit_seen_q, done_q;
  logic [31:0] exit_val_q;
  logic [63:0] cycles_q, hwcnt_q;
  logic [6:0]  quiet_q;
  logic [7:0]  wr_out_q;
  logic [31:0] n_ar_q, n_aw_q, n_r_q, n_b_q;
  logic [31:0] ucnt_q;
  logic [31:0] ubuf [512];     // UART buffer, 2 KB

  // UART byte from the APB side (below)
  logic        uart_we;
  logic [7:0]  uart_byte;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) core_rst_nq <= 1'b0;
    else         core_rst_nq <= run_q;
  end

  // Completion, counters
  wire aw_hs = m_awvalid && m_awready;
  wire b_hs  = m_bvalid  && m_bready;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      exit_seen_q <= 1'b0; done_q <= 1'b0; exit_val_q <= '0;
      cycles_q <= '0; hwcnt_q <= '0; quiet_q <= '0; wr_out_q <= '0;
      n_ar_q <= '0; n_aw_q <= '0; n_r_q <= '0; n_b_q <= '0; ucnt_q <= '0;
    end else if (!core_rst_nq) begin
      // New run: clear the run state (the core is held in reset)
      exit_seen_q <= 1'b0; done_q <= 1'b0; exit_val_q <= '0;
      cycles_q <= '0; hwcnt_q <= '0; quiet_q <= '0; wr_out_q <= '0;
      n_ar_q <= '0; n_aw_q <= '0; n_r_q <= '0; n_b_q <= '0; ucnt_q <= '0;
    end else begin
      if (exit_o[0] && !exit_seen_q) begin
        exit_seen_q <= 1'b1;
        exit_val_q  <= exit_o[32:1];
      end
      if (!exit_seen_q) begin
        cycles_q <= cycles_q + 64'd1;
        if (hw_cnt_en_o[0]) hwcnt_q <= hwcnt_q + 64'd1;
      end
      wr_out_q <= wr_out_q + 8'(aw_hs) - 8'(b_hs);
      if (!exit_seen_q || wr_out_q != '0 || m_awvalid || m_wvalid || m_arvalid)
        quiet_q <= '0;
      else if (!quiet_q[6])
        quiet_q <= quiet_q + 7'd1;
      if (quiet_q[6]) done_q <= 1'b1;
      if (m_arvalid && m_arready) n_ar_q <= n_ar_q + 1;
      if (aw_hs)                  n_aw_q <= n_aw_q + 1;
      if (m_rvalid && m_rready && m_rlast) n_r_q <= n_r_q + 1;
      if (b_hs)                   n_b_q  <= n_b_q + 1;
      if (uart_we)                ucnt_q <= ucnt_q + 1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (uart_we && ucnt_q < 32'd2048)
      for (int b = 0; b < 4; b++)
        if (ucnt_q[1:0] == 2'(b)) ubuf[ucnt_q[10:2]][8*b +: 8] <= uart_byte;
  end

  // AXI4-Lite slave: one write and one read at a time
  wire s_w_go = s_awvalid && s_wvalid && !s_bvalid;
  assign s_awready = s_w_go;
  assign s_wready  = s_w_go;
  assign s_bresp   = 2'b00;
  assign s_rresp   = 2'b00;
  assign s_arready = !s_rvalid;

  logic [31:0] ubuf_q;
  always_ff @(posedge clk_i) begin
    if (s_arvalid && s_arready) ubuf_q <= ubuf[s_araddr[10:2]];
  end

  logic        rsel_buf_q;
  logic [31:0] rreg_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      run_q <= 1'b0; s_bvalid <= 1'b0; s_rvalid <= 1'b0; rsel_buf_q <= 1'b0; rreg_q <= '0;
    end else begin
      if (s_w_go) begin
        s_bvalid <= 1'b1;
        if (s_awaddr[12:0] == 13'h000 && s_wstrb[0]) run_q <= s_wdata[0];
      end else if (s_bready) begin
        s_bvalid <= 1'b0;
      end
      if (s_arvalid && s_arready) begin
        s_rvalid   <= 1'b1;
        rsel_buf_q <= s_araddr[12];
        unique case (s_araddr[7:0])
          8'h00:   rreg_q <= {31'b0, run_q};
          8'h04:   rreg_q <= {29'b0, run_q && !exit_seen_q, exit_seen_q, done_q};
          8'h08:   rreg_q <= exit_val_q;
          8'h0C:   rreg_q <= cycles_q[31:0];
          8'h10:   rreg_q <= cycles_q[63:32];
          8'h14:   rreg_q <= hwcnt_q[31:0];
          8'h18:   rreg_q <= hwcnt_q[63:32];
          8'h1C:   rreg_q <= ucnt_q;
          8'h20:   rreg_q <= {8'hA7, 8'(NrLanes), 16'(VLEN)};
          8'h24:   rreg_q <= {24'b0, wr_out_q};
          8'h28:   rreg_q <= n_ar_q;
          8'h2C:   rreg_q <= n_aw_q;
          8'h30:   rreg_q <= n_r_q;
          8'h34:   rreg_q <= n_b_q;
          default: rreg_q <= 32'hDEAD_BEEF;
        endcase
      end else if (s_rready) begin
        s_rvalid <= 1'b0;
      end
    end
  end
  assign s_rdata = rsel_buf_q ? ubuf_q : rreg_q;

  //////////////////////
  //  Memory Regions  //
  //////////////////////

  localparam NrAXIMasters = 1;

  typedef enum int unsigned {
    L2MEM = 0,
    UART  = 1,
    CTRL  = 2
  } axi_slaves_e;
  localparam NrAXISlaves = CTRL + 1;

  localparam logic [63:0] UARTLength = 64'h1000;
  localparam logic [63:0] CTRLLength = 64'h1000;

  typedef enum logic [63:0] {
    DRAMBase = 64'h8000_0000,
    UARTBase = 64'hC000_0000,
    CTRLBase = 64'hD000_0000
  } soc_bus_start_e;

  ///////////
  //  AXI  //
  ///////////

  localparam AxiNarrowDataWidth = 64;
  localparam AxiNarrowStrbWidth = AxiNarrowDataWidth / 8;
  localparam AxiWideDataWidth   = AxiDataWidth;

  localparam AxiSocIdWidth  = AxiIdWidth - $clog2(NrAXIMasters);
  localparam AxiCoreIdWidth = AxiSocIdWidth - 1;

  typedef logic [AxiNarrowDataWidth-1:0] axi_narrow_data_t;
  typedef logic [AxiNarrowStrbWidth-1:0] axi_narrow_strb_t;
  typedef logic [AxiSocIdWidth-1:0] axi_soc_id_t;
  typedef logic [AxiCoreIdWidth-1:0] axi_core_id_t;

  `AXI_TYPEDEF_ALL(system, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)
  `AXI_TYPEDEF_ALL(ara_axi, axi_addr_t, axi_core_id_t, axi_data_t, axi_strb_t, axi_user_t)
  `AXI_TYPEDEF_ALL(ariane_axi, axi_addr_t, axi_core_id_t, axi_narrow_data_t, axi_narrow_strb_t,
    axi_user_t)
  `AXI_TYPEDEF_ALL(soc_narrow, axi_addr_t, axi_soc_id_t, axi_narrow_data_t, axi_narrow_strb_t,
    axi_user_t)
  `AXI_TYPEDEF_ALL(soc_wide, axi_addr_t, axi_soc_id_t, axi_data_t, axi_strb_t, axi_user_t)
  `AXI_LITE_TYPEDEF_ALL(soc_narrow_lite, axi_addr_t, axi_narrow_data_t, axi_narrow_strb_t)

  system_req_t  system_axi_req;
  system_resp_t system_axi_resp;

  soc_wide_req_t    [NrAXISlaves-1:0] periph_wide_axi_req;
  soc_wide_resp_t   [NrAXISlaves-1:0] periph_wide_axi_resp;
  soc_narrow_req_t  [NrAXISlaves-1:0] periph_narrow_axi_req;
  soc_narrow_resp_t [NrAXISlaves-1:0] periph_narrow_axi_resp;

  ////////////////
  //  Crossbar  //
  ////////////////

  localparam axi_pkg::xbar_cfg_t XBarCfg = '{
    NoSlvPorts        : NrAXIMasters,
    NoMstPorts        : NrAXISlaves,
    MaxMstTrans       : 4,
    MaxSlvTrans       : 4,
    FallThrough       : 1'b0,
    LatencyMode       : axi_pkg::CUT_MST_PORTS,
    PipelineStages    : 0,
    AxiIdWidthSlvPorts: AxiSocIdWidth,
    AxiIdUsedSlvPorts : AxiSocIdWidth,
    UniqueIds         : 1'b0,
    AxiAddrWidth      : AxiAddrWidth,
    AxiDataWidth      : AxiWideDataWidth,
    NoAddrRules       : NrAXISlaves,
    default           : '0
  };

  axi_pkg::xbar_rule_64_t [NrAXISlaves-1:0] routing_rules;
  assign routing_rules = '{
    '{idx: CTRL, start_addr: CTRLBase, end_addr: CTRLBase + CTRLLength},
    '{idx: UART, start_addr: UARTBase, end_addr: UARTBase + UARTLength},
    '{idx: L2MEM, start_addr: DRAMBase, end_addr: DRAMBase + DRAMLength}
  };

  axi_xbar #(
    .Cfg          (XBarCfg                ),
    .slv_aw_chan_t(system_aw_chan_t       ),
    .mst_aw_chan_t(soc_wide_aw_chan_t     ),
    .w_chan_t     (system_w_chan_t        ),
    .slv_b_chan_t (system_b_chan_t        ),
    .mst_b_chan_t (soc_wide_b_chan_t      ),
    .slv_ar_chan_t(system_ar_chan_t       ),
    .mst_ar_chan_t(soc_wide_ar_chan_t     ),
    .slv_r_chan_t (system_r_chan_t        ),
    .mst_r_chan_t (soc_wide_r_chan_t      ),
    .slv_req_t    (system_req_t           ),
    .slv_resp_t   (system_resp_t          ),
    .mst_req_t    (soc_wide_req_t         ),
    .mst_resp_t   (soc_wide_resp_t        ),
    .rule_t       (axi_pkg::xbar_rule_64_t)
  ) i_soc_xbar (
    .clk_i                (clk_i               ),
    .rst_ni               (core_rst_nq         ),
    .test_i               (1'b0                ),
    .slv_ports_req_i      (system_axi_req      ),
    .slv_ports_resp_o     (system_axi_resp     ),
    .mst_ports_req_o      (periph_wide_axi_req ),
    .mst_ports_resp_i     (periph_wide_axi_resp),
    .addr_map_i           (routing_rules       ),
    .en_default_mst_port_i('0                  ),
    .default_mst_port_i   ('0                  )
  );

  ///////////////////////////////
  //  DDR (was the L2 memory)  //
  ///////////////////////////////

  soc_wide_req_t  ddr_req;
  soc_wide_resp_t ddr_resp;
  axi_atop_filter #(
    .AxiIdWidth     (AxiSocIdWidth  ),
    .AxiMaxWriteTxns(4              ),
    .axi_req_t      (soc_wide_req_t ),
    .axi_resp_t     (soc_wide_resp_t)
  ) i_l2mem_atop_filter (
    .clk_i     (clk_i                      ),
    .rst_ni    (core_rst_nq                ),
    .slv_req_i (periph_wide_axi_req[L2MEM] ),
    .slv_resp_o(periph_wide_axi_resp[L2MEM]),
    .mst_req_o (ddr_req                    ),
    .mst_resp_i(ddr_resp                   )
  );

  // Ara's 0x8000_0000 + x -> DDR DDRBase + x (x < DRAMLength, checked by the crossbar)
  assign m_awid    = ddr_req.aw.id;
  assign m_awaddr  = 32'(ddr_req.aw.addr - DRAMBase + DDRBase);
  assign m_awlen   = ddr_req.aw.len;
  assign m_awsize  = ddr_req.aw.size;
  assign m_awburst = ddr_req.aw.burst;
  assign m_awlock  = ddr_req.aw.lock;
  assign m_awcache = 4'b0011;
  assign m_awprot  = ddr_req.aw.prot;
  assign m_awqos   = ddr_req.aw.qos;
  assign m_awvalid = ddr_req.aw_valid;
  assign m_wdata   = ddr_req.w.data;
  assign m_wstrb   = ddr_req.w.strb;
  assign m_wlast   = ddr_req.w.last;
  assign m_wvalid  = ddr_req.w_valid;
  assign m_bready  = ddr_req.b_ready;
  assign m_arid    = ddr_req.ar.id;
  assign m_araddr  = 32'(ddr_req.ar.addr - DRAMBase + DDRBase);
  assign m_arlen   = ddr_req.ar.len;
  assign m_arsize  = ddr_req.ar.size;
  assign m_arburst = ddr_req.ar.burst;
  assign m_arlock  = ddr_req.ar.lock;
  assign m_arcache = 4'b0011;
  assign m_arprot  = ddr_req.ar.prot;
  assign m_arqos   = ddr_req.ar.qos;
  assign m_arvalid = ddr_req.ar_valid;
  assign m_rready  = ddr_req.r_ready;

  always_comb begin
    ddr_resp          = '0;
    ddr_resp.aw_ready = m_awready;
    ddr_resp.w_ready  = m_wready;
    ddr_resp.b.id     = m_bid;
    ddr_resp.b.resp   = m_bresp;
    ddr_resp.b_valid  = m_bvalid;
    ddr_resp.ar_ready = m_arready;
    ddr_resp.r.id     = m_rid;
    ddr_resp.r.data   = m_rdata;
    ddr_resp.r.resp   = m_rresp;
    ddr_resp.r.last   = m_rlast;
    ddr_resp.r_valid  = m_rvalid;
  end

  ////////////
  //  UART  //
  ////////////

  `AXI_TYPEDEF_ALL(uart_axi, axi_addr_t, axi_soc_id_t, logic [31:0], logic [3:0], axi_user_t)
  `AXI_LITE_TYPEDEF_ALL(uart_lite, axi_addr_t, logic [31:0], logic [3:0])
  `APB_TYPEDEF_ALL(uart_apb, axi_addr_t, logic [31:0], logic [3:0])

  uart_axi_req_t   uart_axi_req;
  uart_axi_resp_t  uart_axi_resp;
  uart_lite_req_t  uart_lite_req;
  uart_lite_resp_t uart_lite_resp;
  uart_apb_req_t   uart_apb_req;
  uart_apb_resp_t  uart_apb_resp;

  // APB sink: always ready; a write stores its byte lane 0 (the program writes bytes
  // to 0xC000_0000)
  assign uart_apb_resp.prdata  = '0;
  assign uart_apb_resp.pready  = 1'b1;
  assign uart_apb_resp.pslverr = 1'b0;
  assign uart_we   = uart_apb_req.psel && uart_apb_req.penable && uart_apb_req.pwrite;
  assign uart_byte = uart_apb_req.pwdata[7:0];

  typedef struct packed {
    int unsigned idx;
    axi_addr_t   start_addr;
    axi_addr_t   end_addr;
  } uart_apb_rule_t;

  uart_apb_rule_t uart_apb_map = '{idx: 0, start_addr: '0, end_addr: '1};

  axi_lite_to_apb #(
    .NoApbSlaves     (32'd1           ),
    .NoRules         (32'd1           ),
    .AddrWidth       (AxiAddrWidth    ),
    .DataWidth       (32'd32          ),
    .PipelineRequest (1'b0            ),
    .PipelineResponse(1'b0            ),
    .axi_lite_req_t  (uart_lite_req_t ),
    .axi_lite_resp_t (uart_lite_resp_t),
    .apb_req_t       (uart_apb_req_t  ),
    .apb_resp_t      (uart_apb_resp_t ),
    .rule_t          (uart_apb_rule_t )
  ) i_axi_lite_to_apb_uart (
    .clk_i          (clk_i         ),
    .rst_ni         (core_rst_nq   ),
    .axi_lite_req_i (uart_lite_req ),
    .axi_lite_resp_o(uart_lite_resp),
    .apb_req_o      (uart_apb_req  ),
    .apb_resp_i     (uart_apb_resp ),
    .addr_map_i     (uart_apb_map  )
  );

  axi_to_axi_lite #(
    .AxiAddrWidth   (AxiAddrWidth    ),
    .AxiDataWidth   (32'd32          ),
    .AxiIdWidth     (AxiSocIdWidth   ),
    .AxiUserWidth   (AxiUserWidth    ),
    .AxiMaxWriteTxns(32'd1           ),
    .AxiMaxReadTxns (32'd1           ),
    .FallThrough    (1'b1            ),
    .full_req_t     (uart_axi_req_t  ),
    .full_resp_t    (uart_axi_resp_t ),
    .lite_req_t     (uart_lite_req_t ),
    .lite_resp_t    (uart_lite_resp_t)
  ) i_axi_to_axi_lite_uart (
    .clk_i     (clk_i         ),
    .rst_ni    (core_rst_nq   ),
    .test_i    (1'b0          ),
    .slv_req_i (uart_axi_req  ),
    .slv_resp_o(uart_axi_resp ),
    .mst_req_o (uart_lite_req ),
    .mst_resp_i(uart_lite_resp)
  );

  axi_dw_converter #(
    .AxiSlvPortDataWidth(AxiWideDataWidth  ),
    .AxiMstPortDataWidth(32                ),
    .AxiAddrWidth       (AxiAddrWidth      ),
    .AxiIdWidth         (AxiSocIdWidth     ),
    .AxiMaxReads        (1                 ),
    .ar_chan_t          (soc_wide_ar_chan_t),
    .mst_r_chan_t       (uart_axi_r_chan_t ),
    .slv_r_chan_t       (soc_wide_r_chan_t ),
    .aw_chan_t          (uart_axi_aw_chan_t),
    .b_chan_t           (soc_wide_b_chan_t ),
    .mst_w_chan_t       (uart_axi_w_chan_t ),
    .slv_w_chan_t       (soc_wide_w_chan_t ),
    .axi_mst_req_t      (uart_axi_req_t    ),
    .axi_mst_resp_t     (uart_axi_resp_t   ),
    .axi_slv_req_t      (soc_wide_req_t    ),
    .axi_slv_resp_t     (soc_wide_resp_t   )
  ) i_axi_slave_uart_dwc (
    .clk_i     (clk_i                     ),
    .rst_ni    (core_rst_nq               ),
    .slv_req_i (periph_wide_axi_req[UART] ),
    .slv_resp_o(periph_wide_axi_resp[UART]),
    .mst_req_o (uart_axi_req              ),
    .mst_resp_i(uart_axi_resp             )
  );

  /////////////////////////
  //  Control registers  //
  /////////////////////////

  soc_narrow_lite_req_t  axi_lite_ctrl_registers_req;
  soc_narrow_lite_resp_t axi_lite_ctrl_registers_resp;

  logic [63:0] event_trigger;

  axi_to_axi_lite #(
    .AxiAddrWidth   (AxiAddrWidth          ),
    .AxiDataWidth   (AxiNarrowDataWidth    ),
    .AxiIdWidth     (AxiSocIdWidth         ),
    .AxiUserWidth   (AxiUserWidth          ),
    .AxiMaxReadTxns (1                     ),
    .AxiMaxWriteTxns(1                     ),
    .FallThrough    (1'b0                  ),
    .full_req_t     (soc_narrow_req_t      ),
    .full_resp_t    (soc_narrow_resp_t     ),
    .lite_req_t     (soc_narrow_lite_req_t ),
    .lite_resp_t    (soc_narrow_lite_resp_t)
  ) i_axi_to_axi_lite (
    .clk_i     (clk_i                        ),
    .rst_ni    (core_rst_nq                  ),
    .test_i    (1'b0                         ),
    .slv_req_i (periph_narrow_axi_req[CTRL]  ),
    .slv_resp_o(periph_narrow_axi_resp[CTRL] ),
    .mst_req_o (axi_lite_ctrl_registers_req  ),
    .mst_resp_i(axi_lite_ctrl_registers_resp )
  );

  ctrl_registers #(
    .DRAMBaseAddr   (DRAMBase              ),
    .DRAMLength     (DRAMLength            ),
    .DataWidth      (AxiNarrowDataWidth    ),
    .AddrWidth      (AxiAddrWidth          ),
    .axi_lite_req_t (soc_narrow_lite_req_t ),
    .axi_lite_resp_t(soc_narrow_lite_resp_t)
  ) i_ctrl_registers (
    .clk_i                (clk_i                       ),
    .rst_ni               (core_rst_nq                 ),
    .axi_lite_slave_req_i (axi_lite_ctrl_registers_req ),
    .axi_lite_slave_resp_o(axi_lite_ctrl_registers_resp),
    .hw_cnt_en_o          (hw_cnt_en_o                 ),
    .dram_base_addr_o     (/* Unused */                ),
    .dram_end_addr_o      (/* Unused */                ),
    .exit_o               (exit_o                      ),
    .event_trigger_o      (event_trigger)
  );

  axi_dw_converter #(
    .AxiSlvPortDataWidth(AxiWideDataWidth    ),
    .AxiMstPortDataWidth(AxiNarrowDataWidth  ),
    .AxiAddrWidth       (AxiAddrWidth        ),
    .AxiIdWidth         (AxiSocIdWidth       ),
    .AxiMaxReads        (2                   ),
    .ar_chan_t          (soc_wide_ar_chan_t  ),
    .mst_r_chan_t       (soc_narrow_r_chan_t ),
    .slv_r_chan_t       (soc_wide_r_chan_t   ),
    .aw_chan_t          (soc_narrow_aw_chan_t),
    .b_chan_t           (soc_narrow_b_chan_t ),
    .mst_w_chan_t       (soc_narrow_w_chan_t ),
    .slv_w_chan_t       (soc_wide_w_chan_t   ),
    .axi_mst_req_t      (soc_narrow_req_t    ),
    .axi_mst_resp_t     (soc_narrow_resp_t   ),
    .axi_slv_req_t      (soc_wide_req_t      ),
    .axi_slv_resp_t     (soc_wide_resp_t     )
  ) i_axi_slave_ctrl_dwc (
    .clk_i     (clk_i                       ),
    .rst_ni    (core_rst_nq                 ),
    .slv_req_i (periph_wide_axi_req[CTRL]   ),
    .slv_resp_o(periph_wide_axi_resp[CTRL]  ),
    .mst_req_o (periph_narrow_axi_req[CTRL] ),
    .mst_resp_i(periph_narrow_axi_resp[CTRL])
  );

  //////////////
  //  System  //
  //////////////

  logic [2:0] hart_id;
  assign hart_id = '0;

  function automatic config_pkg::cva6_user_cfg_t gen_usr_cva6_config(config_pkg::cva6_user_cfg_t cfg);
    cfg.AxiAddrWidth          = AxiAddrWidth;
    cfg.AxiDataWidth          = AxiNarrowDataWidth;
    cfg.AxiIdWidth            = AxiIdWidth;
    cfg.AxiUserWidth          = AxiUserWidth;
    cfg.XF16                  = FPUSupport[3];
    cfg.RVF                   = FPUSupport[4];
    cfg.RVD                   = FPUSupport[5];
    cfg.XF16ALT               = FPUSupport[2];
    cfg.XF8                   = FPUSupport[1];
    cfg.NrPMPEntries          = 0;
    cfg.NrNonIdempotentRules  = 2;
    cfg.NonIdempotentAddrBase = {UARTBase, CTRLBase};
    cfg.NonIdempotentLength   = {UARTLength, CTRLLength};
    cfg.NrExecuteRegionRules  = 3;
    cfg.ExecuteRegionAddrBase = {DRAMBase,   64'h1_0000, 64'h0};
    cfg.ExecuteRegionLength   = {DRAMLength, 64'h10000,  64'h1000};
    cfg.NrCachedRegionRules   = 1;
    cfg.CachedRegionAddrBase  = {DRAMBase};
    cfg.CachedRegionLength    = {DRAMLength};
    return cfg;
  endfunction

  localparam config_pkg::cva6_user_cfg_t CVA6AraConfig_user = gen_usr_cva6_config(cva6_config_pkg::cva6_cfg);
  localparam config_pkg::cva6_cfg_t CVA6AraConfig = build_config_pkg::build_config(CVA6AraConfig_user);

  `CVA6_TYPEDEF_EXCEPTION(exception_t, CVA6AraConfig);
  `CVA6_INTF_TYPEDEF_ACC_REQ(accelerator_req_t, CVA6AraConfig, fpnew_pkg::roundmode_e);
  `CVA6_INTF_TYPEDEF_ACC_RESP(accelerator_resp_t, CVA6AraConfig, exception_t);
  `CVA6_INTF_TYPEDEF_MMU_REQ(acc_mmu_req_t, CVA6AraConfig);
  `CVA6_INTF_TYPEDEF_MMU_RESP(acc_mmu_resp_t, CVA6AraConfig, exception_t);
  `CVA6_INTF_TYPEDEF_CVA6_TO_ACC(cva6_to_acc_t, accelerator_req_t, acc_mmu_resp_t);
  `CVA6_INTF_TYPEDEF_ACC_TO_CVA6(acc_to_cva6_t, accelerator_resp_t, acc_mmu_req_t);

  ara_system #(
    .NrLanes           (NrLanes              ),
    .VLEN              (VLEN                 ),
    .OSSupport         (OSSupport            ),
    .FPUSupport        (FPUSupport           ),
    .FPExtSupport      (FPExtSupport         ),
    .FixPtSupport      (FixPtSupport         ),
    .SegSupport        (SegSupport           ),
    .CVA6Cfg           (CVA6AraConfig        ),
    .exception_t       (exception_t          ),
    .accelerator_req_t (accelerator_req_t    ),
    .accelerator_resp_t(accelerator_resp_t   ),
    .acc_mmu_req_t     (acc_mmu_req_t        ),
    .acc_mmu_resp_t    (acc_mmu_resp_t       ),
    .cva6_to_acc_t     (cva6_to_acc_t        ),
    .acc_to_cva6_t     (acc_to_cva6_t        ),
    .AxiAddrWidth      (AxiAddrWidth         ),
    .AxiIdWidth        (AxiCoreIdWidth       ),
    .AxiNarrowDataWidth(AxiNarrowDataWidth   ),
    .AxiWideDataWidth  (AxiDataWidth         ),
    .ara_axi_ar_t      (ara_axi_ar_chan_t    ),
    .ara_axi_aw_t      (ara_axi_aw_chan_t    ),
    .ara_axi_b_t       (ara_axi_b_chan_t     ),
    .ara_axi_r_t       (ara_axi_r_chan_t     ),
    .ara_axi_w_t       (ara_axi_w_chan_t     ),
    .ara_axi_req_t     (ara_axi_req_t        ),
    .ara_axi_resp_t    (ara_axi_resp_t       ),
    .ariane_axi_ar_t   (ariane_axi_ar_chan_t ),
    .ariane_axi_aw_t   (ariane_axi_aw_chan_t ),
    .ariane_axi_b_t    (ariane_axi_b_chan_t  ),
    .ariane_axi_r_t    (ariane_axi_r_chan_t  ),
    .ariane_axi_w_t    (ariane_axi_w_chan_t  ),
    .ariane_axi_req_t  (ariane_axi_req_t     ),
    .ariane_axi_resp_t (ariane_axi_resp_t    ),
    .system_axi_ar_t   (system_ar_chan_t     ),
    .system_axi_aw_t   (system_aw_chan_t     ),
    .system_axi_b_t    (system_b_chan_t      ),
    .system_axi_r_t    (system_r_chan_t      ),
    .system_axi_w_t    (system_w_chan_t      ),
    .system_axi_req_t  (system_req_t         ),
    .system_axi_resp_t (system_resp_t        ))
  i_system (
    .clk_i        (clk_i              ),
    .rst_ni       (core_rst_nq        ),
    .boot_addr_i  (DRAMBase           ),
    .hart_id_i    (hart_id            ),
    .scan_enable_i(1'b0               ),
    .scan_data_i  (1'b0               ),
    .scan_data_o  (/* Unconnected */  ),
    .axi_req_o    (system_axi_req     ),
    .axi_resp_i   (system_axi_resp    )
  );

  //////////////////
  //  Assertions  //
  //////////////////

  if (AxiDataWidth != 64)
    $error("[ara_ps_top] the board build uses 2 lanes (64-bit DDR port)");

  if (RVVD(FPUSupport) && !CVA6AraConfig.RVD)
    $error("[ara] Cannot support double-precision floating-point on Ara if CVA6 does not support it.");

endmodule : ara_ps_top
