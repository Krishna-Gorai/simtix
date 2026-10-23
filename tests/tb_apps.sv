// =============================================================================
// tb_apps.sv  -  v2 application suite on the board top (simt_ps_top)
//
// The host side is AXI4-Lite tasks, as in tb_ps_top; DDR4 is axi_mem_model
// (4 MB, MEM_LAT cycles, out of order, with ready stalls). Everything a case
// needs comes from the manifest that sim/gen_apps.py writes:
//   KERNEL <slot> <hex>        kernel image -> instruction RAM at 256*slot bytes
//   CASE <name>                start a case: the DDR4 model is cleared
//   MEM <file>                 $readmemh preload of the DDR4 model
//   LAUNCH <tag> <slot> <param address> <threads> <block_log2>
//   GOLD <file>                "<word index> <value>" pairs to compare
//   END                        end of the case
// A launch passes its parameter-block address in REG_BASE_A (a1). Each launch
// prints APPCSV,<case>,<tag>,<threads>,<cycles>,<L1 hits>,<L1 misses>.
// The manifest is +MANIFEST=<path>, else build_apps/apps.manifest found from
// sim/ (Verilator) or build_xsim/<test>/ (xsim).
// =============================================================================
`timescale 1ns/1ps
module tb_apps
  import simtix_pkg::*;
#(
    parameter int MEM_LAT = 24,
    parameter int AGG     = 1,      // AMO variant (see mem_engine)
    parameter int APAR    = 0
);
    localparam int DW    = 128;
    localparam int IDW   = MEM_TAGW + 1;
    localparam int WORDS = 1 << 20;

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

    simt_ps_top #(.AXI_DW(DW), .AMO_AGG(AGG != 0), .AMO_PAR(APAR != 0)) dut (
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

    axi_mem_model #(.IDW(IDW), .DW(DW), .WORDS(WORDS), .LAT(MEM_LAT), .STALL(1), .OOO(1)) u_ddr (
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

    int unsigned errors = 0, checks = 0;
    string       cname;

    /* verilator lint_off UNUSEDSIGNAL */   // only bit 0 of the status words is read
    task automatic launch(input string tag, input int slot, input logic [31:0] prm,
                          input int n, input int blk);
        logic [31:0] st, cyc, hits, miss, err;
        axil_wr(16'(REG_KERNEL_PC), 32'(256*slot));
        axil_wr(16'(REG_BASE_A), prm);
        axil_wr(16'(REG_BASE_B), 32'd0);
        axil_wr(16'(REG_BASE_C), 32'd0);
        axil_wr(16'(REG_N), 32'(n));
        axil_wr(16'(REG_BLOCK), 32'(blk));
        axil_wr(16'(REG_CTRL), 32'd1);
        st = 0;
        for (int g = 0; g < 2000000 && !st[STATUS_DONE_BIT]; g++) axil_rd(16'(REG_STATUS), st);
        if (!st[STATUS_DONE_BIT]) begin $display("  [FAIL] %s/%s timeout", cname, tag); errors++; end
        axil_rd(16'(REG_CYCLES), cyc);
        axil_rd(16'h0100, hits);
        axil_rd(16'h0104, miss);
        axil_rd(16'h0108, err);
        if (err[0]) begin $display("  [FAIL] %s/%s AXI error", cname, tag); errors++; end
        $display("APPCSV,%s,%s,%0d,%0d,%0d,%0d", cname, tag, n, cyc, hits, miss);
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    task automatic load_kernel(input int slot, input string path);
        logic [31:0] kimg [0:63];
        for (int i = 0; i < 64; i++) kimg[i] = 32'h0000_0013;   // nop
        $readmemh(path, kimg);
        for (int i = 0; i < 64; i++) axil_wr(16'h1000 + 16'(256*slot + 4*i), kimg[i]);
    endtask

    task automatic check_gold(input string path);
        int          fd, idx;
        logic [31:0] exp, got;
        int unsigned bad;
        bad = 0;
        fd  = $fopen(path, "r");
        if (fd == 0) begin $display("  [FAIL] %s: cannot open %s", cname, path); errors++; return; end
        while ($fscanf(fd, "%h %h\n", idx, exp) == 2) begin
            got = u_ddr.mem[idx];
            checks++;
            if (got !== exp) begin
                if (bad < 8) $display("  [FAIL] %s word %0h: got=%08h exp=%08h", cname, idx, got, exp);
                bad++;
            end
        end
        $fclose(fd);
        errors += bad;
        // (xsim: a ternary of a string literal and $sformatf does not format as %s)
        if (bad == 0) $display("  %-22s ok", cname);
        else          $display("  %-22s %0d wrong", cname, bad);
    endtask

    string manifest;
    initial begin
        int    fd, slot, n, blk;
        string line, key, a1, tag;
        logic [31:0] prm;
        rst = 1; awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0;
        repeat (4) @(posedge clk);
        rst = 0;

        if (!$value$plusargs("MANIFEST=%s", manifest)) begin
            manifest = "../build_apps/apps.manifest";
            fd = $fopen(manifest, "r");
            if (fd == 0) manifest = "../../build_apps/apps.manifest";
            else $fclose(fd);
        end
        fd = $fopen(manifest, "r");
        if (fd == 0) begin
            $display("[tb_apps] FAIL: no manifest (%s); run sim/gen_apps.py", manifest);
            $finish;
        end
        $display("[tb_apps] manifest %s, DDR4 latency %0d cycles, AGG=%0d APAR=%0d",
                 manifest, MEM_LAT, AGG, APAR);
        while ($fgets(line, fd) > 0) begin
            if ($sscanf(line, "%s", key) != 1) continue;
            if (key == "KERNEL") begin
                void'($sscanf(line, "%s %d %s", key, slot, a1));
                load_kernel(slot, a1);
            end else if (key == "CASE") begin
                void'($sscanf(line, "%s %s", key, cname));
                for (int i = 0; i < WORDS; i++) u_ddr.mem[i] = 32'd0;
            end else if (key == "MEM") begin
                void'($sscanf(line, "%s %s", key, a1));
                $readmemh(a1, u_ddr.mem);
            end else if (key == "LAUNCH") begin
                void'($sscanf(line, "%s %s %d %h %d %d", key, tag, slot, prm, n, blk));
                launch(tag, slot, prm, n, blk);
            end else if (key == "GOLD") begin
                void'($sscanf(line, "%s %s", key, a1));
                check_gold(a1);
            end
        end
        $fclose(fd);

        $display("[tb_apps] %0d checks, %0d errors", checks, errors);
        if (errors == 0 && checks != 0) $display("[tb_apps] PASS");
        else                            $display("[tb_apps] FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("[tb_apps] FAIL: TIMEOUT");
        $finish;
    end
endmodule : tb_apps
