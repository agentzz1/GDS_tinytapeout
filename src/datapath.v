// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module datapath (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              write_query,
    input  wire              write_context,
    input  wire              exec_start,
    input  wire        [1:0] slot_sel,
    input  wire        [2:0] feature_idx,
    input  wire signed [7:0] data_in,
    output reg               busy,
    output reg               done,
    output reg         [2:0] state,
    output reg         [7:0] read_data
);

    localparam STATE_IDLE = 3'b000;
    localparam STATE_PROJ = 3'b001;
    localparam STATE_ATTN = 3'b010;
    localparam STATE_MIX  = 3'b011;
    localparam STATE_FFN  = 3'b100;

    localparam PROJ_QUERY  = 2'd0;
    localparam PROJ_KEY    = 2'd1;
    localparam PROJ_VALUE  = 2'd2;

    localparam ATTN_WEIGHT = 1'b0;
    localparam ATTN_MIX    = 1'b1;

    localparam FFN_HIDDEN  = 1'b0;
    localparam FFN_OUTPUT  = 1'b1;

    integer idx;
    integer sample;
    integer product;
    integer acc_calc;
    integer head_base_next;
    integer weight_next;

    reg signed [7:0] query_mem       [0:7];
    reg signed [7:0] context_mem     [0:15];
    reg signed [7:0] q_proj_mem      [0:7];
    reg signed [7:0] key_mem         [0:15];
    reg signed [7:0] value_mem       [0:15];
    reg signed [7:0] attn_mix_mem    [0:7];
    reg signed [7:0] mix_mem         [0:7];
    reg signed [7:0] hidden_mem      [0:7];
    reg signed [7:0] final_mem       [0:7];
    reg        [7:0] attn_weight_mem [0:7];

    reg [1:0] proj_mode;
    reg [1:0] head_idx;
    reg       attn_mode;
    reg       ffn_mode;
    reg [2:0] row_idx;
    reg [1:0] token_idx;
    reg [2:0] col_idx;
    reg [1:0] out_dim;
    reg [2:0] hidden_idx;
    reg [7:0] denom_reg;
    reg [2:0] shift_reg;
    reg signed [15:0] acc_reg;

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
        input integer row_sel;
        input integer col_sel;
        integer mix;
        begin
            mix = (seed + (row_sel * 3) + (col_sel * 5) + (row_sel * col_sel)) % 7;
            case (mix)
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
        integer abs_x;
        integer pos;
        begin
            abs_x = x[7] ? -x : x;
            if (abs_x >= 48)
                pos = 16;
            else if (abs_x >= 24)
                pos = (abs_x >>> 4) + 10;
            else
                pos = (abs_x >>> 3) + 8;

            if (x[7])
                sigmoid_q44 = sat8(16 - pos);
            else
                sigmoid_q44 = sat8(pos);
        end
    endfunction

    function signed [7:0] gelu_q44;
        input signed [7:0] x;
        integer scaled_x;
        integer sig_x;
        integer prod;
        begin
            scaled_x = sat8(($signed(x) * 3) >>> 1);
            sig_x    = sigmoid_q44(scaled_x[7:0]);
            prod     = $signed(x) * sig_x;
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
                exp_weight = 8'd16 + (x[7] ? 8'd0 : {5'b0, x[3:1]});
            else if (x <= 8'sd24)
                exp_weight = 8'd28 + {4'b0, x[4:1]};
            else
                exp_weight = 8'd48;
        end
    endfunction

    function [2:0] norm_shift;
        input integer weight_sum;
        begin
            if (weight_sum >= 160)
                norm_shift = 3'd6;
            else if (weight_sum >= 96)
                norm_shift = 3'd5;
            else
                norm_shift = 3'd4;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            state      <= STATE_IDLE;
            proj_mode  <= PROJ_QUERY;
            head_idx   <= 2'b00;
            attn_mode  <= ATTN_WEIGHT;
            ffn_mode   <= FFN_HIDDEN;
            row_idx    <= 3'b000;
            token_idx  <= 2'b00;
            col_idx    <= 3'b000;
            out_dim    <= 2'b00;
            hidden_idx <= 3'd0;
            denom_reg  <= 8'd0;
            shift_reg  <= 3'd4;
            acc_reg    <= 16'sd0;

            for (idx = 0; idx < 8; idx = idx + 1) begin
                query_mem[idx]       <= 8'sd0;
                q_proj_mem[idx]      <= 8'sd0;
                attn_mix_mem[idx]    <= 8'sd0;
                mix_mem[idx]         <= 8'sd0;
                final_mem[idx]       <= 8'sd0;
                attn_weight_mem[idx] <= 8'd0;
            end

            for (idx = 0; idx < 8; idx = idx + 1)
                hidden_mem[idx] <= 8'sd0;

            for (idx = 0; idx < 16; idx = idx + 1) begin
                context_mem[idx] <= 8'sd0;
                key_mem[idx]     <= 8'sd0;
                value_mem[idx]   <= 8'sd0;
            end
        end else begin
            if (write_query)
                query_mem[feature_idx] <= data_in;

            if (write_context)
                context_mem[{slot_sel[0], feature_idx[2:0]}] <= data_in;

            if (exec_start) begin
                busy       <= 1'b1;
                done       <= 1'b0;
                state      <= STATE_PROJ;
                proj_mode  <= PROJ_QUERY;
                head_idx   <= 2'b00;
                attn_mode  <= ATTN_WEIGHT;
                ffn_mode   <= FFN_HIDDEN;
                row_idx    <= 3'b000;
                token_idx  <= 2'b00;
                col_idx    <= 3'b000;
                out_dim    <= 2'b00;
                hidden_idx <= 3'd0;
                denom_reg  <= 8'd0;
                shift_reg  <= 3'd4;
                acc_reg    <= 16'sd0;
            end else if (busy) begin
                case (state)
                    STATE_PROJ: begin
                        if (proj_mode == PROJ_QUERY)
                            sample = query_mem[col_idx];
                        else
                            sample = context_mem[(token_idx * 8) + col_idx];

                        if (proj_mode == PROJ_QUERY)
                            product = sample * coeff4(1, row_idx, col_idx);
                        else if (proj_mode == PROJ_KEY)
                            product = sample * coeff4(5, row_idx, col_idx);
                        else
                            product = sample * coeff4(9, row_idx, col_idx);

                        acc_calc = acc_reg + product;

                        if (col_idx == 3'd7) begin
                            if (proj_mode == PROJ_QUERY)
                                q_proj_mem[row_idx] <= sat8(acc_calc >>> 4);
                            else if (proj_mode == PROJ_KEY)
                                key_mem[(token_idx * 8) + row_idx] <= sat8(acc_calc >>> 4);
                            else
                                value_mem[(token_idx * 8) + row_idx] <= sat8(acc_calc >>> 4);

                            if (row_idx == 3'd7) begin
                                if (proj_mode == PROJ_QUERY) begin
                                    proj_mode <= PROJ_KEY;
                                    row_idx   <= 3'b000;
                                    token_idx <= 2'b00;
                                end else if (proj_mode == PROJ_KEY) begin
                                    if (token_idx == 2'd1) begin
                                        proj_mode <= PROJ_VALUE;
                                        row_idx   <= 3'b000;
                                        token_idx <= 2'b00;
                                    end else begin
                                        row_idx   <= 3'b000;
                                        token_idx <= token_idx + 2'd1;
                                    end
                                end else begin
                                    if (token_idx == 2'd1) begin
                                        state     <= STATE_ATTN;
                                        head_idx  <= 2'b00;
                                        attn_mode <= ATTN_WEIGHT;
                                        token_idx <= 2'b00;
                                        out_dim   <= 2'b00;
                                        col_idx   <= 3'b000;
                                        denom_reg <= 8'd0;
                                    end else begin
                                        row_idx   <= 3'b000;
                                        token_idx <= token_idx + 2'd1;
                                    end
                                end
                            end else begin
                                row_idx <= row_idx + 3'd1;
                            end

                            col_idx <= 3'b000;
                            acc_reg <= 16'sd0;
                        end else begin
                            col_idx <= col_idx + 3'd1;
                            acc_reg <= acc_calc;
                        end
                    end

                    STATE_ATTN: begin
                        head_base_next = head_idx * 4;

                        if (attn_mode == ATTN_WEIGHT) begin
                            product  = q_proj_mem[head_base_next + col_idx] * key_mem[(token_idx * 8) + head_base_next + col_idx];
                            acc_calc = acc_reg + product;

                            if (col_idx == 3'd3) begin
                                weight_next = exp_weight(sat8(acc_calc >>> 8));
                                attn_weight_mem[head_base_next + token_idx] <= weight_next[7:0];

                                if (token_idx == 2'd1) begin
                                    attn_mode <= ATTN_MIX;
                                    token_idx <= 2'b00;
                                    out_dim   <= 2'b00;
                                    col_idx   <= 3'b000;
                                    shift_reg <= norm_shift(denom_reg + weight_next);
                                    denom_reg <= 8'd0;
                                    acc_reg   <= 16'sd0;
                                end else begin
                                    token_idx <= token_idx + 2'd1;
                                    col_idx   <= 3'b000;
                                    denom_reg <= denom_reg + weight_next;
                                    acc_reg   <= 16'sd0;
                                end
                            end else begin
                                col_idx <= col_idx + 3'd1;
                                acc_reg <= acc_calc;
                            end
                        end else begin
                            weight_next = attn_weight_mem[head_base_next + token_idx];
                            acc_calc    = acc_reg + (weight_next * value_mem[(token_idx * 8) + head_base_next + out_dim]);

                            if (token_idx == 2'd1) begin
                                attn_mix_mem[head_base_next + out_dim] <= sat8(acc_calc >>> shift_reg);

                                if (out_dim == 2'd3) begin
                                    if (head_idx == 2'd1) begin
                                        state     <= STATE_MIX;
                                        row_idx   <= 3'b000;
                                        col_idx   <= 3'b000;
                                    end else begin
                                        head_idx   <= head_idx + 2'd1;
                                        attn_mode  <= ATTN_WEIGHT;
                                        token_idx  <= 2'b00;
                                        out_dim    <= 2'b00;
                                        col_idx    <= 3'b000;
                                        denom_reg  <= 8'd0;
                                    end
                                end else begin
                                    out_dim   <= out_dim + 2'd1;
                                    token_idx <= 2'b00;
                                end

                                acc_reg <= 16'sd0;
                            end else begin
                                token_idx <= token_idx + 2'd1;
                                acc_reg   <= acc_calc;
                            end
                        end
                    end

                    STATE_MIX: begin
                        acc_calc = acc_reg + (attn_mix_mem[col_idx] * coeff4(11, row_idx, col_idx));

                        if (col_idx == 3'd7) begin
                            mix_mem[row_idx] <= sat8(query_mem[row_idx] + (acc_calc >>> 4));

                            if (row_idx == 3'd7) begin
                                state      <= STATE_FFN;
                                ffn_mode   <= FFN_HIDDEN;
                                hidden_idx <= 3'd0;
                                row_idx    <= 3'b000;
                            end else begin
                                row_idx <= row_idx + 3'd1;
                            end

                            col_idx <= 3'b000;
                            acc_reg <= 16'sd0;
                        end else begin
                            col_idx <= col_idx + 3'd1;
                            acc_reg <= acc_calc;
                        end
                    end

                    STATE_FFN: begin
                        if (ffn_mode == FFN_HIDDEN) begin
                            acc_calc = acc_reg + (mix_mem[col_idx] * coeff4(13, hidden_idx, col_idx));

                            if (col_idx == 3'd7) begin
                                hidden_mem[hidden_idx] <= gelu_q44(sat8(acc_calc >>> 4));

                                if (hidden_idx == 3'd7) begin
                                    ffn_mode   <= FFN_OUTPUT;
                                    row_idx    <= 3'b000;
                                    hidden_idx <= 3'd0;
                                end else begin
                                    hidden_idx <= hidden_idx + 3'd1;
                                end

                                col_idx <= 3'b000;
                                acc_reg <= 16'sd0;
                            end else begin
                                col_idx <= col_idx + 3'd1;
                                acc_reg <= acc_calc;
                            end
                        end else begin
                            acc_calc = acc_reg + (hidden_mem[hidden_idx] * coeff4(3, row_idx, hidden_idx));

                            if (hidden_idx == 3'd7) begin
                                final_mem[row_idx] <= sat8(mix_mem[row_idx] + (acc_calc >>> 5));

                                if (row_idx == 3'd7) begin
                                    busy  <= 1'b0;
                                    done  <= 1'b1;
                                    state <= STATE_IDLE;
                                end else begin
                                    row_idx <= row_idx + 3'd1;
                                end

                                hidden_idx <= 3'd0;
                                acc_reg    <= 16'sd0;
                            end else begin
                                hidden_idx <= hidden_idx + 3'd1;
                                acc_reg    <= acc_calc;
                            end
                        end
                    end

                    default: begin
                        busy  <= 1'b0;
                        done  <= 1'b0;
                        state <= STATE_IDLE;
                    end
                endcase
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
