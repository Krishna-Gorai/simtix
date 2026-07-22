// chip_top_mnist.sv  -  synthesis/impl top for the AI-4 on-chip MNIST config.
//
// A thin wrapper that fixes chip_top's demo parameters to the MNIST driver and the
// 256 KB (65536-word) BRAM weight/data store, so the FPGA flow measures the
// BRAM-inclusive PPA of the deployable MNIST accelerator without relying on
// command-line string generics (whose quoting is fragile in Vivado batch).
//
// Instantiates the *complete* chip: host RISC-V pipeline + SIMTiX accelerator +
// LUTRAM shared working memory + the MNIST driver ROM + the block-RAM weight store.
`timescale 1ns/1ps

module chip_top_mnist (
    input  logic        clk,
    input  logic        rst,            // active-high
    output logic        done,
    output logic [31:0] result
);

    // INIT files are given as BASENAMES (not paths): both the non-project batch flow
    // (synth_chip_mnist.tcl copies them into the run cwd) and the managed GUI project
    // (create_project_mnist.tcl adds them as design sources) put the containing
    // directory on Vivado's $readmemh search path, so a bare filename resolves in
    // synth, elaboration and sim regardless of the run's working directory.
    chip_top #(
        .DRIVER       ("mnist"),
        .MDRIVER_INIT ("mnist_driver.hex"),
        .WSTORE_INIT  ("mnist_store.hex"),
        .WSTORE_WORDS (1 << 16)                              // 65536 words = 256 KB
    ) u_chip (
        .clk    (clk),
        .rst    (rst),
        .done   (done),
        .result (result)
    );

endmodule : chip_top_mnist
