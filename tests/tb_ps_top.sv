// =============================================================================
// tb_ps_top.sv  -  v2 board top (simt_ps_top) driven the way the ARM host will
//
// The host side is AXI4-Lite tasks; DDR4 is axi_mem_model (24-cycle, out of
// order, with ready stalls). The test:
//   1. writes reduce_shfl (PC 0) and histogram (PC 256) into the instruction RAM
//   2. reduce_shfl, N = 1024: C[w] = sum of A[8w .. 8w+7]
//   3. histogram,  N = 1024: C[b] = #{i : A[i] mod 16 = b}   (global AMOs)
//   4. the host changes A in DDR4 and reruns reduce_shfl: the results must use
//      the new data, which checks that GO invalidates the L1
// N (default 1024) sets the size of all three; the board runs N up to 262144. With
// a large N the stream of A evicts the histogram's bin lines from the L1, and an
// AMO read then misses while the previous AMO write is still in flight; with
// MEM_LATE = 1 that read must not see memory before the write has taken effect.
// Each run prints PSCSV,<kernel>,<N>,<cycles>,<L1 hits>,<L1 misses>.
// =============================================================================
`timescale 1ns/1ps
module tb_ps_top
  import simtix_pkg::*;
#(
    parameter int MEM_LAT  = 24,    // DDR4 model latency, see axi_mem_model
    parameter int MEM_RJW  = 3,
    parameter int MEM_BLAT = -1,
    parameter int MEM_SEED = 32'hBEEF,
    parameter int MEM_LATE = 0,
    parameter int N        = 1024   // elements of A (a multiple of 8)
);
    localparam int DW  = 128;
    localparam int IDW = MEM_TAGW + 1;

    // A, then the reduce results (N/8 words) at C_DDR and the 16 bins at C_DDR + H_OFF.
    localparam logic [31:0] A_DDR = 32'h1000_0000;
    localparam logic [31:0] C_DDR = A_DDR + ((4*N > 32'h4000) ? 32'(8*N) : 32'h4000);
    localparam logic [31:0] H_OFF = (N/2 > 32'h1000) ? 32'(N/2) : 32'h1000;
    localparam int WORDS_LG = (N <= 4096) ? 16 : $clog2(N) + 2;   // DDR4 model size

    logic clk = 0;
    logic rst;
    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // AXI4-Lite (host -> board top)
    logic [15:0] awaddr, araddr;
    logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
    logic [31:0] wdata, rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0]  bresp, rresp;
    /* verilator lint_on UNUSEDSIGNAL */

    // AXI4 (board top -> DDR model)
    logic [IDW-1:0]  m_awid, m_bid, m_arid, m_rid;
    logic [31:0]     m_awaddr, m_araddr;
    logic [7:0]      m_awlen, m_arlen;
    logic [2:0]      m_awsize, m_arsize, m_awprot, m_arprot;
    logic [1:0]      m_awburst, m_arburst, m_bresp, m_rresp;
    logic [3:0]      m_awcache, m_arcache;
    logic            m_awvalid, m_awready, m_wvalid, m_wready, m_wlast, m_bvalid, m_bready;
    logic            m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;
    logic [DW-1:0]   m_wdata, m_rdata;
    logic [DW/8-1:0] m_wstrb;

`ifdef PS_WRAP
    // The block design's view (+define PS_WRAP=<IDW>): the Verilog wrapper with the
    // ID width the build gives the cell. The block design connects only the lower
    // ID bits, and the HP port returns the upper ones as 0; so does this hookup. An
    // ID narrower than the core's (MEM_TAGW + 1) drops the read/write bit and the
    // test hangs, as the board did with the B3+B4 build of 2026-11-03.
    localparam int WIDW = `PS_WRAP;
    logic [WIDW-1:0] w_awid, w_arid;
    assign m_awid = IDW'(w_awid);
    assign m_arid = IDW'(w_arid);
    simt_ps_wrap #(.IDW(WIDW)) dut (
        .clk(clk), .aresetn(!rst),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axi_awid(w_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst), .m_axi_awcache(m_awcache),
        .m_axi_awprot(m_awprot), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid[WIDW-1:0]), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid),
        .m_axi_bready(m_bready),
        .m_axi_arid(w_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst), .m_axi_arcache(m_arcache),
        .m_axi_arprot(m_arprot), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid[WIDW-1:0]), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));
`else
    simt_ps_top #(.AXI_DW(DW)) dut (
        .clk(clk), .rst(rst),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst), .m_axi_awcache(m_awcache),
        .m_axi_awprot(m_awprot), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst), .m_axi_arcache(m_arcache),
        .m_axi_arprot(m_arprot), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));
`endif

    axi_mem_model #(.IDW(IDW), .DW(DW), .WORDS(1 << WORDS_LG), .MAXB(LINE_BITS / DW),
                    .LAT(MEM_LAT), .STALL(1), .OOO(1),
                    .RJW(MEM_RJW), .BLAT(MEM_BLAT), .SEED(16'(MEM_SEED)),
                    .LATE(MEM_LATE)) u_ddr (
        .clk(clk), .rst(rst),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize),
        .awburst(m_awburst), .awcache(m_awcache), .awprot(m_awprot),
        .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize),
        .arburst(m_arburst), .arcache(m_arcache), .arprot(m_arprot),
        .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready));

    // ── Host AXI4-Lite tasks ─────────────────────────────────────────────────────
    task automatic axil_wr(input logic [15:0] a, input logic [31:0] d);
        @(posedge clk); #1;
        awaddr = a; awvalid = 1; wdata = d; wvalid = 1; bready = 1;
        do @(posedge clk); while (!(awready && wready));
        #1 awvalid = 0; wvalid = 0;
        while (!bvalid) @(posedge clk);
        @(posedge clk); #1 bready = 0;
    endtask

    task automatic axil_rd(input logic [15:0] a, output logic [31:0] d);
        @(posedge clk); #1;
        araddr = a; arvalid = 1; rready = 1;
        do @(posedge clk); while (!arready);
        #1 arvalid = 0;
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(posedge clk); #1 rready = 0;
    endtask

    // Helpers below read sub-fields of words (addresses, hashes, status words).
    /* verilator lint_off UNUSEDSIGNAL */
    // ── Kernel images (kernels/sync/*.svh write mem[at+k]) ───────────────────────
    logic [31:0] mem [0:511];
    int          at;
    int unsigned errors = 0, checks = 0;
    int unsigned hcount [16];

    function automatic int unsigned widx(input logic [31:0] a);
        return int'(a[WORDS_LG+1:2]);
    endfunction
    function automatic logic [31:0] aval(input int i, input int gen);
        logic [31:0] h;
        h = (i * 32'd2654435761) ^ (gen * 32'h9E3779B9);
        return {20'd0, h[23:12]};
    endfunction

    task automatic run(input string tag, input logic [31:0] pc, input logic [31:0] c_ddr);
        logic [31:0] st, cyc, hits, miss, err;
        axil_wr(16'(REG_KERNEL_PC), pc);
        axil_wr(16'(REG_BASE_A), A_DDR);
        axil_wr(16'(REG_BASE_C), c_ddr);
        axil_wr(16'(REG_N), N);
        axil_wr(16'(REG_BLOCK), 0);
        axil_wr(16'(REG_CTRL), 32'd1);
        st = 0;
        for (int g = 0; g < 100000 + 4*N && !st[STATUS_DONE_BIT]; g++) axil_rd(16'(REG_STATUS), st);
        if (!st[STATUS_DONE_BIT]) begin $display("  [FAIL] %s timeout", tag); errors++; end
        axil_rd(16'(REG_CYCLES), cyc);
        axil_rd(16'h0100, hits);
        axil_rd(16'h0104, miss);
        axil_rd(16'h0108, err);
        if (err[0]) begin $display("  [FAIL] %s AXI error", tag); errors++; end
        $display("PSCSV,%s,%0d,%0d,%0d,%0d", tag, N, cyc, hits, miss);
        dbgchk(tag);
    endtask

    // Debug window (0x0200): after a kernel nothing is in flight, so every warp slot
    // is empty or done, no context, tag or miss register is in use, and the AXI port
    // has answered every read and write it issued.
    task automatic dbgchk(input string tag);
        logic [31:0] w [0:63];
        for (int i = 0; i < 64; i++) axil_rd(16'h0200 + 16'(4*i), w[i]);
        checks++;
        if (w[1][7:0] != 0 || w[2] != 0 || w[28][15:0] != 0 || w[29] != 0 || w[44] != 0 ||
            w[48] != 0 || w[57] != 0 || w[58] != 0 || w[59] == 0 || w[61] == 0) begin
            $display("  [FAIL] %s debug window: sleep %h loads %h ctx %h tags %h mshr %h wack %h axi %0d/%0d",
                     tag, w[1], w[2], w[28], w[29], w[44], w[48], w[57], w[58]);
            errors++;
        end
        $display("PSDBG,%s,warps=%h,AR=%0d,R=%0d,AW=%0d,B=%0d", tag, w[0], w[59], w[60], w[61], w[62]);
    endtask

    task automatic chk(input string tag, input logic [31:0] addr, input logic [31:0] exp);
        logic [31:0] got;
        got = u_ddr.mem[widx(addr)];
        checks++;
        if (got !== exp) begin
            if (errors < 10) $display("  [FAIL] %s @%h got=%h exp=%h", tag, addr, got, exp);
            errors++;
        end
    endtask

    task automatic preload_a(input int gen);
        for (int i = 0; i < N; i++) begin
            logic [31:0] v;
            v = aval(i, gen);
            u_ddr.mem[widx(A_DDR + 32'(4*i))] = v;
        end
    endtask

    task automatic check_reduce(input string tag, input int gen);
        for (int w = 0; w < N/8; w++) begin
            logic [31:0] s;
            s = 0;
            for (int l = 0; l < 8; l++) s += aval(8*w + l, gen);
            chk(tag, C_DDR + 32'(4*w), s);
        end
    endtask

    initial begin
        rst = 1; awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0;
        for (int i = 0; i < 512; i++) mem[i] = 32'h0000_0013;   // nop
        at = 0;  `include "reduce_shfl.svh"
        at = 64; `include "histogram.svh"
        repeat (4) @(posedge clk);
        rst = 0;
`ifdef PS_WRAP
        repeat (8) @(posedge clk);       // the wrapper's reset synchroniser
`endif

        // 1. kernels into the instruction RAM, as the host would
        for (int i = 0; i < 128; i++) axil_wr(16'h1000 + 16'(4*i), mem[i]);

        // 2. reduce
        preload_a(0);
        run("reduce_shfl", 32'd0, C_DDR);
        check_reduce("reduce_shfl", 0);

        // 3. histogram (bins after the reduce results)
        for (int b = 0; b < 16; b++) u_ddr.mem[widx(C_DDR + H_OFF + 32'(4*b))] = 0;
        run("histogram", 32'd256, C_DDR + H_OFF);
        for (int b = 0; b < 16; b++) hcount[b] = 0;
        for (int i = 0; i < N; i++) begin
            logic [31:0] v;              // temporary: no function call inside the index
            v = aval(i, 0);
            hcount[v[3:0]]++;
        end
        for (int b = 0; b < 16; b++) chk("histogram", C_DDR + H_OFF + 32'(4*b), hcount[b]);

        // 4. new data in DDR4, rerun: must not see stale L1 lines
        preload_a(1);
        run("reduce_rerun", 32'd0, C_DDR);
        check_reduce("reduce_rerun", 1);

        $display("[tb_ps_top] %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("[tb_ps_top] PASS");
        else             $display("[tb_ps_top] FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[tb_ps_top] FAIL: TIMEOUT");
        $finish;
    end
    /* verilator lint_on UNUSEDSIGNAL */
endmodule : tb_ps_top
