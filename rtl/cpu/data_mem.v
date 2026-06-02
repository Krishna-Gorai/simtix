// =============================================================================
// data_mem.v  -  Data SRAM  (Vivado synthesizable, DEPTH=32)
// =============================================================================
`timescale 1ns/1ps

(* dont_touch = "true" *)
module data_mem #(
    parameter DEPTH = 32
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire [ 2:0] funct3,
    input  wire [31:0] addr,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    output wire        mem_ready
);

    reg [31:0] mem [0:DEPTH-1];

    // ── Sequential clear controller (32 cycles after reset) ───────────────────
    localparam CNT_W = 5;   // 2^5 = 32

    reg [CNT_W-1:0] clr_cnt;
    reg             clearing;

    // NO initial block - rst drives the clearing FSM instead
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            clr_cnt  <= {CNT_W{1'b0}};
            clearing <= 1'b1;
        end else if (clearing) begin
            mem[clr_cnt] <= 32'd0;
            if (clr_cnt == DEPTH - 1)
                clearing <= 1'b0;
            else
                clr_cnt <= clr_cnt + 1'b1;
        end else if (we) begin
            case (funct3[1:0])
                2'b00: case (addr[1:0])
                    2'b00: mem[addr[6:2]][ 7: 0] <= wd[7:0];
                    2'b01: mem[addr[6:2]][15: 8] <= wd[7:0];
                    2'b10: mem[addr[6:2]][23:16] <= wd[7:0];
                    2'b11: mem[addr[6:2]][31:24] <= wd[7:0];
                    default: mem[addr[6:2]] <= mem[addr[6:2]];
                endcase
                2'b01: case (addr[1])
                    1'b0: mem[addr[6:2]][15: 0] <= wd[15:0];
                    1'b1: mem[addr[6:2]][31:16] <= wd[15:0];
                    default: mem[addr[6:2]] <= mem[addr[6:2]];
                endcase
                2'b10:    mem[addr[6:2]] <= wd;
                default:  mem[addr[6:2]] <= wd;
            endcase
        end
    end

    assign mem_ready = ~clearing;

    // ── Asynchronous read ─────────────────────────────────────────────────────
    wire [31:0] word = mem[addr[6:2]];

    always @(*) begin
        case (funct3)
            3'b000: case (addr[1:0])
                2'b00: rd = {{24{word[ 7]}}, word[ 7: 0]};
                2'b01: rd = {{24{word[15]}}, word[15: 8]};
                2'b10: rd = {{24{word[23]}}, word[23:16]};
                2'b11: rd = {{24{word[31]}}, word[31:24]};
                default: rd = 32'd0;
            endcase
            3'b001: case (addr[1])
                1'b0: rd = {{16{word[15]}}, word[15: 0]};
                1'b1: rd = {{16{word[31]}}, word[31:16]};
                default: rd = 32'd0;
            endcase
            3'b010:   rd = word;
            3'b100: case (addr[1:0])
                2'b00: rd = {24'd0, word[ 7: 0]};
                2'b01: rd = {24'd0, word[15: 8]};
                2'b10: rd = {24'd0, word[23:16]};
                2'b11: rd = {24'd0, word[31:24]};
                default: rd = 32'd0;
            endcase
            3'b101: case (addr[1])
                1'b0: rd = {16'd0, word[15: 0]};
                1'b1: rd = {16'd0, word[31:16]};
                default: rd = 32'd0;
            endcase
            default: rd = word;
        endcase
    end

endmodule