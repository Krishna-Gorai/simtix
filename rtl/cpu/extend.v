// =============================================================================
// extend.v  -  Immediate sign-extension unit  (fully synthesizable)
//
// ImmSrc encoding (3-bit)
//   3'b000 : I-type  imm[11:0]  = instr[31:20]
//   3'b001 : S-type  imm[11:0]  = {instr[31:25], instr[11:7]}
//   3'b010 : B-type  imm[12:1]  = {instr[31],instr[7],instr[30:25],instr[11:8]}
//   3'b011 : J-type  imm[20:1]  = {instr[31],instr[19:12],instr[20],instr[30:21]}
//   3'b100 : U-type  imm[31:12] = instr[31:12]
// =============================================================================
`timescale 1ns/1ps

(* dont_touch = "true" *)
module extend (
    input  wire [31:7] instr,    // instruction bits [31:7]
    input  wire [ 2:0] immsrc,
    output reg  [31:0] immext
);

    always @(*) begin
        case (immsrc)
            // I-type: sign-extend bits [31:20]
            3'b000: immext = {{20{instr[31]}}, instr[31:20]};

            // S-type: sign-extend {[31:25], [11:7]}
            3'b001: immext = {{20{instr[31]}}, instr[31:25], instr[11:7]};

            // B-type: sign-extend {[31],[7],[30:25],[11:8], 1'b0}
            3'b010: immext = {{19{instr[31]}}, instr[31],    instr[7],
                               instr[30:25],   instr[11:8],  1'b0};

            // J-type: sign-extend {[31],[19:12],[20],[30:21], 1'b0}
            3'b011: immext = {{11{instr[31]}}, instr[31],    instr[19:12],
                               instr[20],      instr[30:21], 1'b0};

            // U-type: {[31:12], 12'b0}
            3'b100: immext = {instr[31:12], 12'b0};

            // Default - tie to 0 (synthesis: no latch)
            default: immext = 32'd0;
        endcase
    end

endmodule