// =============================================================================
// driver_rom.sv  -  generic $readmemh host-CPU instruction ROM
//
// A combinational (async-read) instruction ROM whose contents come from an
// assembled hex image (one 32-bit little-endian word per line, word address =
// addr[AW+1:2]). This is the scalable alternative to the hand-encoded case ROM
// in cpu_driver_rom.sv: the MNIST on-chip demo's host driver is a few hundred
// rv32i instructions (assembled from mnist_driver.S), far too many to hand-lay.
//
// Async read matches the CPU's single-cycle instruction-fetch expectation
// (InstrF is consumed the same cycle PCF is presented), exactly like the case
// ROM it replaces. On the FPGA Vivado infers distributed/LUT ROM and honours
// the $readmemh initialiser.
// =============================================================================
`timescale 1ns/1ps

module driver_rom #(
    parameter int    WORDS = 1024,                   // program capacity (4 KB)
    parameter        INIT  = ""                       // assembled hex image
)(
    /* verilator lint_off UNUSEDSIGNAL */             // only addr[AW+1:2] indexes
    input  wire [31:0] addr,                          // byte PC
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [31:0] instr
);
    localparam int AW = $clog2(WORDS);

    (* rom_style = "distributed" *) reg [31:0] mem [0:WORDS-1];

    initial begin
        for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;  // nop-fill
        if (INIT != "") $readmemh(INIT, mem);
    end

    assign instr = mem[addr[AW+1:2]];
endmodule : driver_rom
