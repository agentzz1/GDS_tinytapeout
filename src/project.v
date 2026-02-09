// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module tt_um_agentzz1_rtx8090 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // uio_in[4] = mode: 0=ALU, 1=SFU
    wire mode = uio_in[4];

    // --- ALU mode wiring ---
    wire [3:0] operand_a = ui_in[3:0];
    wire [2:0] op_select = ui_in[6:4];
    wire       start     = ui_in[7];
    wire [3:0] operand_b = uio_in[3:0];

    wire       load_a, load_b;
    wire [2:0] alu_op;
    wire       result_valid, busy;
    wire [7:0] alu_result;
    wire       zero_flag, carry_flag, overflow_flag;

    control u_control (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start & ~mode),
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
        .result        (alu_result),
        .zero_flag     (zero_flag),
        .carry_flag    (carry_flag),
        .overflow_flag (overflow_flag)
    );

    // --- SFU mode wiring ---
    wire signed [7:0] sfu_x = ui_in;
    wire [2:0] func_sel = uio_in[2:0];
    wire signed [7:0] sfu_y;

    sfu u_sfu (
        .x        (sfu_x),
        .func_sel (func_sel),
        .y        (sfu_y)
    );

    // --- Output mux ---
    assign uo_out = mode ? sfu_y : alu_result;

    assign uio_out = mode ?
        {3'b000, 1'b0, 1'b1, 1'b0, 1'b0, (sfu_y == 8'sd0)} :
        {3'b000, busy, result_valid, overflow_flag, carry_flag, zero_flag};

    assign uio_oe = 8'b00011111;

    wire _unused = ena;

endmodule
