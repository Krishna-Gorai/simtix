// =============================================================================
// tb_chip_mnist_short.sv  -  fast reduced-image on-chip MNIST regression, sized
// for POST-SYNTHESIS gate-level simulation in xsim.
//
// Identical intent to tb_chip_mnist.sv, but it drives chip_top_mnist_short (whose
// driver ROM is the -DNIMG=2 build), so the host processes NIMG_SHORT images and
// raises `done` after a few hundred thousand cycles — a post-synth gate-level run
// completes in minutes. In a post-synthesis functional simulation, Vivado swaps the
// synthesized netlist in for `chip_top_mnist_short`; this testbench only drives
// clk/rst and checks the published golden-match count, so it works unchanged on the
// behavioral RTL and on the netlist.
//
// Behavioral smoke test: make -C sim test-chip-mnist-short  (needs
// kernels/mnist/mnist_driver_short.hex + ml/data/mnist_store.hex).
// =============================================================================
`timescale 1ns/1ps

module tb_chip_mnist_short;

    logic        clk = 0;
    logic        rst;
    logic        done;
    logic [31:0] result;

    // Must match the -DNIMG= used to build mnist_driver_short.hex (Makefile: NIMG=2).
    localparam logic [31:0] NIMG_SHORT = 32'd2;

    chip_top_mnist_short dut (
        .clk    (clk),
        .rst    (rst),
        .done   (done),
        .result (result)
    );

    always #5 clk = ~clk;

    longint unsigned guard;

    initial begin
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        $display("=============================================================================");
        $display("[tb_chip_mnist_short] chip booted; host CPU driving on-chip MNIST inference");
        $display("                      (784->128->10 INT8, %0d images, weights from BRAM)", NIMG_SHORT);

        guard = 0;
        while (!done && guard < 20_000_000) begin
            @(posedge clk);
            guard++;
        end

        if (!done) begin
            $display("[tb_chip_mnist_short] FAIL: chip never raised done (timeout after %0d cyc)", guard);
            $fatal(1);
        end

        $display("[tb_chip_mnist_short] chip done in ~%0d cycles; golden-match count = %0d / %0d",
                 guard, result, NIMG_SHORT);
        if (result !== NIMG_SHORT) begin
            $display("[tb_chip_mnist_short] FAIL: %0d / %0d images matched golden (expected all)",
                     result, NIMG_SHORT);
            $fatal(1);
        end

        $display("[tb_chip_mnist_short] PASS: netlist reproduced the integer-exact golden for all %0d images",
                 NIMG_SHORT);
        $display("=============================================================================");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("[tb_chip_mnist_short] TIMEOUT (global)");
        $fatal(1);
    end

endmodule : tb_chip_mnist_short
