// =============================================================================
// warp.sv  -  one SIMT warp: NUM_LANES threads in lockstep (M2)
//
// A warp shares ONE program counter and ONE instruction fetch across all lanes
// (the defining SIMT efficiency: 1 fetch/decode drives N datapaths). Each lane
// owns its slice of a banked vector register file (vrf[lane][reg]) and its own
// ALU, so the lanes compute different results from the same instruction stream.
//
// Lanes execute the same instruction every cycle. M2 assumes CONVERGENT control
// flow — every active lane agrees on branches/jumps — so the shared next-PC
// follows lane 0. Per-thread divergence (active mask + reconvergence stack) is
// added in M5. A static tail mask handles a partial final warp (tid >= N).
//
// Memory model: the lanes' loads/stores are SERIALIZED through the single data
// port, one lane per cycle (up to NUM_LANES cycles). Address coalescing (doing
// them in fewer cycles when they hit the same line) is the M4 contribution; the
// external memory interface is identical to the M1 single-lane core.
//
// Scope: LUI AUIPC JAL JALR BRANCH OP OP-IMM LOAD STORE CSRR(tid) ECALL.
// =============================================================================
`timescale 1ns/1ps

module warp
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,           // active-high

    // Dispatch interface: launch WARP_SIZE threads starting at base_tid.
    input  logic        start,         // 1-cycle: begin a new warp
    input  logic [31:0] base_tid,      // tid of lane 0 (0, 8, 16, ...)
    input  logic [31:0] base_a,
    input  logic [31:0] base_b,
    input  logic [31:0] base_c,
    input  logic [31:0] n_threads,
    input  logic [31:0] kernel_pc,

    // Shared kernel instruction fetch (async-read ROM).
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_data,

    // Single data port (lane accesses are serialized onto it).
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic        dmem_we,
    output logic [3:0]  dmem_be,
    input  logic [31:0] dmem_rdata,

    output logic        busy,
    output logic        done,          // 1-cycle pulse when the warp retires
    output logic [31:0] dbg_retire_a0  // lane 0's a0 at retire (verification)
);

    localparam int NL    = NUM_LANES;
    localparam int LIDXW = $clog2(NL);

    // ── Architectural state ──────────────────────────────────────────────────────
    typedef enum logic [1:0] { S_IDLE, S_EXEC, S_MEM } state_e;
    state_e          state;
    logic [31:0]     pc;
    logic [31:0]     vrf [0:NL-1][0:31];   // banked vector register file
    logic [NL-1:0]   active;               // per-lane enable (tail mask)
    logic [31:0]     warp_base;            // latched base_tid (for the tid CSR)
    logic [LIDXW-1:0] lane_idx;            // current lane during the S_MEM replay

    assign imem_addr = pc;

    // ── Decode (shared across all lanes) ──────────────────────────────────────────
    logic [31:0] instr;
    logic [6:0]  opcode;
    logic [4:0]  rd, rs1, rs2;
    logic [2:0]  funct3;
    logic        funct7b5;
    logic [31:0] i_imm, s_imm, u_imm, b_imm, j_imm;

    assign instr    = imem_data;
    assign opcode   = instr[6:0];
    assign rd       = instr[11:7];
    assign funct3   = instr[14:12];
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign funct7b5 = instr[30];

    assign i_imm = {{20{instr[31]}}, instr[31:20]};
    assign s_imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign u_imm = {instr[31:12], 12'b0};
    assign b_imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign j_imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    logic is_load, is_store, is_mem, is_ecall, is_csr;
    assign is_load  = (opcode == OP_LOAD);
    assign is_store = (opcode == OP_STORE);
    assign is_mem   = is_load | is_store;
    assign is_ecall = (opcode == OP_SYSTEM) && (funct3 == 3'b000);
    assign is_csr   = (opcode == OP_SYSTEM) && (funct3 != 3'b000);

    // ── ALU control decode (shared) ───────────────────────────────────────────────
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
                    default: alu_ctrl = ALU_AND;
                endcase
            end
            OP_OPIMM: begin
                unique case (funct3)
                    3'b000:  alu_ctrl = ALU_ADD;
                    3'b010:  alu_ctrl = ALU_SLT;
                    3'b011:  alu_ctrl = ALU_SLTU;
                    3'b100:  alu_ctrl = ALU_XOR;
                    3'b001:  alu_ctrl = ALU_SLL;
                    3'b101:  alu_ctrl = funct7b5 ? ALU_SRA : ALU_SRL;
                    3'b110:  alu_ctrl = ALU_OR;
                    default: alu_ctrl = ALU_AND;
                endcase
            end
            OP_LUI:   alu_ctrl = ALU_PASSB;
            OP_AUIPC: alu_ctrl = ALU_ADD;
            default:  alu_ctrl = ALU_ADD;   // LOAD/STORE address = base + imm
        endcase
    end

    // ── Per-lane datapath (combinational) ─────────────────────────────────────────
    logic [31:0] rv1   [0:NL-1];
    logic [31:0] rv2   [0:NL-1];
    logic [31:0] addr  [0:NL-1];   // effective address / ALU result per lane
    logic [31:0] wb_val[0:NL-1];
    logic        wb_en [0:NL-1];

    always_comb begin
        for (int l = 0; l < NL; l++) begin
            logic [31:0] a, b, y;
            logic [31:0] tid_l;
            rv1[l] = (rs1 == 5'd0) ? 32'd0 : vrf[l][rs1];
            rv2[l] = (rs2 == 5'd0) ? 32'd0 : vrf[l][rs2];
            tid_l  = warp_base + l[31:0];

            // ALU operand select.
            unique case (opcode)
                OP_OP:    begin a = rv1[l]; b = rv2[l]; end
                OP_OPIMM: begin a = rv1[l]; b = i_imm;  end
                OP_LOAD:  begin a = rv1[l]; b = i_imm;  end
                OP_STORE: begin a = rv1[l]; b = s_imm;  end
                OP_LUI:   begin a = 32'd0;  b = u_imm;  end
                OP_AUIPC: begin a = pc;     b = u_imm;  end
                default:  begin a = rv1[l]; b = rv2[l]; end
            endcase

            // ALU (same encoding as rtl/cpu/alu.v).
            unique case (alu_ctrl)
                ALU_ADD:  y = a + b;
                ALU_SUB:  y = a - b;
                ALU_AND:  y = a & b;
                ALU_OR:   y = a | b;
                ALU_XOR:  y = a ^ b;
                ALU_SLT:  y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                ALU_SLTU: y = (a < b) ? 32'd1 : 32'd0;
                ALU_SLL:  y = a << b[4:0];
                ALU_SRL:  y = a >> b[4:0];
                ALU_SRA:  y = $signed(a) >>> b[4:0];
                ALU_PASSB:y = b;
                default:  y = 32'd0;
            endcase

            addr[l]  = y;

            // Write-back (the load path writes back during S_MEM, not here).
            wb_val[l] = 32'd0;
            wb_en[l]  = 1'b0;
            unique case (opcode)
                OP_OP, OP_OPIMM, OP_LUI, OP_AUIPC: begin wb_val[l] = y;        wb_en[l] = 1'b1; end
                OP_JAL, OP_JALR:                   begin wb_val[l] = pc + 32'd4; wb_en[l] = 1'b1; end
                OP_SYSTEM: if (is_csr)             begin wb_val[l] = tid_l;     wb_en[l] = 1'b1; end
                default: ;
            endcase
            if (rd == 5'd0)  wb_en[l] = 1'b0;
            if (!active[l])  wb_en[l] = 1'b0;
        end
    end

    // ── Shared next-PC (convergent control flow → follow lane 0) ───────────────────
    logic branch_taken0;
    always_comb begin
        unique case (funct3)
            3'b000:  branch_taken0 = (rv1[0] == rv2[0]);
            3'b001:  branch_taken0 = (rv1[0] != rv2[0]);
            3'b100:  branch_taken0 = ($signed(rv1[0]) <  $signed(rv2[0]));
            3'b101:  branch_taken0 = ($signed(rv1[0]) >= $signed(rv2[0]));
            3'b110:  branch_taken0 = (rv1[0] <  rv2[0]);
            3'b111:  branch_taken0 = (rv1[0] >= rv2[0]);
            default: branch_taken0 = 1'b0;
        endcase
    end

    logic [31:0] next_pc;
    always_comb begin
        next_pc = pc + 32'd4;
        unique case (opcode)
            OP_JAL:    next_pc = pc + j_imm;
            OP_JALR:   next_pc = (rv1[0] + i_imm) & ~32'd1;
            OP_BRANCH: if (branch_taken0) next_pc = pc + b_imm;
            default: ;
        endcase
    end

    // ── Memory port (serialized over lanes during S_MEM) ──────────────────────────
    logic [31:0] cur_addr;
    logic [31:0] cur_rv2;
    logic [1:0]  cur_b;
    assign cur_addr = addr[lane_idx];
    assign cur_rv2  = rv2[lane_idx];
    assign cur_b    = cur_addr[1:0];

    // Load extraction (for the lane being serviced this cycle).
    logic [7:0]  ld_byte;
    logic [15:0] ld_half;
    logic [31:0] cur_load_data;
    assign ld_byte = dmem_rdata[8*cur_b +: 8];
    assign ld_half = cur_addr[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
    always_comb begin
        unique case (funct3)
            3'b000:  cur_load_data = {{24{ld_byte[7]}},  ld_byte};
            3'b001:  cur_load_data = {{16{ld_half[15]}}, ld_half};
            3'b010:  cur_load_data = dmem_rdata;
            3'b100:  cur_load_data = {24'b0, ld_byte};
            3'b101:  cur_load_data = {16'b0, ld_half};
            default: cur_load_data = dmem_rdata;
        endcase
    end

    always_comb begin
        dmem_addr  = 32'd0;
        dmem_wdata = 32'd0;
        dmem_we    = 1'b0;
        dmem_be    = 4'b0000;
        if ((state == S_MEM) && active[lane_idx]) begin
            dmem_addr = cur_addr;
            if (is_store) begin
                dmem_we = 1'b1;
                unique case (funct3)
                    3'b000:  begin dmem_wdata = {4{cur_rv2[7:0]}};  dmem_be = 4'b0001 << cur_b;            end
                    3'b001:  begin dmem_wdata = {2{cur_rv2[15:0]}}; dmem_be = cur_addr[1] ? 4'b1100 : 4'b0011; end
                    default: begin dmem_wdata = cur_rv2;            dmem_be = 4'b1111;                      end
                endcase
            end
        end
    end

    // ── Sequential update ─────────────────────────────────────────────────────────
    integer i, j;
    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            pc            <= 32'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
            active        <= '0;
            warp_base     <= 32'd0;
            lane_idx      <= '0;
            dbg_retire_a0 <= 32'd0;
            for (i = 0; i < NL; i = i + 1)
                for (j = 0; j < 32; j = j + 1) vrf[i][j] <= 32'd0;
        end else begin
            done <= 1'b0;                         // default: 1-cycle pulse

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        warp_base <= base_tid;
                        for (i = 0; i < NL; i = i + 1) begin
                            for (j = 0; j < 32; j = j + 1) vrf[i][j] <= 32'd0;
                            vrf[i][ARG_TID] <= base_tid + i[31:0];
                            vrf[i][ARG_A]   <= base_a;
                            vrf[i][ARG_B]   <= base_b;
                            vrf[i][ARG_C]   <= base_c;
                            vrf[i][ARG_N]   <= n_threads;
                            active[i]       <= ((base_tid + i[31:0]) < n_threads);
                        end
                        pc       <= kernel_pc;
                        busy     <= 1'b1;
                        lane_idx <= '0;
                        state    <= S_EXEC;
                    end
                end

                S_EXEC: begin
                    if (is_ecall) begin
                        dbg_retire_a0 <= vrf[0][ARG_TID];
                        busy          <= 1'b0;
                        done          <= 1'b1;
                        state         <= S_IDLE;
                    end else if (is_mem) begin
                        lane_idx <= '0;
                        state    <= S_MEM;        // replay lanes onto the data port
                    end else begin
                        for (i = 0; i < NL; i = i + 1)
                            if (wb_en[i]) vrf[i][rd] <= wb_val[i];
                        pc <= next_pc;
                    end
                end

                S_MEM: begin
                    // Service the current lane; capture loads into its bank.
                    if (is_load && active[lane_idx] && (rd != 5'd0))
                        vrf[lane_idx][rd] <= cur_load_data;

                    if (lane_idx == LIDXW'(NL - 1)) begin
                        lane_idx <= '0;
                        pc       <= next_pc;       // memory ops are not control flow
                        state    <= S_EXEC;
                    end else begin
                        lane_idx <= lane_idx + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule : warp
