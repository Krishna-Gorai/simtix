// =============================================================================
// tb_lane.sv  -  unit test for a single SIMT lane (M1.1 ALU + M1.2 LSU)
//
// Hand-assembled RV32I kernels in an async-read ROM are run for several thread
// ids / entry points; the retired a0 is checked each time.
//
//   Phase A  arithmetic           a0 = 3*tid + 7   (LUI-free OP/OP-IMM path)
//   Phase B  byte load/store       sb / lb / lbu    sign- vs zero-extension
//   Phase C  halfword load/store   sh / lhu / lh    high-half byte-enables
// =============================================================================
`timescale 1ns/1ps

module tb_lane
  import simtix_pkg::*;
;
    /* verilator lint_off UNUSEDSIGNAL */  // testbench probe/convenience signals
    logic        clk = 0;
    logic        rst;
    logic        start;
    logic [31:0] tid, base_a, base_b, base_c, n_threads, kernel_pc;
    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_we;
    logic [3:0]  dmem_be;
    logic        busy, done;
    logic [31:0] dbg_retire_a0;

    int unsigned errors = 0;

    lane dut (
        .clk(clk), .rst(rst),
        .start(start), .tid(tid),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_rdata(dmem_rdata),
        .busy(busy), .done(done), .dbg_retire_a0(dbg_retire_a0)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Kernel ROM (async read) ──────────────────────────────────────────────────
    logic [31:0] rom [0:31];
    initial begin
        for (int k = 0; k < 32; k++) rom[k] = 32'h00000013;  // nop fill

        // Phase A @ pc=0x00 : a0 = 3*tid + 7
        rom[0]  = 32'h00151293;   // slli t0, a0, 1     t0 = tid*2
        rom[1]  = 32'h00550533;   // add  a0, a0, t0    a0 = 3*tid
        rom[2]  = 32'h00750513;   // addi a0, a0, 7     a0 = 3*tid + 7
        rom[3]  = 32'h00000073;   // ecall

        // Phase B @ pc=0x20 : byte store/load  (a3 = data base)
        rom[8]  = 32'hf8000293;   // addi t0, x0, -128  t0 = 0xFFFFFF80
        rom[9]  = 32'h00568023;   // sb   t0, 0(a3)     mem[a3] = 0x80
        rom[10] = 32'h00068303;   // lb   t1, 0(a3)     t1 = sext(0x80) = -128
        rom[11] = 32'h0006c383;   // lbu  t2, 0(a3)     t2 = zext(0x80) =  128
        rom[12] = 32'h00730533;   // add  a0, t1, t2    a0 = 0
        rom[13] = 32'h00000073;   // ecall

        // Phase C @ pc=0x40 : halfword store/load to the high half (a3+2)
        rom[16] = 32'hffff8eb7;   // lui  t4, 0xFFFF8   t4 = 0xFFFF8000
        rom[17] = 32'h01d69123;   // sh   t4, 2(a3)     mem[a3+2] = 0x8000
        rom[18] = 32'h0026df03;   // lhu  t5, 2(a3)     t5 = 0x00008000
        rom[19] = 32'h00269f83;   // lh   t6, 2(a3)     t6 = 0xFFFF8000
        rom[20] = 32'h01ff0533;   // add  a0, t5, t6    a0 = 0
        rom[21] = 32'h00000073;   // ecall
    end
    assign imem_data = rom[imem_addr[6:2]];   // word index from byte address

    // ── Tiny data memory (async read, byte-enabled write) ─────────────────────────
    logic [31:0] dram [0:15];
    assign dmem_rdata = dram[dmem_addr[5:2]];
    always @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_be[0]) dram[dmem_addr[5:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_be[1]) dram[dmem_addr[5:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_be[2]) dram[dmem_addr[5:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_be[3]) dram[dmem_addr[5:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    // ── Run one thread from a given entry point, return its retired a0 ────────────
    task automatic run_thread(input logic [31:0] t, input logic [31:0] kpc,
                              output logic [31:0] result);
        int unsigned guard;
        @(posedge clk);
        tid = t; kernel_pc = kpc; start = 1;
        @(posedge clk);
        start = 0;
        guard = 0;
        while (!done && guard < 1000) begin @(posedge clk); guard++; end
        result = dbg_retire_a0;
    endtask

    task automatic check(input string name, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("  [FAIL] %-16s got=%0d exp=%0d", name, got, exp);
            errors++;
        end else begin
            $display("  [ ok ] %-16s = %0d", name, got);
        end
    endtask

    logic [31:0] got;

    initial begin
        start = 0; tid = 0; kernel_pc = 0;
        base_a = 0; base_b = 0; base_c = 32'h0000_0010; n_threads = 0;
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        // Phase A: arithmetic over several thread ids.
        for (int t = 0; t < 5; t++) begin
            run_thread(t, 32'h0000_0000, got);
            check($sformatf("A:3*%0d+7", t), got, 3*t + 7);
        end

        // Phase B: byte store then sign/zero-extended loads → -128 + 128 == 0.
        run_thread(0, 32'h0000_0020, got);
        check("B:sb/lb/lbu", got, 32'd0);

        // Phase C: halfword store to the high half then lhu+lh → wraps to 0.
        run_thread(0, 32'h0000_0040, got);
        check("C:sh/lhu/lh", got, 32'd0);

        if (errors == 0) begin
            $display("[tb_lane] PASS");
            $finish;
        end else begin
            $display("[tb_lane] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #100000;
        $display("[tb_lane] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_lane
