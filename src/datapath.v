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

    integer init_i;

    reg signed [7:0] query_mem       [0:7];
    reg signed [7:0] context_mem     [0:31];
    reg signed [7:0] q_proj_mem      [0:7];
    reg signed [7:0] key_mem         [0:31];
    reg signed [7:0] value_mem       [0:31];
    reg signed [7:0] attn_mix_mem    [0:7];
    reg signed [7:0] mix_mem         [0:7];
    reg signed [7:0] hidden_mem      [0:15];
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
    reg [4:0] hidden_idx;
    reg [9:0] denom_reg;
    reg [2:0] shift_reg;
    reg       gelu_phase;
    reg signed [15:0] acc_reg;
    reg signed [7:0] gelu_in_q;

    reg signed [3:0] coeff_proj_q [0:63];
    reg signed [3:0] coeff_proj_k [0:63];
    reg signed [3:0] coeff_proj_v [0:63];
    reg signed [3:0] coeff_mix    [0:63];
    reg signed [3:0] coeff_ffn_h  [0:127];
    reg signed [3:0] coeff_ffn_o  [0:127];

    reg signed [7:0]  sample;
    reg signed [11:0] product;
    reg signed [15:0] acc_calc;

    function signed [7:0] sat8;
        input signed [15:0] value;
        begin
            if (value > 16'sd127)
                sat8 = 8'sd127;
            else if (value < -16'sd128)
                sat8 = -8'sd128;
            else
                sat8 = value[7:0];
        end
    endfunction

    function signed [7:0] sigmoid_q44;
        input signed [7:0] x;
        reg [7:0] abs_x;
        reg [7:0] pos;
        begin
            abs_x = x[7] ? (-x) : x;
            if (abs_x >= 8'd48)
                pos = 8'd16;
            else if (abs_x >= 8'd24)
                pos = (abs_x >>> 4) + 8'd10;
            else
                pos = (abs_x >>> 3) + 8'd8;

            if (x[7])
                sigmoid_q44 = sat8(16'sd16 - {8'd0, pos});
            else
                sigmoid_q44 = {1'b0, pos[6:0]};
        end
    endfunction

    function signed [7:0] gelu_q44;
        input signed [7:0] x;
        reg signed [7:0] scaled_x;
        reg signed [7:0] sig_x;
        reg signed [15:0] prod;
        begin
            scaled_x = sat8(($signed({{8{x[7]}}, x}) * 16'sd3) >>> 1);
            sig_x    = sigmoid_q44(scaled_x);
            prod     = $signed({{8{x[7]}}, x}) * $signed({{8{sig_x[7]}}, sig_x});
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
        input [9:0] weight_sum;
        begin
            if (weight_sum >= 10'd160)
                norm_shift = 3'd6;
            else if (weight_sum >= 10'd96)
                norm_shift = 3'd5;
            else
                norm_shift = 3'd4;
        end
    endfunction

    function signed [3:0] coeff4_fn;
        input integer seed;
        input integer row_sel;
        input integer col_sel;
        integer mix;
        begin
            mix = (seed + (row_sel * 3) + (col_sel * 5) + (row_sel * col_sel)) % 7;
            case (mix)
                0: coeff4_fn = -4;
                1: coeff4_fn = -3;
                2: coeff4_fn = -2;
                3: coeff4_fn = -1;
                4: coeff4_fn = 1;
                5: coeff4_fn = 2;
                default: coeff4_fn = 3;
            endcase
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
            hidden_idx <= 5'd0;
            denom_reg  <= 10'd0;
            shift_reg  <= 3'd4;
            gelu_phase <= 1'b0;
            gelu_in_q  <= 8'sd0;
            acc_reg    <= 16'sd0;

            for (init_i = 0; init_i < 64; init_i = init_i + 1) begin
                coeff_proj_q[init_i] <= coeff4_fn(1,  init_i[5:3], init_i[2:0]);
                coeff_proj_k[init_i] <= coeff4_fn(5,  init_i[5:3], init_i[2:0]);
                coeff_proj_v[init_i] <= coeff4_fn(9,  init_i[5:3], init_i[2:0]);
                coeff_mix[init_i]    <= coeff4_fn(11, init_i[5:3], init_i[2:0]);
            end
            for (init_i = 0; init_i < 128; init_i = init_i + 1) begin
                coeff_ffn_h[init_i] <= coeff4_fn(13, init_i[6:3], init_i[2:0]);
                coeff_ffn_o[init_i] <= coeff4_fn(3,  init_i[6:3], init_i[2:0]);
            end

            for (init_i = 0; init_i < 8; init_i = init_i + 1) begin
                query_mem[init_i]       <= 8'sd0;
                q_proj_mem[init_i]      <= 8'sd0;
                attn_mix_mem[init_i]    <= 8'sd0;
                mix_mem[init_i]         <= 8'sd0;
                final_mem[init_i]       <= 8'sd0;
                attn_weight_mem[init_i] <= 8'd0;
            end
            for (init_i = 0; init_i < 16; init_i = init_i + 1)
                hidden_mem[init_i] <= 8'sd0;
            for (init_i = 0; init_i < 32; init_i = init_i + 1) begin
                context_mem[init_i] <= 8'sd0;
                key_mem[init_i]     <= 8'sd0;
                value_mem[init_i]   <= 8'sd0;
            end
        end else begin
            if (write_query)
                query_mem[feature_idx] <= data_in;

            if (write_context)
                context_mem[{slot_sel, feature_idx}] <= data_in;

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
                hidden_idx <= 5'd0;
                denom_reg  <= 10'd0;
                shift_reg  <= 3'd4;
                gelu_phase <= 1'b0;
                gelu_in_q  <= 8'sd0;
                acc_reg    <= 16'sd0;
            end else if (busy) begin
                case (state)
                    STATE_PROJ: begin
                        if (proj_mode == PROJ_QUERY)
                            sample = query_mem[col_idx];
                        else
                            sample = context_mem[{token_idx, col_idx}];

                        if (proj_mode == PROJ_QUERY)
                            product = sample * coeff_proj_q[{row_idx, col_idx}];
                        else if (proj_mode == PROJ_KEY)
                            product = sample * coeff_proj_k[{row_idx, col_idx}];
                        else
                            product = sample * coeff_proj_v[{row_idx, col_idx}];

                        acc_calc = acc_reg + {{4{product[11]}}, product};

                        if (col_idx == 3'd7) begin
                            if (proj_mode == PROJ_QUERY)
                                q_proj_mem[row_idx] <= sat8(acc_calc >>> 4);
                            else if (proj_mode == PROJ_KEY)
                                key_mem[{token_idx, row_idx}] <= sat8(acc_calc >>> 4);
                            else
                                value_mem[{token_idx, row_idx}] <= sat8(acc_calc >>> 4);

                            if (row_idx == 3'd7) begin
                                if (proj_mode == PROJ_QUERY) begin
                                    proj_mode <= PROJ_KEY;
                                    row_idx   <= 3'b000;
                                    token_idx <= 2'b00;
                                end else if (proj_mode == PROJ_KEY) begin
                                    if (token_idx == 2'd3) begin
                                        proj_mode <= PROJ_VALUE;
                                        row_idx   <= 3'b000;
                                        token_idx <= 2'b00;
                                    end else begin
                                        row_idx   <= 3'b000;
                                        token_idx <= token_idx + 2'd1;
                                    end
                                end else begin
                                    if (token_idx == 2'd3) begin
                                        state     <= STATE_ATTN;
                                        head_idx  <= 2'b00;
                                        attn_mode <= ATTN_WEIGHT;
                                        token_idx <= 2'b00;
                                        out_dim   <= 2'b00;
                                        col_idx   <= 3'b000;
                                        denom_reg <= 10'd0;
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
                            acc_reg <= acc_calc[15:0];
                        end
                    end

                    STATE_ATTN: begin
                        if (attn_mode == ATTN_WEIGHT) begin
                            product  = q_proj_mem[{head_idx, col_idx[1:0]}] * key_mem[{token_idx, head_idx, col_idx[1:0]}];
                            acc_calc = acc_reg + {{4{product[11]}}, product};

                            if (col_idx[1:0] == 2'd3) begin
                                attn_weight_mem[{head_idx, token_idx}] <= exp_weight(sat8(acc_calc >>> 8));

                                if (token_idx == 2'd3) begin
                                    attn_mode <= ATTN_MIX;
                                    token_idx <= 2'b00;
                                    out_dim   <= 2'b00;
                                    col_idx   <= 3'b000;
                                    shift_reg <= norm_shift(denom_reg + {2'b0, exp_weight(sat8(acc_calc >>> 8))});
                                    acc_reg   <= 16'sd0;
                                end else begin
                                    token_idx <= token_idx + 2'd1;
                                    col_idx   <= 3'b000;
                                    acc_reg   <= 16'sd0;
                                end

                                denom_reg <= denom_reg + {2'b0, exp_weight(sat8(acc_calc >>> 8))};
                            end else begin
                                col_idx <= col_idx + 3'd1;
                                acc_reg <= acc_calc[15:0];
                            end
                        end else begin
                            acc_calc = acc_reg + ({{4{1'b0}}, attn_weight_mem[{head_idx, token_idx}]} * $signed({{8{value_mem[{token_idx, head_idx, out_dim[1:0]}][7]}}, value_mem[{token_idx, head_idx, out_dim[1:0]}]}));

                            if (token_idx == 2'd3) begin
                                attn_mix_mem[{head_idx, out_dim}] <= sat8(acc_calc >>> shift_reg);

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
                                        denom_reg  <= 10'd0;
                                    end
                                end else begin
                                    out_dim   <= out_dim + 2'd1;
                                    token_idx <= 2'b00;
                                end

                                acc_reg <= 16'sd0;
                            end else begin
                                token_idx <= token_idx + 2'd1;
                                acc_reg   <= acc_calc[15:0];
                            end
                        end
                    end

                    STATE_MIX: begin
                        product  = attn_mix_mem[col_idx] * coeff_mix[{row_idx, col_idx}];
                        acc_calc = acc_reg + {{4{product[11]}}, product};

                        if (col_idx == 3'd7) begin
                            mix_mem[row_idx] <= sat8({{8{query_mem[row_idx][7]}}, query_mem[row_idx]} + (acc_calc >>> 4));

                            if (row_idx == 3'd7) begin
                                state      <= STATE_FFN;
                                ffn_mode   <= FFN_HIDDEN;
                                hidden_idx <= 5'd0;
                                row_idx    <= 3'b000;
                                gelu_phase <= 1'b0;
                            end else begin
                                row_idx <= row_idx + 3'd1;
                            end

                            col_idx <= 3'b000;
                            acc_reg <= 16'sd0;
                        end else begin
                            col_idx <= col_idx + 3'd1;
                            acc_reg <= acc_calc[15:0];
                        end
                    end

                    STATE_FFN: begin
                        if (ffn_mode == FFN_HIDDEN) begin
                            if (gelu_phase == 1'b0) begin
                                product  = mix_mem[col_idx] * coeff_ffn_h[{hidden_idx, col_idx}];
                                acc_calc = acc_reg + {{4{product[11]}}, product};

                                if (col_idx == 3'd7) begin
                                    gelu_in_q  <= sat8(acc_calc >>> 4);
                                    gelu_phase <= 1'b1;
                                    col_idx    <= 3'b000;
                                    acc_reg    <= 16'sd0;
                                end else begin
                                    col_idx <= col_idx + 3'd1;
                                    acc_reg <= acc_calc[15:0];
                                end
                            end else begin
                                hidden_mem[hidden_idx] <= gelu_q44(gelu_in_q);
                                gelu_phase <= 1'b0;

                                if (hidden_idx == 5'd15) begin
                                    ffn_mode   <= FFN_OUTPUT;
                                    row_idx    <= 3'b000;
                                    hidden_idx <= 5'd0;
                                end else begin
                                    hidden_idx <= hidden_idx + 5'd1;
                                end
                            end
                        end else begin
                            product  = hidden_mem[hidden_idx[3:0]] * coeff_ffn_o[{row_idx, hidden_idx[3:0]}];
                            acc_calc = acc_reg + {{4{product[11]}}, product};

                            if (hidden_idx == 5'd15) begin
                                final_mem[row_idx] <= sat8({{8{mix_mem[row_idx][7]}}, mix_mem[row_idx]} + (acc_calc >>> 5));

                                if (row_idx == 3'd7) begin
                                    busy  <= 1'b0;
                                    done  <= 1'b1;
                                    state <= STATE_IDLE;
                                end else begin
                                    row_idx <= row_idx + 3'd1;
                                end

                                hidden_idx <= 5'd0;
                                acc_reg    <= 16'sd0;
                            end else begin
                                hidden_idx <= hidden_idx + 5'd1;
                                acc_reg    <= acc_calc[15:0];
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
