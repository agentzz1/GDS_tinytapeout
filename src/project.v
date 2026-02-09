// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire [3:0] operand_a = ui_in[3:0];
    wire [2:0] op_select = ui_in[6:4];
    wire       start     = ui_in[7];
    wire [3:0] operand_b = uio_in[3:0];

    wire       load_a;
    wire       load_b;
    wire [2:0] alu_op;
    wire       result_valid;
    wire       busy;

    wire [7:0] result;
    wire       zero_flag;
    wire       carry_flag;
    wire       overflow_flag;

    control u_control (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .op_select    (op_select),
        .zero_flag    (zero_flag),
        .carry_flag   (carry_flag),
        .load_a       (load_a),
        .load_b       (load_b),
        .alu_op       (alu_op),
        .result_valid (result_valid),
        .busy         (busy)
    );

    datapath u_datapath (
        .clk           (clk),
        .rst_n         (rst_n),
        .operand_a     (operand_a),
        .operand_b     (operand_b),
        .alu_op        (alu_op),
        .load_a        (load_a),
        .load_b        (load_b),
        .result        (result),
        .zero_flag     (zero_flag),
        .carry_flag    (carry_flag),
        .overflow_flag (overflow_flag)
    );

    assign uo_out  = result;
    assign uio_out = {3'b000, busy, result_valid, overflow_flag, carry_flag, zero_flag};
    assign uio_oe  = 8'b00011111;

    wire _unused = ena;

endmodule
