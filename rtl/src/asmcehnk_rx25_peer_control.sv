// A owns local+remote ARM/CAPTURE. B needs no host-side command producer.
// RXD2 travels outside checksum pause; only one transaction, no auto retry.
`resetall
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_peer_control #(
    parameter bit C_RESPONDER=0,
    parameter int C_WAIT_LIMIT=500000
)(
    input wire logic clk,rst,
    input wire logic arm_valid,capture_valid,
    input wire logic [31:0] command_nonce,
    output logic arm_accepted,command_rejected,snapshot_valid,
    output logic [511:0] peer_registers,
    output logic fault,
    output logic [31:0] fault_reason,rejected_commands,
    output wire logic local_arm_valid,local_capture_valid,
    output wire logic [31:0] local_nonce,
    input wire logic local_arm_accepted,local_rejected,local_snapshot_valid,
    input wire logic [511:0] local_registers,
    output wire logic tx_valid,
    input wire logic tx_ready,
    output wire logic [7:0] tx_opcode,
    output wire logic [31:0] tx_nonce,tx_status,
    output wire logic [511:0] tx_bank,
    input wire logic rx_valid,
    output wire logic rx_ready,
    input wire logic [7:0] rx_opcode,
    input wire logic [31:0] rx_nonce,rx_status,
    input wire logic [511:0] rx_bank
);
    localparam [2:0] IDLE=0,ISSUE_LOCAL=1,WAIT_LOCAL=2,SEND_PEER=3,WAIT_PEER=4,CHECK_PEER=5;
    logic [2:0] state;
    logic [7:0] opcode;
    logic [31:0] nonce,age,reply_status;
    logic [511:0] reply_bank;
    // Sample identity checks and data on the same accepted response. Commit on
    // the next clock so the nonce comparisons do not drive a 512-bit bank CE.
    logic peer_candidate_ok;
    logic [511:0] peer_candidate_bank;
    wire command_seen=arm_valid || capture_valid;
    wire nonce_ok=command_nonce[31:5]!=0 && command_nonce[4:0]==0;
    wire local_event=local_arm_accepted || local_rejected || local_snapshot_valid;
    wire local_event_ok=local_rejected ||
        (opcode==1 && local_arm_accepted && !local_snapshot_valid) ||
        (opcode==2 && local_snapshot_valid && !local_arm_accepted);
    wire local_bank_ok=local_registers[31:0]==32'h31535250 && local_registers[95:64]==nonce &&
        (opcode==1 ? (local_registers[33:32]==2'b11 && !local_registers[35]) : local_registers[36]);
    wire peer_bank_ok=rx_bank[31:0]==32'h31535250 && rx_bank[95:64]==nonce &&
        (opcode==1 ? (rx_bank[33:32]==2'b11 && !rx_bank[35]) : rx_bank[36]);
    assign local_arm_valid=state==ISSUE_LOCAL && opcode==1 && C_WAIT_LIMIT>=1 && !fault;
    assign local_capture_valid=state==ISSUE_LOCAL && opcode==2 && C_WAIT_LIMIT>=1 && !fault;
    assign local_nonce=nonce;
    assign tx_valid=state==SEND_PEER;
    assign tx_opcode=C_RESPONDER ? (8'h80|opcode) : opcode;
    assign tx_nonce=nonce;
    assign tx_status=C_RESPONDER ? reply_status : 32'd0;
    assign tx_bank=C_RESPONDER ? reply_bank : 512'd0;
    assign rx_ready=C_RESPONDER ? state==IDLE : state==WAIT_PEER || state==IDLE;
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;opcode<=0;nonce<=0;age<=0;reply_status<=0;reply_bank<=0;
            arm_accepted<=0;command_rejected<=0;snapshot_valid<=0;peer_registers<=0;
            peer_candidate_ok<=0;peer_candidate_bank<=0;
            fault<=0;fault_reason<=0;rejected_commands<=0;
        end else begin
            arm_accepted<=0;command_rejected<=0;snapshot_valid<=0;
            // tx_bank is consumed only with tx_valid. Sample the local bank on
            // a raw fault/disabled request handshake, before wide validation;
            // the complete validation below still owns SEND_PEER. Invalid
            // requests may update this idle data register but cannot send it.
            if(C_RESPONDER && state==IDLE && rx_valid && rx_ready && (fault || C_WAIT_LIMIT<1))
                reply_bank<=local_registers;
            if(command_seen && (C_RESPONDER || state!=IDLE)) begin
                // A caller must own a command until its result; an unrelated
                // second pulse cannot replace its nonce or retire it early.
                rejected_commands<=rejected_commands+1;
                if(C_RESPONDER) command_rejected<=1;
            end
            if(state!=IDLE && state!=SEND_PEER) age<=age+1;
            case(state)
                IDLE:begin
                    age<=0;
                    if(!C_RESPONDER && command_seen) begin
                        if(arm_valid==capture_valid || !nonce_ok || fault || C_WAIT_LIMIT<1) begin
                            command_rejected<=1;rejected_commands<=rejected_commands+1;
                        end else begin
                            opcode<=arm_valid?8'd1:8'd2;nonce<=command_nonce;state<=ISSUE_LOCAL;
                        end
                    end else if(rx_valid && rx_ready) begin
                        if(C_RESPONDER && (rx_opcode==1 || rx_opcode==2) &&
                            rx_nonce[31:5]!=0 && rx_nonce[4:0]==0 && rx_status==0 && rx_bank==0) begin
                            opcode<=rx_opcode;nonce<=rx_nonce;
                            if(fault || C_WAIT_LIMIT<1) begin
                                reply_status<=2;state<=SEND_PEER;
                            end else state<=ISSUE_LOCAL;
                        end else rejected_commands<=rejected_commands+1;
                    end
                end
                ISSUE_LOCAL:begin age<=0;state<=WAIT_LOCAL;end
                WAIT_LOCAL:begin
                    if(local_event) begin
                        if(!local_event_ok || (!local_rejected && !local_bank_ok) || (local_arm_accepted && local_rejected) ||
                            (local_snapshot_valid && local_rejected)) begin
                            fault<=1;fault_reason<=1;
                            if(C_RESPONDER) begin reply_status<=2;reply_bank<=local_registers;state<=SEND_PEER;end
                            else begin command_rejected<=1;state<=IDLE;end
                        end else if(local_rejected) begin
                            if(C_RESPONDER) begin reply_status<=1;reply_bank<=local_registers;state<=SEND_PEER;end
                            else begin command_rejected<=1;state<=IDLE;end
                        end else begin
                            reply_status<=0;reply_bank<=local_registers;state<=SEND_PEER;
                        end
                    end else if(age>=32'(C_WAIT_LIMIT-1)) begin
                        fault<=1;fault_reason<=2;
                        if(C_RESPONDER) begin reply_status<=2;reply_bank<=local_registers;state<=SEND_PEER;end
                        else begin command_rejected<=1;state<=IDLE;end
                    end
                end
                SEND_PEER:if(tx_valid && tx_ready) begin
                    age<=0;state<=C_RESPONDER?IDLE:WAIT_PEER;
                end
                WAIT_PEER:begin
                    if(rx_valid && rx_ready) begin
                        peer_candidate_ok<=!(rx_opcode!=(8'h80|opcode) || rx_nonce!=nonce || rx_status!=0 ||
                            !peer_bank_ok || !local_bank_ok);
                        peer_candidate_bank<=rx_bank;
                        state<=CHECK_PEER;
                    end else if(age>=32'(C_WAIT_LIMIT-1)) begin
                        fault<=1;fault_reason<=8;command_rejected<=1;state<=IDLE;
                    end
                end
                CHECK_PEER:begin
                        if(!peer_candidate_ok) begin
                            fault<=1;fault_reason<=4;command_rejected<=1;
                        end else begin
                            peer_registers<=peer_candidate_bank;
                            if(opcode==1) arm_accepted<=1;else snapshot_valid<=1;
                        end
                        state<=IDLE;
                end
                default:begin state<=IDLE;fault<=1;fault_reason<=16;end
            endcase
        end
    end
endmodule
`default_nettype wire
