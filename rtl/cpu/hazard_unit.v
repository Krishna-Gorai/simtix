// =============================================================================
// hazard_unit.v  -  Pipeline hazard detection & control  (fully synthesizable)
//
// Handles two hazard classes:
//
// 1. Load-use data hazard (1-cycle stall):
//    Condition: a load is in EX (ResultSrcE[0]=1) AND its destination
//               register matches rs1 or rs2 of the instruction in ID.
//    Action:    StallF=1, StallD=1, FlushE=1
//               (PC and IF/ID register held; bubble inserted into ID/EX)
//
// 2. Control hazard - branch taken or jump (2-instruction flush):
//    Branches and jumps are resolved at the END of the EX stage.
//    Two instructions have already entered IF and ID incorrectly.
//    Action:    FlushD=1, FlushE=1  when PCSrcE=1
//               (IF/ID and ID/EX registers cleared to NOP/zero)
// =============================================================================
`timescale 1ns/1ps
(* dont_touch = "true" *)
module hazard_unit (
    // ID stage source registers
    input  wire [ 4:0] Rs1D,
    input  wire [ 4:0] Rs2D,
    // EX stage registers
    input  wire [ 4:0] Rs1E,
    input  wire [ 4:0] Rs2E,
    input  wire [ 4:0] RdE,
    input  wire        PCSrcE,       // branch taken or jump
    input  wire [ 1:0] ResultSrcE,   // ResultSrcE[0]=1 means load in EX
    // MEM / WB destination registers (unused here; kept for interface symmetry)
    input  wire [ 4:0] RdM,
    input  wire        RegWriteM,
    input  wire [ 4:0] RdW,
    input  wire        RegWriteW,
    // Hazard control outputs
    output wire        StallF,
    output wire        StallD,
    output wire        FlushD,
    output wire        FlushE
);

    // Load-use hazard: load in EX, dependent instruction in ID
    wire load_use_hazard = ResultSrcE[0]           &&
                           (RdE != 5'd0)           &&
                           ((RdE == Rs1D) || (RdE == Rs2D));

    assign StallF = load_use_hazard;
    assign StallD = load_use_hazard;
    assign FlushD = PCSrcE;
    assign FlushE = load_use_hazard | PCSrcE;

   

endmodule