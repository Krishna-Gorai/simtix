// =============================================================================
// control_unit.v  -  Main decoder + ALU decoder for RV32I  (fully synthesizable)
//
// Supported opcodes:
//   7'b0000011  Load      (lw, lh, lb, lhu, lbu)
//   7'b0100011  Store     (sw, sh, sb)
//   7'b0110011  R-type    (add, sub, and, or, xor, slt, sltu, sll, srl, sra)
//   7'b0010011  I-ALU     (addi, andi, ori, xori, slti, sltiu, slli, srli, srai)
//   7'b1100011  Branch    (beq, bne, blt, bge, bltu, bgeu)
//   7'b1101111  JAL
//   7'b1100111  JALR
//   7'b0110111  LUI
//   7'b0010111  AUIPC
//
// Internal ALUOp (2-bit):
//   2'b00 -> ADD (loads, stores, JALR, AUIPC)
//   2'b01 -> SUB (branches)
//   2'b10 -> decode via funct3/funct7 (R-type, I-ALU)
//   2'b11 -> PASS_B (LUI)
// =============================================================================
`timescale 1ns/1ps
(* dont_touch = "true" *)
module control_unit (
    input  wire [ 6:0] op,
    input  wire [ 2:0] funct3,
    input  wire        funct7b5,    // instr[30]

    output wire        RegWrite,
    output wire [ 2:0] ImmSrc,
    output wire        ALUSrc,
    output wire        MemWrite,
    output wire [ 1:0] ResultSrc,
    output wire        Branch,
    output wire        Jump,
    output wire        Jalr,
    output wire        Auipc,
    output wire [ 3:0] ALUControl
);

    // =========================================================================
    // Main decoder
    // =========================================================================
    reg        reg_write_d, alu_src_d, mem_write_d, branch_d, jump_d;
    reg        jalr_d, auipc_d;
    reg [ 2:0] imm_src_d;
    reg [ 1:0] result_src_d;
    reg [ 1:0] alu_op_d;

    always @(*) begin
        // Safe defaults (prevent latches)
        reg_write_d  = 1'b0;
        imm_src_d    = 3'b000;
        alu_src_d    = 1'b0;
        mem_write_d  = 1'b0;
        result_src_d = 2'b00;
        branch_d     = 1'b0;
        jump_d       = 1'b0;
        jalr_d       = 1'b0;
        auipc_d      = 1'b0;
        alu_op_d     = 2'b00;

        case (op)
            7'b0000011: begin                         // Load
                reg_write_d  = 1'b1;
                imm_src_d    = 3'b000;
                alu_src_d    = 1'b1;
                result_src_d = 2'b01;
                alu_op_d     = 2'b00;
            end
            7'b0100011: begin                         // Store
                imm_src_d   = 3'b001;
                alu_src_d   = 1'b1;
                mem_write_d = 1'b1;
                alu_op_d    = 2'b00;
            end
            7'b0110011: begin                         // R-type
                reg_write_d = 1'b1;
                alu_op_d    = 2'b10;
            end
            7'b0010011: begin                         // I-type ALU
                reg_write_d = 1'b1;
                imm_src_d   = 3'b000;
                alu_src_d   = 1'b1;
                alu_op_d    = 2'b10;
            end
            7'b1100011: begin                         // Branch
                imm_src_d = 3'b010;
                branch_d  = 1'b1;
                alu_op_d  = 2'b01;
            end
            7'b1101111: begin                         // JAL
                reg_write_d  = 1'b1;
                imm_src_d    = 3'b011;
                result_src_d = 2'b10;
                jump_d       = 1'b1;
            end
            7'b1100111: begin                         // JALR
                reg_write_d  = 1'b1;
                imm_src_d    = 3'b000;
                alu_src_d    = 1'b1;
                result_src_d = 2'b10;
                jump_d       = 1'b1;
                jalr_d       = 1'b1;
                alu_op_d     = 2'b00;
            end
            7'b0110111: begin                         // LUI
                reg_write_d = 1'b1;
                imm_src_d   = 3'b100;
                alu_src_d   = 1'b1;
                alu_op_d    = 2'b11;
            end
            7'b0010111: begin                         // AUIPC
                reg_write_d = 1'b1;
                imm_src_d   = 3'b100;
                alu_src_d   = 1'b1;
                auipc_d     = 1'b1;
                alu_op_d    = 2'b00;
            end
            default: begin                            // NOP / undefined
                reg_write_d  = 1'b0;
                imm_src_d    = 3'b000;
                alu_src_d    = 1'b0;
                mem_write_d  = 1'b0;
                result_src_d = 2'b00;
                branch_d     = 1'b0;
                jump_d       = 1'b0;
                jalr_d       = 1'b0;
                auipc_d      = 1'b0;
                alu_op_d     = 2'b00;
            end
        endcase
    end

    assign RegWrite  = reg_write_d;
    assign ImmSrc    = imm_src_d;
    assign ALUSrc    = alu_src_d;
    assign MemWrite  = mem_write_d;
    assign ResultSrc = result_src_d;
    assign Branch    = branch_d;
    assign Jump      = jump_d;
    assign Jalr      = jalr_d;
    assign Auipc     = auipc_d;

    // =========================================================================
    // ALU decoder
    // =========================================================================
    reg [3:0] alu_ctrl;

    always @(*) begin
        case (alu_op_d)
            2'b00: alu_ctrl = 4'b0000;           // ADD
            2'b01: alu_ctrl = 4'b0001;           // SUB  (branches)
            2'b11: alu_ctrl = 4'b1010;           // PASS_B (LUI)
            2'b10: begin
                case (funct3)
                    3'b000: alu_ctrl = (op[5] & funct7b5) ? 4'b0001  // SUB
                                                           : 4'b0000; // ADD/ADDI
                    3'b001: alu_ctrl = 4'b0111;  // SLL / SLLI
                    3'b010: alu_ctrl = 4'b0101;  // SLT / SLTI
                    3'b011: alu_ctrl = 4'b0110;  // SLTU / SLTIU
                    3'b100: alu_ctrl = 4'b0100;  // XOR / XORI
                    3'b101: alu_ctrl = funct7b5  ? 4'b1001  // SRA / SRAI
                                                 : 4'b1000; // SRL / SRLI
                    3'b110: alu_ctrl = 4'b0011;  // OR  / ORI
                    3'b111: alu_ctrl = 4'b0010;  // AND / ANDI
                    default: alu_ctrl = 4'b0000;
                endcase
            end
            default: alu_ctrl = 4'b0000;
        endcase
    end

    assign ALUControl = alu_ctrl;

endmodule