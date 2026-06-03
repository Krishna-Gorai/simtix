// =============================================================================
// tb_soc_top.sv  -  M1.3 full-system regression: host CPU launches the kernel
//
// The host CPU runs a hand-assembled RV32I *driver* program from its own
// instruction ROM. The driver writes the command block to the MMIO aperture
// (kernel_pc / base_a / base_b / base_c / N), sets GO, then polls STATUS.DONE
// in a loop and halts. The vector-add kernel and the input arrays A, B live in
// the accelerator's shared memory (preloaded here, as a loader/DMA would).
//
// Success criterion: after the CPU has driven the launch, the accelerator has
// written C[tid] = A[tid] + B[tid] back into shared memory.
//
// MMIO base = 0x8000_0000.  Shared-memory layout (byte addresses):
//   kernel  @ 0x200   A @ 0x300   B @ 0x340   C @ 0x380
// =============================================================================
`timescale 1ns/1ps

module tb_soc_top
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */  // only addr[*:2] indexes the models
    logic        clk = 0;
    logic        rst;

    logic [31:0] cpu_imem_addr, cpu_imem_data;
    logic [31:0] accel_imem_addr, accel_imem_data;
    logic [31:0] accel_dmem_addr, accel_dmem_wdata, accel_dmem_rdata;
    logic        accel_dmem_we;
    logic [3:0]  accel_dmem_be;

    int unsigned errors = 0;

    soc_top dut (
        .clk(clk), .rst(rst), .reset_vector(32'h0000_0000),
        .cpu_imem_addr(cpu_imem_addr), .cpu_imem_data(cpu_imem_data),
        .accel_imem_addr(accel_imem_addr), .accel_imem_data(accel_imem_data),
        .accel_dmem_addr(accel_dmem_addr), .accel_dmem_wdata(accel_dmem_wdata),
        .accel_dmem_we(accel_dmem_we), .accel_dmem_be(accel_dmem_be),
        .accel_dmem_rdata(accel_dmem_rdata)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Host CPU instruction ROM (the driver program) ─────────────────────────────
    // x1 = MMIO base; program the command block, set GO, poll DONE, halt.
    logic [31:0] drom [0:255];
    initial begin
        for (int k = 0; k < 256; k++) drom[k] = 32'h00000013;  // nop fill
        drom[0]  = 32'h800000b7;   // lui  x1, 0x80000     x1 = 0x80000000 (MMIO base)
        drom[1]  = 32'h20000113;   // addi x2, x0, 0x200   kernel_pc
        drom[2]  = 32'h0020a023;   // sw   x2, 0x00(x1)     REG_KERNEL_PC
        drom[3]  = 32'h30000113;   // addi x2, x0, 0x300   base_a
        drom[4]  = 32'h0020a223;   // sw   x2, 0x04(x1)     REG_BASE_A
        drom[5]  = 32'h34000113;   // addi x2, x0, 0x340   base_b
        drom[6]  = 32'h0020a423;   // sw   x2, 0x08(x1)     REG_BASE_B
        drom[7]  = 32'h38000113;   // addi x2, x0, 0x380   base_c
        drom[8]  = 32'h0020a623;   // sw   x2, 0x0C(x1)     REG_BASE_C
        drom[9]  = 32'h00800113;   // addi x2, x0, 8       N = 8
        drom[10] = 32'h0020a823;   // sw   x2, 0x10(x1)     REG_N
        drom[11] = 32'h00100113;   // addi x2, x0, 1       GO
        drom[12] = 32'h0020aa23;   // sw   x2, 0x14(x1)     REG_CTRL (launch)
        drom[13] = 32'h0180a383;   // lw   x7, 0x18(x1)     REG_STATUS   <- poll
        drom[14] = 32'h0013f393;   // andi x7, x7, 1        isolate DONE
        drom[15] = 32'hfe038ce3;   // beq  x7, x0, -8       loop while !DONE
        drom[16] = 32'h00000063;   // beq  x0, x0, 0        halt (self-loop)
    end
    assign cpu_imem_data = drom[cpu_imem_addr[9:2]];

    // ── Accelerator shared memory (kernel code + data arrays) ─────────────────────
    localparam int MEM_WORDS = 1024;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign accel_imem_data  = mem[accel_imem_addr[13:2]];
    assign accel_dmem_rdata = mem[accel_dmem_addr[13:2]];
    always @(posedge clk) begin
        if (accel_dmem_we) begin
            if (accel_dmem_be[0]) mem[accel_dmem_addr[13:2]][7:0]   <= accel_dmem_wdata[7:0];
            if (accel_dmem_be[1]) mem[accel_dmem_addr[13:2]][15:8]  <= accel_dmem_wdata[15:8];
            if (accel_dmem_be[2]) mem[accel_dmem_addr[13:2]][23:16] <= accel_dmem_wdata[23:16];
            if (accel_dmem_be[3]) mem[accel_dmem_addr[13:2]][31:24] <= accel_dmem_wdata[31:24];
        end
    end

    // Shared-memory map (word indices).
    localparam int KW = 32'h200 >> 2;   // kernel  @ word 0x80
    localparam int AW = 32'h300 >> 2;   // A       @ word 0xC0
    localparam int BW = 32'h340 >> 2;   // B       @ word 0xD0
    localparam int CW = 32'h380 >> 2;   // C       @ word 0xE0
    localparam int N  = 8;

    int          i;
    int unsigned guard;

    initial begin
        // vector-add kernel (a0=tid, a1=&A, a2=&B, a3=&C, a4=N)
        mem[KW+0] = 32'h00251293;   // slli t0, a0, 2
        mem[KW+1] = 32'h00558333;   // add  t1, a1, t0
        mem[KW+2] = 32'h00032383;   // lw   t2, 0(t1)
        mem[KW+3] = 32'h00560e33;   // add  t3, a2, t0
        mem[KW+4] = 32'h000e2e83;   // lw   t4, 0(t3)
        mem[KW+5] = 32'h01d383b3;   // add  t2, t2, t4
        mem[KW+6] = 32'h00568f33;   // add  t5, a3, t0
        mem[KW+7] = 32'h007f2023;   // sw   t2, 0(t5)
        mem[KW+8] = 32'h00000073;   // ecall

        for (i = 0; i < N; i++) begin
            mem[AW + i] = 32'd10  + i;        // A[i] = 10 + i
            mem[BW + i] = 32'd100 + 2*i;      // B[i] = 100 + 2i
            mem[CW + i] = 32'hdead_beef;      // C[i] = poison
        end

        rst = 1; repeat (5) @(posedge clk); rst = 0;

        $display("[tb_soc_top] host CPU driving an %0d-thread vector-add launch", N);

        // Wait for the CPU-driven kernel to finish (C fully written), with a guard.
        guard = 0;
        while ((mem[CW + N - 1] === 32'hdead_beef) && (guard < 20000)) begin
            @(posedge clk); guard++;
        end
        repeat (4) @(posedge clk);   // settle the final store

        if (guard >= 20000)
            $display("  [WARN] guard expired before C was written");

        for (i = 0; i < N; i++) begin
            automatic logic [31:0] got = mem[CW + i];
            automatic logic [31:0] exp = (32'd10 + i) + (32'd100 + 2*i);  // 110 + 3i
            if (got !== exp) begin
                $display("  [FAIL] C[%0d] got=%0d exp=%0d", i, got, exp);
                errors++;
            end else begin
                $display("  [ ok ] C[%0d] = %0d", i, got);
            end
        end

        if (errors == 0) begin
            $display("[tb_soc_top] PASS (CPU launched accelerator end-to-end in ~%0d cycles)", guard);
            $finish;
        end else begin
            $display("[tb_soc_top] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #2000000;
        $display("[tb_soc_top] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_soc_top
