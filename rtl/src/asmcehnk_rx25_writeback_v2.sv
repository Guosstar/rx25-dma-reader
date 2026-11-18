// Bounded, store-and-forward A writeback + RCQ2 publisher. Standalone.
// One ordered raw-TLP output; stream acceptance is NOT a PCIe drain fence.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_writeback_v2 #(
    parameter int WAIT_LIMIT=1000000,
    parameter logic [15:0] REQUESTER_ID=16'h0100
)(
    input wire clk,rst,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [63:0] cfg_base,cfg_buffer_id,
    input wire [31:0] cfg_bytes,
    output logic cfg_accepted,cfg_rejected,
    input wire write_valid,
    output wire write_ready,
    input wire [63:0] write_address,write_cq_address,write_sequence,
    input wire [31:0] write_length,write_rid,write_generation,
    input wire [127:0] payload_data,
    input wire payload_valid,payload_last,
    output wire payload_ready,
    output wire retire_valid,retire_success,
    output wire [63:0] retire_sequence,
    output wire [31:0] retire_bytes,
    output wire fault,
    output logic [3:0] state,
    IfAXIS128.source tlps_out
);
    localparam logic [3:0] UNCONFIG=0,IDLE=1,COLLECT=2,
        CQ_START=3,CQ_WAIT=4,CQ_GAP=5,DATA_START=6,DATA_WAIT=7,RETIRE=8,FAULT=9;
    logic [63:0] base_q,buffer_q,address_q,cq_q,sequence_q,last_sequence;
    logic [31:0] length_q,rid_q,generation_q,last_generation;
    logic [127:0] payload_buffer[0:7];
    logic [3:0] collected,send_index;
    logic [3:0] cq_step; // 0 invalidate, 1..8 body then final publish
    logic select_cq,data_started;
    integer wait_cycles;
    IfAXIS128 data_tlps();
    IfAXIS128 cq_tlps();
    logic [31:0] data_done;
    logic data_busy,data_error,data_ready,cqw_done;
    logic [63:0] debug_address,debug_config;
    logic [2:0] cq_index;
    logic [31:0] cq_value;
    wire [63:0] offset=write_address-base_q;
    wire config_ok=cfg_buffer_id!=0 && cfg_bytes==8192 && cfg_base[11:0]==0 &&
        cfg_base<=64'hffffffffffffdfff;
    // Globally unique increasing generation prevents an ABA publish when the
    // same or overlapping CQ location is reused inside this live allocation.
    wire command_ok=write_sequence!=0 && write_sequence>last_sequence && write_rid!=0 &&
        write_generation>last_generation && write_generation<=65535 &&
        (write_length==16 || write_length==128) && write_address>=base_q &&
        write_address[3:0]==0 && offset<=4064 && {32'd0,write_length}<=4096-offset &&
        write_cq_address==write_address+4096;
    assign cfg_ready=state==UNCONFIG;
    assign write_ready=state==IDLE;
    assign payload_ready=state==COLLECT;
    assign retire_valid=state==RETIRE;
    assign retire_success=state==RETIRE;
    assign retire_sequence=sequence_q;
    assign retire_bytes=length_q;
    assign fault=state==FAULT;

    always_comb begin
        case(cq_step)
            0:cq_index=1;
            1:cq_index=0;
            2:cq_index=2;
            3:cq_index=3;
            4:cq_index=4;
            5:cq_index=5;
            6:cq_index=6;
            7:cq_index=7;
            default:cq_index=1;
        endcase
        case(cq_index)
            0:cq_value=rid_q;
            1:cq_value=cq_step==0 ? 32'd0 : (32'h00010000 | generation_q);
            2:cq_value=length_q;
            3:cq_value=sequence_q[31:0];
            4:cq_value=0;
            5:cq_value=sequence_q[63:32];
            6:cq_value=32'h32514352; // RCQ2, deliberately not the v1 ABI
            default:cq_value=0;
        endcase
    end

    asmcehnk_mwr_stream #(.C_PAYLOAD_BYTES(128),.C_REQID(REQUESTER_ID)) data_writer(
        .clk(clk),.rst(rst),.cfg_addr(address_q),.cfg_len(length_q),.cfg_start(state==DATA_START),
        .done_bytes(data_done),.busy(data_busy),.error(data_error),
        .dbg_addr_reg(debug_address),.dbg_cfg_addr(debug_config),
        .s_tdata(payload_buffer[send_index[2:0]]),.s_tkeepdw(4'hf),
        .s_tvalid(data_started && send_index<4'(length_q>>4)),.s_tready(data_ready),
        .s_tlast(send_index==4'((length_q>>4)-1)),.tlps_out(data_tlps.source));
    // Pulse cqw_valid for one cycle per dword. The existing writer captures it
    // in IDLE, acknowledges after last beat, then takes its own ACK bubble.
    asmcehnk_cq_writer #(.C_REQID(REQUESTER_ID)) cq_writer(
        .clk(clk),.rst(rst),.cqw_valid(state==CQ_START),
        .cqw_addr(cq_q+{59'd0,cq_index,2'b00}),.cqw_data(cq_value),.cqw_index(cq_index),
        .cqw_done(cqw_done),.tlps_out(cq_tlps.source));
    // Owner is latched, NOT selected from state, so an outstanding packet is
    // never revoked by timeout/FAULT. Its module may finish on this same output.
    assign tlps_out.tdata=select_cq ? cq_tlps.tdata : data_tlps.tdata;
    assign tlps_out.tkeepdw=select_cq ? cq_tlps.tkeepdw : data_tlps.tkeepdw;
    assign tlps_out.tuser=select_cq ? cq_tlps.tuser : data_tlps.tuser;
    assign tlps_out.tlast=select_cq ? cq_tlps.tlast : data_tlps.tlast;
    assign tlps_out.tvalid=select_cq ? cq_tlps.tvalid : data_tlps.tvalid;
    assign tlps_out.has_data=select_cq ? cq_tlps.has_data : data_tlps.has_data;
    assign cq_tlps.tready=select_cq && tlps_out.tready;
    assign data_tlps.tready=!select_cq && tlps_out.tready;

    always_ff @(posedge clk) begin
        if(rst) begin
            state<=UNCONFIG;base_q<=0;buffer_q<=0;address_q<=0;cq_q<=0;sequence_q<=0;
            last_sequence<=0;last_generation<=0;length_q<=0;rid_q<=0;generation_q<=0;
            cfg_accepted<=0;cfg_rejected<=0;collected<=0;send_index<=0;
            cq_step<=0;select_cq<=0;data_started<=0;wait_cycles<=0;
            for(integer k=0;k<8;k=k+1) payload_buffer[k]<=0;
        end else begin
            cfg_accepted<=0;cfg_rejected<=0;
            if(cfg_valid) begin
                if(cfg_ready && config_ok) begin
                    base_q<=cfg_base;buffer_q<=cfg_buffer_id;state<=IDLE;cfg_accepted<=1;
                end else cfg_rejected<=1;
            end
            // This stream continues in FAULT if a data TLP was already started.
            if(data_started && send_index<4'(length_q>>4) && data_ready) send_index<=send_index+1;
            case(state)
                IDLE:if(write_valid && write_ready) begin
                    if(command_ok) begin
                        address_q<=write_address;cq_q<=write_cq_address;sequence_q<=write_sequence;
                        rid_q<=write_rid;generation_q<=write_generation;length_q<=write_length;
                        last_sequence<=write_sequence;last_generation<=write_generation;
                        collected<=0;send_index<=0;data_started<=0;cq_step<=0;
                        state<=COLLECT;
                    end else state<=FAULT;
                end
                COLLECT:if(payload_valid && payload_ready) begin
                    if(payload_last!=(collected==4'((length_q>>4)-1))) state<=FAULT;
                    else begin
                        payload_buffer[collected[2:0]]<=payload_data;collected<=collected+1;
                        if(payload_last) begin select_cq<=1;state<=CQ_START;end
                    end
                end
                CQ_START:state<=CQ_WAIT;
                CQ_WAIT:if(cqw_done) begin
                    if(cq_step==0) begin select_cq<=0;state<=DATA_START;end
                    else if(cq_step==8) state<=RETIRE;
                    else begin cq_step<=cq_step+1;state<=CQ_GAP;end
                end
                CQ_GAP:state<=CQ_START;
                DATA_START:begin data_started<=1;state<=DATA_WAIT;end
                DATA_WAIT:begin
                    if(data_error) state<=FAULT;
                    else if(data_done==length_q && !data_busy && send_index==4'(length_q>>4)) begin
                        cq_step<=1;select_cq<=1;state<=CQ_START;
                    end
                end
                RETIRE:state<=IDLE;
                default:;
            endcase
            if(state!=UNCONFIG && state!=IDLE && state!=RETIRE && state!=FAULT) begin
                if(wait_cycles==WAIT_LIMIT-1) state<=FAULT;
                else wait_cycles<=wait_cycles+1;
            end else wait_cycles<=0;
        end
    end
endmodule
`default_nettype wire
