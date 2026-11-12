// ara_ooc_top.sv - out-of-context synthesis top for Ara + CVA6 (ara_soc) on the XCZU9EG
//
// ara_soc = CVA6 + Ara (ara_system) + AXI crossbar + L2 + control registers + UART APB.
// On the board the L2 is replaced by an AXI4 master to the PS DDR4; here it is kept,
// shrunk to L2_WORDS words (block RAM), so that every path of the core reaches a port
// and synthesis keeps the whole design. Area of the core = hierarchy i_ara_soc/i_system.
// NR_LANES and VLEN come from the Bender defines (vivado_sources_<n>l.tcl).
module ara_ooc_top #(
  parameter int unsigned L2_WORDS = 4096
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  output logic [63:0] exit_o,
  output logic [63:0] hw_cnt_en_o,
  output logic        uart_penable_o,
  output logic        uart_pwrite_o,
  output logic [31:0] uart_paddr_o,
  output logic        uart_psel_o,
  output logic [31:0] uart_pwdata_o,
  input  logic [31:0] uart_prdata_i,
  input  logic        uart_pready_i,
  input  logic        uart_pslverr_i
);

  // ARA_FPU_HS: FP32 and FP16 only (no FP64), in Ara and in CVA6, as SIMTiX is FP32
`ifdef ARA_FPU_HS
  localparam ara_pkg::fpu_support_e FPU = ara_pkg::FPUSupportHalfSingle;
`else
  localparam ara_pkg::fpu_support_e FPU = ara_pkg::FPUSupportHalfSingleDouble;
`endif

  ara_soc #(
    .NrLanes   (`NR_LANES),
    .VLEN      (`VLEN    ),
    .FPUSupport(FPU      ),
    .L2NumWords(L2_WORDS )
  ) i_ara_soc (
    .clk_i         (clk_i         ),
    .rst_ni        (rst_ni        ),
    .exit_o        (exit_o        ),
    .hw_cnt_en_o   (hw_cnt_en_o   ),
    .scan_enable_i (1'b0          ),
    .scan_data_i   (1'b0          ),
    .scan_data_o   (              ),
    .uart_penable_o(uart_penable_o),
    .uart_pwrite_o (uart_pwrite_o ),
    .uart_paddr_o  (uart_paddr_o  ),
    .uart_psel_o   (uart_psel_o   ),
    .uart_pwdata_o (uart_pwdata_o ),
    .uart_prdata_i (uart_prdata_i ),
    .uart_pready_i (uart_pready_i ),
    .uart_pslverr_i(uart_pslverr_i)
  );

endmodule
