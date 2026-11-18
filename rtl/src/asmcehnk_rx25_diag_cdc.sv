// Bounded diagnostic mailbox. Both resets must be asserted for a new epoch;
// neither reset constitutes PCIe/host-DMA draining or automatic retry.
`resetall
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_diag_cdc #(
    parameter int C_RESPONSE_LIMIT=500000,
    parameter int C_BANK_WIDTH=512
)(
    input wire logic p_clk,p_rst,
    input wire logic command_valid,
    output wire logic command_ready,
    input wire logic [1:0] command_opcode, // 1 ARM, 2 CAPTURE; others reject
    input wire logic [31:0] command_nonce,
    output wire logic response_valid,
    input wire logic response_ready,
    output wire logic [1:0] response_kind, // 0 bridge fault, 1 ARM ACK, 2 reject, 3 snapshot
    output wire logic [1:0] response_opcode,
    output wire logic [31:0] response_nonce,
    output wire logic [C_BANK_WIDTH-1:0] response_registers,
    output wire logic p_busy,
    output logic p_fault,
    input wire logic n_clk,n_rst,
    output wire logic net_arm_valid,net_capture_valid,
    output wire logic [31:0] net_command_nonce,
    input wire logic net_arm_accepted,net_command_rejected,net_snapshot_valid,
    input wire logic [C_BANK_WIDTH-1:0] net_registers,
    output logic n_fault
);
    // KEEP is disabled: DEPTH=4 means four complete messages, irrespective of
    // the width. Each complete result crosses as one FIFO word, never bitwise.
    taxi_axis_if #(.DATA_W(34),.KEEP_EN(0),.LAST_EN(0)) cmd_tx(),cmd_rx();
    taxi_axis_if #(.DATA_W(C_BANK_WIDTH+36),.KEEP_EN(0),.LAST_EN(0)) result_tx(),result_rx();
    logic outstanding;
    logic [1:0] expected_opcode;
    logic [31:0] expected_nonce;
    assign command_ready=cmd_tx.tready && !outstanding && !p_fault && !p_rst;
    assign cmd_tx.tvalid=command_valid && !outstanding && !p_fault && !p_rst;
    assign cmd_tx.tdata={command_opcode,command_nonce};
    assign cmd_tx.tkeep='1;
    assign cmd_tx.tstrb='1;
    assign cmd_tx.tlast=1'b1;
    assign cmd_tx.tid=0;
    assign cmd_tx.tdest=0;
    assign cmd_tx.tuser=0;
    assign p_busy=outstanding;
    assign response_valid=result_rx.tvalid && outstanding && !p_rst;
    assign result_rx.tready=response_ready && outstanding && !p_rst;
    assign {response_kind,response_opcode,response_nonce,response_registers}=result_rx.tdata;
    wire response_identity_ok=response_opcode==expected_opcode && response_nonce==expected_nonce;
    wire response_type_ok=response_kind==2 ||
        (response_kind==1 && expected_opcode==1) ||
        (response_kind==3 && expected_opcode==2);
    always_ff @(posedge p_clk) begin
        if(p_rst) begin
            outstanding<=0;p_fault<=0;expected_opcode<=0;expected_nonce<=0;
        end else begin
            if(command_valid && command_ready) begin
                outstanding<=1;expected_opcode<=command_opcode;expected_nonce<=command_nonce;
            end
            if(result_rx.tvalid && (!outstanding || !response_identity_ok || !response_type_ok)) p_fault<=1;
            if(response_valid && response_ready) outstanding<=0;
        end
    end
    taxi_axis_async_fifo #(.DEPTH(4),.RAM_PIPELINE(1),.FRAME_FIFO(0)) commands(
        .s_clk(p_clk),.s_rst(p_rst),.s_axis(cmd_tx),.m_clk(n_clk),.m_rst(n_rst),.m_axis(cmd_rx),
        .s_pause_req(1'b0),.m_pause_req(1'b0));
    taxi_axis_async_fifo #(.DEPTH(4),.RAM_PIPELINE(1),.FRAME_FIFO(0)) results(
        .s_clk(n_clk),.s_rst(n_rst),.s_axis(result_tx),.m_clk(p_clk),.m_rst(p_rst),.m_axis(result_rx),
        .s_pause_req(1'b0),.m_pause_req(1'b0));

    localparam [1:0] IDLE=0,ISSUE=1,WAIT_RESULT=2,SEND=3;
    logic [1:0] state,opcode;
    logic [31:0] nonce,age;
    logic [C_BANK_WIDTH+35:0] held_result;
    assign cmd_rx.tready=state==IDLE && !n_rst;
    assign net_arm_valid=state==ISSUE && opcode==1 && C_RESPONSE_LIMIT>=1 && !n_fault && !n_rst;
    assign net_capture_valid=state==ISSUE && opcode==2 && C_RESPONSE_LIMIT>=1 && !n_fault && !n_rst;
    assign net_command_nonce=nonce;
    assign result_tx.tvalid=state==SEND && !n_rst;
    assign result_tx.tdata=held_result;
    assign result_tx.tkeep='1;
    assign result_tx.tstrb='1;
    assign result_tx.tlast=1;
    assign result_tx.tid=0;
    assign result_tx.tdest=0;
    assign result_tx.tuser=0;
    wire any_event=net_arm_accepted || net_command_rejected || net_snapshot_valid;
    wire multiple_events=(net_arm_accepted && net_command_rejected) ||
        (net_arm_accepted && net_snapshot_valid) || (net_command_rejected && net_snapshot_valid);
    wire result_type_ok=net_command_rejected ||
        (net_arm_accepted && opcode==1) || (net_snapshot_valid && opcode==2);
    always_ff @(posedge n_clk) begin
        if(n_rst) begin state<=IDLE;opcode<=0;nonce<=0;age<=0;held_result<=0;n_fault<=0;end
        else begin
            // Unexpected notifications are a terminal protocol error, not a
            // reason to reinterpret a later event as the current command.
            if(any_event && state!=WAIT_RESULT) n_fault<=1;
            case(state)
                IDLE: if(cmd_rx.tvalid && cmd_rx.tready) begin
                    opcode<=cmd_rx.tdata[33:32];nonce<=cmd_rx.tdata[31:0];state<=ISSUE;
                end
                ISSUE: begin
                    age<=0;
                    if(n_fault || C_RESPONSE_LIMIT<1) begin
                        n_fault<=1;held_result<={2'd0,opcode,nonce,net_registers};state<=SEND;
                    end else if(opcode!=1 && opcode!=2) begin
                        held_result<={2'd2,opcode,nonce,net_registers};state<=SEND;
                    end else state<=WAIT_RESULT;
                end
                WAIT_RESULT: begin
                    if(any_event) begin
                        if(multiple_events || !result_type_ok || n_fault) begin
                            n_fault<=1;held_result<={2'd0,opcode,nonce,net_registers};
                        end else if(net_command_rejected) held_result<={2'd2,opcode,nonce,net_registers};
                        else if(net_arm_accepted) held_result<={2'd1,opcode,nonce,net_registers};
                        else held_result<={2'd3,opcode,nonce,net_registers};
                        state<=SEND;
                    end else if(age>=32'(C_RESPONSE_LIMIT-1)) begin
                        n_fault<=1;held_result<={2'd0,opcode,nonce,net_registers};state<=SEND;
                    end else age<=age+1;
                end
                SEND: if(result_tx.tvalid && result_tx.tready) state<=IDLE;
                default: begin state<=IDLE;n_fault<=1;end
            endcase
        end
    end
endmodule
`default_nettype wire
