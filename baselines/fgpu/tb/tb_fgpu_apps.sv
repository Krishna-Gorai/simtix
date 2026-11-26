// tb_fgpu_apps.sv - SIMTiX's simulation cases (sim/gen_*.py) on FGPU's board wrapper, driven as the
// A53 host drives it (docs/fgpu_plan.md, phase 1; before the board runs). Input: the file of
// gen_fgpu_cases.py (+CASES=<file>) and FGPU's kernel image (+CODE=<hex>, +CODELEN=<words>):
//   CASE <name> <tol>   MEM <file>   LAUNCH <entry> <param address hex> <work-items>   GOLD <file>   END
// The code image is written to FGPU's code RAM once. Per case the memory model is cleared and
// preloaded ($readmemh, the window at 0x1000_0000 aliases to word 0, as tests/tb_apps.sv); each
// launch: kernel descriptor (entry, global size = work-items rounded up to 64, work-group 64,
// 2 parameters: the parameter block and the work-item count), INITIATE, CLEAN_CACHE, START,
// poll STATUS. Then the gold words: tol 0 exact; tol 1 (fused multiply-adds in the definition,
// FGPU multiplies and adds separately) within 1e-3 of the case's largest |gold|, the worst ratio
// printed. One line per case: "FGCASE <name> <launches> <words> <exact> <errors> <worst> <ns>".
`timescale 1ns/1ps
module tb_fgpu_apps;
    logic clk = 0, aresetn = 0;
    always #5 clk = ~clk;                                // 100 MHz

    logic [15:0] awaddr, araddr;
    logic        awvalid, wvalid, bready, arvalid, rready;
    logic [31:0] wdata;
    wire         awready, wready, bvalid, arready, rvalid;
    wire  [1:0]  bresp, rresp;
    wire  [31:0] rdata;
    wire [5:0]  m_awid, m_bid, m_arid, m_rid;
    wire [31:0] m_awaddr, m_araddr;
    wire [7:0]  m_awlen, m_arlen, m_wstrb;
    wire [2:0]  m_awsize, m_arsize, m_awprot, m_arprot;
    wire [1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
    wire [3:0]  m_awcache, m_arcache, m_awqos, m_arqos;
    wire        m_awlock, m_arlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready;
    wire        m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    wire [63:0] m_wdata, m_rdata;

    fgpu_ps_wrap dut (
        .clk(clk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache),
        .m_axi_awprot(m_awprot), .m_axi_awqos(m_awqos), .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready), .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb),
        .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache),
        .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos), .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready), .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));

    localparam int WORDS = 1 << 20;     // 4 MB: the cases' window at 0x1000_0000 aliases to word 0
    axi_mem_model #(.IDW(6), .DW(64), .WORDS(WORDS), .MAXB(16), .LAT(24), .STALL(1), .OOO(1),
                    .LATE(1)) mem (
        .clk(clk), .rst(!aresetn),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
        .awcache(m_awcache), .awprot(m_awprot), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
        .arcache(m_arcache), .arprot(m_arprot), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid),
        .rready(m_rready));

    task automatic wr(input logic [15:0] a, input logic [31:0] d);
        @(posedge clk);
        awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1; bready <= 1;
        fork
            begin do @(posedge clk); while (!awready); awvalid <= 0; end
            begin do @(posedge clk); while (!wready);  wvalid  <= 0; end
        join
        while (!bvalid) @(posedge clk);
        @(posedge clk); bready <= 0;
    endtask
    task automatic rd(input logic [15:0] a, output logic [31:0] d);
        @(posedge clk);
        araddr <= a; arvalid <= 1; rready <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0;
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(posedge clk); rready <= 0;
    endtask

    localparam logic [15:0] CRAM = 16'h4000, STATUS = 16'h8000, START = 16'h8004,
                            CLEAN_CACHE = 16'h8008, INITIATE = 16'h800C;
    int total_err = 0, total_words = 0, ncases = 0;

    task automatic launch(input int entry, input logic [31:0] pa, input int n, output bit ok);
        logic [31:0] st;
        int sz, cyc;
        longint t_start;
        sz = (n + 63) / 64 * 64;
        cyc = 0;
        for (int i = 0; i < 12; i++) wr(16'(4 * i), 0);
        wr(16'h00, entry);                                // nWF_WG-1 = 0, entry word
        wr(16'h04, sz);                                   // size0
        wr(16'h1C, 64);                                   // nDim-1 = 0, wg_size0 = 64
        wr(16'h20, sz / 64 - 1);                          // n_wg0-1
        wr(16'h24, 32'hFFFF_FFFF);                        // n_wg1-1, n_wg2-1 (1-D)
        wr(16'h28, 32'hFFFF_FFFF);
        wr(16'h2C, (2 << 28) | 64);                       // nParams = 2, wg_size
        wr(16'h40, pa);                                   // the parameter block
        wr(16'h44, n);                                    // the work-item count
        wr(INITIATE, 32'hFFFF);
        wr(CLEAN_CACHE, 32'hFFFF);
        wr(START, 1);
        t_start = $time;
        do begin rd(STATUS, st); cyc++; end while (st == 0 && cyc < 4000000);
        ok = (st != 0);
        // progress, one line per launch (xsim runs FGPU at ~100-300 cycles/s: a case can take hours)
        $display("FGLAUNCH entry %0d n %0d %0d cycles at %0t%s", entry, n, ($time - t_start) / 10,
                 $time, ok ? "" : " TIMEOUT");
        // FGPU raises STATUS when its end-of-kernel cache sweep has queued the last dirty lines,
        // not when they are written (gmem_cntrl_tag.vhd: finish_exec needs only idle AXI writers
        // at that moment). A case whose outputs end on the last cache lines (gemm_rb_64: C at
        // 0x8000..0xBFFF, lines 126-127 of 128) reads them 0 after a fixed 40 cycles: wait for
        // 128 cycles without write traffic instead.
        begin
            int idle = 0, w = 0;
            while (idle < 128 && w < 100000) begin
                @(posedge clk); w++;
                idle = (m_awvalid || m_wvalid || m_bvalid) ? 0 : idle + 1;
            end
        end
    endtask

    task automatic check(input string name, input string gold, input int tol, input int nl,
                         input longint t0);
        int fd, idx, words, exact, errs, r;
        logic [31:0] v, got;
        real gmax, worst, d, q;
        int idxs[$];
        logic [31:0] vals[$];
        words = 0; exact = 0; errs = 0; gmax = 0.0; worst = 0.0;
        fd = $fopen(gold, "r");
        if (fd == 0) begin $display("  [FAIL] %s: no gold file %s", name, gold); total_err++; return; end
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h\n", idx, v);           // "<word index hex> <value hex>"
            if (r == 2) begin idxs.push_back(idx); vals.push_back(v); end
            else break;
        end
        $fclose(fd);
        if (tol) foreach (vals[i]) begin
            d = $bitstoshortreal(vals[i]);
            if (d < 0) d = -d;
            if (d > gmax) gmax = d;
        end
        foreach (vals[i]) begin
            got = mem.mem[idxs[i]];
            words++;
            if (got === vals[i]) begin exact++; continue; end
            if (tol && gmax > 0.0) begin
                d = $bitstoshortreal(got) - $bitstoshortreal(vals[i]);
                if (d < 0) d = -d;
                q = d / gmax;
                if (q == q && q <= 1.0e-3) begin
                    if (q > worst) worst = q;
                    continue;
                end
                if (q == q && q > worst) worst = q;
            end
            if (errs < 5) $display("  [FAIL] %s word %0d = %08h, expected %08h", name, idxs[i], got, vals[i]);
            errs++;
        end
        total_err += errs;
        total_words += words;
        $display("FGCASE %s %0d %0d %0d %0d %e %0d", name, nl, words, exact, errs, worst, $time - t0);
    endtask

    initial begin
        string cases, code, line, kw, name, f1;
        int codelen, fd, tol, entry, n, nl, r;
        longint t0;
        logic [31:0] pa;
        logic [31:0] img [0:4095];
        bit ok;
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        if (!$value$plusargs("CASES=%s", cases)) $fatal(1, "+CASES=<file> missing");
        if (!$value$plusargs("CODE=%s", code)) $fatal(1, "+CODE=<hex> missing");
        if (!$value$plusargs("CODELEN=%d", codelen)) $fatal(1, "+CODELEN=<words> missing");
        repeat (20) @(posedge clk);
        aresetn = 1;
        repeat (20) @(posedge clk);
        $readmemh(code, img);
        for (int i = 0; i < codelen; i++) wr(CRAM + 16'(4 * i), img[i]);
        fd = $fopen(cases, "r");
        if (fd == 0) $fatal(1, "cannot open %s", cases);
        nl = 0; t0 = 0; name = ""; tol = 0;
        while (!$feof(fd)) begin
            line = "";
            r = $fgets(line, fd);
            if (line.len() < 3) continue;
            r = $sscanf(line, "%s", kw);
            if (kw == "CASE") begin
                r = $sscanf(line, "%s %s %d", kw, name, tol);
                for (int i = 0; i < WORDS; i++) mem.mem[i] = 32'h0;
                nl = 0; t0 = $time; ncases++;
            end else if (kw == "MEM") begin
                r = $sscanf(line, "%s %s", kw, f1);
                $readmemh(f1, mem.mem);
            end else if (kw == "LAUNCH") begin
                r = $sscanf(line, "%s %d %h %d", kw, entry, pa, n);
                launch(entry, pa, n, ok);
                nl++;
                if (!ok) begin $display("  [FAIL] %s launch %0d: no completion", name, nl); total_err++; end
            end else if (kw == "GOLD") begin
                r = $sscanf(line, "%s %s", kw, f1);
                check(name, f1, tol, nl, t0);
            end
        end
        $fclose(fd);
        $display("[tb_fgpu_apps] %0d cases, %0d gold words, %0d errors", ncases, total_words, total_err);
        if (total_err == 0) $display("[tb_fgpu_apps] PASS");
        else                $display("[tb_fgpu_apps] FAIL");
        $finish;
    end
endmodule
