// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module sfu (
    input  wire signed [7:0] x,
    input  wire        [2:0] func_sel,
    output reg  signed [7:0] y
);

    wire [7:0] abs_x = x[7] ? -x : x;

    // --- Sigmoid (PLAN approximation, symmetric) ---
    reg [7:0] sig_pos;
    always @(*) begin
        if (abs_x >= 8'd40)
            sig_pos = 8'd16;
        else if (abs_x >= 8'd16)
            sig_pos = (abs_x >>> 3) + 8'd10;
        else
            sig_pos = (abs_x >>> 2) + 8'd8;
    end
    wire signed [7:0] sigmoid_out = x[7] ? (8'd16 - sig_pos) : sig_pos;

    // --- GELU: x * sigmoid(1.7 * x) ---
    wire signed [15:0] sx_wide = x * 8'sd27;
    wire signed [7:0]  sx = sx_wide[11:4];
    wire [7:0] abs_sx = sx[7] ? -sx : sx;
    reg [7:0] sig_gelu_pos;
    always @(*) begin
        if (abs_sx >= 8'd40)
            sig_gelu_pos = 8'd16;
        else if (abs_sx >= 8'd16)
            sig_gelu_pos = (abs_sx >>> 3) + 8'd10;
        else
            sig_gelu_pos = (abs_sx >>> 2) + 8'd8;
    end
    wire signed [7:0] sig_gelu = sx[7] ? (8'd16 - sig_gelu_pos) : sig_gelu_pos;
    wire signed [15:0] gelu_wide = x * sig_gelu;
    wire signed [7:0]  gelu_out = gelu_wide[11:4];

    // --- Tanh: 2*sigmoid(2x) - 1 ---
    wire signed [7:0] x2 = (x > 8'sd63) ? 8'sd127 :
                           (x < -8'sd64) ? -8'sd128 :
                           (x <<< 1);
    wire [7:0] abs_x2 = x2[7] ? -x2 : x2;
    reg [7:0] sig_tanh_pos;
    always @(*) begin
        if (abs_x2 >= 8'd40)
            sig_tanh_pos = 8'd16;
        else if (abs_x2 >= 8'd16)
            sig_tanh_pos = (abs_x2 >>> 3) + 8'd10;
        else
            sig_tanh_pos = (abs_x2 >>> 2) + 8'd8;
    end
    wire signed [7:0] sig_tanh = x2[7] ? (8'd16 - sig_tanh_pos) : sig_tanh_pos;
    wire signed [7:0] tanh_out = (sig_tanh <<< 1) - 8'sd16;

    // --- Exp (piecewise linear, range [-4, 2]) ---
    reg signed [7:0] exp_out;
    always @(*) begin
        if (x >= 8'sd32)
            exp_out = 8'sd127;
        else if (x >= 8'sd0)
            exp_out = 8'sd16 + x;
        else if (x >= -8'sd16)
            exp_out = 8'sd6 + (((x + 8'sd16) * 8'sd10) >>> 4);
        else if (x >= -8'sd32)
            exp_out = 8'sd2 + ((x + 8'sd32) >>> 2);
        else if (x >= -8'sd48)
            exp_out = (x + 8'sd48) >>> 3;
        else
            exp_out = 8'sd0;
    end

    // --- Reciprocal Sqrt (coarse piecewise estimate) ---
    reg signed [7:0] rsqrt_out;
    always @(*) begin
        if (x <= 8'sd0)
            rsqrt_out = 8'sd127;
        else if (x < 8'sd4)
            rsqrt_out = 8'sd64;
        else if (x < 8'sd16)
            rsqrt_out = 8'sd24;
        else if (x < 8'sd64)
            rsqrt_out = 8'sd16;
        else
            rsqrt_out = 8'sd8;
    end

    // --- Output mux ---
    always @(*) begin
        case (func_sel)
            3'b000: y = (x[7]) ? 8'sd0 : x;       // ReLU
            3'b001: y = sigmoid_out;                 // Sigmoid
            3'b010: y = gelu_out;                    // GELU
            3'b011: y = tanh_out;                    // Tanh
            3'b100: y = exp_out;                     // Exp
            3'b101: y = rsqrt_out;                   // 1/sqrt(x)
            3'b110: y = x;                           // Identity
            3'b111: y = (x[7]) ? -x : x;            // Abs
            default: y = 8'sd0;
        endcase
    end

endmodule
