// =============================================================================
// tb_lane.sv  -  M1.1 unit test for a single SIMT lane
//
// Provides a tiny hand-assembled RV32I kernel in an async-read ROM and runs it
// for several thread ids, checking the retired a0.
//
// Kernel (computes a0 = 3*tid + 7):
//   slli t0, a0, 1     # 0x00151293   t0 = tid*2
//   add  a0, a0, t0    # 0x00550533   a0 = tid + 2*tid = 3*tid
//   addi a0, a0, 7     # 0x00750513   a0 = 3*tid + 7
//   ecall              # 0x00000073   retire
// (a0 is seeded with tid at dispatch.)
// =============================================================================
`timescale 1ns/1ps

module tb_lane
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */  // testbench probe/convenience signals
    logic        clk = 0;
    logic        rst;
    logic        start;
    logic [31:0] tid, base_a, base_b, base_c, n_threads, kernel_pc;
    logic [31:0] imem_addr, imem_data;
    logic        busy, done;
    logic [31:0] dbg_retire_a0;

    int unsigned errors = 0;

    lane dut (
        .clk(clk), .rst(rst),
        .start(start), .tid(tid),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .busy(busy), .done(done), .dbg_retire_a0(dbg_retire_a0)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Kernel ROM (async read) ──────────────────────────────────────────────────
    logic [31:0] rom [0:15];
    initial begin
        rom[0] = 32'h00151293;   // slli t0, a0, 1
        rom[1] = 32'h00550533;   // add  a0, a0, t0
        rom[2] = 32'h00750513;   // addi a0, a0, 7
        rom[3] = 32'h00000073;   // ecall
        for (int k = 4; k < 16; k++) rom[k] = 32'h00000013; // nop padding
    end
    assign imem_data = rom[imem_addr[5:2]];   // word index from byte address

    // ── Run one thread, return its retired a0 ─────────────────────────────────────
    task automatic run_thread(input logic [31:0] t, output logic [31:0] result);
        int unsigned guard;
        @(posedge clk);
        tid = t; kernel_pc = 32'd0; start = 1;
        @(posedge clk);
        start = 0;
        guard = 0;
        while (!done && guard < 1000) begin @(posedge clk); guard++; end
        result = dbg_retire_a0;
    endtask

    logic [31:0] got, exp;

    initial begin
        start = 0; tid = 0; kernel_pc = 0;
        base_a = 0; base_b = 0; base_c = 0; n_threads = 0;
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        for (int t = 0; t < 5; t++) begin
            run_thread(t, got);
            exp = 3*t + 7;
            if (got !== exp) begin
                $display("  [FAIL] tid=%0d  a0=%0d  exp=%0d", t, got, exp);
                errors++;
            end else begin
                $display("  [ ok ] tid=%0d  a0=%0d", t, got);
            end
        end

        if (errors == 0) begin
            $display("[tb_lane] PASS");
            $finish;
        end else begin
            $display("[tb_lane] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #100000;
        $display("[tb_lane] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_lane
