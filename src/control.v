// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module control (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [2:0] op_select,
    input  wire       zero_flag,
    input  wire       carry_flag,
    output wire       load_a,
    output wire       load_b,
    output wire [2:0] alu_op,
    output wire       result_valid,
    output wire       busy
);

    localparam IDLE    = 3'b000;
    localparam LOAD    = 3'b001;
    localparam EXECUTE = 3'b010;
    localparam DONE    = 3'b011;

    reg [2:0] state, next_state;
    reg [2:0] op_reg;

    // State register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= IDLE;
            op_reg <= 3'b000;
        end else begin
            state <= next_state;
            if (state == IDLE && start)
                op_reg <= op_select;
        end
    end

    // Next-state logic
    always @(*) begin
        case (state)
            IDLE:    next_state = start ? LOAD : IDLE;
            LOAD:    next_state = EXECUTE;
            EXECUTE: next_state = DONE;
            DONE:    next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    // Moore outputs
    assign load_a        = (state == LOAD);
    assign load_b        = (state == LOAD);
    assign alu_op        = (state == EXECUTE || state == DONE) ? op_reg : 3'b000;
    assign result_valid  = (state == DONE);
    assign busy          = (state != IDLE);

endmodule
