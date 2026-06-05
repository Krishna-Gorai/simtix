// =============================================================================
// tb_chip_top.sv  -  M10 full-chip regression
//
// Drives ONLY clk and rst — everything else (driver program, kernel, data) is
// on-chip. The host CPU boots, programs and launches the accelerator, polls
// DONE, reads the C results back from shared memory, sums them, and publishes
// the sum on `result` while raising `done`. This proves the entire
// CPU <-> MMIO <-> accelerator <-> shared-memory loop in one self-contained chip.
//
// Expected: result = sum_i (A[i]+B[i]) = sum_i (110 + 3i), i=0..7 = 964.
// =============================================================================
`timescale 1ns/1ps

module tb_chip_top;

    logic        clk = 0;
    logic        rst;
    logic        done;
    logic [31:0] result;

    localparam logic [31:0] EXPECTED = 32'd964;

    chip_top dut (
        .clk    (clk),
        .rst    (rst),
        .done   (done),
        .result (result)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    int unsigned guard;

    initial begin
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        $display("[tb_chip_top] chip booted; host CPU is driving the accelerator");

        // Wait for the CPU to publish the result (with a guard against hangs).
        guard = 0;
        while (!done && guard < 50000) begin
            @(posedge clk);
            guard++;
        end

        if (!done) begin
            $display("[tb_chip_top] FAIL: chip never raised done (timeout)");
            $fatal(1);
        end

        if (result !== EXPECTED) begin
            $display("[tb_chip_top] FAIL: result = %0d, expected %0d", result, EXPECTED);
            $fatal(1);
        end

        $display("[tb_chip_top] PASS: chip computed result = %0d in ~%0d cycles",
                 result, guard);
        $finish;
    end

    initial begin
        #5000000;
        $display("[tb_chip_top] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_chip_top
