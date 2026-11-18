// Standalone A-side PL11 v2 controller. No PCIe fence or OS release output.
// Configuration and retirement come from trusted outer adapters, not IOCTL
// claims. Full DATA is checked before a bounded ready/valid write is offered.
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_initiator_v2 #(
    parameter int RX_IDLE_LIMIT=4096,
    parameter int WAIT_LIMIT=1000000
)(
    input wire clk,rst,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [63:0] cfg_local_epoch,cfg_peer_epoch,cfg_session,cfg_window,cfg_base,
    input wire [31:0] cfg_bytes,cfg_caps,
    output logic cfg_accepted,cfg_rejected,
    input wire job_valid,
    output wire job_ready,
    input wire [63:0] job_sequence,
    input wire [31:0] job_rid,job_generation,job_source_offset,job_target_offset,job_length,
    output logic job_accepted,job_rejected,
    input wire stop_valid,
    input wire [63:0] stop_sequence,
    output logic stop_accepted,stop_rejected,
    output logic [63:0] tx_data,
    output wire tx_valid,tx_last,
    input wire tx_ready,
    input wire [63:0] rx_data,
    input wire rx_valid,rx_last,
    output wire rx_ready,
    // Stable metadata until accepted. Addresses derived solely from cfg_base.
    output wire write_valid,
    input wire write_ready,
    output wire [63:0] write_address,write_cq_address,write_sequence,
    output wire [31:0] write_length,write_rid,write_generation,
    output wire [127:0] payload_data,
    output wire payload_valid,payload_last,
    input wire payload_ready,
    // Trusted sink completion, tagged to the reserved task. This is LOCAL
    // accounting only, NOT PCIe ordering/drain proof or validated host CQ.
    input wire retire_valid,retire_success,
    input wire [63:0] retire_sequence,
    input wire [31:0] retire_bytes,
    output logic retired,
    // Held until consumed; requires matching wire ACK AND local retirement.
    output wire peer_stop_valid,
    input wire peer_stop_ready,
    output wire [63:0] peer_stop_sequence,
    output logic [2:0] state, // 0 closed,1 opening,2 ready,3 stopping,4 peer stopped,5 fault
    output logic active,
    output logic [31:0] rejected_frames,rejected_retirements
);
    localparam logic [31:0] MAGIC=32'h31314c50;
    localparam logic [2:0] CLOSED=0,OPENING=1,READY=2,STOPPING=3,PEER_STOPPED=4,FAULT=5;
    logic [63:0] local_q,peer_q,session_q,window_q,base_q,last_sequence,stop_q;
    logic [63:0] seq_q,data_address_q;
    logic [31:0] rid_q,gen_q,source_q,len_q;
    logic [63:0] outgoing[0:11],frame[0:27],payload[0:15];
    logic tx_busy,frame_pending,dropping,open_sent,req_sent,stop_sent,stop_ack;
    logic command_pending,sending,await_retire,peer_event_sent,peer_event_pending;
    logic [3:0] tx_index;
    logic [4:0] rx_index,frame_words;
    logic [3:0] payload_index;
    integer idle_cycles,wait_cycles;

    wire config_ok=cfg_local_epoch!=0 && cfg_peer_epoch!=0 && cfg_session!=0 && cfg_window!=0 &&
        cfg_bytes==8192 && cfg_caps==32'h10f && cfg_base[11:0]==0 && cfg_base<=64'hffffffffffffdfff;
    wire job_ok=last_sequence!=64'hffffffffffffffff && job_sequence==last_sequence+1 &&
        job_rid!=0 && job_generation!=0 && job_generation<=65535 &&
        (job_length==16 || job_length==128) && job_source_offset[3:0]==0 &&
        job_source_offset<4096 && job_length<=4096-job_source_offset &&
        job_target_offset[3:0]==0 && job_target_offset<=4064 &&
        job_length<=4096-job_target_offset;
    wire token_ok=frame[1]==local_q && frame[2]==peer_q &&
        frame[3]==session_q && frame[4]==window_q;
    wire common_ok=frame[0][31:0]==MAGIC && frame[0][47:32]==2 &&
        frame[8]==1 && frame[9]==4096 && frame[10]==64'h10f && frame[11]==0;
    wire empty_fields=frame[6]==0 && frame[7]==0;
    wire data_ok=frame_words==5'd12+5'(len_q>>3) && frame[5]==seq_q &&
        frame[6]=={gen_q,rid_q} && frame[7]=={len_q,source_q};
    logic pattern_ok;
    always_comb begin
        pattern_ok=1;
        for(integer k=0;k<16;k=k+1)
            if(k<int'(len_q>>3) && frame[12+k]!=(64'ha5a5000000000000 | ((64'(source_q)>>3)+64'(k))))
                pattern_ok=0;
    end

    assign cfg_ready=state==CLOSED && !tx_busy;
    assign job_ready=state==READY && !active && !tx_busy && !stop_valid && !frame_pending;
    assign rx_ready=!frame_pending;
    assign tx_valid=tx_busy;
    assign tx_last=tx_busy && tx_index==11;
    always_comb tx_data=outgoing[tx_index];
    assign write_valid=command_pending;
    assign write_address=data_address_q;
    assign write_cq_address=data_address_q+4096;
    assign write_length=len_q;
    assign write_sequence=seq_q;
    assign write_rid=rid_q;
    assign write_generation=gen_q;
    assign payload_data={payload[payload_index+4'd1],payload[payload_index]};
    assign payload_valid=sending;
    assign payload_last=sending && payload_index==4'((len_q>>3)-2);
    assign peer_stop_valid=peer_event_pending;
    assign peer_stop_sequence=stop_q;

    task automatic send_control(input logic [15:0] kind,input logic [63:0] sequence_value,
        input logic [63:0] request_fields,input logic [63:0] span);
        outgoing[0]<={kind,16'd2,MAGIC};outgoing[1]<=local_q;outgoing[2]<=peer_q;
        outgoing[3]<=session_q;outgoing[4]<=window_q;outgoing[5]<=sequence_value;
        outgoing[6]<=request_fields;outgoing[7]<=span;
        outgoing[8]<=1;outgoing[9]<=4096;outgoing[10]<=0;outgoing[11]<=0;
        tx_busy<=1;tx_index<=0;
    endtask

    always_ff @(posedge clk) begin
        if(rst) begin
            state<=CLOSED;active<=0;
            local_q<=0;peer_q<=0;session_q<=0;window_q<=0;base_q<=0;
            last_sequence<=0;stop_q<=0;seq_q<=0;data_address_q<=0;
            rid_q<=0;gen_q<=0;source_q<=0;len_q<=0;
            tx_busy<=0;frame_pending<=0;dropping<=0;tx_index<=0;rx_index<=0;frame_words<=0;
            command_pending<=0;sending<=0;await_retire<=0;payload_index<=0;
            open_sent<=0;req_sent<=0;stop_sent<=0;stop_ack<=0;peer_event_sent<=0;peer_event_pending<=0;
            idle_cycles<=0;wait_cycles<=0;retired<=0;
            cfg_accepted<=0;cfg_rejected<=0;job_accepted<=0;job_rejected<=0;
            stop_accepted<=0;stop_rejected<=0;rejected_frames<=0;rejected_retirements<=0;
            for(integer k=0;k<12;k=k+1) outgoing[k]<=0;
            for(integer k=0;k<28;k=k+1) frame[k]<=0;
            for(integer k=0;k<16;k=k+1) payload[k]<=0;
        end else begin
            cfg_accepted<=0;cfg_rejected<=0;job_accepted<=0;job_rejected<=0;
            stop_accepted<=0;stop_rejected<=0;retired<=0;
            if(cfg_valid) begin
                if(cfg_ready && config_ok) begin
                    local_q<=cfg_local_epoch;peer_q<=cfg_peer_epoch;session_q<=cfg_session;
                    window_q<=cfg_window;base_q<=cfg_base;state<=OPENING;cfg_accepted<=1;
                end else cfg_rejected<=1;
            end

            if(tx_busy && tx_ready) begin
                if(tx_last) begin
                    tx_busy<=0;
                    case(outgoing[0][63:48])
                        16'h12:open_sent<=1;
                        16'h14:req_sent<=1;
                        16'h16:stop_sent<=1;
                        default:;
                    endcase
                end else tx_index<=tx_index+1;
            end
            if(state==OPENING && !open_sent && !tx_busy) send_control(16'h12,0,0,0);

            if(job_valid && job_ready) begin
                if(job_ok) begin
                    seq_q<=job_sequence;rid_q<=job_rid;gen_q<=job_generation;
                    source_q<=job_source_offset;len_q<=job_length;
                    data_address_q<=base_q+{32'd0,job_target_offset};
                    active<=1;last_sequence<=job_sequence;req_sent<=0;job_accepted<=1;
                    send_control(16'h14,job_sequence,{job_generation,job_rid},{job_length,job_source_offset});
                end else job_rejected<=1;
            end
            if(stop_valid) begin
                if(state==READY && stop_sequence!=0) begin
                    state<=STOPPING;stop_q<=stop_sequence;stop_ack<=0;
                    stop_sent<=0;peer_event_sent<=0;stop_accepted<=1;
                end else if((state==STOPPING || state==PEER_STOPPED) && stop_q==stop_sequence && stop_sequence!=0)
                    stop_accepted<=1;
                else stop_rejected<=1;
            end
            if(state==STOPPING && !stop_sent && !tx_busy) send_control(16'h16,stop_q,0,0);

            // Downstream ready/valid ownership survives fault: never revoke an
            // offered command/payload under stall, and never splice a partial
            // accepted write. Fault remains quarantined regardless of retire.
            if(command_pending && write_ready) begin
                command_pending<=0;sending<=1;payload_index<=0;
            end
            if(sending && payload_ready) begin
                if(payload_last) begin sending<=0;await_retire<=1;end
                else payload_index<=payload_index+2;
            end
            if(retire_valid) begin
                if(state!=FAULT && active && await_retire && retire_sequence==seq_q) begin
                    if(retire_success && retire_bytes==len_q) begin
                        active<=0;await_retire<=0;retired<=1;
                    end else state<=FAULT;
                end else rejected_retirements<=rejected_retirements+1;
            end
            if(state==STOPPING && stop_ack && !active && !peer_event_sent && !frame_pending &&
               !peer_event_pending && rx_index==0 && !rx_valid) peer_event_pending<=1;
            if(peer_stop_valid && peer_stop_ready) begin
                peer_event_pending<=0;peer_event_sent<=1;
                if(state==STOPPING) state<=PEER_STOPPED;
            end

            if(rx_valid && rx_ready) begin
                idle_cycles<=0;
                if(dropping) begin
                    if(rx_last) begin dropping<=0;rx_index<=0;end
                end else if(rx_last) begin
                    frame[rx_index]<=rx_data;frame_words<=rx_index+1;frame_pending<=1;rx_index<=0;
                end else if(rx_index==27) begin
                    dropping<=1;rx_index<=0;rejected_frames<=rejected_frames+1;state<=FAULT;
                end else begin frame[rx_index]<=rx_data;rx_index<=rx_index+1;end
            end else if(rx_index!=0 && !frame_pending && !dropping) begin
                if(idle_cycles==RX_IDLE_LIMIT-1) begin
                    idle_cycles<=0;dropping<=1;rx_index<=0;
                    rejected_frames<=rejected_frames+1;state<=FAULT;
                end else idle_cycles<=idle_cycles+1;
            end

            if(frame_pending) begin
                frame_pending<=0;
                if(state==FAULT || state==CLOSED) rejected_frames<=rejected_frames+1;
                else if(frame_words<12 || !common_ok) begin
                    rejected_frames<=rejected_frames+1;state<=FAULT;
                end else if(!token_ok) rejected_frames<=rejected_frames+1;
                else case(frame[0][63:48])
                    16'h13:begin
                        if(state==OPENING && open_sent && frame_words==12 && frame[5]==0 && empty_fields)
                            state<=READY;
                        else rejected_frames<=rejected_frames+1;
                    end
                    16'h15:begin
                        if(active && req_sent && !command_pending && !sending && !await_retire &&
                           (state==READY || state==STOPPING) && data_ok && pattern_ok) begin
                            for(integer k=0;k<16;k=k+1) payload[k]<=frame[12+k];
                            command_pending<=1;
                        end else begin rejected_frames<=rejected_frames+1;state<=FAULT;end
                    end
                    16'h17:begin
                        if((state==STOPPING || state==PEER_STOPPED) && stop_sent &&
                           frame_words==12 && frame[5]==stop_q && empty_fields) stop_ack<=1;
                        else rejected_frames<=rejected_frames+1;
                    end
                    default:begin rejected_frames<=rejected_frames+1;state<=FAULT;end
                endcase
            end

            // A finite deadline faults even under unbounded peer/sink stalls.
            // It never frees ownership, clears active, or manufactures an ACK.
            if(state==OPENING || active || (state==STOPPING && !(stop_ack && !active))) begin
                if(wait_cycles==WAIT_LIMIT-1) state<=FAULT;
                else wait_cycles<=wait_cycles+1;
            end else wait_cycles<=0;
        end
    end
endmodule
`default_nettype wire
