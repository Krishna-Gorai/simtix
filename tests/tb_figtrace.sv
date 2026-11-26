// =============================================================================
// tb_figtrace.sv  -  cycle traces of the board top (simt_ps_top) for the paper's
// operation figures (docs/figs/arch_v2_tikz/fig_trace.py, gen_*_fig.py)
//
// The host side and DDR4 model are those of tb_ps_top, but the model is
// deterministic (no ready stalls, no reordering) with LAT = MEM_LAT cycles. One
// kernel (KERN) is launched for N threads with block size 2^BLK warps:
//   KERN 0  kernels/figs/saxpy.S       y[i] = a x[i] + y[i]
//   KERN 1  kernels/figs/divergence.S  C[i] = (i >= 3 ? 2i + 1 : 0) + (i mod 4) + 1
//   KERN 2  kernels/figs/issue_rules.S FPU chains (timing only: no result to check)
// and its results are checked. Built with +define+SIMTIX_ISSUE_TRACE, the warp pool
// writes issue_trace.txt (issues, pops, result writes); this testbench adds
// fig_trace.txt with the other stages, on the same cycle count (cycles since GO):
//   S <c> <slot> <tid base> <mask>            a warp is spawned into a slot
//   D <c> <slot>                              its warp has finished (ecall)
//   F <c> <slot> <pc> <sp> {<pc> <rpc> <mask>}  fetch, with the slot's whole stack
//   X <c> <slot> <pc> <mask> <kind>           the fetched instruction in X: issue, pop,
//                                             or wait (held back; the warp retries)
//   B <c> <slot> <kind> <taken> <mask>        stack update: jump, taken, not, diverge
//   M <c> <slot> <pc>                         a memory op enters a context
//   Q <c> <tag> <addr> <we> / A <c> <tag>     line request to the L1 / its response
//   H <c> / U <c>                             L1 read hit / miss
//   L <c> <tag> <addr> <we> / N <c> <tag>     the L1's request to the AXI4 master / reply
//   AR, R, AW, W, BR <c> ...                  AXI4 handshakes
//   Z <c> <slot> <wstate> <sleep>             a slot's state changed (wstate: 0 empty, 1 run,
//                                             2 parked on memory, 3 divide, 4 done, 5 barrier;
//                                             sleep: asleep on the register scoreboard)
// =============================================================================
`timescale 1ns/1ps
module tb_figtrace
  import simtix_pkg::*;
#(
    parameter int KERN    = 0,
    parameter int N       = 8,
    parameter int BLK     = 0,
    parameter int MEM_LAT = 24
);
    localparam int DW  = 128;
    localparam int IDW = MEM_TAGW + 1;
    localparam logic [31:0] X_DDR = 32'h1000_0000;
    localparam logic [31:0] Y_DDR = X_DDR + 32'h0000_1000;
    localparam logic [31:0] S_DDR = X_DDR + 32'h0000_2000;      // the scalar a
    localparam logic [31:0] C_DDR = X_DDR + 32'h0000_3000;      // divergence results
    localparam int WORDS_LG = 16;

    logic clk = 0;
    logic rst;
    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    logic [15:0] awaddr, araddr;
    logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
    logic [31:0] wdata, rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0]  bresp, rresp;
    /* verilator lint_on UNUSEDSIGNAL */
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

    axi_mem_model #(.IDW(IDW), .DW(DW), .WORDS(1 << WORDS_LG), .MAXB(LINE_BITS / DW),
                    .LAT(MEM_LAT), .STALL(0), .OOO(0)) u_ddr (
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

    // ── Stage trace (same cycle count as the warp pool's issue_trace.txt) ──────────
    int     ft_fd;
    longint cyc;
    logic [NUM_WARPS-1:0] done_q;
    logic [4:0]           zq [NUM_WARPS];   // last logged {wstate, sb_wait} of each slot
    // warp_pool's enums by value: wstate_e W_EMPTY 0, W_RUN 1, W_MEM 2, W_SFU 3, W_DONE 4,
    // W_BAR 5; sfu_st_e SFU_IDLE = 0; br_kind_e BK_JUMP = 1
    initial ft_fd = $fopen("fig_trace.txt", "w");

    always @(posedge clk) begin
        if (rst) begin
            cyc    <= 0;
            done_q <= '0;
        end else if (dut.u_accel.u_pool.start) begin
            cyc    <= 0;
            done_q <= '0;
            for (int k = 0; k < NUM_WARPS; k++) zq[k] <= 5'h1F;
            $fdisplay(ft_fd, "G");
        end else if (dut.u_accel.u_pool.running) begin
            cyc <= cyc + 1;
            for (int k = 0; k < NUM_WARPS; k++) begin
                if (dut.u_accel.u_pool.spawn_en[k])
                    $fdisplay(ft_fd, "S %0d %0d %0d %b", cyc, k,
                              dut.u_accel.u_pool.spawn_base[k], dut.u_accel.u_pool.spawn_mask[k]);
                done_q[k] <= (dut.u_accel.u_pool.wstate[k] == 4'd4);
                if ((dut.u_accel.u_pool.wstate[k] == 4'd4) && !done_q[k])
                    $fdisplay(ft_fd, "D %0d %0d", cyc, k);
                // slot state: Z <c> <slot> <wstate> <sb_wait>, logged when it changes
                zq[k] <= {dut.u_accel.u_pool.wstate[k], dut.u_accel.u_pool.sb_wait[k]};
                if ({dut.u_accel.u_pool.wstate[k], dut.u_accel.u_pool.sb_wait[k]} != zq[k])
                    $fdisplay(ft_fd, "Z %0d %0d %0d %0d", cyc, k, dut.u_accel.u_pool.wstate[k],
                              dut.u_accel.u_pool.sb_wait[k]);
            end
            if (dut.u_accel.u_pool.fetch_valid) begin
                automatic int w = dut.u_accel.u_pool.fetch_w;
                automatic int sp = dut.u_accel.u_pool.sp[w];
                automatic string s = $sformatf("F %0d %0d %0h %0d", cyc, w,
                                               dut.u_accel.u_pool.fetch_pc, sp);
                for (int i = 0; i <= sp; i++)
                    s = {s, $sformatf(" %0h %0h %b", dut.u_accel.u_pool.stk_npc[w][i],
                                      dut.u_accel.u_pool.stk_rpc[w][i],
                                      dut.u_accel.u_pool.stk_mask[w][i])};
                $fdisplay(ft_fd, "%s", s);
            end
            if (dut.u_accel.u_pool.issue_valid)
                $fdisplay(ft_fd, "X %0d %0d %0h %b %s", cyc, dut.u_accel.u_pool.issue_w,
                          dut.u_accel.u_pool.cur_pc, dut.u_accel.u_pool.cur_mask,
                          dut.u_accel.u_pool.do_pop ? "pop" :
                          (!dut.u_accel.u_pool.sb_stall &&
                           !(dut.u_accel.u_pool.is_mem && !dut.u_accel.u_pool.me_in_ready) &&
                           !dut.u_accel.u_pool.squash_wb &&
                           !(dut.u_accel.u_pool.is_sfu_op &&
                             dut.u_accel.u_pool.sfu_state != 2'd0))
                          ? "issue" : "wait");
            if (dut.u_accel.u_pool.br_v)
                $fdisplay(ft_fd, "B %0d %0d %s %b %b", cyc, dut.u_accel.u_pool.br_w,
                          (dut.u_accel.u_pool.br_kind == 2'd1) ? "jump" :
                          (dut.u_accel.u_pool.br_taken == dut.u_accel.u_pool.br_mask) ? "taken" :
                          (dut.u_accel.u_pool.br_taken == '0) ? "not" : "diverge",
                          dut.u_accel.u_pool.br_taken, dut.u_accel.u_pool.br_mask);
            if (dut.u_accel.u_pool.me_in_valid && dut.u_accel.u_pool.me_in_ready)
                $fdisplay(ft_fd, "M %0d %0d %0h", cyc, dut.u_accel.u_pool.issue_w,
                          dut.u_accel.u_pool.cur_pc);
            if (dut.u_l1.s_req && dut.u_l1.s_gnt)
                $fdisplay(ft_fd, "Q %0d %0d %08h %0d", cyc, dut.u_l1.s_tag, dut.u_l1.s_addr,
                          dut.u_l1.s_we);
            if (dut.u_l1.s_rvalid) $fdisplay(ft_fd, "A %0d %0d", cyc, dut.u_l1.s_rtag);
            if (dut.u_l1.hit_ev)   $fdisplay(ft_fd, "H %0d", cyc);
            if (dut.u_l1.miss_ev)  $fdisplay(ft_fd, "U %0d", cyc);
            if (dut.u_l1.m_req && dut.u_l1.m_gnt)
                $fdisplay(ft_fd, "L %0d %0d %08h %0d", cyc, dut.u_l1.m_tag, dut.u_l1.m_addr,
                          dut.u_l1.m_we);
            if (dut.u_l1.m_rvalid) $fdisplay(ft_fd, "N %0d %0d", cyc, dut.u_l1.m_rtag);
            if (m_arvalid && m_arready) $fdisplay(ft_fd, "AR %0d %0d %08h", cyc, m_arid, m_araddr);
            if (m_rvalid && m_rready)   $fdisplay(ft_fd, "R %0d %0d %0d", cyc, m_rid, m_rlast);
            if (m_awvalid && m_awready) $fdisplay(ft_fd, "AW %0d %0d %08h", cyc, m_awid, m_awaddr);
            if (m_wvalid && m_wready)   $fdisplay(ft_fd, "W %0d %0d", cyc, m_wlast);
            if (m_bvalid && m_bready)   $fdisplay(ft_fd, "BR %0d %0d", cyc, m_bid);
        end
    end

    // ── Host AXI4-Lite tasks (as tb_ps_top) ───────────────────────────────────────
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

    logic [31:0] mem [0:127];
    int          at;
    int unsigned errors = 0, checks = 0;

    function automatic int unsigned widx(input logic [31:0] a);
        return int'(a[WORDS_LG+1:2]);
    endfunction

    task automatic chk(input string tag, input int i, input logic [31:0] got,
                       input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("  [FAIL] %s[%0d]: got %08h, expected %08h", tag, i, got, exp);
        end
    endtask

    initial begin
        logic [31:0] st, cyc_total;
        rst = 1; awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0;
        for (int i = 0; i < 128; i++) mem[i] = 32'h0000_0013;   // nop
        at = 0;  `include "saxpy.svh"
        at = 64; `include "divergence.svh"
        at = 96; `include "issue_rules.svh"
        repeat (4) @(posedge clk);
        rst = 0;
        for (int i = 0; i < 128; i++) axil_wr(16'h1000 + 16'(4*i), mem[i]);

        // inputs: x[i] = i + 1, y[i] = 2i, a = 2 (exact in FP32: y'[i] = 4i + 2)
        for (int i = 0; i < N; i++) begin
            u_ddr.mem[widx(X_DDR + 32'(4*i))] = $shortrealtobits(shortreal'(i + 1));
            u_ddr.mem[widx(Y_DDR + 32'(4*i))] = $shortrealtobits(shortreal'(2 * i));
            u_ddr.mem[widx(C_DDR + 32'(4*i))] = 32'hDEAD_BEEF;
        end
        u_ddr.mem[widx(S_DDR)] = $shortrealtobits(shortreal'(2.0));

        axil_wr(16'(REG_KERNEL_PC), (KERN == 0) ? 32'd0 : (KERN == 1) ? 32'd256 : 32'd384);
        axil_wr(16'(REG_BASE_A), X_DDR);
        axil_wr(16'(REG_BASE_B), Y_DDR);
        axil_wr(16'(REG_BASE_C), (KERN == 0) ? S_DDR : C_DDR);
        axil_wr(16'(REG_N), N);
        axil_wr(16'(REG_BLOCK), BLK);
        axil_wr(16'(REG_CTRL), 32'd1);
        st = 0;
        for (int g = 0; g < 10000 && !st[STATUS_DONE_BIT]; g++) axil_rd(16'(REG_STATUS), st);
        if (!st[STATUS_DONE_BIT]) begin $display("  [FAIL] timeout"); errors++; end
        axil_rd(16'(REG_CYCLES), cyc_total);

        for (int i = 0; i < N && KERN != 2; i++)
            if (KERN == 0)
                chk("y", i, u_ddr.mem[widx(Y_DDR + 32'(4*i))],
                    $shortrealtobits(shortreal'(4 * i + 2)));
            else
                chk("C", i, u_ddr.mem[widx(C_DDR + 32'(4*i))],
                    32'((i >= 3 ? 2 * i + 1 : 0) + (i % 4) + 1));
        $display("FIGCSV,%0d,%0d,%0d,%0d", KERN, N, BLK, cyc_total);
        $display("[tb_figtrace] %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("[tb_figtrace] PASS");
        else             $display("[tb_figtrace] FAIL (%0d errors)", errors);
        $fclose(ft_fd);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[tb_figtrace] FAIL: TIMEOUT");
        $finish;
    end
endmodule : tb_figtrace
