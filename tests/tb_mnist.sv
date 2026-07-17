// =============================================================================
// tb_mnist.sv — end-to-end quantized MNIST MLP inference on the accelerator (AI-4)
//
// Runs the full forward pass of a pre-trained INT8 MLP (784->128->10) on
// warp_pool, one test image at a time, entirely out of the accelerator's own
// kernels:
//     x -> qgemv(K=784,N=128) -> requant_relu(M1) -> qgemv(K=128,N=10) -> argmax
// The host side (this tb, standing in for the CPU driver) only sets base
// pointers / the Kp config word and launches each kernel. Each predicted digit
// is checked against the integer-exact golden from ml/mnist_quant.py, and the
// accuracy over the 64 test images is reported.
//
// Weights/images/golden are produced by ml/mnist_quant.py (hex, packed 4/word)
// and loaded with $readmemh.  Build/run: make -C sim test-mnist
// =============================================================================
`timescale 1ns/1ps
module tb_mnist
    import simtix_pkg::*;
#()  ;
    // ── MLP dimensions ───────────────────────────────────────────────────────────
    localparam int K1 = 784, N1 = 128, KP1 = K1/4;   // layer 1
    localparam int K2 = 128, N2 = 10,  KP2 = K2/4;   // layer 2
    localparam int NIMG = 64;

    logic                 clk = 0;
    logic                 rst;
    logic                 start;
    logic [31:0]          base_a, base_b, base_c, n_threads, kernel_pc;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]          imem_addr, imem_data;
    logic [31:0]          dmem_addr;
    logic [LINE_BITS-1:0] dmem_wdata, dmem_rdata;
    logic                 dmem_we;
    logic [LINE_BE-1:0]   dmem_be;
    logic                 busy, done;
    logic [31:0]          dbg_retire_a0, dbg_mem_txns, dbg_divergences, dbg_scratch_txns;
    logic [31:0]          dbg_issued_insns, dbg_active_lanes;
    /* verilator lint_on UNUSEDSIGNAL */

    warp_pool dut (
        .clk(clk), .rst(rst), .start(start),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_rdata(dmem_rdata),
        .busy(busy), .done(done),
        .dbg_retire_a0(dbg_retire_a0), .dbg_mem_txns(dbg_mem_txns),
        .dbg_divergences(dbg_divergences), .dbg_scratch_txns(dbg_scratch_txns),
        .dbg_issued_insns(dbg_issued_insns), .dbg_active_lanes(dbg_active_lanes)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Behavioural line memory: 256 KB (byte addr[17:2] word index) ─────────────
    localparam int MEM_WORDS = 1 << 16;      // 65536 words
    logic [31:0] mem [0:MEM_WORDS-1];
    assign imem_data = mem[imem_addr[17:2]];
    logic [31:0] lbase;
    assign lbase = {16'b0, dmem_addr[17:5], 3'b000};
    always_comb
        for (int w = 0; w < LINE_WORDS; w++)
            dmem_rdata[w*32 +: 32] = mem[lbase + w];
    always @(posedge clk)
        if (dmem_we)
            for (int w = 0; w < LINE_WORDS; w++) begin
                logic [31:0] cur;
                cur = mem[lbase + w];
                for (int b = 0; b < 4; b++)
                    if (dmem_be[w*4 + b]) cur[b*8 +: 8] = dmem_wdata[w*32 + b*8 +: 8];
                mem[lbase + w] <= cur;
            end

    // ── Memory map (byte addresses) ──────────────────────────────────────────────
    localparam logic [31:0] KPC_GEMV = 32'h0000_0000;   // qgemv kernel   (words 0..19)
    localparam logic [31:0] KPC_RQR  = 32'h0000_0060;   // requant_relu   (words 24..39)
    localparam logic [31:0] CFG      = 32'h0000_0100;   // config: Kp     (word 64)
    localparam logic [31:0] PARAM    = 32'h0000_0140;   // requant params (word 80)
    localparam logic [31:0] HACC     = 32'h0000_0200;   // layer1 int32 out[128]
    localparam logic [31:0] H        = 32'h0000_0400;   // hidden int8[128] (packed 32 w)
    localparam logic [31:0] OACC     = 32'h0000_0480;   // layer2 int32 out[10]
    localparam logic [31:0] W2       = 32'h0000_0800;   // W2packed [32][10]  (320 w)
    localparam logic [31:0] IMG      = 32'h0000_1000;   // images [64][196]   (12544 w)
    localparam logic [31:0] W1       = 32'h0001_0000;   // W1packed [196][128](25088 w)

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] a); widx = 32'(a[17:2]); endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // qgemv.S (20 words) and requant_relu.S (16 words), inlined.
    task automatic load_kernels();
        // qgemv @ word 0
        mem[ 0]=32'h10000293; mem[ 1]=32'h0002a303; mem[ 2]=32'h00251393; mem[ 3]=32'h007603b3;
        mem[ 4]=32'h00271e13; mem[ 5]=32'h00058e93; mem[ 6]=32'h00000f13; mem[ 7]=32'h00000f93;
        mem[ 8]=32'h000ea403; mem[ 9]=32'h0003a483; mem[10]=32'h0094090b; mem[11]=32'h012f0f33;
        mem[12]=32'h004e8e93; mem[13]=32'h01c383b3; mem[14]=32'h001f8f93; mem[15]=32'hfe6fc2e3;
        mem[16]=32'h00251993; mem[17]=32'h013689b3; mem[18]=32'h01e9a023; mem[19]=32'h00000073;
        // requant_relu @ word 24 (byte 0x60)
        mem[24]=32'h00251293; mem[25]=32'h00558333; mem[26]=32'h00032383; mem[27]=32'h00062087;
        mem[28]=32'h00462107; mem[29]=32'hd003f1d3; mem[30]=32'h1011f1c3; mem[31]=32'h42fe0e37;
        mem[32]=32'hf00e0253; mem[33]=32'hf00002d3; mem[34]=32'h284181d3; mem[35]=32'h285191d3;
        mem[36]=32'hc0018ed3; mem[37]=32'h00a68f33; mem[38]=32'h01df0023; mem[39]=32'h00000073;
    endtask

    logic [31:0] gold   [0:NIMG-1];
    logic [31:0] labels [0:NIMG-1];

    task automatic launch(input logic [31:0] n, input logic [31:0] kpc,
                          input logic [31:0] a, input logic [31:0] b, input logic [31:0] c);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = kpc; base_a = a; base_b = b; base_c = c;
        start = 1; @(posedge clk); start = 0;
        guard = 0;
        while (!done && guard < 2000000) begin @(posedge clk); guard++; end
        if (!done) $display("  [WARN] launch timeout (kpc=%0h)", kpc);
    endtask

    int correct_gold, correct_lbl;

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_kernels();
        $readmemh("../ml/data/w1packed.hex", mem, widx(W1));      // [196][128]
        $readmemh("../ml/data/w2packed.hex", mem, widx(W2));      // [32][10]
        $readmemh("../ml/data/images.hex",   mem, widx(IMG));     // [64][196]
        $readmemh("../ml/data/params.hex",   mem, widx(PARAM));   // M1, zp=0
        $readmemh("../ml/data/gold.hex",   gold);
        $readmemh("../ml/data/labels.hex", labels);

        rst = 1; repeat (3) @(posedge clk); rst = 0;
        $display("=============================================================================");
        $display("SIMTiX end-to-end MNIST inference  (784->128->10 INT8)  %0d images", NIMG);

        correct_gold = 0; correct_lbl = 0;
        for (int i = 0; i < NIMG; i++) begin
            int unsigned imgbase; logic signed [31:0] best; int pred;
            imgbase = IMG + i*KP1*4;                       // image i's packed x-vector
            mem[widx(CFG)] = KP1;                          // Kp for layer 1 (=196)
            launch(N1, KPC_GEMV, imgbase, W1, HACC);       // acc1[128] = x . W1
            launch(N1, KPC_RQR,  HACC, PARAM, H);          // h[128] = requant_relu(acc1)
            mem[widx(CFG)] = KP2;                          // Kp for layer 2 (=32)
            launch(N2, KPC_GEMV, H, W2, OACC);             // acc2[10] = h . W2

            best = mem[widx(OACC)]; pred = 0;              // argmax over 10 logits
            for (int n = 1; n < N2; n++)
                if (signed'(mem[widx(OACC)+n]) > best) begin best = signed'(mem[widx(OACC)+n]); pred = n; end

            if (pred == int'(gold[i]))   correct_gold++;
            else $display("  [MISS] img %0d: accel pred=%0d != golden=%0d (label %0d)",
                          i, pred, gold[i], labels[i]);
            if (pred == int'(labels[i])) correct_lbl++;
        end

        $display("  accelerator vs golden : %0d / %0d match", correct_gold, NIMG);
        $display("  accuracy vs labels    : %0d / %0d = %0d.%0d%%",
                 correct_lbl, NIMG, (correct_lbl*100)/NIMG, ((correct_lbl*1000)/NIMG)%10);
        $display("=============================================================================");
        if (correct_gold != NIMG) begin
            $display("RESULT: FAIL (accelerator does not match the integer golden)"); $fatal(1);
        end else begin
            $display("RESULT: PASS (accelerator reproduces the golden bit-exact)"); $finish;
        end
    end

    initial begin
        #200_000_000; $display("RESULT: FAIL (global timeout)"); $fatal(1);
    end
endmodule : tb_mnist
