// One-shot, address-free batch diagnostic owner. Not a remote-memory API.
`resetall
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_batch_owner #(
    parameter bit C_RESPONDER=0
)(
    input wire logic clk,rst,
    input wire logic host_valid,host_exact,
    input wire logic [1:0] host_opcode, // 1 ARM, 2 START, 3 CAPTURE
    input wire logic [31:0] host_nonce,
    output wire logic command_valid,
    input wire logic command_ready,
    output wire logic [1:0] command_opcode, // mailbox: 1 ARM, 2 CAPTURE
    output wire logic [31:0] command_nonce,
    input wire logic response_valid,
    input wire logic [1:0] response_kind,response_opcode,
    input wire logic [31:0] response_nonce,
    input wire logic [1023:0] response_registers,
    input wire logic bridge_fault,
    output logic start_valid,
    output wire logic [31:0] start_nonce,
    input wire logic start_accepted,start_rejected,
    input wire logic [511:0] batch_registers,
    output logic [1023:0] pressure_registers,
    output logic [511:0] registers
);
    logic pending,start_pending,armed,started,captured,fault;
    logic [31:0] nonce,rejected,last_kind,last_opcode,fault_reason,completed;
    logic [1:0] expected_opcode;
    wire nonce_ok=host_nonce[31:5]!=0 && host_nonce[4:0]==0;
    wire ready_=!C_RESPONDER && !pending && !start_pending && !fault && command_ready && !rst;
    wire arm_ok=ready_ && !armed && !started && host_opcode==1;
    wire capture_ok=ready_ && armed && started && !captured && host_opcode==3 &&
        host_nonce==nonce && !batch_registers[34]; // busy must have drained
    wire mailbox_issue=host_valid && host_exact && nonce_ok && (arm_ok || capture_ok);
    assign command_valid=mailbox_issue;
    assign command_opcode=host_opcode==1?2'd1:2'd2;
    assign command_nonce=host_nonce;
    assign start_nonce=nonce;
    wire start_ok=ready_ && armed && !started && host_opcode==2 && host_nonce==nonce;
    wire banks_identity_ok=response_registers[31:0]==32'h31535250 &&
        response_registers[95:64]==nonce && response_registers[543:512]==32'h31535250 &&
        response_registers[607:576]==nonce;
    wire arm_banks_ok=banks_identity_ok && response_registers[33:32]==3 &&
        !response_registers[35] && response_registers[545:544]==3 && !response_registers[547];
    wire capture_banks_ok=banks_identity_ok && response_registers[36] && response_registers[548];
    wire response_bad=!pending || response_opcode!=expected_opcode || response_nonce!=nonce ||
        (response_kind!=2 && response_kind!=(expected_opcode==1?1:3));
    wire start_bad=!start_pending || start_accepted==start_rejected;
    wire banks_bad=(expected_opcode==1 && !arm_banks_ok) || (expected_opcode==2 && !capture_banks_ok);
    // Merge every cause from this clock before the single sticky write. Two
    // independent notices must not overwrite one another's diagnostic bits.
    wire [31:0] fault_events=(response_valid && response_bad ? 32'h01 : 0) |
        (bridge_fault ? 32'h02 : 0) |
        ((start_accepted || start_rejected) && start_bad ? 32'h04 : 0) |
        ((start_accepted || start_rejected) && !start_bad && start_rejected ? 32'h08 : 0) |
        (response_valid && !response_bad && response_kind==2 ? 32'h10 : 0) |
        (response_valid && !response_bad && response_kind!=2 && banks_bad ? 32'h20 : 0);
    always_comb begin
        registers='0;
        registers[31:0]=32'h31544342; // BCT1
        registers[63:32]=1;
        registers[95:64]={25'd0,fault,captured,started,armed,(pending||start_pending),ready_,1'b1};
        registers[127:96]=nonce;
        registers[159:128]=rejected;
        registers[191:160]=last_kind;
        registers[223:192]=last_opcode;
        registers[255:224]=fault_reason;
        registers[287:256]=completed;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            pending<=0;start_pending<=0;armed<=0;started<=0;captured<=0;fault<=0;
            nonce<=0;rejected<=0;last_kind<=0;last_opcode<=0;fault_reason<=0;completed<=0;
            pressure_registers<=0;expected_opcode<=0;start_valid<=0;
        end else begin
            start_valid<=0;
            fault_reason<=fault_reason|fault_events;
            if(host_valid) begin
                if(mailbox_issue) begin
                    pending<=1;expected_opcode<=command_opcode;
                    if(host_opcode==1) nonce<=host_nonce;
                end else if(host_exact && nonce_ok && start_ok) begin
                    start_valid<=1;start_pending<=1;
                end else if(rejected!=32'hffffffff) rejected<=rejected+1;
            end
            if(start_accepted || start_rejected) begin
                if(start_bad) begin
                    fault<=1;
                end else begin
                    start_pending<=0;last_kind<=start_accepted?1:2;last_opcode<=2;
                    if(start_accepted) begin started<=1;completed<=completed+1;end
                    else fault<=1;
                end
            end
            if(response_valid) begin
                if(response_bad) begin
                    fault<=1;
                end else begin
                    pending<=0;last_kind<={30'd0,response_kind};
                    last_opcode<=expected_opcode==1?1:3;
                    if(response_kind==2) fault<=1;
                    else if(banks_bad) begin
                        fault<=1;
                    end else begin
                        // Both pressure banks are latched from one FIFO word.
                        pressure_registers<=response_registers;completed<=completed+1;
                        if(expected_opcode==1) armed<=1;else captured<=1;
                    end
                end
            end
            if(bridge_fault) fault<=1;
        end
    end
endmodule
`default_nettype wire
