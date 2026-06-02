// =============================================================================
// alu.v  -  32-bit ALU  (fully synthesizable, RV32I)
//
// ALUControl encoding (4-bit)
//   4'b0000 : ADD
//   4'b0001 : SUB
//   4'b0010 : AND
//   4'b0011 : OR
//   4'b0100 : XOR
//   4'b0101 : SLT   (signed less-than  -> result = 32'd1 or 32'd0)
//   4'b0110 : SLTU  (unsigned less-than)
//   4'b0111 : SLL   (shift left  logical)
//   4'b1000 : SRL   (shift right logical)
//   4'b1001 : SRA   (shift right arithmetic)
//   4'b1010 : PASS_B (result = b, used for LUI)
// =============================================================================
`timescale 1ns/1ps

(* dont_touch = "true" *)
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [ 3:0] alucontrol,
    output reg  [31:0] result,
    output wire        zero,
    output wire        negative,
    output wire        overflow,
    output wire        carry_out
);

    // -------------------------------------------------------------------------
    // Combinational ALU operation
    // -------------------------------------------------------------------------
    always @(*) begin
        case (alucontrol)
            4'b0000: result = a + b;
            4'b0001: result = a - b;
            4'b0010: result = a & b;
            4'b0011: result = a | b;
            4'b0100: result = a ^ b;
            4'b0101: result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            4'b0110: result = (a < b)                   ? 32'd1 : 32'd0;
            4'b0111: result = a << b[4:0];
            4'b1000: result = a >> b[4:0];
            4'b1001: result = $signed(a) >>> b[4:0];
            4'b1010: result = b;
            default: result = 32'd0;
        endcase
    end

    // -------------------------------------------------------------------------
    // Flags  (used by branch condition logic in EX stage)
    // -------------------------------------------------------------------------
    wire [32:0] sub_ext = {1'b0, a} - {1'b0, b};

    assign zero      = (result == 32'd0);
    assign negative  = result[31];
    assign overflow  = (alucontrol == 4'b0001) &&
                       (a[31] == ~b[31]) && (result[31] == b[31]);
    assign carry_out = ~sub_ext[32];   // '1' when a >= b unsigned

endmodule