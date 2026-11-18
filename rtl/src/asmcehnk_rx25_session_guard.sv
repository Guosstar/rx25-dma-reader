// Standalone diagnostic gate; not connected to a live DMA/doorbell path.
// open_* is trusted kernel configuration. PeerStopped/LocalFenced commands
// require real hardware evidence adapters which do not yet exist. Never expose
// these as caller-controlled IOCTL flags. reset never emits a release permit.
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_session_guard (
    input wire logic clk,rst,
    input wire logic open_valid,
    input wire logic [63:0] local_epoch,peer_epoch,session_id,buffer_id,dma_address,
    input wire logic [31:0] buffer_bytes,peer_caps,
    input wire logic command_valid,
    input wire logic [3:0] command,
    input wire logic [63:0] message_local_epoch,message_peer_epoch,message_session_id,sequence_id,
    input wire logic [31:0] request_id,generation,target_offset,length,
    output logic reply_valid,
    output logic [1:0] result,
    output logic [2:0] state,
    output wire logic can_close,
    output logic dispatch_valid,
    output logic [63:0] data_address,cq_address,
    output wire logic active
);
    localparam logic [2:0] CLOSED=0,READY=1,RUNNING=2,STOPPING=3,DRAINED=4,FAULT=5;
    localparam logic [1:0] REJECTED=0,ACCEPTED=1,STALE=2,ISOLATED=3;
    logic [63:0] local_q,peer_q,session_q,buffer_q,base_q,last_sequence,stop_sequence;
    logic [31:0] rid_q,generation_q,length_q;
    logic active_q,ever_armed,peer_stopped,local_fenced;
    wire token_matches=message_local_epoch==local_q && message_peer_epoch==peer_q && message_session_id==session_q;
    wire fresh_token=!(session_q!=0 && local_epoch==local_q && peer_epoch==peer_q && session_id==session_q);
    assign active=active_q;
    assign can_close=state==DRAINED && !active_q && (!ever_armed || (peer_stopped && local_fenced));
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=CLOSED;reply_valid<=0;result<=REJECTED;dispatch_valid<=0;
            local_q<=0;peer_q<=0;session_q<=0;buffer_q<=0;base_q<=0;
            last_sequence<=0;stop_sequence<=0;rid_q<=0;generation_q<=0;length_q<=0;
            active_q<=0;ever_armed<=0;peer_stopped<=0;local_fenced<=0;
            data_address<=0;cq_address<=0;
        end else begin
            reply_valid<=0;dispatch_valid<=0;
            if(open_valid || command_valid) begin
                reply_valid<=1;result<=REJECTED;
                if(open_valid && command_valid) result<=REJECTED;
                else if(open_valid) begin
                    if(state==CLOSED && local_epoch!=0 && peer_epoch!=0 && session_id!=0 &&
                        buffer_id!=0 && buffer_bytes==8192 && peer_caps==32'h10f && fresh_token &&
                        dma_address[11:0]==0 && dma_address<=64'hffffffffffffdfff) begin
                        local_q<=local_epoch;peer_q<=peer_epoch;session_q<=session_id;
                        buffer_q<=buffer_id;base_q<=dma_address;last_sequence<=0;stop_sequence<=0;
                        rid_q<=0;generation_q<=0;length_q<=0;active_q<=0;ever_armed<=0;
                        peer_stopped<=0;local_fenced<=0;data_address<=0;cq_address<=0;
                        state<=READY;result<=ACCEPTED;
                    end
                end else if(state==CLOSED) result<=REJECTED;
                else if(!token_matches) result<=STALE;
                else if(state==FAULT) result<=ISOLATED;
                else case(command)
                    1:if(state==READY && !active_q && last_sequence!=64'hffffffffffffffff &&
                        sequence_id==last_sequence+1 && request_id!=0 && generation!=0 && generation<=65535 &&
                        (length==16 || length==128) && target_offset[3:0]==0 &&
                        target_offset<4096 && length<=4096-target_offset && target_offset<=4064) begin
                        last_sequence<=sequence_id;rid_q<=request_id;generation_q<=generation;length_q<=length;
                        data_address<=base_q+{32'd0,target_offset};cq_address<=base_q+{32'd0,target_offset}+4096;
                        active_q<=1;ever_armed<=1;state<=RUNNING;result<=ACCEPTED;dispatch_valid<=1;
                    end
                    2:begin
                        result<=STALE;
                        if(active_q && (state==RUNNING || state==STOPPING) && sequence_id==last_sequence &&
                            request_id==rid_q && generation==generation_q && length==length_q) begin
                            active_q<=0;if(state==RUNNING) state<=READY;result<=ACCEPTED;
                        end
                    end
                    3:if(sequence_id!=0) begin
                        if(state==STOPPING || state==DRAINED) result<=sequence_id==stop_sequence ? ACCEPTED : STALE;
                        else if(state==READY || state==RUNNING) begin
                            stop_sequence<=sequence_id;peer_stopped<=0;local_fenced<=0;
                            state<=ever_armed ? STOPPING : DRAINED;result<=ACCEPTED;
                        end
                    end
                    4:if(state==STOPPING && !active_q && sequence_id==stop_sequence) begin
                        peer_stopped<=1;result<=ACCEPTED;
                    end
                    5:if(state==STOPPING && !active_q && peer_stopped && sequence_id==stop_sequence) begin
                        local_fenced<=1;state<=DRAINED;result<=ACCEPTED;
                    end
                    6:if(can_close && sequence_id==stop_sequence) begin state<=CLOSED;result<=ACCEPTED;end
                    7:begin state<=FAULT;result<=ISOLATED;end
                    default:result<=REJECTED;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
