// =============================================================================
// forwarding_unit.v  -  EX-stage data forwarding  (fully synthesizable)
//
// ForwardAE / ForwardBE mux select (2-bit):
//   2'b00  -> no forward: use register-file output (RD1E / RD2E)
//   2'b10  -> forward from MEM stage: ALUResultM
//   2'b01  -> forward from WB  stage: ResultW
//
// Priority: MEM forwarding takes precedence over WB forwarding
//           because MEM carries the more recently computed value.
// =============================================================================
`timescale 1ns/1ps
(* dont_touch = "true" *)
module forwarding_unit (
    input  wire [ 4:0] Rs1E,
    input  wire [ 4:0] Rs2E,
    input  wire [ 4:0] RdM,
    input  wire        RegWriteM,
    input  wire [ 4:0] RdW,
    input  wire        RegWriteW,
    output reg  [ 1:0] ForwardAE,
    output reg  [ 1:0] ForwardBE
);

    always @(*) begin
        // ----- ForwardAE (source A / rs1) ----
        if (RegWriteM && (RdM != 5'd0) && (RdM == Rs1E))
            ForwardAE = 2'b10;                      // MEM -> EX
        else if (RegWriteW && (RdW != 5'd0) && (RdW == Rs1E))
            ForwardAE = 2'b01;                      // WB  -> EX
        else
            ForwardAE = 2'b00;                      // no forward

        // ----- ForwardBE (source B / rs2) ----
        if (RegWriteM && (RdM != 5'd0) && (RdM == Rs2E))
            ForwardBE = 2'b10;
        else if (RegWriteW && (RdW != 5'd0) && (RdW == Rs2E))
            ForwardBE = 2'b01;
        else
            ForwardBE = 2'b00;
    end

endmodule