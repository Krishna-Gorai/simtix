// =============================================================================
// riscv_pipeline.v  -  5-stage RISC-V RV32I pipeline  (fully synthesizable)
//
//  Stages  : IF -> ID -> EX -> MEM -> WB
//  Hazards : Full EX/MEM->EX forwarding, load-use stall, branch/jump flush
//
//  reset_vector : PC and IF/ID register are loaded with this value on rst.
//                 Allows any hardcoded program in instr_mem to be selected.
//
//  mem_ready    : When data_mem is clearing after reset this signal is LOW.
//                 The pipeline automatically stalls (StallAll) until HIGH.
// =============================================================================
`timescale 1ns/1ps
(* dont_touch = "true" *)
module riscv_pipeline (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] reset_vector,  // PC start address

    // Instruction memory interface
    output wire [31:0] PCF,
    input  wire [31:0] InstrF,

    // Data memory interface
    output wire [31:0] ALUResultM,
    output wire [31:0] WriteDataM,
    input  wire [31:0] ReadDataM,
    output wire        MemWriteM,
    output wire [ 2:0] Funct3M,

    // Data memory ready (stall whole pipeline while dmem is clearing)
    input  wire        mem_ready
);

    // =========================================================================
    // Forward declarations for hazard / control wires
    // =========================================================================
    wire        StallF, StallD, FlushD, FlushE;
    wire        PCSrcE;
    wire [31:0] PCTargetE;

    // Stall everything while data memory is initialising after reset
    wire        StallAll = ~mem_ready;

    // =========================================================================
    // FETCH STAGE
    // =========================================================================
    reg  [31:0] PC_reg;
    wire [31:0] PCPlus4F = PC_reg + 32'd4;
    wire [31:0] PCNextF  = PCSrcE ? PCTargetE : PCPlus4F;

    assign PCF = PC_reg;

    always @(posedge clk) begin   // synchronous reset (FPGA-friendly; no latches)
        if (rst)
            PC_reg <= reset_vector;
        else if (!StallF && !StallAll)
            PC_reg <= PCNextF;
    end

    // =========================================================================
    // IF/ID Pipeline Register
    // =========================================================================
    reg [31:0] InstrD_r, PCD_r, PCPlus4D_r;

    always @(posedge clk) begin   // synchronous reset (FPGA-friendly; no latches)
        if (rst) begin
            InstrD_r   <= 32'h00000013;
            PCD_r      <= reset_vector;
            PCPlus4D_r <= reset_vector + 32'd4;
        end else if (StallAll) begin
            // Hold during dmem clear
            InstrD_r   <= InstrD_r;
            PCD_r      <= PCD_r;
            PCPlus4D_r <= PCPlus4D_r;
        end else if (FlushD && !StallD) begin
            InstrD_r   <= 32'h00000013;
            PCD_r      <= 32'd0;
            PCPlus4D_r <= 32'd0;
        end else if (!StallD) begin
            InstrD_r   <= InstrF;
            PCD_r      <= PC_reg;
            PCPlus4D_r <= PCPlus4F;
        end
    end

    wire [31:0] InstrD   = InstrD_r;
    wire [31:0] PCD      = PCD_r;
    wire [31:0] PCPlus4D = PCPlus4D_r;

    // =========================================================================
    // DECODE STAGE
    // =========================================================================
    wire [ 6:0] opD       = InstrD[ 6: 0];
    wire [ 2:0] funct3D   = InstrD[14:12];
    wire        funct7b5D = InstrD[30];
    wire [ 4:0] Rs1D      = InstrD[19:15];
    wire [ 4:0] Rs2D      = InstrD[24:20];
    wire [ 4:0] RdD       = InstrD[11: 7];

    wire        RegWriteD, ALUSrcD, MemWriteD, BranchD, JumpD, JalrD, AuipcD;
    wire [ 2:0] ImmSrcD;
    wire [ 1:0] ResultSrcD;
    wire [ 3:0] ALUControlD;

    control_unit ctrl (
        .op         (opD),
        .funct3     (funct3D),
        .funct7b5   (funct7b5D),
        .RegWrite   (RegWriteD),
        .ImmSrc     (ImmSrcD),
        .ALUSrc     (ALUSrcD),
        .MemWrite   (MemWriteD),
        .ResultSrc  (ResultSrcD),
        .Branch     (BranchD),
        .Jump       (JumpD),
        .Jalr       (JalrD),
        .Auipc      (AuipcD),
        .ALUControl (ALUControlD)
    );

    // WB-stage signals (driven below; declared here to avoid forward-ref)
    wire [31:0] ResultW;
    wire        RegWriteW;
    wire [ 4:0] RdW;

    wire [31:0] RD1D, RD2D;
    register_file rf (
        .clk (clk),
        .rst (rst),
        .we3 (RegWriteW),
        .a1  (Rs1D),
        .a2  (Rs2D),
        .a3  (RdW),
        .wd3 (ResultW),
        .rd1 (RD1D),
        .rd2 (RD2D)
    );

    wire [31:0] ImmExtD;
    extend ext (
        .instr  (InstrD[31:7]),
        .immsrc (ImmSrcD),
        .immext (ImmExtD)
    );

    // =========================================================================
    // ID/EX Pipeline Register
    // =========================================================================
    reg [31:0] RD1E_r, RD2E_r, ImmExtE_r, PCE_r, PCPlus4E_r;
    reg [ 4:0] Rs1E_r, Rs2E_r, RdE_r;
    reg [ 2:0] funct3E_r;
    reg        RegWriteE_r, ALUSrcE_r, MemWriteE_r;
    reg        BranchE_r, JumpE_r, JalrE_r, AuipcE_r;
    reg [ 1:0] ResultSrcE_r;
    reg [ 3:0] ALUControlE_r;

    always @(posedge clk) begin   // synchronous reset (FPGA-friendly; no latches)
        if (rst || FlushE) begin
            RD1E_r        <= 32'd0;  RD2E_r     <= 32'd0;
            ImmExtE_r     <= 32'd0;  PCE_r      <= 32'd0;
            PCPlus4E_r    <= 32'd0;
            Rs1E_r        <= 5'd0;   Rs2E_r     <= 5'd0;
            RdE_r         <= 5'd0;   funct3E_r  <= 3'd0;
            RegWriteE_r   <= 1'b0;   ALUSrcE_r  <= 1'b0;
            MemWriteE_r   <= 1'b0;   BranchE_r  <= 1'b0;
            JumpE_r       <= 1'b0;   JalrE_r    <= 1'b0;
            AuipcE_r      <= 1'b0;
            ResultSrcE_r  <= 2'd0;   ALUControlE_r <= 4'd0;
        end else if (!StallAll) begin
            RD1E_r        <= RD1D;        RD2E_r      <= RD2D;
            ImmExtE_r     <= ImmExtD;     PCE_r       <= PCD;
            PCPlus4E_r    <= PCPlus4D;
            Rs1E_r        <= Rs1D;        Rs2E_r      <= Rs2D;
            RdE_r         <= RdD;         funct3E_r   <= funct3D;
            RegWriteE_r   <= RegWriteD;   ALUSrcE_r   <= ALUSrcD;
            MemWriteE_r   <= MemWriteD;   BranchE_r   <= BranchD;
            JumpE_r       <= JumpD;       JalrE_r     <= JalrD;
            AuipcE_r      <= AuipcD;
            ResultSrcE_r  <= ResultSrcD;  ALUControlE_r <= ALUControlD;
        end
    end

    wire [31:0] RD1E        = RD1E_r;
    wire [31:0] RD2E        = RD2E_r;
    wire [31:0] ImmExtE     = ImmExtE_r;
    wire [31:0] PCE         = PCE_r;
    wire [31:0] PCPlus4E    = PCPlus4E_r;
    wire [ 4:0] Rs1E        = Rs1E_r;
    wire [ 4:0] Rs2E        = Rs2E_r;
    wire [ 4:0] RdE         = RdE_r;
    wire [ 2:0] funct3E     = funct3E_r;
    wire        RegWriteE   = RegWriteE_r;
    wire        ALUSrcE     = ALUSrcE_r;
    wire        MemWriteE   = MemWriteE_r;
    wire        BranchE     = BranchE_r;
    wire        JumpE       = JumpE_r;
    wire        JalrE       = JalrE_r;
    wire        AuipcE      = AuipcE_r;
    wire [ 1:0] ResultSrcE  = ResultSrcE_r;
    wire [ 3:0] ALUControlE = ALUControlE_r;

    // =========================================================================
    // EXECUTE STAGE
    // =========================================================================

    // Forward declarations for EX/MEM signals used by forwarding unit
    wire [31:0] ALUResultM_int;
    wire [ 4:0] RdM;
    wire        RegWriteM_w;

    wire [ 1:0] ForwardAE, ForwardBE;
    forwarding_unit fwd (
        .Rs1E      (Rs1E),
        .Rs2E      (Rs2E),
        .RdM       (RdM),
        .RegWriteM (RegWriteM_w),
        .RdW       (RdW),
        .RegWriteW (RegWriteW),
        .ForwardAE (ForwardAE),
        .ForwardBE (ForwardBE)
    );

    // Forwarding muxes
    wire [31:0] ForwardedA =
        (ForwardAE == 2'b10) ? ALUResultM_int :
        (ForwardAE == 2'b01) ? ResultW        : RD1E;

    wire [31:0] ForwardedB =
        (ForwardBE == 2'b10) ? ALUResultM_int :
        (ForwardBE == 2'b01) ? ResultW        : RD2E;

    // AUIPC selects PC as operand A; otherwise use forwarded rs1
    wire [31:0] SrcAE      = AuipcE  ? PCE     : ForwardedA;
    // ALUSrc selects immediate or forwarded rs2
    wire [31:0] SrcBE      = ALUSrcE ? ImmExtE : ForwardedB;
    // Write data to memory is always rs2 (before ALUSrc mux)
    wire [31:0] WriteDataE = ForwardedB;

    // ALU
    wire [31:0] ALUResultE;
    wire        ZeroE, NegativeE, OverflowE, CarryOutE;

    alu alu_inst (
        .a          (SrcAE),
        .b          (SrcBE),
        .alucontrol (ALUControlE),
        .result     (ALUResultE),
        .zero       (ZeroE),
        .negative   (NegativeE),
        .overflow   (OverflowE),
        .carry_out  (CarryOutE)
    );

    // Branch condition evaluation
    wire branch_taken =
        (funct3E == 3'b000) ?  ZeroE                   :  // beq
        (funct3E == 3'b001) ? ~ZeroE                   :  // bne
        (funct3E == 3'b100) ? (NegativeE ^ OverflowE)  :  // blt
        (funct3E == 3'b101) ? ~(NegativeE ^ OverflowE) :  // bge
        (funct3E == 3'b110) ? ~CarryOutE               :  // bltu
        (funct3E == 3'b111) ?  CarryOutE               :  // bgeu
        1'b0;

    assign PCSrcE    = JumpE | (BranchE & branch_taken);
    // JALR target: (rs1 + imm) with LSB forced to 0
    // JAL / Branch target: PC + immediate offset
    assign PCTargetE = JalrE ? {ALUResultE[31:1], 1'b0} : (PCE + ImmExtE);

    // =========================================================================
    // EX/MEM Pipeline Register
    // =========================================================================
    reg [31:0] ALUResultM_r, WriteDataM_r, PCPlus4M_r;
    reg [ 4:0] RdM_r;
    reg [ 2:0] Funct3M_r;
    reg        RegWriteM_r, MemWriteM_r;
    reg [ 1:0] ResultSrcM_r;

    always @(posedge clk) begin   // synchronous reset (FPGA-friendly; no latches)
        if (rst) begin
            ALUResultM_r <= 32'd0;  WriteDataM_r <= 32'd0;
            PCPlus4M_r   <= 32'd0;  RdM_r        <= 5'd0;
            Funct3M_r    <= 3'd0;   RegWriteM_r  <= 1'b0;
            MemWriteM_r  <= 1'b0;   ResultSrcM_r <= 2'd0;
        end else if (!StallAll) begin
            ALUResultM_r <= ALUResultE;  WriteDataM_r <= WriteDataE;
            PCPlus4M_r   <= PCPlus4E;   RdM_r        <= RdE;
            Funct3M_r    <= funct3E;    RegWriteM_r  <= RegWriteE;
            MemWriteM_r  <= MemWriteE;  ResultSrcM_r <= ResultSrcE;
        end
    end

    assign ALUResultM_int = ALUResultM_r;
    assign RdM            = RdM_r;
    assign RegWriteM_w    = RegWriteM_r;

    wire [31:0] PCPlus4M   = PCPlus4M_r;
    wire [ 1:0] ResultSrcM = ResultSrcM_r;

    // Drive external data-memory ports
    assign ALUResultM = ALUResultM_int;
    assign WriteDataM = WriteDataM_r;
    assign MemWriteM  = MemWriteM_r & mem_ready;  // suppress writes during clear
    assign Funct3M    = Funct3M_r;

    // =========================================================================
    // MEMORY STAGE  (data memory access is handled externally via ports above)
    // =========================================================================

    // =========================================================================
    // MEM/WB Pipeline Register
    // =========================================================================
    reg [31:0] ALUResultW_r, ReadDataW_r, PCPlus4W_r;
    reg [ 4:0] RdW_r;
    reg        RegWriteW_r;
    reg [ 1:0] ResultSrcW_r;

    always @(posedge clk) begin   // synchronous reset (FPGA-friendly; no latches)
        if (rst) begin
            ALUResultW_r <= 32'd0;  ReadDataW_r  <= 32'd0;
            PCPlus4W_r   <= 32'd0;  RdW_r        <= 5'd0;
            RegWriteW_r  <= 1'b0;   ResultSrcW_r <= 2'd0;
        end else if (!StallAll) begin
            ALUResultW_r <= ALUResultM_int;  ReadDataW_r  <= ReadDataM;
            PCPlus4W_r   <= PCPlus4M;        RdW_r        <= RdM;
            RegWriteW_r  <= RegWriteM_r;     ResultSrcW_r <= ResultSrcM;
        end
    end

    assign RdW       = RdW_r;
    assign RegWriteW = RegWriteW_r;

    wire [31:0] ALUResultW = ALUResultW_r;
    wire [31:0] ReadDataW  = ReadDataW_r;
    wire [31:0] PCPlus4W   = PCPlus4W_r;
    wire [ 1:0] ResultSrcW = ResultSrcW_r;

    // =========================================================================
    // WRITEBACK STAGE
    // ResultSrc: 2'b00 = ALUResult
    //            2'b01 = ReadData (load result)
    //            2'b10 = PCPlus4  (JAL / JALR return address)
    // =========================================================================
    assign ResultW =
        (ResultSrcW == 2'b01) ? ReadDataW  :
        (ResultSrcW == 2'b10) ? PCPlus4W   : ALUResultW;

    // =========================================================================
    // HAZARD UNIT
    // =========================================================================
    hazard_unit hazard (
        .Rs1D      (Rs1D),
        .Rs2D      (Rs2D),
        .Rs1E      (Rs1E),
        .Rs2E      (Rs2E),
        .RdE       (RdE),
        .PCSrcE    (PCSrcE),
        .ResultSrcE(ResultSrcE),
        .RdM       (RdM),
        .RegWriteM (RegWriteM_w),
        .RdW       (RdW),
        .RegWriteW (RegWriteW),
        .StallF    (StallF),
        .StallD    (StallD),
        .FlushD    (FlushD),
        .FlushE    (FlushE)
    );

endmodule