// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module datapath (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              write_query,
    input  wire              write_context,
    input  wire              stage_proj,
    input  wire              stage_attn,
    input  wire              stage_mix,
    input  wire              stage_ffn,
    input  wire        [1:0] slot_sel,
    input  wire        [2:0] feature_idx,
    input  wire signed [7:0] data_in,
    output reg         [7:0] read_data
);

    integer idx;
    integer token;
    integer head;
    integer dim;
    integer row;
    integer col;
    integer hidden_idx;
    integer acc;
    integer denom;
    integer shift_amt;
    integer head_base;
    integer token_base;
    integer hidden_acc;
    integer final_acc;
    integer score_acc;
    integer weight_now;

    reg signed [7:0] query_mem      [0:7];
    reg signed [7:0] context_mem    [0:31];
    reg signed [7:0] q_proj_mem     [0:7];
    reg signed [7:0] key_mem        [0:31];
    reg signed [7:0] value_mem      [0:31];
    reg signed [7:0] attn_mix_mem   [0:7];
    reg signed [7:0] mix_mem        [0:7];
    reg signed [7:0] final_mem      [0:7];
    reg        [7:0] attn_weight_mem[0:7];

    function signed [7:0] sat8;
        input signed [31:0] value;
        begin
            if (value > 127)
                sat8 = 8'sd127;
            else if (value < -128)
                sat8 = -8'sd128;
            else
                sat8 = value[7:0];
        end
    endfunction

    function signed [3:0] coeff4;
        input integer seed;
        input integer row_idx;
        input integer col_idx;
        reg   [7:0] mix;
        begin
            mix = seed + (row_idx * 3) + (col_idx * 5) + (row_idx * col_idx);
            case (mix % 7)
                0: coeff4 = -4;
                1: coeff4 = -3;
                2: coeff4 = -2;
                3: coeff4 = -1;
                4: coeff4 = 1;
                5: coeff4 = 2;
                default: coeff4 = 3;
            endcase
        end
    endfunction

    function signed [7:0] sigmoid_q44;
        input signed [7:0] x;
        reg   [7:0] abs_x;
        reg   [7:0] pos;
        begin
            abs_x = x[7] ? -x : x;
            if (abs_x >= 8'd48)
                pos = 8'd16;
            else if (abs_x >= 8'd24)
                pos = (abs_x >>> 4) + 8'd10;
            else
                pos = (abs_x >>> 3) + 8'd8;

            if (x[7])
                sigmoid_q44 = 8'sd16 - $signed({1'b0, pos[6:0]});
            else
                sigmoid_q44 = $signed({1'b0, pos[6:0]});
        end
    endfunction

    function signed [7:0] gelu_q44;
        input signed [7:0] x;
        reg   signed [7:0] scaled_x;
        reg   signed [7:0] sig_x;
        reg   signed [31:0] prod;
        begin
            scaled_x = sat8(($signed(x) * 3) >>> 1);
            sig_x    = sigmoid_q44(scaled_x);
            prod     = $signed(x) * $signed(sig_x);
            gelu_q44 = sat8(prod >>> 4);
        end
    endfunction

    function [7:0] exp_weight;
        input signed [7:0] x;
        begin
            if (x <= -8'sd48)
                exp_weight = 8'd2;
            else if (x <= -8'sd24)
                exp_weight = 8'd4;
            else if (x <= -8'sd8)
                exp_weight = 8'd8;
            else if (x <= 8'sd8)
                exp_weight = 8'd16 + (x[7] ? 8'd0 : {4'b0, x[3:1]});
            else if (x <= 8'sd24)
                exp_weight = 8'd28 + {3'b0, x[4:1]};
            else
                exp_weight = 8'd48;
        end
    endfunction

    function [2:0] norm_shift;
        input integer weight_sum;
        begin
            if (weight_sum >= 10'd160)
                norm_shift = 3'd6;
            else if (weight_sum >= 10'd96)
                norm_shift = 3'd5;
            else
                norm_shift = 3'd4;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (idx = 0; idx < 8; idx = idx + 1) begin
                query_mem[idx]       <= 8'sd0;
                q_proj_mem[idx]      <= 8'sd0;
                attn_mix_mem[idx]    <= 8'sd0;
                mix_mem[idx]         <= 8'sd0;
                final_mem[idx]       <= 8'sd0;
                attn_weight_mem[idx] <= 8'd0;
            end

            for (idx = 0; idx < 32; idx = idx + 1) begin
                context_mem[idx] <= 8'sd0;
                key_mem[idx]     <= 8'sd0;
                value_mem[idx]   <= 8'sd0;
            end
        end else begin
            if (write_query)
                query_mem[feature_idx] <= data_in;

            if (write_context)
                context_mem[{slot_sel, feature_idx}] <= data_in;

            if (stage_proj) begin
                for (row = 0; row < 8; row = row + 1) begin
                    acc = 0;
                    for (col = 0; col < 8; col = col + 1)
                        acc = acc + query_mem[col] * coeff4(1, row, col);
                    q_proj_mem[row] <= sat8(acc >>> 4);
                end

                for (token = 0; token < 4; token = token + 1) begin
                    token_base = token * 8;
                    for (row = 0; row < 8; row = row + 1) begin
                        acc = 0;
                        for (col = 0; col < 8; col = col + 1)
                            acc = acc + context_mem[token_base + col] * coeff4(5, row, col);
                        key_mem[token_base + row] <= sat8(acc >>> 4);

                        acc = 0;
                        for (col = 0; col < 8; col = col + 1)
                            acc = acc + context_mem[token_base + col] * coeff4(9, row, col);
                        value_mem[token_base + row] <= sat8(acc >>> 4);
                    end
                end
            end

            if (stage_attn) begin
                for (head = 0; head < 2; head = head + 1) begin
                    head_base = head * 4;
                    denom = 0;

                    for (token = 0; token < 4; token = token + 1) begin
                        token_base = token * 8;
                        score_acc = 0;
                        for (dim = 0; dim < 4; dim = dim + 1)
                            score_acc = score_acc + q_proj_mem[head_base + dim] * key_mem[token_base + head_base + dim];
                        weight_now = exp_weight(sat8(score_acc >>> 8));
                        attn_weight_mem[head_base + token] <= weight_now[7:0];
                        denom = denom + weight_now;
                    end

                    shift_amt = norm_shift(denom);
                    for (dim = 0; dim < 4; dim = dim + 1) begin
                        acc = 0;
                        for (token = 0; token < 4; token = token + 1) begin
                            token_base = token * 8;
                            score_acc = 0;
                            for (col = 0; col < 4; col = col + 1)
                                score_acc = score_acc + q_proj_mem[head_base + col] * key_mem[token_base + head_base + col];
                            weight_now = exp_weight(sat8(score_acc >>> 8));
                            acc = acc + weight_now * value_mem[token_base + head_base + dim];
                        end
                        attn_mix_mem[head_base + dim] <= sat8(acc >>> shift_amt);
                    end
                end
            end

            if (stage_mix) begin
                for (row = 0; row < 8; row = row + 1) begin
                    acc = 0;
                    for (col = 0; col < 8; col = col + 1)
                        acc = acc + attn_mix_mem[col] * coeff4(11, row, col);
                    mix_mem[row] <= sat8(query_mem[row] + (acc >>> 4));
                end
            end

            if (stage_ffn) begin
                for (row = 0; row < 8; row = row + 1) begin
                    final_acc = 0;
                    for (hidden_idx = 0; hidden_idx < 16; hidden_idx = hidden_idx + 1) begin
                        hidden_acc = 0;
                        for (col = 0; col < 8; col = col + 1)
                            hidden_acc = hidden_acc + mix_mem[col] * coeff4(13, hidden_idx, col);
                        final_acc = final_acc + gelu_q44(sat8(hidden_acc >>> 4)) * coeff4(3, row, hidden_idx);
                    end
                    final_mem[row] <= sat8(mix_mem[row] + (final_acc >>> 5));
                end
            end
        end
    end

    always @(*) begin
        case (slot_sel)
            2'b00: read_data = final_mem[feature_idx];
            2'b01: read_data = mix_mem[feature_idx];
            2'b10: read_data = q_proj_mem[feature_idx];
            default: read_data = attn_weight_mem[feature_idx];
        endcase
    end

endmodule
