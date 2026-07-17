// =============================================================================
// tb_chip_mnist.sv  -  AI-4 on-chip MNIST inference regression (step 4d)
//
// Drives ONLY clk and rst. The full chip is configured for the MNIST demo:
// DRIVER="mnist" swaps the host driver ROM to the assembled mnist_driver.S, and
// the BRAM data store is initialised from ml/data/mnist_store.hex (kernels,
// params, both weight matrices, all 64 test images, and the golden predictions).
//
// The host CPU streams weight tiles out of the BRAM store into the 16 KB LUTRAM
// working memory, runs qgemv -> requant_relu -> qgemv per image entirely on the
// accelerator, argmaxes, self-checks each predicted digit against the on-chip
// golden, and publishes the count of golden-matching images on `result`. A chip
// that reproduces the integer-exact golden reports 64.
//
// This is the real end-to-end proof: CPU <-> BRAM weights <-> LUTRAM working mem
// <-> MMIO <-> SIMT accelerator, all in one self-contained chip. It is slow (the
// whole weight set is streamed per image), so it is not in the default `test`.
//
// Needs ml/data/mnist_store.hex + kernels/mnist/mnist_driver.hex (both generated:
// `python3 ml/mnist_quant.py` and `make -C sim mnist-driver`).  Run: make test-chip-mnist
// =============================================================================
`timescale 1ns/1ps

module tb_chip_mnist;

    logic        clk = 0;
    logic        rst;
    logic        done;
    logic [31:0] result;

    localparam logic [31:0] NIMG = 32'd64;   // all golden images must match

    chip_top #(
        .DRIVER       ("mnist"),
        .MDRIVER_INIT ("../kernels/mnist/mnist_driver.hex"),
        .WSTORE_INIT  ("../ml/data/mnist_store.hex"),
        .WSTORE_WORDS (1 << 16)
    ) dut (
        .clk    (clk),
        .rst    (rst),
        .done   (done),
        .result (result)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    longint unsigned guard;

    initial begin
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        $display("=============================================================================");
        $display("[tb_chip_mnist] chip booted; host CPU driving on-chip MNIST inference");
        $display("                (784->128->10 INT8, weights streamed from BRAM per image)");

        guard = 0;
        while (!done && guard < 500_000_000) begin
            @(posedge clk);
            guard++;
        end

        if (!done) begin
            $display("[tb_chip_mnist] FAIL: chip never raised done (timeout after %0d cyc)", guard);
            $fatal(1);
        end

        $display("[tb_chip_mnist] chip done in ~%0d cycles; golden-match count = %0d / %0d",
                 guard, result, NIMG);
        if (result !== NIMG) begin
            $display("[tb_chip_mnist] FAIL: %0d / %0d images matched golden (expected all)",
                     result, NIMG);
            $fatal(1);
        end

        $display("[tb_chip_mnist] PASS: chip reproduced the integer-exact golden for all %0d images",
                 NIMG);
        $display("=============================================================================");
        $finish;
    end

    initial begin
        #6_000_000_000;
        $display("[tb_chip_mnist] TIMEOUT (global)");
        $fatal(1);
    end

endmodule : tb_chip_mnist
