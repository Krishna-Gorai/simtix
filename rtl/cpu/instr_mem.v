// =============================================================================
// instr_mem.v  -  Instruction ROM  (Vivado-safe, case-statement ROM inference)
//  Synthesises to Distributed RAM / LUT ROM on Xilinx.
//  No initial block needed - values are hardcoded in the case statement.
// =============================================================================
`timescale 1ns/1ps
(* dont_touch = "true" *)
module instr_mem (
    input  wire [31:0] addr,
    output reg  [31:0] instr
);

    // =========================================================================
    // Pure combinational ROM via case statement
    // Vivado infers this as LUT-based distributed ROM - guaranteed synthesis.
    // Word address = addr[9:2]  (covers byte addresses 0x000..0x3FC)
    // =========================================================================
    always @(*) begin
        case (addr[9:2])

            // -----------------------------------------------------------------
            // T1 - Basic R/I-type ALU          base = 0x000  (word 0)
            // -----------------------------------------------------------------
            8'd0  : instr = 32'h00A00093; // addi x1, x0, 10
            8'd1  : instr = 32'h00300113; // addi x2, x0, 3
            8'd2  : instr = 32'h002081B3; // add  x3, x1, x2
            8'd3  : instr = 32'h40208233; // sub  x4, x1, x2
            8'd4  : instr = 32'h0020F2B3; // and  x5, x1, x2
            8'd5  : instr = 32'h0020E333; // or   x6, x1, x2
            8'd6  : instr = 32'h0020C3B3; // xor  x7, x1, x2
            8'd7  : instr = 32'h00112433; // slt  x8, x2, x1
            8'd8  : instr = 32'h001134B3; // sltu x9, x2, x1
            8'd9  : instr = 32'h00000063; // beq  x0, x0, 0   <- halt (self-loop)

            // -----------------------------------------------------------------
            // T2 - Back-to-back forwarding     base = 0x040  (word 16)
            // -----------------------------------------------------------------
            8'd16 : instr = 32'h00500093; // addi x1, x0, 5
            8'd17 : instr = 32'h00308113; // addi x2, x1, 3
            8'd18 : instr = 32'h001101B3; // add  x3, x2, x1
            8'd19 : instr = 32'h00218233; // add  x4, x3, x2
            8'd20 : instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T3 - Load-use stall              base = 0x080  (word 32)
            // -----------------------------------------------------------------
            8'd32 : instr = 32'h06400093; // addi x1, x0, 100
            8'd33 : instr = 32'h00102023; // sw   x1, 0(x0)
            8'd34 : instr = 32'h00002103; // lw   x2, 0(x0)
            8'd35 : instr = 32'h00110193; // addi x3, x2, 1
            8'd36 : instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T4 - SW/LW round-trip            base = 0x0C0  (word 48)
            // -----------------------------------------------------------------
            8'd48 : instr = 32'h0AB00093; // addi x1, x0, 0xAB
            8'd49 : instr = 32'h00102223; // sw   x1, 4(x0)
            8'd50 : instr = 32'h00402103; // lw   x2, 4(x0)
            8'd51 : instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T5 - BEQ taken                   base = 0x100  (word 64)
            // -----------------------------------------------------------------
            8'd64 : instr = 32'h00500093; // addi x1, x0, 5
            8'd65 : instr = 32'h00500113; // addi x2, x0, 5
            8'd66 : instr = 32'h00208463; // beq  x1, x2, +8
            8'd67 : instr = 32'h06300193; // addi x3, x0, 99  <- skipped
            8'd68 : instr = 32'h02A00213; // addi x4, x0, 42
            8'd69 : instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T6 - BNE taken                   base = 0x140  (word 80)
            // -----------------------------------------------------------------
            8'd80 : instr = 32'h00500093; // addi x1, x0, 5
            8'd81 : instr = 32'h00600113; // addi x2, x0, 6
            8'd82 : instr = 32'h00209463; // bne  x1, x2, +8
            8'd83 : instr = 32'h06300193; // addi x3, x0, 99  <- skipped
            8'd84 : instr = 32'h04D00213; // addi x4, x0, 77
            8'd85 : instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T7 - JAL                         base = 0x180  (word 96)
            // -----------------------------------------------------------------
            8'd96 : instr = 32'h008000EF; // jal  x1, +8
            8'd97 : instr = 32'h06300113; // addi x2, x0, 99  <- skipped
            8'd98 : instr = 32'h03700193; // addi x3, x0, 55
            8'd99 : instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T8 - LUI                         base = 0x1C0  (word 112)
            // -----------------------------------------------------------------
            8'd112: instr = 32'hABCDE0B7; // lui  x1, 0xABCDE
            8'd113: instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T9 - AUIPC                       base = 0x200  (word 128)
            // -----------------------------------------------------------------
            8'd128: instr = 32'h00010097; // auipc x1, 0x10
            8'd129: instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T10 - Sum loop  1+2+...+10 = 55  base = 0x240  (word 144)
            // -----------------------------------------------------------------
            8'd144: instr = 32'h00000093; // addi x1, x0,  0
            8'd145: instr = 32'h00100113; // addi x2, x0,  1
            8'd146: instr = 32'h00B00193; // addi x3, x0, 11
            8'd147: instr = 32'h002080B3; // add  x1, x1, x2   <- loop
            8'd148: instr = 32'h00110113; // addi x2, x2,  1
            8'd149: instr = 32'hFE311CE3; // bne  x2, x3, -8
            8'd150: instr = 32'h00102023; // sw   x1,  0(x0)
            8'd151: instr = 32'h00000063; // halt

            // -----------------------------------------------------------------
            // T11 - FULL ISA SHOWCASE          base = 0x300  (word 192)
            // Exercises every supported instruction once; used by
            // riscv_trace_tb.v.  Auto-generated by tools/assemble_showcase.py.
            // Expected final registers are listed in that testbench.
            // -----------------------------------------------------------------
            8'd192: instr = 32'h123450B7; // lui   x1, 0x12345
            8'd193: instr = 32'h12300113; // addi  x2, x0, 0x123
            8'd194: instr = 32'hFFB00193; // addi  x3, x0, -5
            8'd195: instr = 32'h0F016213; // ori   x4, x2, 0x0F0
            8'd196: instr = 32'h0FF17293; // andi  x5, x2, 0x0FF
            8'd197: instr = 32'h0FF14313; // xori  x6, x2, 0x0FF
            8'd198: instr = 32'h0001A393; // slti  x7, x3, 0
            8'd199: instr = 32'h0011B413; // sltiu x8, x3, 1
            8'd200: instr = 32'h00411493; // slli  x9, x2, 4
            8'd201: instr = 32'h0080D513; // srli  x10, x1, 8
            8'd202: instr = 32'h4011D593; // srai  x11, x3, 1
            8'd203: instr = 32'h00310633; // add   x12, x2, x3
            8'd204: instr = 32'h403106B3; // sub   x13, x2, x3
            8'd205: instr = 32'h0040F733; // and   x14, x1, x4
            8'd206: instr = 32'h009167B3; // or    x15, x2, x9
            8'd207: instr = 32'h00214833; // xor   x16, x2, x2
            8'd208: instr = 32'h002118B3; // sll   x17, x2, x2
            8'd209: instr = 32'h0021A933; // slt   x18, x3, x2
            8'd210: instr = 32'h003139B3; // sltu  x19, x2, x3
            8'd211: instr = 32'h0020DA33; // srl   x20, x1, x2
            8'd212: instr = 32'h4021DAB3; // sra   x21, x3, x2
            8'd213: instr = 32'h00102023; // sw    x1, 0(x0)
            8'd214: instr = 32'h00002B03; // lw    x22, 0(x0)
            8'd215: instr = 32'h00201423; // sh    x2, 8(x0)
            8'd216: instr = 32'h00801B83; // lh    x23, 8(x0)
            8'd217: instr = 32'h00805C03; // lhu   x24, 8(x0)
            8'd218: instr = 32'h00300823; // sb    x3, 16(x0)
            8'd219: instr = 32'h01000C83; // lb    x25, 16(x0)
            8'd220: instr = 32'h01004D03; // lbu   x26, 16(x0)
            8'd221: instr = 32'hFFF00D93; // addi  x27, x0, -1
            8'd222: instr = 32'h01B00A23; // sb    x27, 20(x0)
            8'd223: instr = 32'h01400E03; // lb    x28, 20(x0)
            8'd224: instr = 32'h01404E83; // lbu   x29, 20(x0)
            8'd225: instr = 32'h00000F13; // addi  x30, x0, 0
            8'd226: instr = 32'h00210463; // beq   x2, x2, L1
            8'd227: instr = 32'h064F0F13; // addi  x30, x30, 100  (skipped)
            8'd228: instr = 32'h001F6F13; // L1: ori x30, x30, 0x001
            8'd229: instr = 32'h00311463; // bne   x2, x3, L2
            8'd230: instr = 32'h064F0F13; // addi  x30, x30, 100  (skipped)
            8'd231: instr = 32'h002F6F13; // L2: ori x30, x30, 0x002
            8'd232: instr = 32'h0021C463; // blt   x3, x2, L3
            8'd233: instr = 32'h064F0F13; // addi  x30, x30, 100  (skipped)
            8'd234: instr = 32'h004F6F13; // L3: ori x30, x30, 0x004
            8'd235: instr = 32'h00315463; // bge   x2, x3, L4
            8'd236: instr = 32'h064F0F13; // addi  x30, x30, 100  (skipped)
            8'd237: instr = 32'h008F6F13; // L4: ori x30, x30, 0x008
            8'd238: instr = 32'h00316463; // bltu  x2, x3, L5
            8'd239: instr = 32'h064F0F13; // addi  x30, x30, 100  (skipped)
            8'd240: instr = 32'h010F6F13; // L5: ori x30, x30, 0x010
            8'd241: instr = 32'h0021F463; // bgeu  x3, x2, L6
            8'd242: instr = 32'h064F0F13; // addi  x30, x30, 100  (skipped)
            8'd243: instr = 32'h020F6F13; // L6: ori x30, x30, 0x020
            8'd244: instr = 32'h00310463; // beq   x2, x3, L7   (NOT taken)
            8'd245: instr = 32'h040F6F13; // ori   x30, x30, 0x040  (fall-through)
            8'd246: instr = 32'h00C00FEF; // L7: jal x31, FUNC
            8'd247: instr = 32'h080F6F13; // ori   x30, x30, 0x080  (after return)
            8'd248: instr = 32'h00000663; // beq   x0, x0, END
            8'd249: instr = 32'h100F6F13; // FUNC: ori x30, x30, 0x100
            8'd250: instr = 32'h000F8067; // jalr  x0, x31, 0   (return)
            8'd251: instr = 32'h00000063; // END: halt (self-loop)

            // All other addresses: NOP
            default: instr = 32'h00000013;
        endcase
    end

endmodule