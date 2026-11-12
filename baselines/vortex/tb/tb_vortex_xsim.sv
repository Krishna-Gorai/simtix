// tb_vortex_xsim.sv - the board build's exact configuration in xsim: vortex_ps_wrap with
// the staged sources, defines and Xilinx floating-point IPs (FPU_TYPE=DSP) of
// create_bd_vortex.tcl, which the Verilator testbench (vx_ps_tb.cpp) cannot simulate.
//
// The host (tasks below) does what sw/ps_host/apps.c does with -DSIMTIX_VORTEX: kernel
// arguments at Vortex 0x0001_0000 (DDR 0x4001_0000), the KMU DCRs, START, wait for busy,
// the cache-flush DCR read; then every gold word is compared. The DDR model answers in
// order with random stalls. Inputs from gen_xsim_case.py: +CASE=<dir> (mem.txt,
// launch.txt, gold.txt).
`timescale 1ns/1ps
module tb_vortex_xsim;
  logic clk = 0, aresetn = 0;
  always #4 clk = ~clk;

  logic [15:0]  s_awaddr, s_araddr;
  logic         s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready;
  logic         s_arvalid, s_arready, s_rvalid, s_rready;
  logic [31:0]  s_wdata, s_rdata;
  logic [1:0]   s_bresp, s_rresp;
  logic [5:0]   m_awid, m_bid, m_arid, m_rid;
  logic [31:0]  m_awaddr, m_araddr;
  logic [7:0]   m_awlen, m_arlen;
  logic [2:0]   m_awsize, m_arsize, m_awprot, m_arprot;
  logic [1:0]   m_awburst, m_arburst, m_bresp, m_rresp;
  logic         m_awlock, m_arlock, m_awvalid, m_awready, m_wvalid, m_wready, m_wlast;
  logic         m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;
  logic [3:0]   m_awcache, m_arcache, m_awqos, m_arqos;
  logic [127:0] m_wdata, m_rdata;
  logic [15:0]  m_wstrb;

  vortex_ps_wrap dut (
    .clk(clk), .aresetn(aresetn),
    .s_axi_awaddr(s_awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
    .s_axi_wdata(s_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
    .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
    .s_axi_araddr(s_araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
    .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
    .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
    .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot),
    .m_axi_awqos(m_awqos), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
    .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid),
    .m_axi_wready(m_wready), .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid),
    .m_axi_bready(m_bready),
    .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
    .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot),
    .m_axi_arqos(m_arqos), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
    .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
    .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
  );

  // Heartbeat and watchdog: one line every 10,000 cycles with the DDR traffic so far
  // (a stuck core shows a frozen count), and a stop after +MAXCYC cycles (default 2M).
  longint cyc = 0, maxcyc = 2000000, n_rd = 0, n_wr = 0;
  initial void'($value$plusargs("MAXCYC=%d", maxcyc));
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (m_arvalid && m_arready) n_rd <= n_rd + 1;
    if (m_awvalid && m_awready) n_wr <= n_wr + 1;
    if (cyc % 10000 == 0) $display("[hb] cycle %0d: %0d DDR reads, %0d DDR writes", cyc, n_rd, n_wr);
    if (cyc == maxcyc) begin
      $display("TB_VORTEX_XSIM FAIL: watchdog at %0d cycles", cyc);
      $finish;
    end
  end

  // ── DDR model: word-addressed, in order, random stalls ──────────────────────────
  logic [31:0] mem [logic [31:0]];
  function automatic logic [31:0] mrd(logic [31:0] a); return mem.exists(a) ? mem[a] : 32'h0; endfunction

  int unsigned seed = 5;
  // Responses carry the ID of their request (Vortex matches responses by ID; the
  // Verilator model vx_ps_tb.cpp does the same). Responses stay in request order.
  typedef struct { logic [31:0] addr; int beats; logic [5:0] id; } burst_t;
  burst_t awq[$], arq[$];
  logic [5:0] bq[$];
  int r_beat = 0;
  always @(posedge clk) begin
    m_awready <= ($urandom(seed) % 4) != 0;
    m_wready  <= ($urandom(seed) % 4) != 0;
    m_arready <= ($urandom(seed) % 4) != 0;
  end
  // AW / W (data may come first: beats are applied once their AW is known); B in order
  logic [127:0] wbuf_d[$]; logic [15:0] wbuf_s[$];
  always @(posedge clk) if (!aresetn) begin
    m_bvalid <= 1'b0; m_bid <= '0; m_bresp <= 2'b00;
  end else begin
    if (m_bvalid && m_bready) void'(bq.pop_front());
    if (m_awvalid && m_awready) awq.push_back('{m_awaddr, int'(m_awlen) + 1, m_awid});
    if (m_wvalid && m_wready) begin wbuf_d.push_back(m_wdata); wbuf_s.push_back(m_wstrb); end
    while (awq.size() > 0 && wbuf_d.size() >= awq[0].beats) begin
      for (int bt = 0; bt < awq[0].beats; bt++) begin
        logic [127:0] d = wbuf_d.pop_front(); logic [15:0] s = wbuf_s.pop_front();
        for (int k = 0; k < 4; k++) begin
          logic [31:0] a = (awq[0].addr & ~32'hF) + 16 * bt + 4 * k;
          logic [31:0] o = mrd(a);
          for (int y = 0; y < 4; y++) if (s[4 * k + y]) o[8 * y +: 8] = d[32 * k + 8 * y +: 8];
          mem[a] = o;
        end
      end
      bq.push_back(awq[0].id);
      void'(awq.pop_front());
    end
    m_bvalid <= bq.size() > 0;
    m_bid    <= bq.size() > 0 ? bq[0] : '0;
    m_bresp  <= 2'b00;
  end
  // AR / R: the clocked block presents the current beat of the oldest burst
  always @(posedge clk) if (!aresetn) begin
    m_rvalid <= 1'b0; m_rlast <= 1'b0; m_rid <= '0; m_rresp <= 2'b00; m_rdata <= '0;
  end else begin
    if (m_rvalid && m_rready) begin
      if (r_beat + 1 == arq[0].beats) begin void'(arq.pop_front()); r_beat = 0; end
      else r_beat++;
    end
    if (m_arvalid && m_arready) arq.push_back('{m_araddr, int'(m_arlen) + 1, m_arid});
    m_rvalid <= arq.size() > 0;
    m_rresp  <= 2'b00;
    if (arq.size() > 0) begin
      m_rid   <= arq[0].id;
      m_rlast <= r_beat + 1 == arq[0].beats;
      for (int k = 0; k < 4; k++) m_rdata[32 * k +: 32] <= mrd((arq[0].addr & ~32'hF) + 16 * r_beat + 4 * k);
    end else m_rlast <= 1'b0;
  end

  // ── Host ────────────────────────────────────────────────────────────────────────
  task automatic reg_wr(input logic [15:0] a, input logic [31:0] v);
    @(negedge clk); s_awaddr = a; s_wdata = v; s_awvalid = 1; s_wvalid = 1; s_bready = 1;
    do @(posedge clk); while (!s_awready);
    @(negedge clk); s_awvalid = 0; s_wvalid = 0;
    while (!s_bvalid) @(posedge clk);
    @(negedge clk); s_bready = 0;
  endtask
  task automatic reg_rd(input logic [15:0] a, output logic [31:0] v);
    @(negedge clk); s_araddr = a; s_arvalid = 1; s_rready = 1;
    do @(posedge clk); while (!s_arready);
    @(negedge clk); s_arvalid = 0;
    while (!s_rvalid) @(posedge clk);
    v = s_rdata;
    @(negedge clk); s_rready = 0;
  endtask
  task automatic dcr(input logic [11:0] a, input logic [31:0] v);
    reg_wr(16'h0C, a); reg_wr(16'h10, v);
  endtask
  task automatic busycyc(output longint c);
    logic [31:0] lo, hi; reg_rd(16'h1C, lo); reg_rd(16'h20, hi); c = {hi, lo};
  endtask

  initial begin
    string dir, fn;
    int fd, app, thr, blk, lmem, errs, chk;
    logic [31:0] a, v, base, pc, prm, st;
    longint c0, c1, c2;
    s_awvalid = 0; s_wvalid = 0; s_arvalid = 0; s_bready = 0; s_rready = 0;
    if (!$value$plusargs("CASE=%s", dir)) $fatal(1, "+CASE=<dir> missing");
    fd = $fopen({dir, "/mem.txt"}, "r");
    while ($fscanf(fd, "%h %h", a, v) == 2) mem[a] = v;
    $fclose(fd);
    $display("DDR model: %0d words loaded", mem.num());
    repeat (20) @(posedge clk); aresetn = 1; repeat (20) @(posedge clk);
    reg_rd(16'h24, v); $display("INFO %08x", v);
    reg_wr(16'h00, 1); repeat (64) @(posedge clk); reg_wr(16'h00, 0); repeat (64) @(posedge clk);
    fd = $fopen({dir, "/launch.txt"}, "r");
    void'($fscanf(fd, "%h %h", base, pc));
    while ($fscanf(fd, "%d %h %d %d %d", app, prm, thr, blk, lmem) == 5) begin
      mem[32'h4001_0000] = app; mem[32'h4001_0004] = prm; mem[32'h4001_0008] = thr;
      dcr(12'h010, base); dcr(12'h011, 0); dcr(12'h012, pc); dcr(12'h013, 0);
      dcr(12'h014, 32'h0001_0000); dcr(12'h015, 0);
      dcr(12'h016, blk); dcr(12'h017, 1); dcr(12'h018, 1);
      dcr(12'h019, thr / blk); dcr(12'h01A, 1); dcr(12'h01B, 1);
      dcr(12'h01C, lmem); dcr(12'h01D, blk);
      dcr(12'h01E, 8 % blk); dcr(12'h01F, 0); dcr(12'h020, 0);
      dcr(12'h021, 1); dcr(12'h022, 1); dcr(12'h023, 1);
      busycyc(c0);
      reg_wr(16'h04, 1);
      do begin repeat (200) @(posedge clk); reg_rd(16'h08, st); end while (st[0]);
      busycyc(c1);
      reg_wr(16'h0C, 0); reg_wr(16'h14, 0);
      do begin repeat (50) @(posedge clk); reg_rd(16'h08, st); end while (st[1:0] != 2'b10);
      busycyc(c2);
      $display("launch app %0d, %0d threads: %0d cycles + %0d flush", app, thr, c1 - c0, c2 - c1);
    end
    $fclose(fd);
    reg_rd(16'h08, st);
    if (st[2]) begin reg_rd(16'h38, v); $display("ADDRESS OUTSIDE THE WINDOWS: %08x", v); end
    errs = 0; chk = 0;
    fd = $fopen({dir, "/gold.txt"}, "r");
    while ($fscanf(fd, "%h %h", a, v) == 2) begin
      chk++;
      if (mrd(a) !== v) begin
        if (errs < 8) $display("  [FAIL] %08x: got %08x want %08x", a, mrd(a), v);
        errs++;
      end
    end
    $fclose(fd);
    $display("%s: %0d words checked, %0d wrong", errs || st[2] ? "TB_VORTEX_XSIM FAIL" : "TB_VORTEX_XSIM PASS", chk, errs);
    $finish;
  end
endmodule
