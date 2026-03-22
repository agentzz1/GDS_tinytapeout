// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module control (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cmd_strobe,
    input  wire [1:0] cmd,
    input  wire [2:0] feature_idx,
    output wire       write_query,
    output wire       write_context,
    output wire       stage_proj,
    output wire       stage_attn,
    output wire       stage_mix,
    output wire       stage_ffn,
    output wire       busy,
    output wire       done,
    output wire [2:0] state
);

    localparam CMD_LOAD_QUERY   = 2'b00;
    localparam CMD_LOAD_CONTEXT = 2'b01;
    localparam CMD_CONTROL      = 2'b10;

    localparam STATE_IDLE = 3'b000;
    localparam STATE_PROJ = 3'b001;
    localparam STATE_ATTN = 3'b010;
    localparam STATE_MIX  = 3'b011;
    localparam STATE_FFN  = 3'b100;

    reg [2:0] state_reg;
    reg       done_reg;

    wire execute_req = cmd_strobe && (cmd == CMD_CONTROL) && (feature_idx == 3'b111) && (state_reg == STATE_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= STATE_IDLE;
            done_reg  <= 1'b0;
        end else begin
            case (state_reg)
                STATE_IDLE: begin
                    if (execute_req) begin
                        state_reg <= STATE_PROJ;
                        done_reg  <= 1'b0;
                    end
                end
                STATE_PROJ: begin
                    state_reg <= STATE_ATTN;
                end
                STATE_ATTN: begin
                    state_reg <= STATE_MIX;
                end
                STATE_MIX: begin
                    state_reg <= STATE_FFN;
                end
                STATE_FFN: begin
                    state_reg <= STATE_IDLE;
                    done_reg  <= 1'b1;
                end
                default: begin
                    state_reg <= STATE_IDLE;
                    done_reg  <= 1'b0;
                end
            endcase
        end
    end

    assign write_query   = cmd_strobe && (cmd == CMD_LOAD_QUERY) && (state_reg == STATE_IDLE);
    assign write_context = cmd_strobe && (cmd == CMD_LOAD_CONTEXT) && (state_reg == STATE_IDLE);
    assign stage_proj    = (state_reg == STATE_PROJ);
    assign stage_attn    = (state_reg == STATE_ATTN);
    assign stage_mix     = (state_reg == STATE_MIX);
    assign stage_ffn     = (state_reg == STATE_FFN);
    assign busy          = (state_reg != STATE_IDLE);
    assign done          = done_reg;
    assign state         = state_reg;

endmodule
