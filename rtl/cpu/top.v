// =============================================================================
// top.v  -  AC701 FPGA top-level  (XC7A200T-FBG676-2)
//
// Thin synthesis shell around riscv_soc:
//   Differential board clock -> IBUFDS -> BUFG -> soc clk
//   reset_vector is fixed to the T10 sum-loop program (base 0x240), which
//   exercises forwarding, load-use stall and branch hardware most thoroughly
//   for utilization / PPA reporting.
//
//   mem_ready_out drives GPIO_LED_0 - this single real output anchors the
//   design so opt_design cannot remove the entire netlist.
//   (* dont_touch *) on the soc preserves all flip-flops and LUTs.
//
//   The actual CPU + memory system lives in riscv_soc.v and is shared with
//   the simulation testbench, so the two can never drift out of sync.
// =============================================================================
`timescale 1ns/1ps

(* dont_touch = "true" *)
module top (
    input  wire        sys_clk_p,      // 200 MHz diff clock positive (R3)
    input  wire        sys_clk_n,      // 200 MHz diff clock negative (P3)
    input  wire        rst,            // CPU_RESET U4, active high
    output wire        mem_ready_out,  // routed to GPIO_LED_0 to anchor the design
    // Boundary-observable debug taps (used by post-implementation funcsim).
    // Left unconstrained on purpose - see constraints.xdc DRC downgrades.
    output wire        dbg_store_we,
    output wire [31:0] dbg_store_data,
    output wire [31:0] dbg_store_addr
);

    // ── Clock buffer: differential -> single-ended ─────────────────────────
    wire clk_ibuf;
    IBUFDS #(
        .DIFF_TERM    ("FALSE"),
        .IBUF_LOW_PWR ("FALSE")
    ) u_ibufds (
        .I  (sys_clk_p),
        .IB (sys_clk_n),
        .O  (clk_ibuf)
    );

    wire clk;
    BUFG u_bufg (
        .I (clk_ibuf),
        .O (clk)
    );

    // ── Program selection ───────────────────────────────────────────────────
    // T10 (sum 1..10 = 55) at base 0x240.
    localparam [31:0] RESET_VECTOR = 32'h240;

    // ── RISC-V system ─────────────────────────────────────────────────────────
    (* dont_touch = "true" *)
    riscv_soc soc (
        .clk            (clk),
        .rst            (rst),
        .reset_vector   (RESET_VECTOR),
        .mem_ready_out  (mem_ready_out),
        .dbg_store_we   (dbg_store_we),
        .dbg_store_data (dbg_store_data),
        .dbg_store_addr (dbg_store_addr)
    );

endmodule
