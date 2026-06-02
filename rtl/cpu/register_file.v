// =============================================================================
// register_file.v  -  32x32-bit register file  (Vivado synthesizable)
// =============================================================================
`timescale 1ns/1ps

(* dont_touch = "true" *)
module register_file (
    input  wire        clk,
    input  wire        rst,
    input  wire        we3,
    input  wire [ 4:0] a1,
    input  wire [ 4:0] a2,
    input  wire [ 4:0] a3,
    input  wire [31:0] wd3,
    output wire [31:0] rd1,
    output wire [31:0] rd2
);

    reg [31:0] rf [0:31];

    // Synthesis note: no initial block needed.
    // The synchronous reset clears all registers on rst=1.
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                rf[i] <= 32'd0;
        end else if (we3 && (a3 != 5'd0)) begin
            rf[a3] <= wd3;
        end
    end

    // Write-first (read-during-write bypass): if a register is being written
    // in WB the same cycle it is read in ID, return the new value. Without this
    // the 5-stage pipeline drops a result whenever a producer is in WB while a
    // consumer is in ID (e.g. the value used right after a tight loop's
    // back-edge), because writes commit on the clock edge but reads are
    // combinational. Equivalent to the textbook "write in first half, read in
    // second half" register file.
    wire write_en = we3 && (a3 != 5'd0);

    assign rd1 = (a1 == 5'd0)                  ? 32'd0 :
                 (write_en && (a3 == a1))      ? wd3   : rf[a1];
    assign rd2 = (a2 == 5'd0)                  ? 32'd0 :
                 (write_en && (a3 == a2))      ? wd3   : rf[a2];

endmodule