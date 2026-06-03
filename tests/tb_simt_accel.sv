// =============================================================================
// tb_simt_accel.sv  -  M1.2 end-to-end integration regression
//
// Stands in for the host system: owns the shared memory (preloaded with the
// vector-add kernel and the input arrays A, B), drives the MMIO command port
// (kernel_pc/base ptrs/N + GO), polls STATUS.DONE, then checks that the
// accelerator wrote the correct C[tid] = A[tid] + B[tid] back into memory.
// Self-checking: prints PASS/FAIL and exits non-zero so CI catches regressions.
//
// Kernel (a0=tid, a1=&A, a2=&B, a3=&C, a4=N):
//   slli t0, a0, 2       # t0 = tid*4 (byte offset)
//   add  t1, a1, t0      # &A[tid]
//   lw   t2, 0(t1)       # A[tid]
//   add  t3, a2, t0      # &B[tid]
//   lw   t4, 0(t3)       # B[tid]
//   add  t2, t2, t4      # A[tid] + B[tid]
//   add  t5, a3, t0      # &C[tid]
//   sw   t2, 0(t5)       # C[tid] = sum
//   ecall                # retire
// =============================================================================
`timescale 1ns/1ps

module tb_simt_accel
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */  // only addr[13:2] indexes the model memory
    logic        clk = 0;
    logic        rst;
    logic        sel, we;
    logic [7:0]  offset;
    logic [31:0] wdata, rdata;

    // Accelerator memory-master wires (data port is line-wide).
    logic [31:0]          imem_addr, imem_data;
    logic [31:0]          dmem_addr;
    logic [LINE_BITS-1:0] dmem_wdata, dmem_rdata;
    logic                 dmem_we;
    logic [LINE_BE-1:0]   dmem_be;

    int unsigned errors = 0;

    simt_accel dut (
        .clk(clk), .rst(rst),
        .sel(sel), .we(we), .offset(offset), .wdata(wdata), .rdata(rdata),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_rdata(dmem_rdata)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;   // 100 MHz (testbench clock generator)
    /* verilator lint_on BLKSEQ */

    // ── Shared memory (4096 words) ────────────────────────────────────────────────
    // Both the instruction fetch and data ports read it asynchronously; the data
    // port writes it synchronously under byte-enables.
    localparam int MEM_WORDS = 4096;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign imem_data = mem[imem_addr[13:2]];

    // The data port drives a line-aligned byte address; lbase is its word index.
    logic [31:0] lbase;
    assign lbase = {20'b0, dmem_addr[13:5], 3'b000};

    always_comb
        for (int w = 0; w < LINE_WORDS; w++)
            dmem_rdata[w*32 +: 32] = mem[lbase + w];

    always @(posedge clk) begin
        if (dmem_we)
            for (int w = 0; w < LINE_WORDS; w++) begin
                logic [31:0] cur;
                cur = mem[lbase + w];
                for (int b = 0; b < 4; b++)
                    if (dmem_be[w*4 + b]) cur[b*8 +: 8] = dmem_wdata[w*32 + b*8 +: 8];
                mem[lbase + w] <= cur;
            end
    end

    // ── Memory map for this test ──────────────────────────────────────────────────
    localparam logic [31:0] KPC    = 32'h0000_0000;   // kernel entry
    localparam logic [31:0] BASE_A = 32'h0000_0100;
    localparam logic [31:0] BASE_B = 32'h0000_0140;
    localparam logic [31:0] BASE_C = 32'h0000_0180;
    localparam int          N      = 16;   // 2 warps of WARP_SIZE=8 (multi-warp dispatch)

    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {20'b0, byte_addr[13:2]};
    endfunction

    // ── Bus helpers ──────────────────────────────────────────────────────────────
    task automatic mmio_write(input logic [7:0] off, input logic [31:0] data);
        @(posedge clk);
        sel = 1; we = 1; offset = off; wdata = data;
        @(posedge clk);
        sel = 0; we = 0;
    endtask

    task automatic mmio_read(input logic [7:0] off, output logic [31:0] data);
        @(posedge clk);
        sel = 1; we = 0; offset = off;
        #1 data = rdata;          // combinational read
        @(posedge clk);
        sel = 0;
    endtask

    task automatic check(input string name, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("  [FAIL] %-12s got=%0d exp=%0d", name, got, exp);
            errors++;
        end else begin
            $display("  [ ok ] %-12s = %0d", name, got);
        end
    endtask

    // ── Stimulus ─────────────────────────────────────────────────────────────────
    logic [31:0] rd;
    int unsigned guard;
    int          i;

    initial begin
        sel = 0; we = 0; offset = 0; wdata = 0;

        // Preload the kernel.
        mem[0] = 32'h00251293;   // slli t0, a0, 2
        mem[1] = 32'h00558333;   // add  t1, a1, t0
        mem[2] = 32'h00032383;   // lw   t2, 0(t1)
        mem[3] = 32'h00560e33;   // add  t3, a2, t0
        mem[4] = 32'h000e2e83;   // lw   t4, 0(t3)
        mem[5] = 32'h01d383b3;   // add  t2, t2, t4
        mem[6] = 32'h00568f33;   // add  t5, a3, t0
        mem[7] = 32'h007f2023;   // sw   t2, 0(t5)
        mem[8] = 32'h00000073;   // ecall

        // Preload input arrays; clear the output array.
        for (i = 0; i < N; i++) begin
            mem[widx(BASE_A) + i] = 32'd10  + i;        // A[i] = 10 + i
            mem[widx(BASE_B) + i] = 32'd100 + 2*i;      // B[i] = 100 + 2i
            mem[widx(BASE_C) + i] = 32'hdead_beef;      // C[i] = poison
        end

        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("[tb_simt_accel] launch %0d-thread vector-add kernel", N);
        mmio_write(REG_KERNEL_PC, KPC);
        mmio_write(REG_BASE_A,    BASE_A);
        mmio_write(REG_BASE_B,    BASE_B);
        mmio_write(REG_BASE_C,    BASE_C);
        mmio_write(REG_N,         N);

        // command read-back
        mmio_read(REG_N, rd);          check("N",      rd, N);
        mmio_read(REG_BASE_A, rd);     check("BASE_A", rd, BASE_A);

        // launch
        mmio_write(REG_CTRL, 32'h1);

        // should be BUSY shortly after GO
        mmio_read(REG_STATUS, rd);
        check("BUSY", {31'b0, rd[STATUS_BUSY_BIT]}, 32'd1);

        // poll DONE (with a timeout guard)
        guard = 0;
        do begin
            mmio_read(REG_STATUS, rd);
            guard++;
        end while (rd[STATUS_DONE_BIT] !== 1'b1 && guard < 2000);
        check("DONE", {31'b0, rd[STATUS_DONE_BIT]}, 32'd1);

        mmio_read(REG_CYCLES, rd);
        if (rd == 0) begin
            $display("  [FAIL] CYCLES reported 0"); errors++;
        end else begin
            $display("  [ ok ] CYCLES = %0d", rd);
        end

        // verify results in memory
        for (i = 0; i < N; i++) begin
            automatic logic [31:0] got = mem[widx(BASE_C) + i];
            automatic logic [31:0] exp = (32'd10 + i) + (32'd100 + 2*i);  // 110 + 3i
            if (got !== exp) begin
                $display("  [FAIL] C[%0d] got=%0d exp=%0d", i, got, exp);
                errors++;
            end else begin
                $display("  [ ok ] C[%0d] = %0d", i, got);
            end
        end

        if (errors == 0) begin
            $display("[tb_simt_accel] PASS");
            $finish;
        end else begin
            $display("[tb_simt_accel] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    // global watchdog
    initial begin
        #500000;
        $display("[tb_simt_accel] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_simt_accel
