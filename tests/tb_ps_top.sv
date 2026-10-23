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
// Each run prints PSCSV,<kernel>,<N>,<cycles>,<L1 hits>,<L1 misses>.
// =============================================================================
`timescale 1ns/1ps
module tb_ps_top
  import simtix_pkg::*;
;
    localparam int DW  = 128;
    localparam int IDW = MEM_TAGW + 1;

    localparam logic [31:0] A_DDR = 32'h1000_0000;   // 1024 words
    localparam logic [31:0] C_DDR = 32'h1000_4000;   // results
    localparam int          N     = 1024;

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

    axi_mem_model #(.IDW(IDW), .DW(DW), .LAT(24), .STALL(1), .OOO(1)) u_ddr (
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
        return int'(a[17:2]);
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
        for (int g = 0; g < 100000 && !st[STATUS_DONE_BIT]; g++) axil_rd(16'(REG_STATUS), st);
        if (!st[STATUS_DONE_BIT]) begin $display("  [FAIL] %s timeout", tag); errors++; end
        axil_rd(16'(REG_CYCLES), cyc);
        axil_rd(16'h0100, hits);
        axil_rd(16'h0104, miss);
        axil_rd(16'h0108, err);
        if (err[0]) begin $display("  [FAIL] %s AXI error", tag); errors++; end
        $display("PSCSV,%s,%0d,%0d,%0d,%0d", tag, N, cyc, hits, miss);
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

        // 1. kernels into the instruction RAM, as the host would
        for (int i = 0; i < 128; i++) axil_wr(16'h1000 + 16'(4*i), mem[i]);

        // 2. reduce
        preload_a(0);
        run("reduce_shfl", 32'd0, C_DDR);
        check_reduce("reduce_shfl", 0);

        // 3. histogram (bins after the reduce results)
        for (int b = 0; b < 16; b++) u_ddr.mem[widx(C_DDR + 32'h1000 + 32'(4*b))] = 0;
        run("histogram", 32'd256, C_DDR + 32'h1000);
        for (int b = 0; b < 16; b++) hcount[b] = 0;
        for (int i = 0; i < N; i++) begin
            logic [31:0] v;              // temporary: no function call inside the index
            v = aval(i, 0);
            hcount[v[3:0]]++;
        end
        for (int b = 0; b < 16; b++) chk("histogram", C_DDR + 32'h1000 + 32'(4*b), hcount[b]);

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
