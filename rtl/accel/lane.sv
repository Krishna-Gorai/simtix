// =============================================================================
// lane.sv  -  one SIMT lane: a single-cycle RV32I integer core (M1.1)
//
// Executes ONE thread to completion. The dispatcher asserts `start` for one
// cycle with the thread's identity/arguments; the lane seeds its register file
// by convention (a0=tid, a1..a3=base ptrs, a4=n), runs the kernel starting at
// `kernel_pc`, and pulses `done` when the thread executes `ecall`.
//
// Single-cycle: one instruction per clock. The kernel instruction memory is an
// asynchronous-read ROM (imem_data valid same cycle as imem_addr).
//
// M1.1 scope: LUI AUIPC JAL JALR BRANCH OP OP-IMM CSRR(tid) ECALL.
// Loads/stores (the LOAD/STORE opcodes) are added in M1.2.
// =============================================================================
`timescale 1ns/1ps

module lane
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,           // active-high

    // Dispatch interface.
    input  logic        start,         // 1-cycle: begin a new thread
    input  logic [31:0] tid,
    input  logic [31:0] base_a,
    input  logic [31:0] base_b,
    input  logic [31:0] base_c,
    input  logic [31:0] n_threads,
    input  logic [31:0] kernel_pc,     // byte address of kernel entry

    // Kernel instruction fetch (async-read ROM).
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_data,

    output logic        busy,
    output logic        done,          // 1-cycle pulse when thread retires
    output logic [31:0] dbg_retire_a0  // value of a0 at retire (verification)
);

    // ── Architectural state ──────────────────────────────────────────────────────
    typedef enum logic { S_IDLE, S_RUN } state_e;
    state_e      state;
    logic [31:0] pc;
    logic [31:0] rf [0:31];

    assign imem_addr = pc;

    // ── Decode (combinational, from the registered pc/rf) ─────────────────────────
    logic [31:0] instr;
    logic [6:0]  opcode;
    logic [4:0]  rd, rs1, rs2;
    logic [2:0]  funct3;
    logic        funct7b5;   // instr[30]: distinguishes ADD/SUB, SRL/SRA
    logic [31:0] rv1, rv2;
    logic [31:0] i_imm, u_imm, b_imm, j_imm;

    assign instr    = imem_data;
    assign opcode   = instr[6:0];
    assign rd       = instr[11:7];
    assign funct3   = instr[14:12];
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign funct7b5 = instr[30];

    assign rv1 = (rs1 == 5'd0) ? 32'd0 : rf[rs1];
    assign rv2 = (rs2 == 5'd0) ? 32'd0 : rf[rs2];

    // Immediates.
    assign i_imm = {{20{instr[31]}}, instr[31:20]};
    assign u_imm = {instr[31:12], 12'b0};
    assign b_imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign j_imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    // ── ALU control decode ────────────────────────────────────────────────────────
    logic [3:0] alu_ctrl;
    always_comb begin
        unique case (opcode)
            OP_OP: begin
                unique case (funct3)
                    3'b000:  alu_ctrl = funct7b5 ? ALU_SUB : ALU_ADD;
                    3'b001:  alu_ctrl = ALU_SLL;
                    3'b010:  alu_ctrl = ALU_SLT;
                    3'b011:  alu_ctrl = ALU_SLTU;
                    3'b100:  alu_ctrl = ALU_XOR;
                    3'b101:  alu_ctrl = funct7b5 ? ALU_SRA : ALU_SRL;
                    3'b110:  alu_ctrl = ALU_OR;
                    default: alu_ctrl = ALU_AND;          // 3'b111
                endcase
            end
            OP_OPIMM: begin
                unique case (funct3)
                    3'b000:  alu_ctrl = ALU_ADD;          // addi
                    3'b010:  alu_ctrl = ALU_SLT;          // slti
                    3'b011:  alu_ctrl = ALU_SLTU;         // sltiu
                    3'b100:  alu_ctrl = ALU_XOR;          // xori
                    3'b001:  alu_ctrl = ALU_SLL;          // slli
                    3'b101:  alu_ctrl = funct7b5 ? ALU_SRA : ALU_SRL; // srai/srli
                    3'b110:  alu_ctrl = ALU_OR;           // ori
                    default: alu_ctrl = ALU_AND;          // andi (3'b111)
                endcase
            end
            OP_LUI:   alu_ctrl = ALU_PASSB;
            OP_AUIPC: alu_ctrl = ALU_ADD;
            default:  alu_ctrl = ALU_ADD;
        endcase
    end

    // ── ALU operands ──────────────────────────────────────────────────────────────
    logic [31:0] alu_a, alu_b;
    always_comb begin
        unique case (opcode)
            OP_OP:    begin alu_a = rv1; alu_b = rv2;   end
            OP_OPIMM: begin alu_a = rv1; alu_b = i_imm; end
            OP_LUI:   begin alu_a = 32'd0; alu_b = u_imm; end
            OP_AUIPC: begin alu_a = pc;  alu_b = u_imm; end
            default:  begin alu_a = rv1; alu_b = rv2;   end
        endcase
    end

    // ── ALU (inline; same encoding as rtl/cpu/alu.v) ─────────────────────────────
    logic [31:0] alu_y;
    always_comb begin
        unique case (alu_ctrl)
            ALU_ADD:  alu_y = alu_a + alu_b;
            ALU_SUB:  alu_y = alu_a - alu_b;
            ALU_AND:  alu_y = alu_a & alu_b;
            ALU_OR:   alu_y = alu_a | alu_b;
            ALU_XOR:  alu_y = alu_a ^ alu_b;
            ALU_SLT:  alu_y = ($signed(alu_a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            ALU_SLTU: alu_y = (alu_a < alu_b) ? 32'd1 : 32'd0;
            ALU_SLL:  alu_y = alu_a << alu_b[4:0];
            ALU_SRL:  alu_y = alu_a >> alu_b[4:0];
            ALU_SRA:  alu_y = $signed(alu_a) >>> alu_b[4:0];
            ALU_PASSB:alu_y = alu_b;
            default:  alu_y = 32'd0;
        endcase
    end

    // ── Branch condition ──────────────────────────────────────────────────────────
    logic branch_taken;
    always_comb begin
        unique case (funct3)
            3'b000:  branch_taken = (rv1 == rv2);                       // beq
            3'b001:  branch_taken = (rv1 != rv2);                       // bne
            3'b100:  branch_taken = ($signed(rv1) <  $signed(rv2));     // blt
            3'b101:  branch_taken = ($signed(rv1) >= $signed(rv2));     // bge
            3'b110:  branch_taken = (rv1 <  rv2);                       // bltu
            3'b111:  branch_taken = (rv1 >= rv2);                       // bgeu
            default: branch_taken = 1'b0;
        endcase
    end

    // ── CSR read (only TID supported) ─────────────────────────────────────────────
    logic [31:0] csr_val;
    assign csr_val = (instr[31:20] == CSR_TID) ? tid : 32'd0;

    // ── Write-back value + enable, and next PC ────────────────────────────────────
    logic [31:0] wb_val;
    logic        wb_en;
    logic [31:0] next_pc;
    logic        retire;

    always_comb begin
        wb_val  = 32'd0;
        wb_en   = 1'b0;
        next_pc = pc + 32'd4;
        retire  = 1'b0;

        unique case (opcode)
            OP_OP, OP_OPIMM, OP_LUI, OP_AUIPC: begin
                wb_val = alu_y;        wb_en = 1'b1;
            end
            OP_JAL: begin
                wb_val = pc + 32'd4;   wb_en = 1'b1;   next_pc = pc + j_imm;
            end
            OP_JALR: begin
                wb_val = pc + 32'd4;   wb_en = 1'b1;
                next_pc = (rv1 + i_imm) & ~32'd1;
            end
            OP_BRANCH: begin
                if (branch_taken) next_pc = pc + b_imm;
            end
            OP_SYSTEM: begin
                if (funct3 == 3'b000) begin
                    retire = 1'b1;                       // ecall: thread retires
                end else begin
                    wb_val = csr_val;  wb_en = 1'b1;     // csrr rd, TID
                end
            end
            default: /* unsupported in M1.1: no-op */ ;
        endcase

        if (rd == 5'd0) wb_en = 1'b0;                    // x0 is read-only
    end

    // ── Sequential update ─────────────────────────────────────────────────────────
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            pc            <= 32'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
            dbg_retire_a0 <= 32'd0;
            for (i = 0; i < 32; i = i + 1) rf[i] <= 32'd0;
        end else begin
            done <= 1'b0;                                // default: 1-cycle pulse

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        for (i = 0; i < 32; i = i + 1) rf[i] <= 32'd0;
                        rf[ARG_TID] <= tid;
                        rf[ARG_A]   <= base_a;
                        rf[ARG_B]   <= base_b;
                        rf[ARG_C]   <= base_c;
                        rf[ARG_N]   <= n_threads;
                        pc          <= kernel_pc;
                        busy        <= 1'b1;
                        state       <= S_RUN;
                    end
                end
                S_RUN: begin
                    if (retire) begin
                        dbg_retire_a0 <= rf[ARG_TID];
                        busy          <= 1'b0;
                        done          <= 1'b1;
                        state         <= S_IDLE;
                    end else begin
                        if (wb_en) rf[rd] <= wb_val;
                        pc <= next_pc;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule : lane
