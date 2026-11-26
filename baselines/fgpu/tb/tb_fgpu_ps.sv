// tb_fgpu_ps.sv - FGPU's board wrapper (rtl/fgpu_ps_wrap.v) driven as the A53 host will drive
// it on the ZCU102 (docs/fgpu_plan.md, phase 0 step 4; sim-before-synth): the AXI4-Lite
// writes and reads of FGPU's own host code (benchmark/*/src/kernel_descriptor.cpp:
// download_code, download_descriptor, compute_on_FGPU), against the AXI4 memory model of
// SIMTiX's tests (24-cycle latency, out-of-order responses, ready stalls, writes effective at
// their B response as on the board).
//
// Kernels: images from FGPU's compiler as built here (kernels/compile.sh -> <name>.hex):
//   vec_add (int, entry VEC_ADD_POS)        out[i] = in1[i] + in2[i]
//   add_hard_float (entry 0, -hard-float)   out[i] = in1[i] + in2[i] (FP32, FLOAT_IMPLEMENT)
// Plusargs: +KDIR=<dir with vec_add.hex, vec_add_hard_float.hex> +N=<work-items, multiple of 64>
`timescale 1ns/1ps
module tb_fgpu_ps;
    logic clk = 0, aresetn = 0;
    always #5 clk = ~clk;                                // 100 MHz

    // AXI4-Lite host port
    logic [15:0] awaddr, araddr;
    logic        awvalid, wvalid, bready, arvalid, rready;
    logic [31:0] wdata;
    wire         awready, wready, bvalid, arready, rvalid;
    wire  [1:0]  bresp, rresp;
    wire  [31:0] rdata;
    // AXI4 memory port
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

    localparam int WORDS = 1 << 18;                      // 1 MB, aliases above
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

    // ── AXI4-Lite host, as Xil_Out32 / Xil_In32 ─────────────────────────────────────
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
    localparam logic [31:0] P1 = 32'h0001_0000, P2 = 32'h0002_0000, TGT = 32'h0003_0000;
    int errors = 0, checks = 0;
    logic [31:0] code [0:1023];

    // one kernel run, as kernel<T>::download_code/download_descriptor/compute_on_FGPU
    task automatic run(input string name, input string hexf, input int len, input int pos,
                       input int n, input bit fp);
        logic [31:0] st, want, got;
        int wg, nwf, nwg, t0, cyc;
        shortreal a, b;
        $readmemh(hexf, code);
        for (int i = 0; i < len; i++) wr(CRAM + 16'(4 * i), code[i]);
        for (int i = 0; i < n; i++) begin                 // initialize_memory
            if (fp) begin
                a = shortreal'(i); b = shortreal'(3 * i) + 0.25;
                mem.mem[(P1 >> 2) + i] = $shortrealtobits(a);
                mem.mem[(P2 >> 2) + i] = $shortrealtobits(b);
            end else begin
                mem.mem[(P1 >> 2) + i] = i * 7 + 1;
                mem.mem[(P2 >> 2) + i] = 32'hFFFF_0000 + i;
            end
            mem.mem[(TGT >> 2) + i] = 32'hDEAD_BEEF;
        end
        wg = (n < 64) ? n : 64; nwg = n / wg; nwf = (wg + 63) / 64;
        for (int i = 0; i < 32; i++) wr(16'(4 * i), 0);
        wr(16'h00, ((nwf - 1) << 28) | pos);              // [0] nWF_WG-1, start address
        wr(16'h04, n);                                    // [1] size0
        wr(16'h1C, (0 << 30) | wg);                       // [7] nDim-1, wg sizes
        wr(16'h20, nwg - 1);                              // [8] n_wg0-1
        wr(16'h24, 32'hFFFF_FFFF);                        // [9] n_wg1-1 (n_wg1 = 0, 1-D)
        wr(16'h28, 32'hFFFF_FFFF);                        // [10] n_wg2-1
        wr(16'h2C, (3 << 28) | wg);                       // [11] nParams, wg_size
        wr(16'h40, P1); wr(16'h44, P2); wr(16'h48, TGT);  // [16..18] parameters
        wr(INITIATE, 32'hFFFF);
        wr(CLEAN_CACHE, 32'hFFFF);
        t0 = $time;
        wr(START, 1);
        cyc = 0;
        do begin rd(STATUS, st); cyc++; end while (st == 0 && cyc < 200000);
        if (st == 0) begin $display("  [FAIL] %s: no completion", name); errors++; return; end
        repeat (50) @(posedge clk);                       // let the last writes take effect
        for (int i = 0; i < n; i++) begin
            if (fp) begin
                a = shortreal'(i); b = shortreal'(3 * i) + 0.25;
                want = $shortrealtobits(a + b);
            end else want = (i * 7 + 1) + (32'hFFFF_0000 + i);
            got = mem.mem[(TGT >> 2) + i];
            checks++;
            if (got !== want) begin
                if (errors < 10) $display("  [FAIL] %s out[%0d] = %08h, expected %08h", name, i, got, want);
                errors++;
            end
        end
        $display("  %-16s n=%0d  status=%08h  %0d ns  (%0d errors so far)", name, n, st,
                 ($time - t0), errors);
    endtask

    initial begin
        string kdir;
        int n;
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        if (!$value$plusargs("KDIR=%s", kdir)) kdir = "C:/work/fgpu_build/kernels";
        if (!$value$plusargs("N=%d", n)) n = 1024;
        repeat (20) @(posedge clk);
        aresetn = 1;
        repeat (20) @(posedge clk);
        run("vec_add",        {kdir, "/vec_add.hex"},            369, 252, n, 0);
        run("add_hard_float", {kdir, "/vec_add_hard_float.hex"},  11,   0, n, 1);
        run("vec_add again",  {kdir, "/vec_add.hex"},            369, 252, 256, 0);
        $display("[tb_fgpu_ps] %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("[tb_fgpu_ps] PASS");
        else             $display("[tb_fgpu_ps] FAIL");
        $finish;
    end
    initial begin #50ms; $display("[tb_fgpu_ps] TIMEOUT"); $finish; end
endmodule
