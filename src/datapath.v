// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module datapath (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [3:0] operand_a,
    input  wire [3:0] operand_b,
    input  wire [2:0] alu_op,
    input  wire       load_a,
    input  wire       load_b,
    output reg  [7:0] result,
    output wire       zero_flag,
    output wire       carry_flag,
    output wire       overflow_flag
);

    reg [3:0] reg_a;
    reg [3:0] reg_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_a <= 4'b0;
            reg_b <= 4'b0;
        end else begin
            if (load_a) reg_a <= operand_a;
            if (load_b) reg_b <= operand_b;
        end
    end

    wire       sub_mode = (alu_op == 3'b001) || (alu_op == 3'b111);
    wire [3:0] adder_b_input = sub_mode ? ~reg_b : reg_b;
    wire       carry_in = sub_mode;
    wire [4:0] adder_out = reg_a + adder_b_input + {4'b0, carry_in};

    always @(*) begin
        case (alu_op)
            3'b000:  result = {4'b0, adder_out[3:0]};
            3'b001:  result = {4'b0, adder_out[3:0]};
            3'b010:  result = {4'b0, reg_a & reg_b};
            3'b011:  result = {4'b0, reg_a | reg_b};
            3'b100:  result = {4'b0, reg_a ^ reg_b};
            3'b101:  result = {4'b0, reg_a[2:0], 1'b0};
            3'b110:  result = {4'b0, 1'b0, reg_a[3:1]};
            3'b111:  result = {4'b0, adder_out[3:0]};
            default: result = 8'b0;
        endcase
    end

    assign zero_flag     = (result[3:0] == 4'b0);
    assign carry_flag    = adder_out[4];
    assign overflow_flag = (reg_a[3] ^ adder_out[3]) & ~(reg_a[3] ^ adder_b_input[3]);

endmodule
