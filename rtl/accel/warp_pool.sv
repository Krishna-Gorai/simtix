// =============================================================================
// warp_pool.sv  -  M5 multi-warp SIMT engine with per-warp divergence stack
//
// This is the M2 single warp (rtl/accel/warp.sv) grown into a *pool*: NUM_WARPS
// hardware warp slots are resident at once, each with its own banked VRF
// (vrf[warp][lane][reg]) and a private SIMT reconvergence stack, all sharing ONE
// fetch/decode/ALU datapath and ONE data port. A round-robin scheduler issues
// one warp per cycle.
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
// words) per access; each cycle the memory engine services every pending lane
// sharing the lowest pending lane's line in one transaction. dbg_mem_txns counts.
//
// M5 — control divergence (TRUE SIMT): each warp slot owns a small SIMT
// reconvergence stack. The top-of-stack (TOS) frame defines the warp's current
// PC and *active mask* (which lanes execute). A branch is resolved per lane:
//   * uniform (all lanes agree)  -> just retarget the TOS PC, no divergence.
//   * divergent (lanes disagree) -> push a frame so the two lane groups run in
//     turn and reconverge at a join PC (RPC) stored in the frame.
// The supported, compiler-free convention is single-sided `if (cond){...}` and
// divergent loops (one side of the branch falls straight through to the join):
//   * forward branch  (target>pc): RPC = target;   continue = fall-through lanes.
//   * backward branch (target<=pc): RPC = pc+4;     continue = taken lanes (loop).
// The reconv frame holds the *union* mask at RPC; the pushed "continue" frame
// runs its lanes until their PC reaches RPC, then pops — and the warp reconverges
// with the full mask. Nesting works (stack depth SDEPTH). General two-sided
// if/else (both arms non-empty before the join) is out of scope for M5 — write
// it as two single-sided ifs. dbg_divergences counts divergent branch events.
//
// On GO the engine spawns warps 0,1,2,... covering ceil(n_threads/WARP_SIZE)
// warps; if there are more warps than slots, a slot is recycled as soon as the
// warp occupying it retires. NUM_WARPS must be a power of two (the round-robin
// pointer wraps in its width).
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
    output logic [31:0] dbg_mem_txns,  // global line transactions since last launch
    output logic [31:0] dbg_divergences, // divergent-branch events since last launch
    output logic [31:0] dbg_scratch_txns, // scratchpad transactions since last launch
    // M7 energy study — divergence-aware lane clock-gating accounting.
    output logic [31:0] dbg_issued_insns, // datapath instructions issued (lane-slots
                                          // = NUM_LANES * this if never gated)
    output logic [31:0] dbg_active_lanes  // Σ active lanes per issued instruction
                                          // (lane-cycles a gated design actually clocks)
);

    localparam int NW     = NUM_WARPS;
    localparam int NL     = NUM_LANES;
    localparam int WSZ    = WARP_SIZE;
    localparam int WIDXW  = (NW > 1) ? $clog2(NW) : 1;
    localparam int LIDXW  = $clog2(NL);
    localparam int SDEPTH = 8;                 // SIMT stack depth (nesting limit)
    localparam int SPW    = $clog2(SDEPTH);
    // VRF address = {warp, reg5}. NW is a power of two, so depth = NW*32.
    localparam int VAW    = WIDXW + 5;
    localparam int VDEPTH = (1 << VAW);
    // Scratchpad address = {warp, sidx}. One flat single-port RAM holds all warps'
    // scratch; depth = NW * SCRATCH_WORDS (M9: distributed-RAM, see banks below).
    localparam int SCAW    = WIDXW + SCRATCH_AW;
    localparam int SCDEPTH = NW * SCRATCH_WORDS;

    localparam logic [31:0] RPC_BOTTOM = 32'hFFFF_FFFF;  // base frame never pops

    // ── Per-slot architectural state ──────────────────────────────────────────────
    // W_SFU: parked on the multi-cycle divide/sqrt unit (M14.3). W_FPC: parked on the
    // pipelined FP-compute unit (M15). W_MUL: parked on the pipelined integer-multiply
    // unit (B1) — all mirror W_MEM's "park on a side engine while the scheduler keeps
    // issuing other warps" pattern.
    typedef enum logic [2:0] { W_EMPTY, W_RUN, W_MEM, W_SFU, W_FPC, W_MUL, W_DONE } wstate_e;
    wstate_e        wstate    [0:NW-1];

    // Vector register file — one independent distributed-RAM (LUTRAM) bank per lane,
    // each VDEPTH×32 addressed by {warp,reg}, with ONE synchronous write port and two
    // async read ports (rs1/rs2). The banks are declared per-lane in the generate
    // block below: a single 1D array per lane is what Vivado reliably infers as
    // LUTRAM, whereas a 2D vrf[lane][addr] written in a for-loop is misread as a
    // 3D-RAM and dissolves to 32 768 registers ([Synth 8-11357]). To preserve the
    // single write port we (a) never zero the file on spawn — see reg_written — and
    // (b) arbitrate issue- vs. memory-writeback so only one source drives a lane's
    // port per cycle (see the write arbiter below).
    logic [31:0]    vrf_rd1 [0:NL-1];                   // async read port 1 (rs1)
    logic [31:0]    vrf_rd2 [0:NL-1];                   // async read port 2 (rs2)

    // ── M14.0: floating-point register file (separate from the integer VRF) ──────
    // One independent distributed-RAM bank per lane, VDEPTH×32 addressed by
    // {warp,freg}, exactly like the integer VRF but with THREE async read ports
    // (fs1/fs2/fs3 — fs3 feeds the future FMA) and one sync write port. The 32-bit
    // width holds an FP32 value or a NaN-boxed FP16 (low 16 bits), so a single file
    // serves both formats. f0 is a normal register here (no x0 hardwiring). Unlike
    // the integer file there are no spawn seeds, so an unwritten f-register reads 0
    // (freg_written guards stale RAM contents on a recycled warp slot).
    logic [31:0]    frf_rd1 [0:NL-1];                   // async read port 1 (fs1)
    logic [31:0]    frf_rd2 [0:NL-1];                   // async read port 2 (fs2)
    logic [31:0]    frf_rd3 [0:NL-1];                   // async read port 3 (fs3, FMA)
    logic           freg_written [0:NW-1][0:NL-1][0:31];

    // Per-(warp,lane,reg) "has been written this grid" bit. An unwritten register
    // reads its spawn seed (a0=tid, a1..a4=args, else 0) instead of RAM, which
    // reproduces the old "zero the VRF on spawn then seed" behaviour bit-for-bit
    // without the 1-cycle 32-register clear that blocked RAM inference.
    logic           reg_written [0:NW-1][0:NL-1][0:31];

    logic [31:0]    warp_base [0:NW-1];                 // base tid (for tid CSR)

    // Per-warp on-chip scratchpad (M6): one word per address, shared by the
    // warp's lanes. Accesses in the SCRATCH_BASE aperture are serviced here and
    // never reach the global data port. M9: the array is a single flat
    // single-port distributed RAM (addr = {warp, sidx}); the memory engine now
    // services one lane per cycle (see scratch branch below) so a single port
    // suffices, trading multi-cycle scratch ops for ~8 k fewer flip-flops.
    logic [SCAW-1:0] sc_ra, sc_wa;   // scratch read / write address {warp, sidx}
    logic [31:0]     sc_rd, sc_wd;   // scratch read data / write data
    logic            sc_we;          // scratch write enable (store, lead lane)

    // Per-warp SIMT reconvergence stack. TOS = sp[w]; the TOS frame gives the
    // warp's live PC (stk_npc) and active mask (stk_mask); stk_rpc is the join PC
    // at which a pushed frame pops and reconverges into the frame below.
    logic [31:0]    stk_npc  [0:NW-1][0:SDEPTH-1];
    logic [31:0]    stk_rpc  [0:NW-1][0:SDEPTH-1];
    logic [NL-1:0]  stk_mask [0:NW-1][0:SDEPTH-1];
    logic [SPW-1:0] sp       [0:NW-1];

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
    logic             mem_is_scratch;            // latched: scratchpad vs global op
    logic             mem_is_fp;                 // latched: FP load/store (M14.0)
    logic [2:0]       mem_funct3;
    logic [4:0]       mem_rd;
    logic [31:0]      mem_next_pc;
    logic [31:0]      mem_addr_lane  [0:NL-1];   // latched per-lane eff. address
    logic [31:0]      mem_sdata_lane [0:NL-1];   // latched per-lane store data

    // ── Round-robin issue selection (combinational) ────────────────────────────────
    logic             issue_valid;
    // issue_w is the warp-select that addresses EVERY VRF/FRF distributed-RAM read
    // port (vaddr(issue_w,*)) and the reg_written/seed muxes — placed timing showed
    // its top bit fanning out to ~2419 endpoints (the dominant route-congestion net,
    // 61% of the critical-path delay). max_fanout forces Vivado to replicate the
    // driver into physically-local clusters; logic-equivalent, no functional change.
    (* max_fanout = 80 *)
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

    // ── Live TOS view of the issuing warp ───────────────────────────────────────────
    logic [SPW-1:0] cur_sp;
    logic [31:0]    cur_pc;
    logic [NL-1:0]  cur_mask;        // active lanes for the issuing warp this cycle
    assign cur_sp   = sp[issue_w];
    assign cur_pc   = stk_npc[issue_w][cur_sp];
    assign cur_mask = stk_mask[issue_w][cur_sp];

    // Shared fetch follows the issuing warp's TOS PC.
    assign imem_addr = cur_pc;

    // A pushed frame is "spent" (its lanes have reached the join) when its PC
    // equals its reconvergence PC → pop it next issue instead of executing.
    logic do_pop;
    assign do_pop = issue_valid && (cur_sp != '0) &&
                    (cur_pc == stk_rpc[issue_w][cur_sp]);

    // ── M7: divergence-aware lane clock-gating control ──────────────────────────────
    // The TOS active mask IS the per-lane clock-enable: a lane masked off by
    // divergence does no architectural work (its wb_en is already gated below), yet
    // in the baseline design its datapath registers still toggle every cycle. With
    // lane clock-gating, cur_mask[l] drives an integrated clock-gate (ICG) on lane
    // l's pipeline registers, so only the active lanes are clocked. `lane_ce` is
    // that enable vector (synthesis maps each bit to an ICG); the counters below
    // measure the dynamic energy a gated design saves versus clocking all NL lanes.
    logic [NL-1:0]    lane_ce;
    logic [LIDXW:0]   n_active;     // popcount(cur_mask): lanes a gated design clocks
    assign lane_ce  = cur_mask;
    assign n_active = lane_ce_count(lane_ce);

    function automatic logic [LIDXW:0] lane_ce_count(input logic [NL-1:0] m);
        lane_ce_count = '0;
        for (int l = 0; l < NL; l++) lane_ce_count += {{LIDXW{1'b0}}, m[l]};
    endfunction

    // VRF bank address from {warp, reg}.
    function automatic logic [VAW-1:0] vaddr(input logic [WIDXW-1:0] w,
                                             input logic [4:0]       r);
        vaddr = {w, r};
    endfunction

    // Spawn-seed value of a register that has not yet been written this grid.
    // Mirrors the old spawn writes: a0=tid (warp_base+lane), a1..a4=args, else 0.
    function automatic logic [31:0] seed_val(input logic [WIDXW-1:0] w,
                                             input logic [LIDXW-1:0] l,
                                             input logic [4:0]       r);
        case (r)
            ARG_TID[4:0]: seed_val = warp_base[w] + {{(32-LIDXW){1'b0}}, l};
            ARG_A[4:0]:   seed_val = arg_a;
            ARG_B[4:0]:   seed_val = arg_b;
            ARG_C[4:0]:   seed_val = arg_c;
            ARG_N[4:0]:   seed_val = arg_n;
            default:      seed_val = 32'd0;
        endcase
    endfunction

    // ── Decode ──────────────────────────────────────────────────────────────────────
    // instr = imem_data (the async-LUTRAM instruction fetch). Placed timing showed
    // imem_data fanning out to ~1324 endpoints (decode + every lane's operand mux +
    // read-address fields), the second-worst congestion net. Replicate the driver.
    (* max_fanout = 80 *)
    logic [31:0] instr;
    logic [6:0]  opcode;
    logic [4:0]  rd, rs1, rs2;
    logic [2:0]  funct3;
    logic        funct7b5, funct7b0;
    logic [31:0] i_imm, s_imm, u_imm, b_imm, j_imm;

    assign instr    = imem_data;
    assign opcode   = instr[6:0];
    assign rd       = instr[11:7];
    assign funct3   = instr[14:12];
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign funct7b5 = instr[30];
    assign funct7b0 = instr[25];   // RV32M ops set funct7[0] (e.g. mul: 0000001)

    assign i_imm = {{20{instr[31]}}, instr[31:20]};
    assign s_imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign u_imm = {instr[31:12], 12'b0};
    assign b_imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign j_imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    logic is_load, is_store, is_mem, is_ecall, is_csr, is_mul;
    assign is_load  = (opcode == OP_LOAD)  | (opcode == OP_LOADFP);
    assign is_store = (opcode == OP_STORE) | (opcode == OP_STOREFP);
    assign is_mem   = is_load | is_store;
    assign is_ecall = (opcode == OP_SYSTEM) && (funct3 == 3'b000);
    assign is_csr   = (opcode == OP_SYSTEM) && (funct3 != 3'b000);
    // B1: RV32M `mul` (low 32) — the only RV32M op this engine supports (funct3==000,
    // funct7[0]=1). It no longer executes in the single-cycle ALU; it parks on the
    // multi-cycle DSP-pipelined multiplier (W_MUL) so the DSP leaves the critical path.
    assign is_mul   = (opcode == OP_OP) && (funct3 == 3'b000) && funct7b0;

    // ── M14.0: floating-point decode ────────────────────────────────────────────
    // FP loads/stores reuse the integer memory engine (the address register is an
    // INTEGER reg in RV32F, so address-gen is unchanged); is_fp_mem only steers the
    // data side — store data is read from the f-regfile and load results are written
    // back to it. The OP-FP / fused-multiply-add compute ops are DECODED here so the
    // f-source/format/rounding fields are ready, but they execute no math yet (M14.1
    // adds the FPU); in M14.0 they retire as a PC-advancing no-op (no register
    // write), which is inert for every existing integer kernel.
    logic       is_load_fp, is_store_fp, is_fp_mem;
    logic [4:0] rs3;                       // fs3 for FMA read port (instr[31:27])
    assign is_load_fp  = (opcode == OP_LOADFP);
    assign is_store_fp = (opcode == OP_STOREFP);
    assign is_fp_mem   = is_load_fp | is_store_fp;
    assign rs3         = instr[31:27];

    // FP compute decode (OP-FP). funct5 selects the operation, fmt the format,
    // funct3 the rounding mode / group sub-select, instr[20] the signed/unsigned
    // variant of fcvt. The per-lane simt_fpu (M14.1) consumes these. The fused-
    // multiply-add majors (OP_FMADD..OP_FNMADD) are NOT executed yet (M14.1b): they
    // fall through to the compute default and retire as a PC-advancing no-op, so an
    // FMA-using kernel is inert rather than wrong-but-silent — covered by M14.1b.
    logic       is_fp_op, fp_int_dest, wb_is_fp, fp_cvt_unsigned, fp_cvt_src_h;
    logic [4:0] fp_funct5;                 // OP-FP operation select
    logic [1:0] fp_fmt;                    // 00=S(FP32), 10=H(FP16)
    logic [2:0] fp_rm;                     // rounding mode / sub-select
    assign is_fp_op        = (opcode == OP_FP);
    assign fp_funct5       = instr[31:27];
    assign fp_fmt          = instr[26:25];
    assign fp_rm           = instr[14:12];
    assign fp_cvt_unsigned = instr[20];
    // fcvt.s.h source is half when the rs2 field encodes the H format (00010).
    assign fp_cvt_src_h    = (fp_funct5 == FP_CVT_FF) && (instr[24:20] == 5'b00010);
    // FP ops whose RESULT lands in the integer register file (compares, float->int,
    // fmv.x.w / fclass); all other OP-FP results land in the f-register file.
    assign fp_int_dest = is_fp_op && ((fp_funct5 == FP_CMP)   ||
                                      (fp_funct5 == FP_CVT_W) ||
                                      (fp_funct5 == FP_FMVXW));

    // M14.1b: fused multiply-add majors (fmadd/fmsub/fnmsub/fnmadd). The opcode bits
    // encode the variant: opcode[3]=negate-product, opcode[2]=negate-addend
    //   fmadd 1000011 (np=0,nc=0)  fmsub 1000111 (np=0,nc=1)
    //   fnmsub 1001011(np=1,nc=0)  fnmadd 1001111(np=1,nc=1)
    // The third f-source is rs3 (instr[31:27]); fmt/rm reuse the OP-FP fields. An
    // FMA always writes the f-register file.
    logic is_fma_op, fma_np, fma_nc;
    assign is_fma_op = (opcode == OP_FMADD) || (opcode == OP_FMSUB) ||
                       (opcode == OP_FNMSUB) || (opcode == OP_FNMADD);
    assign fma_np    = opcode[3];
    assign fma_nc    = opcode[2];

    assign wb_is_fp    = (is_fp_op && !fp_int_dest) || is_fma_op;

    // M14.3: divide / square-root go to the multi-cycle shared-style SFU (one
    // fp_divsqrt per lane behind a stall scoreboard), NOT the single-cycle FPU.
    logic is_fdiv, is_fsqrt, is_sfu_op;
    assign is_fdiv   = is_fp_op && (fp_funct5 == FP_DIV);
    assign is_fsqrt  = is_fp_op && (fp_funct5 == FP_SQRT);
    assign is_sfu_op = is_fdiv || is_fsqrt;

    // ── ALU control decode (shared) ────────────────────────────────────────────────
    logic [3:0] alu_ctrl;
    always_comb begin
        unique case (opcode)
            OP_OP: begin
                unique case (funct3)
                    3'b000:  alu_ctrl = funct7b0 ? ALU_MUL
                                                 : (funct7b5 ? ALU_SUB : ALU_ADD);
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

    // ── Lowest active lane of the issuing warp (the leader for uniform decisions) ────
    logic [LIDXW-1:0] first_l;
    always_comb begin
        first_l = '0;
        for (int l = NL-1; l >= 0; l--)        // last write wins -> lowest set lane
            if (cur_mask[l]) first_l = l[LIDXW-1:0];
    end

    // ── Per-lane datapath of the issuing warp (combinational) ───────────────────────
    logic [31:0] rv1   [0:NL-1];
    logic [31:0] rv2   [0:NL-1];
    logic [31:0] frv1  [0:NL-1];   // f-source 1 (fs1) — FPU operand a  (M14.1)
    logic [31:0] frv2  [0:NL-1];   // f-source 2 (fs2) — FPU operand b / fsw data
    logic [31:0] frv3  [0:NL-1];   // f-source 3 (fs3) — FMA addend     (M14.1b)
    logic [31:0] addr  [0:NL-1];   // effective address / ALU result per lane
    logic [31:0] wb_val[0:NL-1];   // integer-VRF writeback value
    logic        wb_en [0:NL-1];   // integer-VRF writeback enable
    logic [NL-1:0] fwb_en;         // per-lane FP-compute writeback enable (-> fpc_we)
    logic [NL-1:0] mwb_en;         // per-lane integer-mul writeback enable (-> mul_we)
    logic [31:0] fpu_res[0:NL-1];  // per-lane FP32 execute result (combinational)
    logic [31:0] mul_res[0:NL-1];  // per-lane integer-mul result (pipelined DSP tree)

    // ── A1: FPU input pipeline registers (captured at FP-compute issue) ───────────────
    // Placed timing showed the worst path was: warp-state -> f-file LUTRAM read -> operand
    // mux -> FPU multiply, all in one cycle. We register the FPU operands + control at the
    // issue cycle (same capture-at-issue idea the SFU already uses for its operands), so
    // each simt_fpu starts stage-1 from clean registers and the f-file read + operand mux
    // + scheduler decode are lifted OUT of the multiply cone. Costs one extra FP-compute
    // latency cycle (absorbed by an added FPC_W2 scoreboard state); results are bit-exact.
    logic [31:0] q_frv1 [0:NL-1], q_frv2 [0:NL-1], q_frv3 [0:NL-1], q_rv1 [0:NL-1];
    // B1: integer-multiply operand hold registers (captured at issue, held while the
    // warp is parked on W_MUL so the DSP pipeline streams one constant pair to result).
    logic [31:0] q_mul_a [0:NL-1], q_mul_b [0:NL-1];
    logic [4:0]  q_fp_funct5;
    logic [2:0]  q_fp_rm;
    logic [1:0]  q_fp_fmt;
    logic        q_fp_cvt_unsigned, q_fp_cvt_src_h, q_is_fma_op, q_fma_np, q_fma_nc;

    // ── M14.1: per-lane FP32 execute unit (combinational) ───────────────────────────
    // One simt_fpu per lane runs the OP-FP datapath (add/sub/mul, sign-inject,
    // min/max, compare, int<->float convert, bit moves). Single-cycle, so an FP op
    // commits through the normal compute-writeback path (below) — to the f-file when
    // wb_is_fp, else to the integer VRF (compares / float->int / fmv.x.w). int_dest
    // is recomputed from the decode (fp_int_dest), so the module's is left open.
    genvar gp;
    generate
        for (gp = 0; gp < NL; gp++) begin : g_fpu
            /* verilator lint_off PINCONNECTEMPTY */
            simt_fpu u_fpu (
                .clk(clk),
                .funct5(q_fp_funct5), .cvt_unsigned(q_fp_cvt_unsigned),
                .cvt_src_h(q_fp_cvt_src_h), .rm(q_fp_rm), .fmt(q_fp_fmt),
                .is_fma(q_is_fma_op), .fma_np(q_fma_np), .fma_nc(q_fma_nc),
                .a(q_frv1[gp]), .b(q_frv2[gp]), .c(q_frv3[gp]), .xa(q_rv1[gp]),
                .res(fpu_res[gp]), .int_dest()      // recomputed as fp_int_dest in decode
            );
            /* verilator lint_on PINCONNECTEMPTY */
        end
    endgenerate

    // ── B1: per-lane multi-cycle integer multiplier (decomposed 16×16 DSPs) ──────────
    // RV32M `mul` (low 32) used to execute as a single-cycle `a*b` in the ALU, putting a
    // DSP48 directly in the fetch→execute→writeback combinational cloud (the placed
    // critical path) and — being un-pipelined — emitting DPIP/DPOP DRC advisories. We
    // pull it into this background engine: operands are captured at issue (q_mul_a/b),
    // the warp parks on W_MUL, the product streams through a fully-pipelined DSP tree,
    // and writes back when the integer VRF port is free.
    //
    // To make EVERY inferred DSP fully pipelined (AREG/BREG + MREG + PREG → 0 DRC
    // warnings) the 32×32 low product is DECOMPOSED into three 16×16 sub-multiplies:
    //     a*b (low32) = aL*bL + ((aL*bH + aH*bL) << 16)   [mod 2^32]
    // aH*bH is <<32 (irrelevant to the low 32); the low 32 is sign-agnostic, so the
    // unsigned sub-products are bit-correct for `mul`. Each 16×16 is one DSP that packs
    // cleanly (validated 0-warning in tests/dsp_pack_probe.sv). Latency = 6 internal
    // stages (split → DSP-in → MREG → PREG → cross-add → final-add); with the issue-cycle
    // q-capture that is 7 cycles issue→result, awaited by the MUL scoreboard countdown.
    genvar gm;
    generate
        for (gm = 0; gm < NL; gm++) begin : g_imul
            logic [15:0] aL, aH, bL, bH;
            always_ff @(posedge clk) begin
                aL <= q_mul_a[gm][15:0];  aH <= q_mul_a[gm][31:16];
                bL <= q_mul_b[gm][15:0];  bH <= q_mul_b[gm][31:16];
            end
            (* use_dsp = "yes" *) logic [15:0] aL_ll, bL_ll, aL_lh, bH_lh, aH_hl, bL_hl;
            logic [31:0] m_ll, p_ll, m_lh, p_lh, m_hl, p_hl;
            always_ff @(posedge clk) begin
                aL_ll <= aL; bL_ll <= bL;          // aL*bL  (low partial)
                aL_lh <= aL; bH_lh <= bH;          // aL*bH  (cross)
                aH_hl <= aH; bL_hl <= bL;          // aH*bL  (cross)
                m_ll <= aL_ll * bL_ll;  p_ll <= m_ll;
                m_lh <= aL_lh * bH_lh;  p_lh <= m_lh;
                m_hl <= aH_hl * bL_hl;  p_hl <= m_hl;
            end
            logic [31:0] cross_s, p_ll_d, lo_r;
            always_ff @(posedge clk) begin
                cross_s <= (p_lh + p_hl) << 16;    // only low 16 of the cross sum survives
                p_ll_d  <= p_ll;
                lo_r    <= p_ll_d + cross_s;
            end
            assign mul_res[gm] = lo_r;
        end
    endgenerate

    // ── M16: ONE shared serial divide/sqrt core, sequenced over the active lanes ─────
    // M14.3 placed a full fp_divsqrt in EVERY lane (8 cores ~= 5.5k LUT) running in
    // lockstep. Placed timing (M15) showed the FP datapath is interconnect-bound, so we
    // fold the eight cores into ONE shared core fed lane-by-lane. At issue we CAPTURE
    // every lane's operands (the live frv* read tracks the issuing warp and moves on to
    // other warps while the SFU iterates for tens of cycles), then walk the active lanes
    // serially through the single core, one result per ~26 (div) / 37 (sqrt) cycles.
    // This trades latency (k active lanes -> ~k x slower) for ~5k LUT and the congestion
    // relief that recovers Fmax. At most one warp's div/sqrt is in flight, as before.
    logic [31:0]      sfu_opa [0:NL-1];   // captured per-lane dividend / radicand
    logic [31:0]      sfu_opb [0:NL-1];   // captured per-lane divisor (unused for sqrt)
    logic             sfu_is_sqrt_r;      // captured op (sqrt vs divide) for the warp
    logic [1:0]       sfu_fmt_r;          // captured format (FP32 / FP16)
    logic [LIDXW-1:0] sfu_lane;           // lane currently in the shared core
    logic             sfu_core_start;     // 1-cycle launch pulse to the shared core
    logic             sfu_core_done;
    logic [31:0]      sfu_core_res;

    /* verilator lint_off PINCONNECTEMPTY */
    fp_divsqrt u_sfu (
        .clk(clk), .rst(rst),
        .start(sfu_core_start), .is_sqrt(sfu_is_sqrt_r), .fmt(sfu_fmt_r),
        .a(sfu_opa[sfu_lane]), .b(sfu_opb[sfu_lane]),
        .busy(), .done(sfu_core_done), .res(sfu_core_res)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // Lane sequencer priority encoders (descending loop -> lowest matching index wins):
    // sfu_first_lane = lowest active lane of the issuing warp; sfu_next_lane/sfu_more =
    // the lowest active lane strictly above the one in flight, and whether one remains.
    logic [LIDXW-1:0] sfu_first_lane, sfu_next_lane;
    logic             sfu_more;
    always_comb begin
        sfu_first_lane = '0;
        for (int l = NL-1; l >= 0; l--) if (cur_mask[l]) sfu_first_lane = l[LIDXW-1:0];
    end
    always_comb begin
        sfu_next_lane = sfu_lane;
        sfu_more      = 1'b0;
        for (int l = NL-1; l >= 0; l--)
            if ((l[LIDXW-1:0] > sfu_lane) && sfu_mask[l]) begin
                sfu_next_lane = l[LIDXW-1:0];
                sfu_more      = 1'b1;
            end
    end

    // SFU scoreboard: which warp is parked, its active mask + dest f-reg + resume PC,
    // and the held result between `done` and its f-file writeback.
    typedef enum logic [1:0] { SFU_IDLE, SFU_RUN, SFU_WB } sfu_st_e;
    sfu_st_e          sfu_state;
    logic [WIDXW-1:0] sfu_w;
    logic [NL-1:0]    sfu_mask;
    logic [4:0]       sfu_rd;
    logic [31:0]      sfu_resume_pc;
    logic [31:0]      sfu_hold [0:NL-1];
    logic             sfu_wb_fire;    // SFU result drives the f-file this cycle

    // ── M15→B2: pipelined FP-compute (add/sub/mul/FMA/cvt/cmp/...) ────────────────────
    // The FPU multiply/FMA cone was the longest path; simt_fpu is now a 5-STAGE pipeline
    // (operands in cycle T -> result `fpu_res` in cycle T+5), the depth set by making the
    // significand multiply a fully-pipelined DSP (clean DRC, B2). To consume the late
    // result correctly the issuing warp parks on a single-slot scoreboard (W_FPC) exactly
    // like the SFU: at issue the warp parks and the operands are captured (held constant);
    // FPC_WAIT counts the latency down, the result is captured into the held `fpc_data`,
    // then written back when the destination port is free (it YIELDS the f-file/VRF port to
    // the memory and SFU engines). Only one FP-compute op is in flight at a time.
    logic        do_fp;             // issue is an FP-compute op (not div/sqrt, not mem)
    logic        do_mul;            // issue is an RV32M `mul` (parks on W_MUL)
    // B2: simt_fpu is now a 5-stage pipeline (operands at T -> result at T+5), so the FPC
    // scoreboard waits the latency with a countdown (fpc_cnt) before capturing the result:
    // IDLE -> WAIT(cnt) -> WB. The +3-cycle deepening came from making the significand
    // multiply a fully-pipelined DSP (clean DRC). FPC_CNT_INIT = the FPU latency (5).
    typedef enum logic [1:0] { FPC_IDLE, FPC_WAIT, FPC_WB } fpc_st_e;
    fpc_st_e          fpc_state;
    logic [WIDXW-1:0] fpc_w;
    logic [4:0]       fpc_rd;
    logic             fpc_isfp;       // 1: result -> f-file; 0: -> integer VRF
    logic [NL-1:0]    fpc_we;         // per-lane writeback enable (mask + x0 guard)
    logic [31:0]      fpc_resume_pc;
    logic [31:0]      fpc_data [0:NL-1];
    logic [3:0]       fpc_cnt;        // FPU pipeline-latency countdown
    logic             fpc_wb_fire;    // held FP-compute result drives its port this cycle
    localparam logic [3:0] FPC_CNT_INIT = 4'd5;   // res valid 5 cycles after operands (q+5)

    // ── B1: pipelined integer-multiply scoreboard (W_MUL) ────────────────────────────
    // Mirrors W_FPC: one mul in flight, operands captured at issue (q_mul_a/b), the warp
    // parked while the decomposed DSP tree computes (mul_cnt counts the pipeline
    // latency), then the per-lane products are written back to the INTEGER VRF when the
    // port is free (yields to the memory + FPC engines). mul is always integer-dest.
    typedef enum logic [1:0] { MUL_IDLE, MUL_RUN, MUL_WB } mul_st_e;
    mul_st_e          mul_state;
    logic [WIDXW-1:0] mul_w;
    logic [4:0]       mul_rd;
    logic [NL-1:0]    mul_we;         // per-lane writeback enable (mask + x0 guard)
    logic [31:0]      mul_resume_pc;
    logic [31:0]      mul_data [0:NL-1];
    logic [3:0]       mul_cnt;        // DSP-tree latency countdown
    logic             mul_wb_fire;    // held mul result drives the integer VRF this cycle
    localparam logic [3:0] MUL_CNT_INIT = 4'd6;   // 7 cycles issue→result (q-capture + 6 stages)

    always_comb begin
        for (int l = 0; l < NL; l++) begin
            logic [31:0] a, b, y;
            rv1[l] = (rs1 == 5'd0) ? 32'd0 :
                     (reg_written[issue_w][l][rs1] ? vrf_rd1[l]
                                                   : seed_val(issue_w, l[LIDXW-1:0], rs1));
            rv2[l] = (rs2 == 5'd0) ? 32'd0 :
                     (reg_written[issue_w][l][rs2] ? vrf_rd2[l]
                                                   : seed_val(issue_w, l[LIDXW-1:0], rs2));
            // FP sources: no x0 hardwiring (f0 is real); unwritten reads 0.
            frv1[l] = freg_written[issue_w][l][rs1] ? frf_rd1[l] : 32'd0;
            frv2[l] = freg_written[issue_w][l][rs2] ? frf_rd2[l] : 32'd0;
            frv3[l] = freg_written[issue_w][l][rs3] ? frf_rd3[l] : 32'd0;

            unique case (opcode)
                OP_OP:     begin a = rv1[l]; b = rv2[l]; end
                OP_OPIMM:  begin a = rv1[l]; b = i_imm;  end
                OP_LOAD,
                OP_LOADFP: begin a = rv1[l]; b = i_imm;  end
                OP_STORE,
                OP_STOREFP:begin a = rv1[l]; b = s_imm;  end
                OP_LUI:    begin a = 32'd0;  b = u_imm;  end
                OP_AUIPC:  begin a = cur_pc; b = u_imm;  end
                default:   begin a = rv1[l]; b = rv2[l]; end
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
                ALU_MUL:  y = 32'd0;            // B1: `mul` executes in the W_MUL DSP engine
                default:  y = 32'd0;
            endcase

            addr[l]  = y;
        end
    end

    // Integer-VRF writeback value/enable for the single-cycle INTEGER compute ops
    // (ALU, jal/jalr link, csr tid). FP-compute results no longer commit here in the
    // issue cycle — they are registered and written back through the FPC pipeline
    // (W_FPC), so this block is integer-only. Kept SEPARATE from the operand reads
    // above to avoid a false UNOPTFLAT loop (fpu_res depends on rv1).
    always_comb begin
        for (int l = 0; l < NL; l++) begin
            logic [31:0] tid_l;
            tid_l = warp_base[issue_w] + l[31:0];
            wb_val[l] = 32'd0;
            wb_en[l]  = 1'b0;
            unique case (opcode)
                OP_OP, OP_OPIMM, OP_LUI, OP_AUIPC: begin wb_val[l] = addr[l];      wb_en[l] = 1'b1; end
                OP_JAL, OP_JALR:                   begin wb_val[l] = cur_pc + 32'd4; wb_en[l] = 1'b1; end
                OP_SYSTEM: if (is_csr)             begin wb_val[l] = tid_l;         wb_en[l] = 1'b1; end
                default: ;
            endcase
            if (rd == 5'd0)        wb_en[l] = 1'b0;
            if (!cur_mask[l])      wb_en[l] = 1'b0;   // masked-off lanes do nothing

            // Per-lane FP-compute writeback enable, captured at issue into fpc_we:
            // f-dest writes f0..f31 (no x0 guard), int-dest (cmp/cvt.w/fmv.x.w)
            // honors rd!=x0. Masked-off lanes never write.
            fwb_en[l]  = cur_mask[l] && (wb_is_fp || (rd != 5'd0));
            // B1: per-lane integer-mul writeback enable, captured at issue into mul_we.
            // mul is integer-dest, so honor rd!=x0; masked-off lanes never write.
            mwb_en[l]  = cur_mask[l] && (rd != 5'd0);
        end
    end

    // ── Per-lane branch decision + divergence masks ─────────────────────────────────
    logic [NL-1:0] btaken;     // active lanes whose branch condition is true
    always_comb begin
        for (int l = 0; l < NL; l++) begin
            logic t;
            unique case (funct3)
                3'b000:  t = (rv1[l] == rv2[l]);
                3'b001:  t = (rv1[l] != rv2[l]);
                3'b100:  t = ($signed(rv1[l]) <  $signed(rv2[l]));
                3'b101:  t = ($signed(rv1[l]) >= $signed(rv2[l]));
                3'b110:  t = (rv1[l] <  rv2[l]);
                3'b111:  t = (rv1[l] >= rv2[l]);
                default: t = 1'b0;
            endcase
            btaken[l] = cur_mask[l] & t;
        end
    end

    logic [NL-1:0] taken_mask, ntaken_mask;
    assign taken_mask  = btaken;
    assign ntaken_mask = cur_mask & ~btaken;

    // Branch/jump targets (relative to the issuing warp's TOS PC).
    logic [31:0] fallthru, br_target, jal_target, jalr_target;
    assign fallthru    = cur_pc + 32'd4;
    assign br_target   = cur_pc + b_imm;
    assign jal_target  = cur_pc + j_imm;
    assign jalr_target = (rv1[first_l] + i_imm) & ~32'd1;   // assumed uniform

    // A memory op targets the scratchpad if the leader lane's effective address
    // is in the SCRATCH_BASE aperture (bits[31:30]==2'b01). A given instruction
    // is assumed uniformly scratch-or-global across its active lanes.
    logic issue_is_scratch;
    assign issue_is_scratch = (addr[first_l][31:30] == 2'b01);

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
        if (mem_busy && !mem_is_scratch) begin
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
            if ((wstate[k] == W_RUN) || (wstate[k] == W_MEM) ||
                (wstate[k] == W_SFU) || (wstate[k] == W_FPC) ||
                (wstate[k] == W_MUL)) any_busy = 1'b1;
    end

    // ── VRF write arbiter (one write port per lane bank) ────────────────────────────
    // Two producers may target the file in the same cycle: the issue stage's compute
    // writeback (warp issue_w) and the memory engine's load result (warp mem_w). A
    // LUTRAM bank has ONE write port, so the memory writeback wins and the compute
    // writeback is squashed that cycle — the instruction simply re-issues next cycle
    // (it is idempotent: same VRF in → same result out). Stores and rd==x0 never
    // write the file.
    logic             mem_wb_act;             // memory engine writes a regfile this cycle
    logic [NL-1:0]    mem_wb_lane;            // per-lane: memory writeback fires
    logic [31:0]      mem_wb_data [0:NL-1];
    logic             do_compute;             // issue is a committing compute instr
    logic             squash_wb;              // its writeback is squashed by a mem write

    logic             v_we [0:NL-1];          // per-lane VRF write enable
    logic [VAW-1:0]   v_wa [0:NL-1];          // …address {warp,reg}
    logic [31:0]      v_wd [0:NL-1];          // …data
    logic [WIDXW-1:0] v_ww [0:NL-1];          // …warp (for the valid bit)
    logic [4:0]       v_wr [0:NL-1];          // …reg  (for the valid bit)

    // M14.0: FP-file write port (separate bank → no contention with the integer
    // VRF). The only FP writer in M14.0 is an `flw` load result; M14.1 adds the
    // FPU compute writeback through the same signals.
    logic             fv_we [0:NL-1];
    logic [VAW-1:0]   fv_wa [0:NL-1];
    logic [31:0]      fv_wd [0:NL-1];
    logic [WIDXW-1:0] fv_ww [0:NL-1];
    logic [4:0]       fv_wr [0:NL-1];

    always_comb begin
        for (int l = 0; l < NL; l++) begin
            mem_wb_lane[l] = 1'b0;
            mem_wb_data[l] = 32'd0;
            // FP loads target f0..f31 where f0 is a real register, so the rd!=x0
            // guard applies to integer loads only.
            if (mem_busy && !mem_is_store && (mem_is_fp || mem_rd != 5'd0)) begin
                // Scratch (M9): the engine serves ONE lane (the lowest-index
                // pending lane) per cycle, so only that lane's VRF is written,
                // sourced from the single RAM read port sc_rd.
                if (mem_is_scratch && mem_pending[lead] && (l[LIDXW-1:0] == lead)) begin
                    mem_wb_lane[l] = 1'b1;
                    mem_wb_data[l] = sc_rd;
                end else if (!mem_is_scratch && grp[l]) begin
                    mem_wb_lane[l] = 1'b1;
                    mem_wb_data[l] = ld_data[l];
                end
            end
        end
    end
    assign mem_wb_act     = |mem_wb_lane;
    // An FP-compute op (add/sub/mul/FMA/sgnj/min/max/cmp/cvt/fmv/fclass — NOT div/
    // sqrt, NOT a load/store): retires through the pipelined FPC unit (W_FPC).
    assign do_fp          = issue_valid && !do_pop && !is_ecall && !is_mem &&
                            ((is_fp_op && !is_sfu_op) || is_fma_op);
    // B1: an RV32M `mul` — retires through the pipelined integer-multiply engine (W_MUL).
    assign do_mul         = issue_valid && !do_pop && !is_ecall && !is_mem &&
                            !is_sfu_op && is_mul;
    // A single-cycle INTEGER compute: not a pop/ecall/memory/divide-sqrt/FP-compute/mul.
    assign do_compute     = issue_valid && !do_pop && !is_ecall && !is_mem &&
                            !is_sfu_op && !do_fp && !do_mul;

    // The held SFU result drives the f-file when the unit is in writeback and the
    // memory engine is not using the FP port this cycle (mem wins; SFU result waits).
    assign sfu_wb_fire = (sfu_state == SFU_WB) && !(mem_busy && mem_is_fp);

    // The held FP-compute result drives its destination port when ready. It YIELDS to
    // the (non-deferrable) memory engine on the relevant port, and to the SFU on the
    // f-file — so it never collides; if blocked, it simply waits (the warp stays
    // parked and the result is held in fpc_data).
    assign fpc_wb_fire = (fpc_state == FPC_WB) &&
                         ( fpc_isfp ? !((mem_wb_act && mem_is_fp) || sfu_wb_fire)
                                    : !(mem_wb_act && !mem_is_fp) );

    // B1: the held integer-mul result drives the integer VRF when the unit is in
    // writeback and that port is free. It is deferrable like FPC: it yields to the
    // (non-deferrable) integer memory writeback and to the integer-dest FPC writeback,
    // so it never collides; if blocked it waits (the warp stays parked in W_MUL).
    assign mul_wb_fire = (mul_state == MUL_WB) &&
                         !((mem_wb_act && !mem_is_fp) || (fpc_wb_fire && !fpc_isfp));

    // A single-cycle integer compute (always integer-VRF dest now) is squashed when
    // its port is taken this cycle by an integer memory load, the integer-dest FPC
    // writeback, or the integer-mul writeback. It re-issues next cycle (idempotent).
    assign squash_wb      = do_compute &&
                            ((mem_wb_act && !mem_is_fp) || (fpc_wb_fire && !fpc_isfp) ||
                             mul_wb_fire);

    always_comb begin
        for (int l = 0; l < NL; l++) begin
            v_we[l] = 1'b0;
            v_wa[l] = '0;
            v_wd[l] = 32'd0;
            v_ww[l] = '0;
            v_wr[l] = 5'd0;
            fv_we[l] = 1'b0;
            fv_wa[l] = '0;
            fv_wd[l] = 32'd0;
            fv_ww[l] = '0;
            fv_wr[l] = 5'd0;
            // The FP file (fv_we) and the integer VRF (v_we) are SEPARATE write ports.
            // FP-file port priority: flw load result > SFU div/sqrt > pipelined
            // FP-compute (fpc, f-dest). The two deferrable engines (SFU, FPC) yield to
            // the memory engine and, for FPC, to the SFU — see *_wb_fire above.
            if (mem_wb_lane[l] && mem_is_fp) begin                     // FP load writeback
                fv_we[l] = 1'b1;
                fv_ww[l] = mem_w;
                fv_wr[l] = mem_rd;
                fv_wa[l] = vaddr(mem_w, mem_rd);
                fv_wd[l] = mem_wb_data[l];
            end else if (sfu_wb_fire && sfu_mask[l]) begin             // SFU div/sqrt result
                fv_we[l] = 1'b1;
                fv_ww[l] = sfu_w;
                fv_wr[l] = sfu_rd;
                fv_wa[l] = vaddr(sfu_w, sfu_rd);
                fv_wd[l] = sfu_hold[l];
            end else if (fpc_wb_fire && fpc_isfp && fpc_we[l]) begin   // pipelined FP-compute (f)
                fv_we[l] = 1'b1;
                fv_ww[l] = fpc_w;
                fv_wr[l] = fpc_rd;
                fv_wa[l] = vaddr(fpc_w, fpc_rd);
                fv_wd[l] = fpc_data[l];
            end
            // Integer VRF port priority: integer load result > pipelined FP-compute
            // (fpc, int-dest: cmp/cvt.w/fmv.x.w/fclass) > single-cycle integer compute
            // (ALU/jal/jalr/csr). A colliding integer compute is squashed (squash_wb).
            if (mem_wb_lane[l] && !mem_is_fp) begin                    // integer mem writeback
                v_we[l] = 1'b1;
                v_ww[l] = mem_w;
                v_wr[l] = mem_rd;
                v_wa[l] = vaddr(mem_w, mem_rd);
                v_wd[l] = mem_wb_data[l];
            end else if (fpc_wb_fire && !fpc_isfp && fpc_we[l]) begin  // pipelined FP-compute (int)
                v_we[l] = 1'b1;
                v_ww[l] = fpc_w;
                v_wr[l] = fpc_rd;
                v_wa[l] = vaddr(fpc_w, fpc_rd);
                v_wd[l] = fpc_data[l];
            end else if (mul_wb_fire && mul_we[l]) begin               // pipelined integer-mul
                v_we[l] = 1'b1;
                v_ww[l] = mul_w;
                v_wr[l] = mul_rd;
                v_wa[l] = vaddr(mul_w, mul_rd);
                v_wd[l] = mul_data[l];
            end else if (do_compute && !squash_wb && wb_en[l]) begin   // int compute writeback
                v_we[l] = 1'b1;
                v_ww[l] = issue_w;
                v_wr[l] = rd;
                v_wa[l] = vaddr(issue_w, rd);
                v_wd[l] = wb_val[l];
            end
        end
    end

    // ── Per-lane VRF banks (distributed RAM) ────────────────────────────────────────
    // One 1D array per lane: a single sync write port + two async read ports. This is
    // the canonical LUTRAM pattern; the ram_style attribute pins it to distributed RAM.
    genvar gl;
    generate
        for (gl = 0; gl < NL; gl++) begin : g_vrf
            (* ram_style = "distributed" *)
            logic [31:0] bank [0:VDEPTH-1];
            always_ff @(posedge clk)
                if (v_we[gl]) bank[v_wa[gl]] <= v_wd[gl];
            assign vrf_rd1[gl] = bank[vaddr(issue_w, rs1)];
            assign vrf_rd2[gl] = bank[vaddr(issue_w, rs2)];
        end
    endgenerate

    // ── Per-lane FP register-file banks (distributed RAM) — M14.0 ────────────────────
    // Same LUTRAM pattern as the integer VRF, but THREE async read ports (fs1/fs2/
    // fs3) feed the future FMA. One sync write port; in M14.0 the only writer is an
    // flw load result (fv_we), M14.1 adds the FPU compute writeback.
    genvar gf;
    generate
        for (gf = 0; gf < NL; gf++) begin : g_frf
            (* ram_style = "distributed" *)
            logic [31:0] bank [0:VDEPTH-1];
            always_ff @(posedge clk)
                if (fv_we[gf]) bank[fv_wa[gf]] <= fv_wd[gf];
            assign frf_rd1[gf] = bank[vaddr(issue_w, rs1)];
            assign frf_rd2[gf] = bank[vaddr(issue_w, rs2)];
            assign frf_rd3[gf] = bank[vaddr(issue_w, rs3)];
        end
    endgenerate

    // ── Scratchpad memory (distributed RAM, single port) ────────────────────────────
    // The memory engine drains scratch ops one lane per cycle. `lead` is the lowest
    // still-pending lane; that lane's word is the one read (load) or written (store)
    // this cycle. Stores commit lead's data; loads feed sc_rd to the VRF arbiter.
    logic [SCRATCH_AW-1:0] sc_sidx;
    assign sc_sidx = mem_addr_lane[lead][SCRATCH_AW+1:2];
    assign sc_ra   = {mem_w, sc_sidx};
    assign sc_wa   = {mem_w, sc_sidx};
    assign sc_wd   = mem_sdata_lane[lead];
    assign sc_we   = mem_busy && mem_is_scratch && mem_is_store && mem_pending[lead];

    (* ram_style = "distributed" *)
    logic [31:0] scratch [0:SCDEPTH-1];
    always_ff @(posedge clk)
        if (sc_we) scratch[sc_wa] <= sc_wd;
    assign sc_rd = scratch[sc_ra];

    // ── Sequential update ───────────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            running        <= 1'b0;
            busy           <= 1'b0;
            done           <= 1'b0;
            next_wid       <= 32'd0;
            total_warps    <= 32'd0;
            rr_ptr         <= '0;
            mem_busy       <= 1'b0;
            mem_is_scratch <= 1'b0;
            mem_pending    <= '0;
            sfu_state      <= SFU_IDLE;
            sfu_core_start <= 1'b0;
            fpc_state      <= FPC_IDLE;
            mul_state      <= MUL_IDLE;
            dbg_retire_a0  <= 32'd0;
            dbg_mem_txns   <= 32'd0;
            dbg_divergences<= 32'd0;
            dbg_scratch_txns<= 32'd0;
            dbg_issued_insns<= 32'd0;
            dbg_active_lanes<= 32'd0;
            for (int k = 0; k < NW; k++) wstate[k] <= W_EMPTY;
            // Two single-statement loops (NOT one begin/end body): Verilator's
            // array-init pass only accepts a lone delayed array write per for loop
            // (BLKLOOPINIT on 5.020), so reg/freg clears stay separate.
            for (int k = 0; k < NW; k++)
                for (int l = 0; l < NL; l++)
                    for (int r = 0; r < 32; r++) reg_written[k][l][r] <= 1'b0;
            for (int k = 0; k < NW; k++)
                for (int l = 0; l < NL; l++)
                    for (int r = 0; r < 32; r++) freg_written[k][l][r] <= 1'b0;
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
                next_wid       <= 32'd0;
                rr_ptr         <= '0;
                mem_busy       <= 1'b0;
                sfu_state      <= SFU_IDLE;
                sfu_core_start <= 1'b0;
                fpc_state      <= FPC_IDLE;
                mul_state      <= MUL_IDLE;
                dbg_mem_txns   <= 32'd0;
                dbg_divergences<= 32'd0;
                dbg_scratch_txns<= 32'd0;
                dbg_issued_insns<= 32'd0;
                dbg_active_lanes<= 32'd0;
                running        <= 1'b1;
                busy           <= 1'b1;
                for (int k = 0; k < NW; k++) wstate[k] <= W_EMPTY;
            end else if (running) begin
                // 1) Spawn step: drop the next warp into a free/retired slot.
                if ((next_wid < total_warps) && fill_valid) begin
                    logic [31:0]   sbase;
                    logic [NL-1:0] tmask;
                    sbase = next_wid * WSZ;
                    // No VRF clear here (that 1-cycle 32-register write blocked RAM
                    // inference). Instead mark every register unwritten so reads
                    // return their spawn seed (a0=tid, a1..a4=args, else 0).
                    for (int l = 0; l < NL; l++) begin
                        // Separate single-statement r-loops (see BLKLOOPINIT note above).
                        for (int r = 0; r < 32; r++) reg_written[fill_w][l][r]  <= 1'b0;
                        for (int r = 0; r < 32; r++) freg_written[fill_w][l][r] <= 1'b0;
                        tmask[l] = ((sbase + l[31:0]) < arg_n);   // tail mask
                    end
                    warp_base[fill_w]        <= sbase;
                    // Seed the SIMT stack: base frame = whole warp at kernel_pc.
                    sp[fill_w]               <= '0;
                    stk_npc[fill_w][0]       <= arg_pc;
                    stk_rpc[fill_w][0]       <= RPC_BOTTOM;
                    stk_mask[fill_w][0]      <= tmask;
                    wstate[fill_w]           <= W_RUN;
                    next_wid                 <= next_wid + 32'd1;
                end

                // 2) Issue step: advance one runnable warp on the shared datapath.
                if (issue_valid) begin
                    // M7 energy accounting: a committed datapath instruction clocks
                    // n_active lanes under gating vs all NL lanes ungated. A pop is
                    // bookkeeping (no datapath); a memory op or an fdiv/fsqrt that
                    // finds its engine busy re-attempts later (don't count the stall).
                    if (!do_pop && !(is_mem && mem_busy) && !squash_wb &&
                        !(is_sfu_op && sfu_state != SFU_IDLE) &&
                        !(do_fp && fpc_state != FPC_IDLE) &&
                        !(do_mul && mul_state != MUL_IDLE)) begin
                        dbg_issued_insns <= dbg_issued_insns + 32'd1;
                        dbg_active_lanes <= dbg_active_lanes +
                                            {{(31-LIDXW){1'b0}}, n_active};
                    end
                    if (do_pop) begin
                        // Pushed frame reached its join: reconverge into the frame
                        // below (which already holds the union mask at this PC).
                        sp[issue_w] <= cur_sp - 1'b1;
                    end else if (is_ecall) begin
                        wstate[issue_w] <= W_DONE;
                        dbg_retire_a0   <= warp_base[issue_w];
                    end else if (do_fp) begin
                        // FP-compute: capture the operands + control into the FPU input
                        // registers this cycle (A1); the registered operands then feed the
                        // 5-stage FPU, so the result is valid five cycles later. Park the
                        // warp on the single-slot FPC pipeline; FPC_WAIT counts the latency
                        // down (fpc_cnt) and captures the result. If FPC busy, the warp waits.
                        if (fpc_state == FPC_IDLE) begin
                            fpc_w           <= issue_w;
                            fpc_rd          <= rd;
                            fpc_isfp        <= wb_is_fp;
                            fpc_we          <= fwb_en;
                            fpc_resume_pc   <= fallthru;
                            wstate[issue_w] <= W_FPC;
                            fpc_state       <= FPC_WAIT;
                            fpc_cnt         <= FPC_CNT_INIT;
                            // A1: latch this op's operands + control into the FPU input
                            // registers, so stage-1 starts from a clean register boundary.
                            for (int l = 0; l < NL; l++) begin
                                q_frv1[l] <= frv1[l]; q_frv2[l] <= frv2[l];
                                q_frv3[l] <= frv3[l]; q_rv1[l]  <= rv1[l];
                            end
                            q_fp_funct5       <= fp_funct5;
                            q_fp_cvt_unsigned <= fp_cvt_unsigned;
                            q_fp_cvt_src_h    <= fp_cvt_src_h;
                            q_fp_rm           <= fp_rm;
                            q_fp_fmt          <= fp_fmt;
                            q_is_fma_op       <= is_fma_op;
                            q_fma_np          <= fma_np;
                            q_fma_nc          <= fma_nc;
                        end
                        // else: FPC busy → warp waits.
                    end else if (do_mul) begin
                        // B1: RV32M `mul` — capture the operands into the multiply
                        // pipeline's hold registers, park the warp on the single-slot
                        // W_MUL scoreboard, and arm the latency countdown. The scheduler
                        // keeps issuing other warps while the DSP tree streams. If the
                        // multiplier is busy with another warp, this warp waits (W_RUN).
                        if (mul_state == MUL_IDLE) begin
                            mul_w           <= issue_w;
                            mul_rd          <= rd;
                            mul_we          <= mwb_en;
                            mul_resume_pc   <= fallthru;
                            wstate[issue_w] <= W_MUL;
                            mul_state       <= MUL_RUN;
                            mul_cnt         <= MUL_CNT_INIT;
                            for (int l = 0; l < NL; l++) begin
                                q_mul_a[l] <= rv1[l];
                                q_mul_b[l] <= rv2[l];
                            end
                        end
                        // else: multiplier busy → warp waits.
                    end else if (is_sfu_op) begin
                        // Divide / square-root: capture every lane's f-operands now (they
                        // are live this cycle but move on with the scheduler), park the
                        // warp, and arm the shared serial SFU on its first active lane.
                        // The scheduler keeps issuing other warps. If the SFU is busy with
                        // another warp, this warp waits (stays W_RUN).
                        if (sfu_state == SFU_IDLE) begin
                            sfu_w         <= issue_w;
                            sfu_mask      <= cur_mask;
                            sfu_rd        <= rd;
                            sfu_resume_pc <= fallthru;
                            sfu_is_sqrt_r <= is_fsqrt;
                            sfu_fmt_r     <= fp_fmt;
                            for (int l = 0; l < NL; l++) begin
                                sfu_opa[l] <= frv1[l];
                                sfu_opb[l] <= frv2[l];
                            end
                            sfu_lane       <= sfu_first_lane;
                            sfu_core_start <= 1'b1;        // launch the first lane next cycle
                            wstate[issue_w] <= W_SFU;
                            sfu_state      <= SFU_RUN;
                        end
                        // else: SFU busy → warp waits.
                    end else if (is_mem) begin
                        if (!mem_busy) begin
                            // Hand the coalesced access to the background engine.
                            // Only the currently-active lanes (cur_mask) participate.
                            mem_busy     <= 1'b1;
                            mem_w        <= issue_w;
                            mem_pending  <= cur_mask;
                            mem_is_store <= is_store;
                            mem_is_scratch <= issue_is_scratch;
                            mem_is_fp    <= is_fp_mem;       // M14.0: flw/fsw
                            mem_funct3   <= funct3;
                            mem_rd       <= rd;
                            mem_next_pc  <= fallthru;        // mem is not control flow
                            for (int l = 0; l < NL; l++) begin
                                mem_addr_lane[l]  <= addr[l];
                                // fsw stores an f-register; integer stores an x-register.
                                mem_sdata_lane[l] <= is_store_fp ? frv2[l] : rv2[l];
                            end
                            wstate[issue_w] <= W_MEM;
                        end
                        // else: data port busy → warp waits (stays W_RUN).
                    end else if (!squash_wb) begin
                        // Compute commit. The register writeback is performed by the
                        // central VRF write arbiter below (a memory writeback this
                        // cycle would have set squash_wb and deferred us instead).
                        // Control flow / next-PC for the TOS frame.
                        unique case (opcode)
                            OP_BRANCH: begin
                                if (taken_mask == cur_mask) begin
                                    stk_npc[issue_w][cur_sp] <= br_target;     // uniform taken
                                end else if (taken_mask == '0) begin
                                    stk_npc[issue_w][cur_sp] <= fallthru;       // uniform not-taken
                                end else begin
                                    // Divergent: push a "continue" frame; the rest
                                    // of the lanes wait, reconverging at RPC.
                                    dbg_divergences <= dbg_divergences + 32'd1;
                                    stk_mask[issue_w][cur_sp]      <= cur_mask;  // union @ join
                                    if (br_target > cur_pc) begin
                                        // forward `if`: join = target; run the
                                        // fall-through (not-taken) lanes first.
                                        stk_npc [issue_w][cur_sp]       <= br_target;
                                        stk_npc [issue_w][cur_sp + 1'b1] <= fallthru;
                                        stk_mask[issue_w][cur_sp + 1'b1] <= ntaken_mask;
                                        stk_rpc [issue_w][cur_sp + 1'b1] <= br_target;
                                    end else begin
                                        // backward loop: join = fall-through (exit);
                                        // run the taken (still-looping) lanes.
                                        stk_npc [issue_w][cur_sp]       <= fallthru;
                                        stk_npc [issue_w][cur_sp + 1'b1] <= br_target;
                                        stk_mask[issue_w][cur_sp + 1'b1] <= taken_mask;
                                        stk_rpc [issue_w][cur_sp + 1'b1] <= fallthru;
                                    end
                                    sp[issue_w] <= cur_sp + 1'b1;
                                end
                            end
                            OP_JAL:  stk_npc[issue_w][cur_sp] <= jal_target;
                            OP_JALR: stk_npc[issue_w][cur_sp] <= jalr_target;
                            default: stk_npc[issue_w][cur_sp] <= fallthru;
                        endcase
                    end
                    rr_ptr <= issue_w + 1'b1;     // round-robin, advance past it
                end

                // 3) Memory engine step.
                if (mem_busy) begin
                    if (mem_is_scratch) begin
                        // On-chip scratchpad (M9): single-port distributed RAM, so the
                        // engine serves ONE lane — the lowest still-pending lane `lead`
                        // — per cycle. The store data write commits in the scratch RAM
                        // block (sc_we); scratch LOADS write the VRF via the central
                        // arbiter (lead lane only). Here we just retire lead and finish
                        // when the warp's last scratch lane drains.
                        logic [NL-1:0] lead_oh;
                        lead_oh = '0;
                        lead_oh[lead] = 1'b1;
                        dbg_scratch_txns <= dbg_scratch_txns + 32'd1;
                        if ((mem_pending & ~lead_oh) == '0) begin
                            mem_busy                  <= 1'b0;
                            stk_npc[mem_w][sp[mem_w]] <= mem_next_pc;
                            wstate[mem_w]             <= W_RUN;
                        end else begin
                            mem_pending <= mem_pending & ~lead_oh;
                        end
                    end else begin
                        // Global memory: one coalesced line transaction / cycle. The
                        // load result is written to the VRF by the central arbiter.
                        dbg_mem_txns <= dbg_mem_txns + 32'd1;

                        if ((mem_pending & ~grp) == '0) begin
                            mem_busy                  <= 1'b0;
                            stk_npc[mem_w][sp[mem_w]] <= mem_next_pc;  // resume after mem
                            wstate[mem_w]             <= W_RUN;
                        end else begin
                            mem_pending <= mem_pending & ~grp;
                        end
                    end
                end

                // 3c) SFU (divide/sqrt) engine step. RUN: the single shared core works
                //     one active lane at a time; on each core `done` latch that lane's
                //     result and, if another active lane remains, advance and relaunch
                //     (the core is back in S_IDLE the cycle it pulses done, so the restart
                //     costs only a 1-cycle bubble); otherwise go to writeback. WB: drive
                //     the held results onto the f-file (the arbiter gives the memory
                //     engine priority, so this may wait a cycle), then resume the warp.
                unique case (sfu_state)
                    SFU_IDLE: ;   // armed in the issue step (captures operands, enters RUN)
                    SFU_RUN: begin
                        sfu_core_start <= 1'b0;            // 1-cycle launch pulse default-low
                        if (sfu_core_done) begin
                            sfu_hold[sfu_lane] <= sfu_core_res;
                            if (sfu_more) begin
                                sfu_lane       <= sfu_next_lane;
                                sfu_core_start <= 1'b1;   // launch the next active lane
                            end else begin
                                sfu_state <= SFU_WB;
                            end
                        end
                    end
                    SFU_WB:   if (sfu_wb_fire) begin
                        stk_npc[sfu_w][sp[sfu_w]] <= sfu_resume_pc;
                        wstate[sfu_w]             <= W_RUN;
                        sfu_state                 <= SFU_IDLE;
                    end
                    default: sfu_state <= SFU_IDLE;
                endcase

                // 3d) FPC (pipelined FP-compute) engine step. WAIT: count down the 5-stage
                //     FPU latency (operands held constant in q_frv*/q_rv1 stream one result
                //     through), and when the result is valid capture it. WB: drive it onto
                //     the f-file/VRF when the port is free (yields to the memory + SFU
                //     engines), then resume the parked warp after the FP op.
                unique case (fpc_state)
                    FPC_IDLE: ;   // launched in the issue step (sets FPC_WAIT)
                    FPC_WAIT: begin
                        if (fpc_cnt != 4'd0) fpc_cnt <= fpc_cnt - 4'd1;
                        else begin
                            for (int l = 0; l < NL; l++) fpc_data[l] <= fpu_res[l];
                            fpc_state <= FPC_WB;
                        end
                    end
                    FPC_WB: if (fpc_wb_fire) begin
                        stk_npc[fpc_w][sp[fpc_w]] <= fpc_resume_pc;
                        wstate[fpc_w]             <= W_RUN;
                        fpc_state                 <= FPC_IDLE;
                    end
                    default: fpc_state <= FPC_IDLE;
                endcase

                // 3e) MUL (pipelined integer multiply) engine step. RUN: count down the
                //     DSP-tree latency (operands held constant in q_mul_a/b stream one
                //     product through), then capture the per-lane results. WB: drive them
                //     onto the integer VRF when the port is free (yields to the memory +
                //     FPC engines), then resume the parked warp after the mul.
                unique case (mul_state)
                    MUL_IDLE: ;   // armed in the issue step (sets MUL_RUN, captures operands)
                    MUL_RUN: begin
                        if (mul_cnt != 4'd0) mul_cnt <= mul_cnt - 4'd1;
                        else begin
                            for (int l = 0; l < NL; l++) mul_data[l] <= mul_res[l];
                            mul_state <= MUL_WB;
                        end
                    end
                    MUL_WB: if (mul_wb_fire) begin
                        stk_npc[mul_w][sp[mul_w]] <= mul_resume_pc;
                        wstate[mul_w]             <= W_RUN;
                        mul_state                 <= MUL_IDLE;
                    end
                    default: mul_state <= MUL_IDLE;
                endcase

                // 3b) Mark written registers valid. The VRF data write itself happens
                //     in the per-lane distributed-RAM banks (see the generate block);
                //     here we only record that the register is no longer at its seed.
                //     Kept as two single-statement loops (see BLKLOOPINIT note above).
                for (int l = 0; l < NL; l++)
                    if (v_we[l])  reg_written [v_ww[l]][l][v_wr[l]] <= 1'b1;
                for (int l = 0; l < NL; l++)
                    if (fv_we[l]) freg_written[fv_ww[l]][l][fv_wr[l]] <= 1'b1;

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
