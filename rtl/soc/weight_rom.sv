// =============================================================================
// weight_rom.sv  -  on-chip BRAM weight store for the MNIST demo (AI-4 step 4)
//
// A large, BRAM-backed read-only memory holding the quantized MLP weights
// (W1packed then W2packed). Unlike the 4 KB LUTRAM shared_mem, this uses block
// RAM (ram_style="block") so it scales to ~100 KB of weights at a handful of
// BRAM tiles instead of tens of thousands of LUTs — which is exactly why real
// inference accelerators keep weights in BRAM/DRAM, not fabric.
//
// The host CPU reads it word-by-word and streams weight tiles into the
// accelerator's async working memory; the accelerator itself is untouched. BRAM
// read is SYNCHRONOUS (1-cycle latency), so a read presents `rdata` the cycle
// after `en`, with `rvalid` marking it. chip_top turns `rvalid` into the CPU's
// `mem_ready` handshake (the pipeline stalls one cycle on a weight load).
//
// Contents are initialised from ml/data/weights_rom.hex (produced by
// ml/mnist_quant.py); on the FPGA this becomes a BRAM INIT (Vivado honours the
// $readmemh init for block RAM).
// =============================================================================
`timescale 1ns/1ps

module weight_rom #(
    parameter int    WORDS = 1 << 15,               // 32768 words = 128 KB (holds 25408 wts)
    parameter        INIT  = "../ml/data/weights_rom.hex"
)(
    input  logic        clk,
    input  logic        en,                          // asserted on a weight-ROM read
    /* verilator lint_off UNUSEDSIGNAL */            // only addr[AW+1:2] indexes the ROM
    input  logic [31:0] addr,                        // byte address (word = addr[AW+1:2])
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] rdata,                       // valid the cycle after `en`
    output logic        rvalid                       // 1-cycle-delayed read-valid
);
    localparam int AW = $clog2(WORDS);               // word-index width

    (* ram_style = "block" *) logic [31:0] mem [0:WORDS-1];

    initial begin
        for (int i = 0; i < WORDS; i++) mem[i] = 32'd0;
        if (INIT != "") $readmemh(INIT, mem);
    end

    // Synchronous (BRAM) read: address registers into the block RAM, data out next
    // cycle. `rvalid` tracks `en` delayed one cycle to drive the CPU stall handshake.
    always_ff @(posedge clk) begin
        rdata  <= mem[addr[AW+1:2]];
        rvalid <= en;
    end
endmodule : weight_rom
