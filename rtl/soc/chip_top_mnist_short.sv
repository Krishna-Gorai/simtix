// chip_top_mnist_short.sv  -  reduced-image MNIST chip config for a FAST post-
// synthesis gate-level simulation.
//
// Identical hardware to chip_top_mnist (host CPU + SIMTiX accelerator + LUTRAM
// working memory + 256 KB BRAM weight/data store) — the ONLY difference is the
// driver ROM is loaded with the SHORT driver (mnist_driver_short.hex, built with
// -DNIMG=2), so the host processes just a couple of images and raises `done` after
// ~a few hundred thousand cycles instead of ~10.7 M. That makes a post-synthesis
// xsim run finish in minutes while exercising the identical datapath (tiled qgemv,
// requant_relu, layer-2 qgemv, argmax, self-check-vs-golden). The full store is
// unchanged, so images/weights/golden are the same as the 64-image build.
`timescale 1ns/1ps

module chip_top_mnist_short (
    input  logic        clk,
    input  logic        rst,            // active-high
    output logic        done,
    output logic [31:0] result          // golden-match count (== NIMG when correct)
);

    // INIT files given as BASENAMES; create_project_mnist_sim.tcl adds their
    // directories to Vivado's $readmemh search path (see chip_top_mnist.sv).
    chip_top #(
        .DRIVER       ("mnist"),
        .MDRIVER_INIT ("mnist_driver_short.hex"),
        .WSTORE_INIT  ("mnist_store.hex"),
        .WSTORE_WORDS (1 << 16)                              // 65536 words = 256 KB
    ) u_chip (
        .clk    (clk),
        .rst    (rst),
        .done   (done),
        .result (result)
    );

endmodule : chip_top_mnist_short
