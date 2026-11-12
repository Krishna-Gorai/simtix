// ara_ps_tb.sv - Verilator testbench of the board wrapper ara_ps_wrap (exact board
// configuration: 2 lanes, VLEN 2048, FP64/32/16, the same Verilog top as the block
// design).
//
//   host  : an FSM in place of the A53. It writes CTRL.run = 1, polls STATUS.done
//           over AXI4-Lite, reads EXIT, CYCLES, HWCNT and the UART buffer, prints
//           them and ends the simulation.
//   DDR   : the wrapper's AXI4 master -> axi_delayer (random stalls on every channel,
//           +LAT fixed cycles) -> axi_to_mem -> tc_sram i_ddr. The program (ELF linked
//           at 0x8000_0000) is preloaded by the C++ driver into i_ddr, which models
//           the DDR window at 0x4000_0000 (1 MB here).
module ara_ps_tb (
    input  logic        clk_i,
    input  logic        rst_ni,
    output logic [63:0] exit_o
  );

  `include "axi/typedef.svh"

  localparam int unsigned DW = 64, IW = 5, AW = 32;
  localparam logic [31:0] DDRBase  = 32'h4000_0000;
  localparam int unsigned DDRWords = 1 << 17;          // 1 MB
  localparam int unsigned PollGap  = 200;              // cycles between STATUS polls

  typedef logic [AW-1:0]   addr_t;
  typedef logic [DW-1:0]   data_t;
  typedef logic [DW/8-1:0] strb_t;
  typedef logic [IW-1:0]   id_t;
  typedef logic [0:0]      user_t;
  `AXI_TYPEDEF_ALL(ddr, addr_t, id_t, data_t, strb_t, user_t)

  ddr_req_t  m_req, d_req;
  ddr_resp_t m_resp, d_resp;

  // Host AXI4-Lite
  logic [15:0] s_awaddr, s_araddr;
  logic        s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready;
  logic [31:0] s_wdata, s_rdata;
  logic        s_arvalid, s_arready, s_rvalid, s_rready;
  logic [1:0]  s_bresp, s_rresp;

  ara_ps_wrap dut (
    .clk(clk_i), .aresetn(rst_ni),
    .s_axi_awaddr(s_awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(s_awvalid),
    .s_axi_awready(s_awready), .s_axi_wdata(s_wdata), .s_axi_wstrb(4'hF),
    .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready), .s_axi_bresp(s_bresp),
    .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready), .s_axi_araddr(s_araddr),
    .s_axi_arprot(3'b0), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
    .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid),
    .s_axi_rready(s_rready),
    .m_axi_awid(m_req.aw.id), .m_axi_awaddr(m_req.aw.addr), .m_axi_awlen(m_req.aw.len),
    .m_axi_awsize(m_req.aw.size), .m_axi_awburst(m_req.aw.burst),
    .m_axi_awlock(m_req.aw.lock), .m_axi_awcache(m_req.aw.cache),
    .m_axi_awprot(m_req.aw.prot), .m_axi_awqos(m_req.aw.qos),
    .m_axi_awvalid(m_req.aw_valid), .m_axi_awready(m_resp.aw_ready),
    .m_axi_wdata(m_req.w.data), .m_axi_wstrb(m_req.w.strb), .m_axi_wlast(m_req.w.last),
    .m_axi_wvalid(m_req.w_valid), .m_axi_wready(m_resp.w_ready),
    .m_axi_bid(m_resp.b.id), .m_axi_bresp(m_resp.b.resp), .m_axi_bvalid(m_resp.b_valid),
    .m_axi_bready(m_req.b_ready),
    .m_axi_arid(m_req.ar.id), .m_axi_araddr(m_req.ar.addr), .m_axi_arlen(m_req.ar.len),
    .m_axi_arsize(m_req.ar.size), .m_axi_arburst(m_req.ar.burst),
    .m_axi_arlock(m_req.ar.lock), .m_axi_arcache(m_req.ar.cache),
    .m_axi_arprot(m_req.ar.prot), .m_axi_arqos(m_req.ar.qos),
    .m_axi_arvalid(m_req.ar_valid), .m_axi_arready(m_resp.ar_ready),
    .m_axi_rid(m_resp.r.id), .m_axi_rdata(m_resp.r.data), .m_axi_rresp(m_resp.r.resp),
    .m_axi_rlast(m_resp.r.last), .m_axi_rvalid(m_resp.r_valid), .m_axi_rready(m_req.r_ready)
  );
  assign m_req.aw.region = '0; assign m_req.aw.atop = '0; assign m_req.aw.user = '0;
  assign m_req.ar.region = '0; assign m_req.ar.user = '0;
  assign m_req.w.user    = '0;

  // Address check: every DDR access must fall in the 256 MB window
  always_ff @(posedge clk_i) begin
    if (rst_ni && m_req.ar_valid && (m_req.ar.addr < DDRBase || m_req.ar.addr >= DDRBase + 32'h1000_0000))
      $error("DDR read outside the window: %h", m_req.ar.addr);
    if (rst_ni && m_req.aw_valid && (m_req.aw.addr < DDRBase || m_req.aw.addr >= DDRBase + 32'h1000_0000))
      $error("DDR write outside the window: %h", m_req.aw.addr);
  end

  ///////////
  //  DDR  //
  ///////////

  axi_delayer #(
    .aw_chan_t(ddr_aw_chan_t), .w_chan_t(ddr_w_chan_t), .b_chan_t(ddr_b_chan_t),
    .ar_chan_t(ddr_ar_chan_t), .r_chan_t(ddr_r_chan_t),
    .axi_req_t(ddr_req_t), .axi_resp_t(ddr_resp_t),
    .StallRandomInput(1), .StallRandomOutput(1),
    .FixedDelayInput(0), .FixedDelayOutput(0)
  ) i_delay (
    .clk_i, .rst_ni,
    .slv_req_i(m_req), .slv_resp_o(m_resp),
    .mst_req_o(d_req), .mst_resp_i(d_resp)
  );

  logic        mem_req, mem_we, mem_rvalid;
  addr_t       mem_addr;
  strb_t       mem_be;
  data_t       mem_wdata, mem_rdata;

  axi_to_mem #(
    .AddrWidth(AW), .DataWidth(DW), .IdWidth(IW), .NumBanks(1),
    .axi_req_t(ddr_req_t), .axi_resp_t(ddr_resp_t)
  ) i_axi_to_mem (
    .clk_i, .rst_ni,
    .axi_req_i(d_req), .axi_resp_o(d_resp),
    .mem_req_o(mem_req), .mem_gnt_i(mem_req), .mem_we_o(mem_we), .mem_addr_o(mem_addr),
    .mem_strb_o(mem_be), .mem_wdata_o(mem_wdata), .mem_rdata_i(mem_rdata),
    .mem_rvalid_i(mem_rvalid), .mem_atop_o(), .busy_o()
  );

  addr_t ddr_off;
  assign ddr_off = mem_addr - DDRBase;

  tc_sram #(
    .NumWords(DDRWords), .NumPorts(1), .DataWidth(DW), .SimInit("random")
  ) i_ddr (
    .clk_i, .rst_ni,
    .req_i(mem_req), .we_i(mem_we),
    .addr_i(ddr_off[$clog2(DDRWords)+2:3]),
    .wdata_i(mem_wdata), .be_i(mem_be), .rdata_o(mem_rdata)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mem_rvalid <= 1'b0;
    else         mem_rvalid <= mem_req;
  end

  ////////////////////////////////
  //  Host (in place of the A53)  //
  ////////////////////////////////

  typedef enum logic [3:0] {
    H_IDLE, H_WR, H_WR_B, H_GAP, H_RD, H_RD_R, H_UART, H_END
  } hstate_e;
  hstate_e     hs_q;
  logic [31:0] gap_q, cyc_q;
  logic [3:0]  step_q;        // which register is being read
  logic [31:0] status_q, exitv_q, cyclo_q, cychi_q, hwlo_q, ucnt_q;
  logic        tmo_q;                                    // the host timed out
  int unsigned tmo_cyc;                                  // +TMO=<cycles>, default 20M
  initial if (!$value$plusargs("TMO=%d", tmo_cyc)) tmo_cyc = 20_000_000;
  logic [15:0] uaddr_q;

  assign s_wdata = 32'h1;
  assign s_bready = 1'b1;
  assign s_rready = 1'b1;

  // Register read sequence: STATUS (polled), then EXIT, CYCLES lo/hi, HWCNT lo, UARTCNT
  function automatic logic [15:0] reg_addr(logic [3:0] s);
    case (s)
      4'd0: return 16'h0004;
      4'd1: return 16'h0008;
      4'd2: return 16'h000C;
      4'd3: return 16'h0010;
      4'd4: return 16'h0014;
      default: return 16'h001C;
    endcase
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hs_q <= H_IDLE; gap_q <= '0; cyc_q <= '0; step_q <= '0;
      s_awvalid <= 1'b0; s_wvalid <= 1'b0; s_arvalid <= 1'b0;
      s_awaddr <= '0; s_araddr <= '0; uaddr_q <= '0;
      status_q <= '0; exitv_q <= '0; cyclo_q <= '0; cychi_q <= '0; hwlo_q <= '0; ucnt_q <= '0;
      tmo_q <= 1'b0;
      exit_o <= '0;
    end else begin
      cyc_q <= cyc_q + 1;
      unique case (hs_q)
        H_IDLE: if (cyc_q == 32'd20) begin
          s_awaddr <= 16'h0000; s_awvalid <= 1'b1; s_wvalid <= 1'b1; hs_q <= H_WR;
        end
        H_WR: begin
          if (s_awready) begin s_awvalid <= 1'b0; s_wvalid <= 1'b0; hs_q <= H_WR_B; end
        end
        H_WR_B: if (s_bvalid) begin
          $display("[host] CTRL.run = 1 at cycle %0d", cyc_q);
          gap_q <= '0; step_q <= '0; hs_q <= H_GAP;
        end
        H_GAP: begin
          gap_q <= gap_q + 1;
          if (gap_q == PollGap) begin
            s_araddr <= reg_addr(step_q); s_arvalid <= 1'b1; hs_q <= H_RD;
          end
        end
        H_RD: if (s_arready) begin s_arvalid <= 1'b0; hs_q <= H_RD_R; end
        H_RD_R: if (s_rvalid) begin
          case (step_q)
            4'd0: status_q <= s_rdata;
            4'd1: exitv_q  <= s_rdata;
            4'd2: cyclo_q  <= s_rdata;
            4'd3: cychi_q  <= s_rdata;
            4'd4: hwlo_q   <= s_rdata;
            default: ucnt_q <= s_rdata;
          endcase
          if (step_q == 4'd0 && !s_rdata[0]) begin
            gap_q <= '0; hs_q <= H_GAP;                    // not done: poll again
            if (cyc_q > tmo_cyc && !tmo_q) begin           // timeout: read the rest and the UART
              $display("[host] timeout at cycle %0d, STATUS = %h", cyc_q, s_rdata);
              tmo_q <= 1'b1; step_q <= 4'd1; s_araddr <= reg_addr(4'd1);
              s_arvalid <= 1'b1; hs_q <= H_RD;
            end
          end else if (step_q == 4'd5) begin
            uaddr_q <= 16'h1000;
            if (s_rdata != 0) begin
              $display("[host] UART (%0d bytes):", s_rdata);
              s_araddr <= 16'h1000; s_arvalid <= 1'b1; hs_q <= H_UART;
            end else hs_q <= H_END;
          end else begin
            step_q <= step_q + 1; s_araddr <= reg_addr(step_q + 1);
            s_arvalid <= 1'b1; hs_q <= H_RD;
          end
        end
        H_UART: begin
          if (s_arvalid && s_arready) s_arvalid <= 1'b0;
          if (s_rvalid) begin
            for (int b = 0; b < 4; b++)
              if (32'(uaddr_q - 16'h1000) + b < ucnt_q && 32'(uaddr_q - 16'h1000) + b < 2048)
                $write("%c", s_rdata[8*b +: 8]);
            if (32'(uaddr_q - 16'h1000) + 4 >= ucnt_q || uaddr_q == 16'h17FC) hs_q <= H_END;
            else begin
              uaddr_q <= uaddr_q + 4; s_araddr <= uaddr_q + 4; s_arvalid <= 1'b1;
            end
          end
        end
        H_END: begin
          if (exit_o == '0) begin
            $display("");
            $display("[host] STATUS %h EXIT %0d CYCLES %0d HWCNT %0d UART bytes %0d",
                     status_q, exitv_q, {cychi_q, cyclo_q}, hwlo_q, ucnt_q);
            $display("[host] DDR handshakes AR %0d AW %0d R %0d B %0d",
                     dut.i_top.n_ar_q, dut.i_top.n_aw_q, dut.i_top.n_r_q, dut.i_top.n_b_q);
            if (tmo_q)             $display("ARA_PS_TB: TIMEOUT");
            else if (exitv_q == 0) $display("ARA_PS_TB: PASS");
            else                   $display("ARA_PS_TB: FAIL (exit %0d)", exitv_q);
            exit_o <= tmo_q ? {63'd99, 1'b1} : {31'b0, exitv_q, 1'b1};
          end else begin
            $finish;
          end
        end
        default: hs_q <= H_IDLE;
      endcase
    end
  end

endmodule : ara_ps_tb
