// =============================================================================
// tb_simt_accel.sv  -  M0 handshake regression
//
// Drives the MMIO port directly (standing in for the host CPU's data bus):
// programs a command, writes GO, polls STATUS.DONE, and checks CYCLES.
// Self-checking: prints PASS/FAIL and exits non-zero on failure so CI catches it.
// =============================================================================
`timescale 1ns/1ps

module tb_simt_accel
  import simtix_pkg::*;
;
    logic        clk = 0;
    logic        rst;
    logic        sel, we;
    logic [7:0]  offset;
    logic [31:0] wdata, rdata;

    int unsigned errors = 0;

    simt_accel dut (
        .clk(clk), .rst(rst),
        .sel(sel), .we(we), .offset(offset), .wdata(wdata), .rdata(rdata)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;   // 100 MHz (testbench clock generator)
    /* verilator lint_on BLKSEQ */

    // ── Bus helpers ──────────────────────────────────────────────────────────────
    task automatic mmio_write(input logic [7:0] off, input logic [31:0] data);
        @(posedge clk);
        sel = 1; we = 1; offset = off; wdata = data;
        @(posedge clk);
        sel = 0; we = 0;
    endtask

    task automatic mmio_read(input logic [7:0] off, output logic [31:0] data);
        @(posedge clk);
        sel = 1; we = 0; offset = off;
        #1 data = rdata;          // combinational read
        @(posedge clk);
        sel = 0;
    endtask

    task automatic check(input string name, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("  [FAIL] %-12s got=%0d exp=%0d", name, got, exp);
            errors++;
        end else begin
            $display("  [ ok ] %-12s = %0d", name, got);
        end
    endtask

    // ── Stimulus ─────────────────────────────────────────────────────────────────
    logic [31:0] rd;
    int unsigned guard;

    initial begin
        sel = 0; we = 0; offset = 0; wdata = 0;
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("[tb_simt_accel] launch a 16-thread kernel");
        mmio_write(REG_KERNEL_PC, 32'h0000_0040);
        mmio_write(REG_BASE_A,    32'h0000_1000);
        mmio_write(REG_BASE_B,    32'h0000_2000);
        mmio_write(REG_BASE_C,    32'h0000_3000);
        mmio_write(REG_N,         32'd16);

        // command read-back
        mmio_read(REG_N, rd);          check("N",         rd, 32'd16);
        mmio_read(REG_BASE_A, rd);     check("BASE_A",    rd, 32'h0000_1000);

        // launch
        mmio_write(REG_CTRL, 32'h1);

        // should be BUSY shortly after GO
        mmio_read(REG_STATUS, rd);
        check("BUSY", {31'b0, rd[STATUS_BUSY_BIT]}, 32'd1);

        // poll DONE (with a timeout guard)
        guard = 0;
        do begin
            mmio_read(REG_STATUS, rd);
            guard++;
        end while (rd[STATUS_DONE_BIT] !== 1'b1 && guard < 1000);

        check("DONE",   {31'b0, rd[STATUS_DONE_BIT]}, 32'd1);
        mmio_read(REG_CYCLES, rd);
        check("CYCLES", rd, 32'd16);   // stub retires 1 thread/cycle

        if (errors == 0) begin
            $display("[tb_simt_accel] PASS");
            $finish;
        end else begin
            $display("[tb_simt_accel] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    // global watchdog
    initial begin
        #100000;
        $display("[tb_simt_accel] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_simt_accel
