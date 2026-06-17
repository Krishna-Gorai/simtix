// =============================================================================
// tb_cpu_bench.sv  -  scalar host-CPU baseline for the SIMTiX benchmark suite
//
// Runs the SAME kernels as tb_bench.sv, but on the reused 5-stage RV32I host
// pipeline (rtl/cpu/riscv_pipeline.v) executing a plain scalar loop over all N
// elements — the MEASURED single-core baseline the paper's speedup is computed
// against (CPU cycles / accelerator cycles).  The scalar programs are the
// kernels/scalar/s_*.S images (no `mul` — the host core is pure RV32I, so the
// constant multiplies are lowered to shift-add; matmul, which needs a real
// multiply, is not part of the scalar baseline).
//
// A flat von-Neumann memory backs both the instruction fetch and the data port.
// Completion is the program's store to 0x9000_0000 (sentinel), mirroring the
// chip's result-register convention.  Per (kernel,N) it prints cycles and emits
// a "CSVCPU," row; docs/plot_bench.py joins these with docs/bench.csv to produce
// the speedup table and figure:
//     make cpu-bench | grep '^CSVCPU,' > docs/bench_cpu.csv
// =============================================================================
`timescale 1ns/1ps

module tb_cpu_bench;
    logic        clk = 0;
    logic        rst;
    logic [31:0] reset_vector;

    // CPU <-> memory wires.
    logic [31:0] PCF, InstrF;
    logic [31:0] ALUResultM, WriteDataM, ReadDataM;
    logic        MemWriteM;
    logic [2:0]  Funct3M;

    int unsigned errors = 0;

    riscv_pipeline u_cpu (
        .clk(clk), .rst(rst), .reset_vector(reset_vector),
        .PCF(PCF), .InstrF(InstrF),
        .ALUResultM(ALUResultM), .WriteDataM(WriteDataM), .ReadDataM(ReadDataM),
        .MemWriteM(MemWriteM), .Funct3M(Funct3M),
        .mem_ready(1'b1)                      // preloaded memory is always ready
    );

    always #5 clk = ~clk;

    // ── Unified 64 KB memory (same map as tb_bench's data arrays) ─────────────────
    localparam int MEM_WORDS = 16384;
    logic [31:0] mem [0:MEM_WORDS-1];

    assign InstrF = mem[PCF[15:2]];

    // Async data read with sub-word extraction (mirrors rtl/cpu/data_mem.v).
    logic [31:0] dword;
    assign dword = mem[ALUResultM[15:2]];
    always_comb begin
        unique case (Funct3M)
            3'b000: unique case (ALUResultM[1:0])
                2'b00: ReadDataM = {{24{dword[ 7]}}, dword[ 7: 0]};
                2'b01: ReadDataM = {{24{dword[15]}}, dword[15: 8]};
                2'b10: ReadDataM = {{24{dword[23]}}, dword[23:16]};
                2'b11: ReadDataM = {{24{dword[31]}}, dword[31:24]};
            endcase
            3'b001: ReadDataM = ALUResultM[1] ? {{16{dword[31]}}, dword[31:16]}
                                              : {{16{dword[15]}}, dword[15: 0]};
            3'b100: unique case (ALUResultM[1:0])
                2'b00: ReadDataM = {24'd0, dword[ 7: 0]};
                2'b01: ReadDataM = {24'd0, dword[15: 8]};
                2'b10: ReadDataM = {24'd0, dword[23:16]};
                2'b11: ReadDataM = {24'd0, dword[31:24]};
            endcase
            3'b101: ReadDataM = ALUResultM[1] ? {16'd0, dword[31:16]}
                                              : {16'd0, dword[15: 0]};
            default: ReadDataM = dword;
        endcase
    end

    // Sync write (sub-word) + sentinel-store completion detector.
    logic done_r;
    always @(posedge clk) begin
        if (rst) begin
            done_r <= 1'b0;
        end else if (MemWriteM) begin
            if (ALUResultM[31:28] == 4'h9) begin
                done_r <= 1'b1;                          // store to 0x9000_0000 => done
            end else begin
                unique case (Funct3M[1:0])
                    2'b00: unique case (ALUResultM[1:0]) // sb
                        2'b00: mem[ALUResultM[15:2]][ 7: 0] <= WriteDataM[7:0];
                        2'b01: mem[ALUResultM[15:2]][15: 8] <= WriteDataM[7:0];
                        2'b10: mem[ALUResultM[15:2]][23:16] <= WriteDataM[7:0];
                        2'b11: mem[ALUResultM[15:2]][31:24] <= WriteDataM[7:0];
                    endcase
                    2'b01: if (ALUResultM[1])            // sh
                        mem[ALUResultM[15:2]][31:16] <= WriteDataM[15:0];
                    else
                        mem[ALUResultM[15:2]][15: 0] <= WriteDataM[15:0];
                    default: mem[ALUResultM[15:2]] <= WriteDataM;  // sw
                endcase
            end
        end
    end

    // ── Memory map ────────────────────────────────────────────────────────────────
    localparam int W_SVADD=0, W_SSAXPY=64, W_SFIR=128, W_SRELU=192, W_SCOLLATZ=256, W_SREDUCE=320;
    localparam logic [31:0] PARAM_N = 32'h0000_1000;  // word 1024
    localparam logic [31:0] A_BASE  = 32'h0000_2000;
    localparam logic [31:0] B_BASE  = 32'h0000_4000;
    localparam logic [31:0] C_BASE  = 32'h0000_6000;

    function automatic int unsigned widx(input logic [31:0] b);
        widx = {18'b0, b[15:2]};
    endfunction

    task automatic load_scalar_kernels();
        mem[W_SVADD+0]=32'h000025b7; mem[W_SVADD+1]=32'h00004637; mem[W_SVADD+2]=32'h000066b7;
        mem[W_SVADD+3]=32'h00001fb7; mem[W_SVADD+4]=32'h000fa703; mem[W_SVADD+5]=32'h00000293;
        mem[W_SVADD+6]=32'h00229313; mem[W_SVADD+7]=32'h006583b3; mem[W_SVADD+8]=32'h0003ae03;
        mem[W_SVADD+9]=32'h00660eb3; mem[W_SVADD+10]=32'h000eaf03; mem[W_SVADD+11]=32'h01ee0e33;
        mem[W_SVADD+12]=32'h006683b3; mem[W_SVADD+13]=32'h01c3a023; mem[W_SVADD+14]=32'h00128293;
        mem[W_SVADD+15]=32'hfce2cee3; mem[W_SVADD+16]=32'h90000337; mem[W_SVADD+17]=32'h00532023;
        mem[W_SVADD+18]=32'h0000006f;

        mem[W_SSAXPY+0]=32'h000025b7; mem[W_SSAXPY+1]=32'h00004637; mem[W_SSAXPY+2]=32'h000066b7;
        mem[W_SSAXPY+3]=32'h00001fb7; mem[W_SSAXPY+4]=32'h000fa703; mem[W_SSAXPY+5]=32'h00000293;
        mem[W_SSAXPY+6]=32'h00229313; mem[W_SSAXPY+7]=32'h006583b3; mem[W_SSAXPY+8]=32'h0003ae03;
        mem[W_SSAXPY+9]=32'h001e1e93; mem[W_SSAXPY+10]=32'h01ce8e33; mem[W_SSAXPY+11]=32'h00660eb3;
        mem[W_SSAXPY+12]=32'h000eaf03; mem[W_SSAXPY+13]=32'h01ee0e33; mem[W_SSAXPY+14]=32'h006683b3;
        mem[W_SSAXPY+15]=32'h01c3a023; mem[W_SSAXPY+16]=32'h00128293; mem[W_SSAXPY+17]=32'hfce2cae3;
        mem[W_SSAXPY+18]=32'h90000337; mem[W_SSAXPY+19]=32'h00532023; mem[W_SSAXPY+20]=32'h0000006f;

        mem[W_SFIR+0]=32'h000025b7; mem[W_SFIR+1]=32'h000066b7; mem[W_SFIR+2]=32'h00001fb7;
        mem[W_SFIR+3]=32'h000fa703; mem[W_SFIR+4]=32'h00000293; mem[W_SFIR+5]=32'h00229313;
        mem[W_SFIR+6]=32'h006583b3; mem[W_SFIR+7]=32'h0003ae03; mem[W_SFIR+8]=32'h0043ae83;
        mem[W_SFIR+9]=32'h0083af03; mem[W_SFIR+10]=32'h001e9e93; mem[W_SFIR+11]=32'h01de0e33;
        mem[W_SFIR+12]=32'h01ee0e33; mem[W_SFIR+13]=32'h006683b3; mem[W_SFIR+14]=32'h01c3a023;
        mem[W_SFIR+15]=32'h00128293; mem[W_SFIR+16]=32'hfce2cae3; mem[W_SFIR+17]=32'h90000337;
        mem[W_SFIR+18]=32'h00532023; mem[W_SFIR+19]=32'h0000006f;

        mem[W_SRELU+0]=32'h000025b7; mem[W_SRELU+1]=32'h000066b7; mem[W_SRELU+2]=32'h00001fb7;
        mem[W_SRELU+3]=32'h000fa703; mem[W_SRELU+4]=32'h00000293; mem[W_SRELU+5]=32'h00229313;
        mem[W_SRELU+6]=32'h006583b3; mem[W_SRELU+7]=32'h0003ae03; mem[W_SRELU+8]=32'h000e5463;
        mem[W_SRELU+9]=32'h00000e13; mem[W_SRELU+10]=32'h006683b3; mem[W_SRELU+11]=32'h01c3a023;
        mem[W_SRELU+12]=32'h00128293; mem[W_SRELU+13]=32'hfee2c0e3; mem[W_SRELU+14]=32'h90000337;
        mem[W_SRELU+15]=32'h00532023; mem[W_SRELU+16]=32'h0000006f;

        mem[W_SCOLLATZ+0]=32'h000025b7;  mem[W_SCOLLATZ+1]=32'h000066b7;  mem[W_SCOLLATZ+2]=32'h00001fb7;
        mem[W_SCOLLATZ+3]=32'h000fa703;  mem[W_SCOLLATZ+4]=32'h00000293;  mem[W_SCOLLATZ+5]=32'h00229313;
        mem[W_SCOLLATZ+6]=32'h006583b3;  mem[W_SCOLLATZ+7]=32'h0003ae03;  mem[W_SCOLLATZ+8]=32'h00000e93;
        mem[W_SCOLLATZ+9]=32'h00100f13;  mem[W_SCOLLATZ+10]=32'h03ee0463; mem[W_SCOLLATZ+11]=32'h001e7f13;
        mem[W_SCOLLATZ+12]=32'h000f0a63; mem[W_SCOLLATZ+13]=32'h001e1f13; mem[W_SCOLLATZ+14]=32'h01ee0e33;
        mem[W_SCOLLATZ+15]=32'h001e0e13; mem[W_SCOLLATZ+16]=32'h0080006f; mem[W_SCOLLATZ+17]=32'h001e5e13;
        mem[W_SCOLLATZ+18]=32'h001e8e93; mem[W_SCOLLATZ+19]=32'hfd9ff06f; mem[W_SCOLLATZ+20]=32'h006683b3;
        mem[W_SCOLLATZ+21]=32'h01d3a023; mem[W_SCOLLATZ+22]=32'h00128293; mem[W_SCOLLATZ+23]=32'hfae2cce3;
        mem[W_SCOLLATZ+24]=32'h90000337; mem[W_SCOLLATZ+25]=32'h00532023; mem[W_SCOLLATZ+26]=32'h0000006f;

        mem[W_SREDUCE+0]=32'h000025b7;  mem[W_SREDUCE+1]=32'h000066b7;  mem[W_SREDUCE+2]=32'h00001fb7;
        mem[W_SREDUCE+3]=32'h000fa703;  mem[W_SREDUCE+4]=32'h00375793;  mem[W_SREDUCE+5]=32'h00000293;
        mem[W_SREDUCE+6]=32'h00529313;  mem[W_SREDUCE+7]=32'h006583b3;  mem[W_SREDUCE+8]=32'h00000e13;
        mem[W_SREDUCE+9]=32'h0003ae83;  mem[W_SREDUCE+10]=32'h01de0e33; mem[W_SREDUCE+11]=32'h0043ae83;
        mem[W_SREDUCE+12]=32'h01de0e33; mem[W_SREDUCE+13]=32'h0083ae83; mem[W_SREDUCE+14]=32'h01de0e33;
        mem[W_SREDUCE+15]=32'h00c3ae83; mem[W_SREDUCE+16]=32'h01de0e33; mem[W_SREDUCE+17]=32'h0103ae83;
        mem[W_SREDUCE+18]=32'h01de0e33; mem[W_SREDUCE+19]=32'h0143ae83; mem[W_SREDUCE+20]=32'h01de0e33;
        mem[W_SREDUCE+21]=32'h0183ae83; mem[W_SREDUCE+22]=32'h01de0e33; mem[W_SREDUCE+23]=32'h01c3ae83;
        mem[W_SREDUCE+24]=32'h01de0e33; mem[W_SREDUCE+25]=32'h00229f13; mem[W_SREDUCE+26]=32'h01e68fb3;
        mem[W_SREDUCE+27]=32'h01cfa023; mem[W_SREDUCE+28]=32'h00128293; mem[W_SREDUCE+29]=32'hfaf2c2e3;
        mem[W_SREDUCE+30]=32'h90000337; mem[W_SREDUCE+31]=32'h00532023; mem[W_SREDUCE+32]=32'h0000006f;
    endtask

    // ── Run one scalar program (reset_vector = word_base*4); count cycles ─────────
    int unsigned m_cyc;
    task automatic run(input int word_base, input int unsigned n);
        int unsigned guard;
        mem[widx(PARAM_N)] = n[31:0];
        reset_vector = word_base*4;
        rst = 1; repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;
        m_cyc = 0; guard = 0;
        while (!done_r && guard < 4000000) begin @(posedge clk); m_cyc++; guard++; end
    endtask

    function automatic int unsigned csteps(input logic [31:0] n0);
        logic [31:0] n; int unsigned s;
        n = n0; s = 0;
        for (int it = 0; it < 32; it++)
            if (n != 32'd1) begin n = n[0] ? (3*n + 32'd1) : (n >> 1); s++; end
        csteps = s;
    endfunction

    task automatic chk(input int idx, input logic [31:0] exp, input string tag);
        logic [31:0] got;
        got = mem[widx(C_BASE) + idx];
        if (got !== exp) begin
            $display("  [FAIL] %-8s C[%0d] got=%0d exp=%0d", tag, idx, $signed(got), $signed(exp));
            errors++;
        end
    endtask

    task automatic preload_stream(input int n);
        for (int i = 0; i < n+2; i++) mem[widx(A_BASE) + i] = 32'd10  + i[31:0];
        for (int i = 0; i < n;   i++) mem[widx(B_BASE) + i] = 32'd100 + 2*i[31:0];
        for (int i = 0; i < n;   i++) mem[widx(C_BASE) + i] = 32'hdead_beef;
    endtask

    task automatic report(input string name, input int unsigned n);
        $display("  %-9s %4d | %8d cycles", name, n, m_cyc);
        $display("CSVCPU,%s,%0d,%0d", name, n, m_cyc);
    endtask

    int i;
    int unsigned sizes [4] = '{8, 64, 256, 1024};

    initial begin
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_scalar_kernels();

        $display("=============================================================================");
        $display("SIMTiX scalar host-CPU baseline (rtl/cpu, 5-stage RV32I)");
        $display("  kernel      N  | cycles");
        $display("  -----------------------------------");

        foreach (sizes[s]) begin
            preload_stream(sizes[s]);
            run(W_SVADD, sizes[s]);
            for (i = 0; i < sizes[s]; i++) chk(i, (32'd10+i) + (32'd100+2*i), "vadd");
            report("vadd", sizes[s]);
        end
        foreach (sizes[s]) begin
            preload_stream(sizes[s]);
            run(W_SSAXPY, sizes[s]);
            for (i = 0; i < sizes[s]; i++) chk(i, 32'd3*(32'd10+i) + (32'd100+2*i), "saxpy");
            report("saxpy", sizes[s]);
        end
        foreach (sizes[s]) begin
            preload_stream(sizes[s]);
            run(W_SFIR, sizes[s]);
            for (i = 0; i < sizes[s]; i++) chk(i, (32'd10+i) + 2*(32'd11+i) + (32'd12+i), "fir");
            report("fir", sizes[s]);
        end
        foreach (sizes[s]) begin
            for (i = 0; i < sizes[s]; i++)
                mem[widx(A_BASE)+i] = (i % 2 == 1) ? (32'd1+i) : -(32'd1+i);
            for (i = 0; i < sizes[s]; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
            run(W_SRELU, sizes[s]);
            for (i = 0; i < sizes[s]; i++) chk(i, (i % 2 == 1) ? (32'd1+i) : 32'd0, "relu");
            report("relu", sizes[s]);
        end
        for (int si = 0; si < 3; si++) begin
            int unsigned n = sizes[si];
            for (i = 0; i < n; i++) mem[widx(A_BASE)+i] = (i & 7) + 32'd2;
            for (i = 0; i < n; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
            run(W_SCOLLATZ, n);
            for (i = 0; i < n; i++) chk(i, csteps((i & 7) + 32'd2), "collatz");
            report("collatz", n);
        end
        foreach (sizes[s]) begin
            for (i = 0; i < sizes[s]; i++) mem[widx(A_BASE)+i] = 32'd10 + i[31:0];
            for (i = 0; i < sizes[s]/8; i++) mem[widx(C_BASE)+i] = 32'hdead_beef;
            run(W_SREDUCE, sizes[s]);
            for (i = 0; i < sizes[s]/8; i++) begin
                automatic logic [31:0] exp = 32'd0;
                for (int l = 0; l < 8; l++) exp += 32'd10 + 8*i[31:0] + l[31:0];
                chk(i, exp, "reduce");
            end
            report("reduce", sizes[s]);
        end

        $display("  -----------------------------------");
        if (errors == 0) begin
            $display("[tb_cpu_bench] PASS — scalar baseline verified across all sizes");
            $finish;
        end else begin
            $display("[tb_cpu_bench] FAIL (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #80000000;
        $display("[tb_cpu_bench] TIMEOUT");
        $fatal(1);
    end

endmodule : tb_cpu_bench
