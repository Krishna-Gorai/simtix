// vortex_ps_top.sv - Vortex 3.0 (Vortex_axi) as a Zynq UltraScale+ PS peripheral (ZCU102)
//
// The A53 drives Vortex the way Vortex's command processor does (hw/rtl/cp), through
// host registers instead of a command ring: DCR writes, a start pulse, busy, and the
// per-core cache-flush DCR read. Vortex's memory master (Vortex_axi, AXI_DATA_WIDTH =
// 128, its own data adapter) goes to the PS DDR4 through S_AXI_HP0_FPD.
//
// Address windows (Vortex 32-bit address -> DDR byte address):
//   0x0000_0000-0x0FFF_FFFF  IO (cout ring, exit code), kernel args -> DDRBase + 0x0000_0000
//   0x1000_0000-0x1FFF_FFFF  the A53 host's data arena (SIMTiX's)    -> 0x1000_0000 (identity)
//   0x8000_0000-0x8FFF_FFFF  kernel image (STARTUP_ADDR)            -> DDRBase + 0x1000_0000
//   0xF000_0000-0xFFFF_FFFF  page table, stacks (0xFFFF_0000 down)  -> DDRBase + 0x2000_0000
// The identity window lets the kernels read SIMTiX's parameter blocks and buffers
// (sw/ps_host/apps.c) unchanged. Any other address goes to DDRBase + 0x3000_0000 and
// sets STATUS.addr_err.
// The port's IDs are EXT_IDW bits, always 0. Vortex orders read-after-write itself
// (VX_mem_to_axi: all writes AWID 0, a read to an
// address with an unanswered write is held). Its 512 -> 128-bit data adapter splits a
// line into four reads with different IDs and needs their data back in order, which the
// PS interconnect does not promise across IDs: every read leaves with ARID 0 (one ID:
// in order), the original IDs wait in a FIFO and are put back on the R beats.
//
// Host registers (AXI4-Lite, byte offsets, 32-bit):
//   0x00 CTRL      rw  bit 0 reset (1 = Vortex held in reset, the value after power-up)
//   0x04 START     wo  any write: one-cycle start (ignored while busy)
//   0x08 STATUS    ro  bit 0 busy (start pending, Vortex busy, a DCR read pending or an
//                      AXI transaction in flight), bit 1 dcr_rsp (the last DCR read has
//                      answered), bit 2 addr_err (sticky until reset)
//   0x0C DCR_ADDR  rw  DCR address (12 bits)
//   0x10 DCR_WRITE wo  write: DCR write of this data to DCR_ADDR
//   0x14 DCR_READ  wo  write: DCR read of DCR_ADDR with this data on the bus (the core
//                      index for VX_DCR_BASE_CACHE_FLUSH, which answers once flushed)
//   0x18 DCR_RDATA ro  data of the last DCR read
//   0x1C/0x20      ro  BUSYCYC lo/hi: cycles with STATUS.busy set since the last reset
//   0x24 INFO      ro  {8'hB7, 8'(warps), 8'(threads), 8'(cores)}
//   0x28..0x34     ro  AR, AW, R-last, B handshakes on the DDR port (since reset)
//   0x38 ERRADDR   ro  the first address outside the windows
module vortex_ps_top import VX_gpu_pkg::*; #(
    parameter int unsigned DW      = 128,
    parameter int unsigned IDW     = VX_MEM_TAG_WIDTH,   // Vortex's AXI ID (11 bits here)
    parameter int unsigned EXT_IDW = 6,                  // the port's ID (S_AXI_HP0_FPD: 6)
    parameter logic [31:0] DDRBase = 32'h4000_0000
  ) (
    input  logic            clk,
    input  logic            aresetn,
    // Host AXI4-Lite slave (M_AXI_HPM0_FPD through SmartConnect)
    input  logic [15:0]     s_awaddr,
    input  logic            s_awvalid,
    output logic            s_awready,
    input  logic [31:0]     s_wdata,
    input  logic [3:0]      s_wstrb,
    input  logic            s_wvalid,
    output logic            s_wready,
    output logic [1:0]      s_bresp,
    output logic            s_bvalid,
    input  logic            s_bready,
    input  logic [15:0]     s_araddr,
    input  logic            s_arvalid,
    output logic            s_arready,
    output logic [31:0]     s_rdata,
    output logic [1:0]      s_rresp,
    output logic            s_rvalid,
    input  logic            s_rready,
    // DDR AXI4 master (S_AXI_HP0_FPD)
    output logic [EXT_IDW-1:0] m_awid,
    output logic [31:0]     m_awaddr,
    output logic [7:0]      m_awlen,
    output logic [2:0]      m_awsize,
    output logic [1:0]      m_awburst,
    output logic            m_awlock,
    output logic [3:0]      m_awcache,
    output logic [2:0]      m_awprot,
    output logic [3:0]      m_awqos,
    output logic            m_awvalid,
    input  logic            m_awready,
    output logic [DW-1:0]   m_wdata,
    output logic [DW/8-1:0] m_wstrb,
    output logic            m_wlast,
    output logic            m_wvalid,
    input  logic            m_wready,
    input  logic [EXT_IDW-1:0] m_bid,
    input  logic [1:0]      m_bresp,
    input  logic            m_bvalid,
    output logic            m_bready,
    output logic [EXT_IDW-1:0] m_arid,
    output logic [31:0]     m_araddr,
    output logic [7:0]      m_arlen,
    output logic [2:0]      m_arsize,
    output logic [1:0]      m_arburst,
    output logic            m_arlock,
    output logic [3:0]      m_arcache,
    output logic [2:0]      m_arprot,
    output logic [3:0]      m_arqos,
    output logic            m_arvalid,
    input  logic            m_arready,
    input  logic [EXT_IDW-1:0] m_rid,
    input  logic [DW-1:0]   m_rdata,
    input  logic [1:0]      m_rresp,
    input  logic            m_rlast,
    input  logic            m_rvalid,
    output logic            m_rready
  );

  // ── Control state ────────────────────────────────────────────────────────────
  logic        vx_reset_q;                 // CTRL.reset
  logic        start_q;                    // one-cycle start
  logic [2:0]  guard_q;                    // busy right after start, until Vortex raises busy
  logic        dcr_valid_q, dcr_rw_q;
  logic [VX_DCR_ADDR_WIDTH-1:0] dcr_addr_q;
  logic [VX_DCR_DATA_WIDTH-1:0] dcr_data_q;
  logic        dcr_rd_pend_q, dcr_rsp_q;
  logic [31:0] dcr_rdata_q;
  logic [63:0] busycyc_q;
  logic [31:0] n_ar_q, n_aw_q, n_r_q, n_b_q, erraddr_q;
  logic [15:0] wr_out_q, rd_out_q;
  logic        addr_err_q;
  // read IDs in issue order (reads go out with ARID 0)
  logic [IDW-1:0] rid_fifo [64];
  logic [5:0]     rid_wr_q, rid_rd_q;

  wire vx_busy;
  wire dcr_rsp_valid;
  wire [VX_DCR_DATA_WIDTH-1:0] dcr_rsp_data;
  wire vx_reset = vx_reset_q || !aresetn;

  wire aw_hs = m_awvalid && m_awready;
  wire ar_hs = m_arvalid && m_arready;
  wire b_hs  = m_bvalid && m_bready;
  wire r_hs  = m_rvalid && m_rready && m_rlast;
  wire busy  = start_q || (guard_q != '0) || vx_busy || dcr_rd_pend_q || dcr_valid_q
             || (wr_out_q != '0) || (rd_out_q != '0) || m_awvalid || m_arvalid;

  // ── Vortex ───────────────────────────────────────────────────────────────────
  wire              vx_awvalid [1], vx_awready [1], vx_wvalid [1], vx_wready [1], vx_wlast [1];
  wire              vx_bvalid [1], vx_bready [1], vx_arvalid [1], vx_arready [1];
  wire              vx_rvalid [1], vx_rready [1], vx_rlast [1];
  wire [31:0]       vx_awaddr [1], vx_araddr [1];
  wire [IDW-1:0]    vx_awid [1], vx_arid [1], vx_bid [1], vx_rid [1];
  wire [7:0]        vx_awlen [1], vx_arlen [1];
  wire [2:0]        vx_awsize [1], vx_arsize [1], vx_awprot [1], vx_arprot [1];
  wire [1:0]        vx_awburst [1], vx_arburst [1], vx_awlock [1], vx_arlock [1];
  wire [1:0]        vx_bresp [1], vx_rresp [1];
  wire [3:0]        vx_awcache [1], vx_arcache [1], vx_awqos [1], vx_arqos [1];
  wire [3:0]        vx_awregion [1], vx_arregion [1];
  wire [DW-1:0]     vx_wdata [1], vx_rdata [1];
  wire [DW/8-1:0]   vx_wstrb [1];

  Vortex_axi #(
    .AXI_DATA_WIDTH (DW),
    .AXI_ADDR_WIDTH (32),
    .AXI_TID_WIDTH  (IDW),
    .AXI_NUM_BANKS  (1)
  ) i_vortex (
    .clk            (clk),
    .reset          (vx_reset),
    .m_axi_awvalid  (vx_awvalid),  .m_axi_awready (vx_awready),  .m_axi_awaddr (vx_awaddr),
    .m_axi_awid     (vx_awid),     .m_axi_awlen   (vx_awlen),    .m_axi_awsize (vx_awsize),
    .m_axi_awburst  (vx_awburst),  .m_axi_awlock  (vx_awlock),   .m_axi_awcache(vx_awcache),
    .m_axi_awprot   (vx_awprot),   .m_axi_awqos   (vx_awqos),    .m_axi_awregion(vx_awregion),
    .m_axi_wvalid   (vx_wvalid),   .m_axi_wready  (vx_wready),   .m_axi_wdata  (vx_wdata),
    .m_axi_wstrb    (vx_wstrb),    .m_axi_wlast   (vx_wlast),
    .m_axi_bvalid   (vx_bvalid),   .m_axi_bready  (vx_bready),   .m_axi_bid    (vx_bid),
    .m_axi_bresp    (vx_bresp),
    .m_axi_arvalid  (vx_arvalid),  .m_axi_arready (vx_arready),  .m_axi_araddr (vx_araddr),
    .m_axi_arid     (vx_arid),     .m_axi_arlen   (vx_arlen),    .m_axi_arsize (vx_arsize),
    .m_axi_arburst  (vx_arburst),  .m_axi_arlock  (vx_arlock),   .m_axi_arcache(vx_arcache),
    .m_axi_arprot   (vx_arprot),   .m_axi_arqos   (vx_arqos),    .m_axi_arregion(vx_arregion),
    .m_axi_rvalid   (vx_rvalid),   .m_axi_rready  (vx_rready),   .m_axi_rdata  (vx_rdata),
    .m_axi_rlast    (vx_rlast),    .m_axi_rid     (vx_rid),      .m_axi_rresp  (vx_rresp),
    .dcr_req_valid  (dcr_valid_q),
    .dcr_req_rw     (dcr_rw_q),
    .dcr_req_addr   (dcr_addr_q),
    .dcr_req_data   (dcr_data_q),
    .dcr_rsp_valid  (dcr_rsp_valid),
    .dcr_rsp_data   (dcr_rsp_data),
    .start          (start_q),
    .busy           (vx_busy)
  );

  // ── Address windows ──────────────────────────────────────────────────────────
  function automatic logic [31:0] to_ddr(input logic [31:0] a);
    unique case (a[31:28])
      4'h0:    return DDRBase + {4'h0, a[27:0]};
      4'h1:    return a;
      4'h8:    return DDRBase + {4'h1, a[27:0]};
      4'hF:    return DDRBase + {4'h2, a[27:0]};
      default: return DDRBase + {4'h3, a[27:0]};
    endcase
  endfunction
  function automatic logic in_win(input logic [31:0] a);
    return a[31:28] == 4'h0 || a[31:28] == 4'h1 || a[31:28] == 4'h8 || a[31:28] == 4'hF;
  endfunction

  assign m_awid    = '0;             assign m_awaddr  = to_ddr(vx_awaddr[0]);   // Vortex: AWID 0
  assign m_awlen   = vx_awlen[0];    assign m_awsize  = vx_awsize[0];
  assign m_awburst = vx_awburst[0];  assign m_awlock  = vx_awlock[0][0];
  assign m_awcache = 4'b0011;        assign m_awprot  = 3'b000;      // normal, bufferable, non-secure data
  assign m_awqos   = 4'h0;           assign m_awvalid = vx_awvalid[0];
  assign vx_awready[0] = m_awready;
  assign m_wdata   = vx_wdata[0];    assign m_wstrb   = vx_wstrb[0];
  assign m_wlast   = vx_wlast[0];    assign m_wvalid  = vx_wvalid[0];
  assign vx_wready[0] = m_wready;
  assign vx_bvalid[0] = m_bvalid;    assign vx_bid[0] = '0;           assign vx_bresp[0] = m_bresp;
  assign m_bready  = vx_bready[0];
  assign m_arid    = '0;             assign m_araddr  = to_ddr(vx_araddr[0]);
  assign m_arlen   = vx_arlen[0];    assign m_arsize  = vx_arsize[0];
  assign m_arburst = vx_arburst[0];  assign m_arlock  = vx_arlock[0][0];
  assign m_arcache = 4'b0011;        assign m_arprot  = 3'b000;
  assign m_arqos   = 4'h0;           assign m_arvalid = vx_arvalid[0];
  assign vx_arready[0] = m_arready;
  assign vx_rvalid[0] = m_rvalid;    assign vx_rdata[0] = m_rdata;    assign vx_rlast[0] = m_rlast;
  assign vx_rid[0]    = rid_fifo[rid_rd_q]; assign vx_rresp[0] = m_rresp;
  assign m_rready  = vx_rready[0];

  // ── Host AXI4-Lite slave: one write and one read at a time ────────────────────
  wire s_w_go = s_awvalid && s_wvalid && !s_bvalid;
  assign s_awready = s_w_go;
  assign s_wready  = s_w_go;
  assign s_bresp   = 2'b00;
  assign s_rresp   = 2'b00;
  assign s_arready = !s_rvalid;

  always_ff @(posedge clk) begin
    if (!aresetn) begin
      vx_reset_q <= 1'b1; start_q <= 1'b0; guard_q <= '0;
      dcr_valid_q <= 1'b0; dcr_rw_q <= 1'b0; dcr_addr_q <= '0; dcr_data_q <= '0;
      dcr_rd_pend_q <= 1'b0; dcr_rsp_q <= 1'b0; dcr_rdata_q <= '0;
      busycyc_q <= '0; n_ar_q <= '0; n_aw_q <= '0; n_r_q <= '0; n_b_q <= '0;
      wr_out_q <= '0; rd_out_q <= '0; addr_err_q <= 1'b0; erraddr_q <= '0;
      rid_wr_q <= '0; rid_rd_q <= '0;
      s_bvalid <= 1'b0; s_rvalid <= 1'b0; s_rdata <= '0;
    end else begin
      // one-cycle pulses
      start_q     <= 1'b0;
      dcr_valid_q <= 1'b0;
      if (ar_hs) begin rid_fifo[rid_wr_q] <= vx_arid[0]; rid_wr_q <= rid_wr_q + 6'd1; end
      if (r_hs)  rid_rd_q <= rid_rd_q + 6'd1;
      if (start_q)            guard_q <= 3'd7;
      else if (guard_q != '0) guard_q <= guard_q - 3'd1;
      if (dcr_rsp_valid && dcr_rd_pend_q) begin
        dcr_rd_pend_q <= 1'b0; dcr_rsp_q <= 1'b1; dcr_rdata_q <= dcr_rsp_data;
      end

      // host writes
      if (s_w_go) begin
        s_bvalid <= 1'b1;
        unique case (s_awaddr[7:0])
          8'h00: vx_reset_q <= s_wdata[0];
          8'h04: if (!busy && !vx_reset_q) start_q <= 1'b1;
          8'h0C: dcr_addr_q <= VX_DCR_ADDR_WIDTH'(s_wdata);
          8'h10: if (!vx_reset_q) begin
                   dcr_valid_q <= 1'b1; dcr_rw_q <= 1'b1; dcr_data_q <= VX_DCR_DATA_WIDTH'(s_wdata);
                 end
          8'h14: if (!vx_reset_q) begin
                   dcr_valid_q <= 1'b1; dcr_rw_q <= 1'b0; dcr_data_q <= VX_DCR_DATA_WIDTH'(s_wdata);
                   dcr_rd_pend_q <= 1'b1; dcr_rsp_q <= 1'b0;
                 end
          default: ;
        endcase
      end else if (s_bready) begin
        s_bvalid <= 1'b0;
      end

      // DDR port bookkeeping (counted while Vortex runs; cleared by its reset)
      if (vx_reset_q) begin
        busycyc_q <= '0; n_ar_q <= '0; n_aw_q <= '0; n_r_q <= '0; n_b_q <= '0;
        wr_out_q <= '0; rd_out_q <= '0; addr_err_q <= 1'b0; erraddr_q <= '0;
      end else begin
        if (busy) busycyc_q <= busycyc_q + 64'd1;
        if (ar_hs) n_ar_q <= n_ar_q + 1;
        if (aw_hs) n_aw_q <= n_aw_q + 1;
        if (r_hs)  n_r_q  <= n_r_q + 1;
        if (b_hs)  n_b_q  <= n_b_q + 1;
        wr_out_q <= wr_out_q + 16'(aw_hs) - 16'(b_hs);
        rd_out_q <= rd_out_q + 16'(ar_hs) - 16'(r_hs);
        if (!addr_err_q && aw_hs && !in_win(vx_awaddr[0])) begin addr_err_q <= 1'b1; erraddr_q <= vx_awaddr[0]; end
        else if (!addr_err_q && ar_hs && !in_win(vx_araddr[0])) begin addr_err_q <= 1'b1; erraddr_q <= vx_araddr[0]; end
      end

      // host reads
      if (s_arvalid && s_arready) begin
        s_rvalid <= 1'b1;
        unique case (s_araddr[7:0])
          8'h00:   s_rdata <= {31'b0, vx_reset_q};
          8'h08:   s_rdata <= {29'b0, addr_err_q, dcr_rsp_q, busy};
          8'h0C:   s_rdata <= 32'(dcr_addr_q);
          8'h18:   s_rdata <= 32'(dcr_rdata_q);
          8'h1C:   s_rdata <= busycyc_q[31:0];
          8'h20:   s_rdata <= busycyc_q[63:32];
          8'h24:   s_rdata <= {8'hB7, 8'(`VX_CFG_NUM_WARPS), 8'(`VX_CFG_NUM_THREADS), 8'(`VX_CFG_NUM_CORES)};
          8'h28:   s_rdata <= n_ar_q;
          8'h2C:   s_rdata <= n_aw_q;
          8'h30:   s_rdata <= n_r_q;
          8'h34:   s_rdata <= n_b_q;
          8'h38:   s_rdata <= erraddr_q;
          default: s_rdata <= 32'hDEAD_BEEF;
        endcase
      end else if (s_rready) begin
        s_rvalid <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (aresetn && ar_hs && rd_out_q >= 16'd63)
      $error("vortex_ps_top: more than 63 reads in flight (read-ID FIFO)");
    if (aresetn && aw_hs && vx_awid[0] != '0)
      $error("vortex_ps_top: a write with AWID %0d (expected 0)", vx_awid[0]);
  end
`endif

endmodule : vortex_ps_top
