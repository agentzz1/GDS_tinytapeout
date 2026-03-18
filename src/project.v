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

    localparam CMD_LOAD_QUERY   = 2'b00;
    localparam CMD_LOAD_CONTEXT = 2'b01;
    localparam CMD_CONTROL      = 2'b10;
    localparam CMD_READ_BANK    = 2'b11;

    wire [1:0] slot_sel    = uio_in[1:0];
    wire [2:0] feature_idx = uio_in[4:2];
    wire [1:0] cmd         = uio_in[6:5];
    wire       cmd_strobe  = uio_in[7];

    wire       write_query;
    wire       write_context;
    wire       stage_proj;
    wire       stage_attn;
    wire       stage_mix;
    wire       stage_ffn;
    wire       busy;
    wire       done;
    wire [2:0] state;
    wire [7:0] read_data;
    wire [7:0] status_word;

    control u_control (
        .clk           (clk),
        .rst_n         (rst_n),
        .cmd_strobe    (cmd_strobe),
        .cmd           (cmd),
        .feature_idx   (feature_idx),
        .write_query   (write_query),
        .write_context (write_context),
        .stage_proj    (stage_proj),
        .stage_attn    (stage_attn),
        .stage_mix     (stage_mix),
        .stage_ffn     (stage_ffn),
        .busy          (busy),
        .done          (done),
        .state         (state)
    );

    datapath u_datapath (
        .clk           (clk),
        .rst_n         (rst_n),
        .write_query   (write_query),
        .write_context (write_context),
        .stage_proj    (stage_proj),
        .stage_attn    (stage_attn),
        .stage_mix     (stage_mix),
        .stage_ffn     (stage_ffn),
        .slot_sel      (slot_sel),
        .feature_idx   (feature_idx),
        .data_in       (ui_in),
        .read_data     (read_data)
    );

    assign status_word = {done, busy, (cmd == CMD_READ_BANK), state, 2'b00};
    assign uo_out      = (cmd == CMD_READ_BANK) ? read_data : status_word;

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    wire _unused = &{ena, 1'b0, cmd == CMD_LOAD_QUERY, cmd == CMD_LOAD_CONTEXT, cmd == CMD_CONTROL};

endmodule
