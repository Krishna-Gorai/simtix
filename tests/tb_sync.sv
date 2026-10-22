// =============================================================================
// tb_sync.sv — v2 synchronisation: warp shuffle, block barrier, block-shared
// scratchpad and RV32A atomics, checked bit-exact on real kernels.
//
// Drives warp_pool directly with a behavioural line memory (as tb_pdot8 does).
// Every kernel in kernels/sync/ is placed at its own PC and run on a fresh grid;
// results are compared against SystemVerilog reference models, and the kernel
// cycle counts are printed as SYNCCSV rows:
//   SYNCCSV,<kernel>,<N>,<block_log2>,<cycles>,<gmem_txns>,<scratch_txns>
//
// Kernels are assembled by kernels/sync/build.py into .svh include files.
//   Build/run:  make -C sim test-sync      (or python sim/run_xsim.py sync)
// =============================================================================
`timescale 1ns/1ps
module tb_sync
    import simtix_pkg::*;
#(
    // Data-memory timing. MEM_LAT = 0 answers in the request cycle. MEM_LAT > 0
    // reads/writes the array when a request is accepted and returns its response
    // MEM_LAT cycles later. MEM_STALL = 1 withholds the grant on about one cycle in
    // four (pseudo-random), to exercise back-pressure. MEM_OOO = 1 adds 0..7 random
    // cycles to each request's latency, so responses return out of order.
    parameter int MEM_LAT   = 0,
    parameter int MEM_STALL = 0,
    parameter int MEM_OOO   = 0
)  ;
    logic                 clk = 0;
    logic                 rst;
    logic                 start;
    logic [31:0]          base_a, base_b, base_c, n_threads, kernel_pc;
    logic [2:0]           block_log2;
    /* verilator lint_off UNUSEDSIGNAL */   // only address sub-fields / done are read
    logic [31:0]          imem_addr, imem_data;
    logic [31:0]          dmem_addr;
    logic [LINE_BITS-1:0] dmem_wdata, dmem_rdata;
    logic                 dmem_we;
    logic                 dmem_req, dmem_gnt, dmem_rvalid;
    logic [MEM_TAGW-1:0]  dmem_tag, dmem_rtag;
    logic [LINE_BE-1:0]   dmem_be;
    logic                 busy, done;
    logic [31:0]          dbg_retire_a0, dbg_mem_txns, dbg_divergences, dbg_scratch_txns;
    logic [31:0]          dbg_issued_insns, dbg_active_lanes;
    /* verilator lint_on UNUSEDSIGNAL */

    int unsigned errors = 0;
    int unsigned checks = 0;

    warp_pool dut (
        .clk(clk), .rst(rst), .start(start),
        .base_a(base_a), .base_b(base_b), .base_c(base_c),
        .n_threads(n_threads), .kernel_pc(kernel_pc), .block_log2(block_log2),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_req(dmem_req), .dmem_gnt(dmem_gnt), .dmem_tag(dmem_tag), .dmem_rtag(dmem_rtag), .dmem_we(dmem_we), .dmem_be(dmem_be),
        .dmem_rvalid(dmem_rvalid), .dmem_rdata(dmem_rdata),
        .busy(busy), .done(done),
        .dbg_retire_a0(dbg_retire_a0), .dbg_mem_txns(dbg_mem_txns),
        .dbg_divergences(dbg_divergences), .dbg_scratch_txns(dbg_scratch_txns),
        .dbg_issued_insns(dbg_issued_insns), .dbg_active_lanes(dbg_active_lanes)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    // ── Behavioural line memory (64 KB), identical to tb_pdot8 ───────────────────
    localparam int MEM_WORDS = 16384;
    logic [31:0] mem [0:MEM_WORDS-1];
    assign imem_data = mem[imem_addr[15:2]];
    logic [31:0] lbase;
    assign lbase = {18'b0, dmem_addr[15:5], 3'b000};
    logic [LINE_BITS-1:0] line_now;              // the addressed line, this cycle
    always_comb
        for (int w = 0; w < LINE_WORDS; w++)
            line_now[w*32 +: 32] = mem[lbase + w];

    logic [15:0] lfsr;
    always @(posedge clk)
        if (rst) lfsr <= 16'hACE1;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    assign dmem_gnt = (MEM_STALL == 0) || (lfsr[1:0] != 2'b00);

    generate
        if (MEM_LAT == 0) begin : g_lat0
            assign dmem_rvalid = dmem_req;
            assign dmem_rtag   = dmem_tag;
            assign dmem_rdata  = line_now;
        end else begin : g_lat
            // One slot per tag (a tag is unique while outstanding): the line read at
            // acceptance and the cycle its response is due. Each cycle the lowest
            // due slot answers.
            int unsigned          now;
            logic                 sv  [MEM_TAGS];
            int unsigned          due [MEM_TAGS];
            logic [LINE_BITS-1:0] sd  [MEM_TAGS];
            logic                 rv;
            logic [MEM_TAGW-1:0]  rt;
            always_comb begin
                rv = 1'b0;
                rt = '0;
                for (int t = MEM_TAGS-1; t >= 0; t--)
                    if (sv[t] && (due[t] <= now)) begin rv = 1'b1; rt = MEM_TAGW'(t); end
            end
            always @(posedge clk) begin
                if (rst) begin
                    now <= 0;
                    for (int t = 0; t < MEM_TAGS; t++) sv[t] <= 1'b0;
                end else begin
                    now <= now + 1;
                    if (rv) sv[rt] <= 1'b0;
                    if (dmem_req && dmem_gnt) begin
                        sv[dmem_tag]  <= 1'b1;
                        due[dmem_tag] <= now + MEM_LAT + ((MEM_OOO != 0) ? 32'(lfsr[4:2]) : 0);
                        sd[dmem_tag]  <= line_now;
                    end
                end
            end
            assign dmem_rvalid = rv;
            assign dmem_rtag   = rt;
            assign dmem_rdata  = sd[rt];
        end
    endgenerate

    always @(posedge clk)
        if (dmem_we && dmem_req && dmem_gnt)
            for (int w = 0; w < LINE_WORDS; w++) begin
                logic [31:0] cur;
                cur = mem[lbase + w];
                for (int b = 0; b < 4; b++)
                    if (dmem_be[w*4 + b]) cur[b*8 +: 8] = dmem_wdata[w*32 + b*8 +: 8];
                mem[lbase + w] <= cur;
            end

    localparam logic [31:0] A_BASE = 32'h0000_2000;   // 1024 words
    localparam logic [31:0] B_BASE = 32'h0000_3000;   // 1024 words
    localparam logic [31:0] C_BASE = 32'h0000_4000;   // 1024 words
    localparam int          NMAX   = 1024;

    // Kernel slots: kernel k lives at word 64*k (PC = 256*k).
    localparam int K_SHFL = 0, K_RSHFL = 1, K_RALL = 2, K_RBLK = 3, K_HIST = 4,
                   K_HSH = 5, K_SCAN = 6, K_AMO = 7, K_ROLD = 8;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic int unsigned widx(input logic [31:0] byte_addr);
        widx = {18'b0, byte_addr[15:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    task automatic load_kernels();
        int at;
        at = 64*K_SHFL;  `include "shfl_test.svh"
        at = 64*K_RSHFL; `include "reduce_shfl.svh"
        at = 64*K_RALL;  `include "reduce_all.svh"
        at = 64*K_RBLK;  `include "reduce_block.svh"
        at = 64*K_HIST;  `include "histogram.svh"
        at = 64*K_HSH;   `include "hist_shared.svh"
        at = 64*K_SCAN;  `include "scan_warp.svh"
        at = 64*K_AMO;   `include "amo_test.svh"
        at = 64*K_ROLD;  `include "reduce.svh"
    endtask

    // Deterministic test data. avals are small, so block sums never overflow.
    /* verilator lint_off UNUSEDSIGNAL */   // aval keeps the middle 16 bits of the hash
    function automatic logic [31:0] aval(input int i);
        logic [31:0] h;
        h = i * 32'h9E37_79B1;
        aval = {16'd0, h[23:8]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    function automatic logic [31:0] bval(input int i);
        logic [31:0] h;
        h = (i + 77) * 32'h85EB_CA6B;
        bval = h ^ (h >> 13);
    endfunction

    task automatic fill_inputs();
        for (int i = 0; i < NMAX; i++) begin
            mem[widx(A_BASE) + i] = aval(i);
            mem[widx(B_BASE) + i] = bval(i);
            mem[widx(C_BASE) + i] = 32'd0;
        end
    endtask

    task automatic clear_c();
        for (int i = 0; i < NMAX; i++) mem[widx(C_BASE) + i] = 32'd0;
    endtask

    int unsigned last_cycles;
    task automatic run(input string tag, input int k, input int n, input int blk,
                       input logic [31:0] b);
        int unsigned guard;
        @(posedge clk);
        n_threads = n; kernel_pc = 256*k; block_log2 = 3'(blk);
        base_a = A_BASE; base_b = b; base_c = C_BASE;
        start = 1; @(posedge clk); start = 0;
        guard = 0;
        while (!done && guard < 400000) begin @(posedge clk); guard++; end
        if (!done) begin $display("  [FAIL] %s timeout", tag); errors++; end
        last_cycles = guard + 1;
        $display("SYNCCSV,%s,%0d,%0d,%0d,%0d,%0d", tag, n, blk, last_cycles,
                 dbg_mem_txns, dbg_scratch_txns);
    endtask

    task automatic chk(input string tag, input int idx, input logic [31:0] exp);
        logic [31:0] got;
        got = mem[widx(C_BASE) + idx];
        checks++;
        if (got !== exp) begin
            if (errors < 20)
                $display("  [FAIL] %-12s C[%0d]: got=%08h exp=%08h", tag, idx, got, exp);
            errors++;
        end
    endtask

    // ── Reference models ─────────────────────────────────────────────────────────
    function automatic logic [31:0] range_sum(input int lo, input int hi);   // [lo, hi)
        logic [31:0] s;
        s = 0;
        for (int i = lo; i < hi; i++) s += aval(i);
        return s;
    endfunction

    function automatic logic [31:0] amo_ref(input int op, input logic [31:0] m,
                                            input logic [31:0] v);
        case (op)
            0: amo_ref = v;                                            // swap
            1: amo_ref = m + v;                                        // add
            2: amo_ref = m ^ v;                                        // xor
            3: amo_ref = m & v;                                        // and
            4: amo_ref = m | v;                                        // or
            5: amo_ref = ($signed(m) < $signed(v)) ? m : v;            // min
            6: amo_ref = ($signed(m) < $signed(v)) ? v : m;            // max
            7: amo_ref = (m < v) ? m : v;                              // minu
            default: amo_ref = (m < v) ? v : m;                        // maxu
        endcase
    endfunction

    task automatic test_shfl();
        int n;
        n = 16;
        clear_c();
        run("shfl_test", K_SHFL, n, 0, B_BASE);
        for (int t = 0; t < n; t++) begin
            int l, w, s;
            l = t % 8; w = t / 8;
            s = (3*l + 1) % 8;                    chk("shfl.idx",  t,       aval(8*w + s));
            s = (l >= 2) ? l - 2 : l;             chk("shfl.up",   64 + t,  aval(8*w + s));
            s = (l + 3 < 8) ? l + 3 : l;          chk("shfl.down", 128 + t, aval(8*w + s));
            s = l ^ 5;                            chk("shfl.xor",  192 + t, aval(8*w + s));
        end
    endtask

    task automatic test_reduce(input int n);
        int unsigned c_old, c_new;
        clear_c();
        run("reduce_v1", K_ROLD, n, 0, B_BASE);
        c_old = last_cycles;
        for (int w = 0; w < n/8; w++) chk("reduce_v1", w, range_sum(8*w, 8*w + 8));
        clear_c();
        run("reduce_shfl", K_RSHFL, n, 0, B_BASE);
        c_new = last_cycles;
        for (int w = 0; w < n/8; w++) chk("reduce_shfl", w, range_sum(8*w, 8*w + 8));
        $display("  reduce N=%0d: v1 %0d cycles -> shuffle %0d cycles (%.2fx)",
                 n, c_old, c_new, real'(c_old) / real'(c_new));
    endtask

    task automatic test_reduce_all(input int n);
        clear_c();
        run("reduce_all", K_RALL, n, 0, B_BASE);
        chk("reduce_all", 0, range_sum(0, n));
    endtask

    // Block reduction: lg = log2(threads per block), block_log2 = lg - 3.
    task automatic test_reduce_block(input int n, input int lg);
        int bt;
        bt = 1 << lg;
        clear_c();
        run($sformatf("reduce_block%0d", bt), K_RBLK, n, lg - 3, lg);
        for (int b = 0; b < (n + bt - 1) / bt; b++)
            chk("reduce_block", b, range_sum(b*bt, (b*bt + bt < n) ? b*bt + bt : n));
    endtask

    task automatic test_hist(input string tag, input int k, input int n, input int blk);
        int unsigned hcount [16];
        for (int j = 0; j < 16; j++) hcount[j] = 0;
        for (int i = 0; i < n; i++) begin
            logic [3:0] b;           // temporary: no function call inside the index
            b = 4'(aval(i));
            hcount[b]++;
        end
        clear_c();
        run(tag, k, n, blk, B_BASE);
        for (int j = 0; j < 16; j++) chk(tag, j, hcount[j]);
    endtask

    task automatic test_scan(input int n);
        clear_c();
        run("scan_warp", K_SCAN, n, 0, B_BASE);
        for (int t = 0; t < n; t++) chk("scan_warp", t, range_sum(8*(t/8), t + 1));
    endtask

    task automatic test_amo(input int n);
        logic [31:0] m [NMAX];
        clear_c();
        for (int t = 0; t < n; t++) m[t] = mem[widx(A_BASE) + t];
        run("amo_test", K_AMO, n, 0, B_BASE);
        for (int t = 0; t < n; t++) begin
            logic [31:0] v;
            v = bval(t);
            for (int op = 0; op < 9; op++) begin
                chk("amo_old", 16*t + op, m[t]);
                m[t] = amo_ref(op, m[t], v);
                v = v + 32'h0123_4567;
            end
            checks++;
            if (mem[widx(A_BASE) + t] !== m[t]) begin
                $display("  [FAIL] amo final M[%0d]: got=%08h exp=%08h",
                         t, mem[widx(A_BASE) + t], m[t]);
                errors++;
            end
        end
        fill_inputs();                           // amo_test rewrote A[0..n)
    endtask

    initial begin
        start = 0; n_threads = 0; kernel_pc = 0; block_log2 = 0;
        base_a = 0; base_b = 0; base_c = 0;
        for (int w = 0; w < MEM_WORDS; w++) mem[w] = 32'd0;
        load_kernels();
        fill_inputs();
        rst = 1; repeat (3) @(posedge clk); rst = 0;

        $display("=============================================================================");
        $display("SIMTiX v2 synchronisation test  (NUM_LANES=%0d  NUM_WARPS=%0d)", NUM_LANES, NUM_WARPS);

        test_shfl();
        test_scan(64);
        test_amo(16);
        test_reduce(1024);
        test_reduce_all(1024);
        test_reduce_all(1004);                   // partial last warp
        test_reduce_block(1024, 5);              // 4-warp blocks, one resident block
        test_reduce_block(1024, 4);              // 2-warp blocks, two resident blocks
        test_reduce_block(1024, 3);              // 1-warp blocks
        test_reduce_block(1004, 5);              // partial last block (2 of 4 warps)
        test_hist("histogram", K_HIST, 1024, 0);
        test_hist("hist_shared", K_HSH, 1024, 2);

        $display("  %0d checks, %0d errors", checks, errors);
        $display("=============================================================================");
        if (errors != 0) begin $display("RESULT: FAIL (%0d errors)", errors); $fatal(1); end
        else             $display("RESULT: PASS");
        $finish;
    end

    // Global watchdog.
    initial begin
        #100_000_000;
        $display("RESULT: FAIL (global timeout)");
        $fatal(1);
    end
endmodule : tb_sync
