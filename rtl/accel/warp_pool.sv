// =============================================================================
// warp_pool.sv  -  M3 multi-warp SIMT engine with a round-robin scheduler
//
// This is the M2 single warp (rtl/accel/warp.sv) grown into a *pool*: NUM_WARPS
// hardware warp slots are resident at once, each with its own PC, banked VRF
// (vrf[warp][lane][reg]) and tail mask, all sharing ONE fetch/decode/ALU
// datapath and ONE data port. A round-robin scheduler issues one warp per cycle.
//
// Why this hides latency:  a memory instruction's lane accesses run in a
// *background* memory engine while the scheduler keeps issuing OTHER warps'
// compute instructions on the (otherwise idle) fetch/ALU datapath. So a warp's
// memory cost is overlapped with another warp's useful work — the classic GPU
// latency-hiding trick. The two resources advance in the same cycle:
//   * issue engine  : 1 warp fetch+decode+execute / cycle (single imem port)
//   * memory engine : 1 coalesced line transaction / cycle (single line dport)
// At most one memory instruction is in flight (single data port); a warp that
// wants memory while the port is busy simply waits its turn in the scheduler.
//
// M4 — address coalescing: the data port serves a whole cache line (LINE_WORDS
// words) per access. Each cycle the memory engine takes the line of the lowest
// still-pending active lane and services EVERY pending lane sharing that line in
// one line transaction. A contiguous warp access (A[tid]) is one line -> one
// transaction (1 cycle); a scattered access costs one transaction per distinct
// line (up to NUM_LANES). dbg_mem_txns counts transactions to show the win.
//
// On GO the engine spawns warps 0,1,2,... covering ceil(n_threads/WARP_SIZE)
// warps; if there are more warps than slots, a slot is recycled as soon as the
// warp occupying it retires. Convergent control flow only (shared next-PC follows
// lane 0); per-thread divergence is M5. Coalescing the replay is M4.
//
// NUM_WARPS must be a power of two (the round-robin pointer wraps in its width).
// =============================================================================
`timescale 1ns/1ps

module warp_pool
  import simtix_pkg::*;
(
    input  logic        clk,
    input  logic        rst,           // active-high

    // Dispatch: launch the whole grid (n_threads threads) in one GO.
    input  logic        start,         // 1-cycle: begin a new grid
    input  logic [31:0] base_a,
    input  logic [31:0] base_b,
    input  logic [31:0] base_c,
    input  logic [31:0] n_threads,
    input  logic [31:0] kernel_pc,

    // Shared kernel instruction fetch (async-read ROM).
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_data,

    // Single line-wide data port (coalesced accesses are issued onto it).
    output logic [31:0]          dmem_addr,    // line-aligned byte address
    output logic [LINE_BITS-1:0] dmem_wdata,   // one cache line of write data
    output logic                 dmem_we,
    output logic [LINE_BE-1:0]   dmem_be,       // per-byte write enable across line
    input  logic [LINE_BITS-1:0] dmem_rdata,    // one cache line of read data

    output logic        busy,
    output logic        done,          // 1-cycle pulse when the whole grid retires
    output logic [31:0] dbg_retire_a0, // last-retired warp's lane-0 tid (observ.)
    output logic [31:0] dbg_mem_txns   // line transactions since the last launch
);

    localparam int NW    = NUM_WARPS;
    localparam int NL    = NUM_LANES;
    localparam int WSZ   = WARP_SIZE;
    localparam int WIDXW = (NW > 1) ? $clog2(NW) : 1;
    localparam int LIDXW = $clog2(NL);

    // ── Per-slot architectural state ──────────────────────────────────────────────
    typedef enum logic [1:0] { W_EMPTY, W_RUN, W_MEM, W_DONE } wstate_e;
    wstate_e        wstate    [0:NW-1];
    logic [31:0]    pc        [0:NW-1];
    logic [31:0]    vrf       [0:NW-1][0:NL-1][0:31];   // banked, per warp
    logic [NL-1:0]  active    [0:NW-1];                 // tail mask, per warp
    logic [31:0]    warp_base [0:NW-1];                 // base tid (for tid CSR)

    // ── Grid bookkeeping ──────────────────────────────────────────────────────────
    logic [31:0]    arg_a, arg_b, arg_c, arg_n, arg_pc;
    logic [31:0]    total_warps;     // ceil(n_threads / WSZ)
    logic [31:0]    next_wid;        // next warp index to spawn into a free slot
    logic           running;
    logic [WIDXW-1:0] rr_ptr;        // round-robin issue pointer

    // ── Background memory engine (one in-flight, coalesced memory instruction) ──────
    logic             mem_busy;
    logic [WIDXW-1:0] mem_w;
    logic [NL-1:0]    mem_pending;               // active lanes not yet serviced
    logic             mem_is_store;
    logic [2:0]       mem_funct3;
    logic [4:0]       mem_rd;
    logic [31:0]      mem_next_pc;
    logic [31:0]      mem_addr_lane  [0:NL-1];   // latched per-lane eff. address
    logic [31:0]      mem_sdata_lane [0:NL-1];   // latched per-lane store data

    // ── Round-robin issue selection (combinational) ────────────────────────────────
    logic             issue_valid;
    logic [WIDXW-1:0] issue_w;
    always_comb begin
        issue_valid = 1'b0;
        issue_w     = '0;
        for (int k = 0; k < NW; k++) begin
            logic [WIDXW-1:0] idx;
            idx = rr_ptr + k[WIDXW-1:0];          // wraps in WIDXW bits (NW is pow2)
            if (!issue_valid && (wstate[idx] == W_RUN)) begin
                issue_valid = 1'b1;
                issue_w     = idx;
            end
        end
    end

    // ── Free-slot selection for spawning the next warp (combinational) ──────────────
    logic             fill_valid;
    logic [WIDXW-1:0] fill_w;
    always_comb begin
        fill_valid = 1'b0;
        fill_w     = '0;
        for (int k = 0; k < NW; k++) begin
            if (!fill_valid && ((wstate[k] == W_EMPTY) || (wstate[k] == W_DONE))) begin
                fill_valid = 1'b1;
                fill_w     = k[WIDXW-1:0];
            end
        end
    end

    // ── Shared fetch + decode (for the issuing warp) ───────────────────────────────
    assign imem_addr = pc[issue_w];

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

    // ── ALU control decode (shared) ────────────────────────────────────────────────
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

    // ── Per-lane datapath of the issuing warp (combinational) ───────────────────────
    logic [31:0] rv1   [0:NL-1];
    logic [31:0] rv2   [0:NL-1];
    logic [31:0] addr  [0:NL-1];   // effective address / ALU result per lane
    logic [31:0] wb_val[0:NL-1];
    logic        wb_en [0:NL-1];

    always_comb begin
        for (int l = 0; l < NL; l++) begin
            logic [31:0] a, b, y;
            logic [31:0] tid_l;
            rv1[l] = (rs1 == 5'd0) ? 32'd0 : vrf[issue_w][l][rs1];
            rv2[l] = (rs2 == 5'd0) ? 32'd0 : vrf[issue_w][l][rs2];
            tid_l  = warp_base[issue_w] + l[31:0];

            unique case (opcode)
                OP_OP:    begin a = rv1[l]; b = rv2[l]; end
                OP_OPIMM: begin a = rv1[l]; b = i_imm;  end
                OP_LOAD:  begin a = rv1[l]; b = i_imm;  end
                OP_STORE: begin a = rv1[l]; b = s_imm;  end
                OP_LUI:   begin a = 32'd0;  b = u_imm;  end
                OP_AUIPC: begin a = pc[issue_w]; b = u_imm; end
                default:  begin a = rv1[l]; b = rv2[l]; end
            endcase

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

            wb_val[l] = 32'd0;
            wb_en[l]  = 1'b0;
            unique case (opcode)
                OP_OP, OP_OPIMM, OP_LUI, OP_AUIPC: begin wb_val[l] = y;             wb_en[l] = 1'b1; end
                OP_JAL, OP_JALR:                   begin wb_val[l] = pc[issue_w] + 32'd4; wb_en[l] = 1'b1; end
                OP_SYSTEM: if (is_csr)             begin wb_val[l] = tid_l;          wb_en[l] = 1'b1; end
                default: ;
            endcase
            if (rd == 5'd0)             wb_en[l] = 1'b0;
            if (!active[issue_w][l])    wb_en[l] = 1'b0;
        end
    end

    // ── Shared next-PC (convergent control flow → follow lane 0) ────────────────────
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
        next_pc = pc[issue_w] + 32'd4;
        unique case (opcode)
            OP_JAL:    next_pc = pc[issue_w] + j_imm;
            OP_JALR:   next_pc = (rv1[0] + i_imm) & ~32'd1;
            OP_BRANCH: if (branch_taken0) next_pc = pc[issue_w] + b_imm;
            default: ;
        endcase
    end

    // ── Coalescing memory engine (uses the LATCHED replay context) ──────────────────
    // Pick the line of the lowest still-pending lane, then gather EVERY pending
    // lane sharing that line into one transaction. grp[l] = lanes serviced now.
    logic [LIDXW-1:0]   lead;        // lowest-index pending lane (the line leader)
    logic [31:LINE_OFF] lead_tag;    // its cache-line tag
    logic [NL-1:0]      grp;         // lanes coalesced into this cycle's line

    always_comb begin
        lead = '0;
        for (int l = NL-1; l >= 0; l--)        // low-to-... last write wins -> lowest
            if (mem_pending[l]) lead = l[LIDXW-1:0];
    end
    assign lead_tag = mem_addr_lane[lead][31:LINE_OFF];

    always_comb begin
        for (int l = 0; l < NL; l++)
            grp[l] = mem_pending[l] &&
                     (mem_addr_lane[l][31:LINE_OFF] == lead_tag);
    end

    // Per-lane load result, extracted from this cycle's line read.
    logic [31:0] ld_data [0:NL-1];
    always_comb begin
        for (int l = 0; l < NL; l++) begin
            logic [LINE_WOFFW-1:0] woff;
            logic [1:0]            bsel;
            logic [31:0]           word;
            logic [7:0]            lb;
            logic [15:0]           lh;
            woff    = mem_addr_lane[l][LINE_OFF-1:2];
            bsel    = mem_addr_lane[l][1:0];
            word    = dmem_rdata[woff*32 +: 32];
            lb      = word[8*bsel +: 8];
            lh      = mem_addr_lane[l][1] ? word[31:16] : word[15:0];
            unique case (mem_funct3)
                3'b000:  ld_data[l] = {{24{lb[7]}},  lb};
                3'b001:  ld_data[l] = {{16{lh[15]}}, lh};
                3'b010:  ld_data[l] = word;
                3'b100:  ld_data[l] = {24'b0, lb};
                3'b101:  ld_data[l] = {16'b0, lh};
                default: ld_data[l] = word;
            endcase
        end
    end

    // Drive the line port: line-aligned address, plus a merged store line.
    always_comb begin
        dmem_addr  = 32'd0;
        dmem_wdata = '0;
        dmem_we    = 1'b0;
        dmem_be    = '0;
        if (mem_busy) begin
            dmem_addr = {mem_addr_lane[lead][31:LINE_OFF], {LINE_OFF{1'b0}}};
            if (mem_is_store) begin
                dmem_we = 1'b1;
                for (int l = 0; l < NL; l++) begin
                    if (grp[l]) begin
                        logic [LINE_WOFFW-1:0] woff;
                        logic [1:0]            bsel;
                        logic [31:0]           sd;
                        woff = mem_addr_lane[l][LINE_OFF-1:2];
                        bsel = mem_addr_lane[l][1:0];
                        sd   = mem_sdata_lane[l];
                        unique case (mem_funct3)
                            3'b000: begin  // sb
                                dmem_wdata[woff*32 + bsel*8 +: 8] = sd[7:0];
                                dmem_be[woff*4 + bsel]            = 1'b1;
                            end
                            3'b001: begin  // sh
                                if (mem_addr_lane[l][1]) begin
                                    dmem_wdata[woff*32 + 16 +: 16] = sd[15:0];
                                    dmem_be[woff*4 + 2 +: 2]       = 2'b11;
                                end else begin
                                    dmem_wdata[woff*32 +: 16] = sd[15:0];
                                    dmem_be[woff*4 +: 2]      = 2'b11;
                                end
                            end
                            default: begin  // sw
                                dmem_wdata[woff*32 +: 32] = sd;
                                dmem_be[woff*4 +: 4]      = 4'b1111;
                            end
                        endcase
                    end
                end
            end
        end
    end

    // ── "Anything still running?" (combinational over current state) ────────────────
    logic any_busy;
    always_comb begin
        any_busy = (next_wid != total_warps);   // warps still to spawn
        for (int k = 0; k < NW; k++)
            if ((wstate[k] == W_RUN) || (wstate[k] == W_MEM)) any_busy = 1'b1;
    end

    // ── Sequential update ───────────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            running       <= 1'b0;
            busy          <= 1'b0;
            done          <= 1'b0;
            next_wid      <= 32'd0;
            total_warps   <= 32'd0;
            rr_ptr        <= '0;
            mem_busy      <= 1'b0;
            mem_pending   <= '0;
            dbg_retire_a0 <= 32'd0;
            dbg_mem_txns  <= 32'd0;
            for (int k = 0; k < NW; k++) wstate[k] <= W_EMPTY;
        end else begin
            done <= 1'b0;                         // default: 1-cycle pulse

            if (start) begin
                // Latch the grid and arm the spawner; clear all slots.
                arg_a       <= base_a;
                arg_b       <= base_b;
                arg_c       <= base_c;
                arg_n       <= n_threads;
                arg_pc      <= kernel_pc;
                total_warps <= (n_threads + WSZ - 1) / WSZ;
                next_wid     <= 32'd0;
                rr_ptr       <= '0;
                mem_busy     <= 1'b0;
                dbg_mem_txns <= 32'd0;
                running      <= 1'b1;
                busy         <= 1'b1;
                for (int k = 0; k < NW; k++) wstate[k] <= W_EMPTY;
            end else if (running) begin
                // 1) Spawn step: drop the next warp into a free/retired slot.
                if ((next_wid < total_warps) && fill_valid) begin
                    logic [31:0] sbase;
                    sbase = next_wid * WSZ;
                    for (int l = 0; l < NL; l++) begin
                        for (int r = 0; r < 32; r++) vrf[fill_w][l][r] <= 32'd0;
                        vrf[fill_w][l][ARG_TID] <= sbase + l[31:0];
                        vrf[fill_w][l][ARG_A]   <= arg_a;
                        vrf[fill_w][l][ARG_B]   <= arg_b;
                        vrf[fill_w][l][ARG_C]   <= arg_c;
                        vrf[fill_w][l][ARG_N]   <= arg_n;
                        active[fill_w][l]       <= ((sbase + l[31:0]) < arg_n);
                    end
                    warp_base[fill_w] <= sbase;
                    pc[fill_w]        <= arg_pc;
                    wstate[fill_w]    <= W_RUN;
                    next_wid          <= next_wid + 32'd1;
                end

                // 2) Issue step: advance one runnable warp on the shared datapath.
                if (issue_valid) begin
                    if (is_ecall) begin
                        wstate[issue_w] <= W_DONE;
                        dbg_retire_a0   <= warp_base[issue_w];
                    end else if (is_mem) begin
                        if (!mem_busy) begin
                            // Hand the coalesced access to the background engine.
                            // (active!=0 always holds: a spawned warp has >=1 lane.)
                            mem_busy     <= 1'b1;
                            mem_w        <= issue_w;
                            mem_pending  <= active[issue_w];
                            mem_is_store <= is_store;
                            mem_funct3   <= funct3;
                            mem_rd       <= rd;
                            mem_next_pc  <= next_pc;
                            for (int l = 0; l < NL; l++) begin
                                mem_addr_lane[l]  <= addr[l];
                                mem_sdata_lane[l] <= rv2[l];
                            end
                            wstate[issue_w] <= W_MEM;
                        end
                        // else: data port busy → warp waits (stays W_RUN).
                    end else begin
                        for (int l = 0; l < NL; l++)
                            if (wb_en[l]) vrf[issue_w][l][rd] <= wb_val[l];
                        pc[issue_w] <= next_pc;
                    end
                    rr_ptr <= issue_w + 1'b1;     // round-robin, advance past it
                end

                // 3) Memory engine step: one coalesced line transaction / cycle.
                if (mem_busy) begin
                    if (!mem_is_store && (mem_rd != 5'd0))
                        for (int l = 0; l < NL; l++)
                            if (grp[l]) vrf[mem_w][l][mem_rd] <= ld_data[l];

                    dbg_mem_txns <= dbg_mem_txns + 32'd1;

                    if ((mem_pending & ~grp) == '0) begin
                        mem_busy      <= 1'b0;
                        pc[mem_w]     <= mem_next_pc;   // mem ops are not control flow
                        wstate[mem_w] <= W_RUN;
                    end else begin
                        mem_pending <= mem_pending & ~grp;
                    end
                end

                // 4) Completion: nothing left to spawn and no slot running.
                if (!any_busy) begin
                    running <= 1'b0;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                end
            end
        end
    end

endmodule : warp_pool
