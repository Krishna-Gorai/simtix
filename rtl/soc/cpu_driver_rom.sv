// =============================================================================
// cpu_driver_rom.sv  -  M10 host-CPU driver program (instruction ROM)
//
// The program the host RISC-V core runs on the full chip. It drives the whole
// offload handshake and then consumes the result, exercising the complete
// CPU <-> MMIO <-> accelerator <-> shared-memory loop:
//
//   1. program the accelerator command block over MMIO (0x8000_0000):
//        kernel_pc=0x200, base_a=0x300, base_b=0x340, base_c=0x380, N=8
//   2. set GO, then poll STATUS.DONE
//   3. read C[0..7] back from shared memory and sum them
//   4. store the sum to the chip result register (0x9000_0000), which latches
//      `result` and raises `done` at the chip boundary
//   5. halt (self-loop)
//
// Expected result: sum_i (A[i]+B[i]) = sum_i (110 + 3i), i=0..7 = 964.
//
// Combinational case ROM (Vivado infers LUT/distributed ROM; no init file). Word
// address = addr[9:2]. Encodings were hand-assembled and verified bit-by-bit.
// =============================================================================
`timescale 1ns/1ps

module cpu_driver_rom (
    input  wire [31:0] addr,
    output reg  [31:0] instr
);
    always @(*) begin
        case (addr[9:2])
            // ── program the command block over MMIO (x1 = 0x8000_0000) ──────────
            8'd0 : instr = 32'h800000b7;   // lui  x1, 0x80000
            8'd1 : instr = 32'h20000113;   // addi x2, x0, 0x200    kernel_pc
            8'd2 : instr = 32'h0020a023;   // sw   x2, 0x00(x1)
            8'd3 : instr = 32'h30000113;   // addi x2, x0, 0x300    base_a
            8'd4 : instr = 32'h0020a223;   // sw   x2, 0x04(x1)
            8'd5 : instr = 32'h34000113;   // addi x2, x0, 0x340    base_b
            8'd6 : instr = 32'h0020a423;   // sw   x2, 0x08(x1)
            8'd7 : instr = 32'h38000113;   // addi x2, x0, 0x380    base_c
            8'd8 : instr = 32'h0020a623;   // sw   x2, 0x0C(x1)
            8'd9 : instr = 32'h00800113;   // addi x2, x0, 8        N = 8
            8'd10: instr = 32'h0020a823;   // sw   x2, 0x10(x1)
            8'd11: instr = 32'h00100113;   // addi x2, x0, 1        GO
            8'd12: instr = 32'h0020aa23;   // sw   x2, 0x14(x1)     launch

            // ── poll STATUS.DONE ────────────────────────────────────────────────
            8'd13: instr = 32'h0180a383;   // lw   x7, 0x18(x1)     <- poll
            8'd14: instr = 32'h0013f393;   // andi x7, x7, 1
            8'd15: instr = 32'hfe038ce3;   // beq  x7, x0, -8       loop while !DONE

            // ── read C[0..7] back from shared memory and sum ────────────────────
            8'd16: instr = 32'h38000293;   // addi x5,  x0, 0x380   &C
            8'd17: instr = 32'h00000313;   // addi x6,  x0, 0       acc = 0
            8'd18: instr = 32'h00000e13;   // addi x28, x0, 0       i   = 0
            8'd19: instr = 32'h00800e93;   // addi x29, x0, 8       N   = 8
            8'd20: instr = 32'h002e1f13;   // slli x30, x28, 2      <- loop  (i*4)
            8'd21: instr = 32'h01e28fb3;   // add  x31, x5, x30     &C[i]
            8'd22: instr = 32'h000fa203;   // lw   x4, 0(x31)       C[i]
            8'd23: instr = 32'h00430333;   // add  x6, x6, x4       acc += C[i]
            8'd24: instr = 32'h001e0e13;   // addi x28, x28, 1      i++
            8'd25: instr = 32'hffde16e3;   // bne  x28, x29, -20    loop

            // ── publish the result and halt ─────────────────────────────────────
            8'd26: instr = 32'h900004b7;   // lui  x9, 0x90000      result reg
            8'd27: instr = 32'h0064a023;   // sw   x6, 0(x9)        result=acc, done=1
            8'd28: instr = 32'h00000063;   // beq  x0, x0, 0        halt (self-loop)

            default: instr = 32'h00000013; // nop
        endcase
    end
endmodule
