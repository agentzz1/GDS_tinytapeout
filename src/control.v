// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module control (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cmd_strobe,
    input  wire [1:0] cmd,
    input  wire [2:0] feature_idx,
    input  wire       datapath_busy,
    input  wire       datapath_done,
    input  wire [2:0] datapath_state,
    output wire       write_query,
    output wire       write_context,
    output wire       exec_start,
    output wire       busy,
    output wire       done,
    output wire [2:0] state
);

    localparam CMD_LOAD_QUERY   = 2'b00;
    localparam CMD_LOAD_CONTEXT = 2'b01;
    localparam CMD_CONTROL      = 2'b10;

    assign write_query   = cmd_strobe && (cmd == CMD_LOAD_QUERY) && !datapath_busy;
    assign write_context = cmd_strobe && (cmd == CMD_LOAD_CONTEXT) && !datapath_busy;
    assign exec_start    = cmd_strobe && (cmd == CMD_CONTROL) && (feature_idx == 3'b111) && !datapath_busy;

    assign busy  = datapath_busy;
    assign done  = datapath_done;
    assign state = datapath_state;

    wire _unused = &{clk, rst_n, 1'b0};

endmodule
