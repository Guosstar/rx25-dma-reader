// Standalone integration, not a board top or a live driver interface.
// verified_* must originate in a trusted mapped-memory observer that checks
// CQ/payload/guards with actual DMA visibility barriers. No fence exists here.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_pipeline_v2 #(
    parameter int A_WAIT_LIMIT=1000000,
    parameter int SINK_WAIT_LIMIT=1000000,
    parameter int VERIFY_WAIT_LIMIT=1000000
)(
    input wire clk,rst,external_fault,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [63:0] cfg_local_epoch,cfg_peer_epoch,cfg_session,cfg_window,cfg_base,cfg_buffer_id,
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
    input wire verified_valid,verified_success,
    output wire verified_ready,
    input wire [63:0] verified_local_epoch,verified_peer_epoch,verified_session,verified_window,verified_buffer_id,verified_sequence,
    input wire [31:0] verified_rid,verified_generation,verified_length,
    output logic verified_accepted,verified_rejected,completed,
    // Telemetry only: local output acceptance, never host visibility/fence.
    output wire local_retire_valid,local_retire_success,
    output wire [63:0] local_retire_sequence,
    output wire [31:0] local_retire_bytes,
    output wire [63:0] tx_data,
    output wire tx_valid,tx_last,
    input wire tx_ready,
    input wire [63:0] rx_data,
    input wire rx_valid,rx_last,
    output wire rx_ready,
    output logic configured,quarantined,owned,peer_confirmed,
    output wire release_allowed,
    output wire [2:0] guard_state,a_state,
    output wire [3:0] sink_state,
    IfAXIS128.source tlps_out
);
    localparam logic [3:0] COLD=0,CONFIG_SEND=1,CONFIG_REPLY=2,OPEN_WAIT=3,
        SCAN=4,SUBMIT_SEND=5,SUBMIT_REPLY=6,HANDOFF=7,
        STOP_SEND=8,STOP_REPLY=9,COMPLETE_SEND=10,COMPLETE_REPLY=11,
        PEER_SEND=12,PEER_REPLY=13,ISOLATED=14;
    logic [3:0] phase;
    logic [63:0] local_q,peer_q,session_q,window_q,base_q,buffer_q,seq_q,stop_q,last_sequence;
    logic [31:0] rid_q,gen_q,source_q,target_q,len_q,last_generation;
    logic retire_seen,verification_seen,stop_pending,guard_stop_sent,a_stop_sent;
    logic a_job_valid,a_job_ready,a_job_accepted,a_job_rejected;
    logic a_cfg_ready,a_cfg_accepted,a_cfg_rejected,a_stop_accepted,a_stop_rejected,a_retired,a_active;
    logic sink_cfg_ready,sink_cfg_accepted,sink_cfg_rejected,sink_fault;
    logic guard_reply,guard_can_close,guard_dispatch,guard_active;
    logic [1:0] guard_result;
    logic [3:0] guard_command;
    logic guard_command_valid;
    logic [63:0] guard_sequence,guard_data_address,guard_cq_address;
    logic write_valid,write_ready,payload_valid,payload_ready,payload_last;
    logic [63:0] write_address,write_cq_address,write_sequence;
    logic [31:0] write_length,write_rid,write_generation;
    logic [127:0] payload_data;
    logic retire_valid,retire_success;
    logic [63:0] retire_sequence,a_peer_sequence;
    logic [31:0] retire_bytes,a_rejected_frames,a_rejected_retirements;
    logic a_peer_valid;
    integer verify_cycles;
    wire configuration_ok=cfg_local_epoch!=0 && cfg_peer_epoch!=0 && cfg_session!=0 &&
        cfg_window!=0 && cfg_buffer_id!=0 && cfg_bytes==8192 && cfg_caps==32'h10f &&
        cfg_base[11:0]==0 && cfg_base<=64'hffffffffffffdfff;
    wire job_ok=last_sequence!=64'hffffffffffffffff && job_sequence==last_sequence+1 &&
        job_rid!=0 && job_generation>last_generation && job_generation<=65535 &&
        (job_length==16 || job_length==128) && job_source_offset[3:0]==0 &&
        job_source_offset<4096 && job_length<=4096-job_source_offset &&
        job_target_offset[3:0]==0 && job_target_offset<=4064 && job_length<=4096-job_target_offset;
    wire verify_matches=verified_local_epoch==local_q && verified_peer_epoch==peer_q &&
        verified_session==session_q && verified_window==window_q && verified_buffer_id==buffer_q &&
        verified_sequence==seq_q && verified_rid==rid_q && verified_generation==gen_q && verified_length==len_q;
    wire verification_failed=verified_valid && verified_ready && verify_matches && !verified_success;
    wire verify_timeout=owned && retire_seen && !verification_seen && verify_cycles==VERIFY_WAIT_LIMIT-1;
    wire fault_now=external_fault || a_state==5 || sink_fault || guard_state==5 || verification_failed || verify_timeout;
    wire run_ok=!quarantined && !fault_now;
    wire config_pulse=phase==CONFIG_SEND && run_ok;
    // There is deliberately no LOCAL_FENCED command and no release path.
    assign release_allowed=1'b0;
    assign local_retire_valid=retire_valid;
    assign local_retire_success=retire_success;
    assign local_retire_sequence=retire_sequence;
    assign local_retire_bytes=retire_bytes;
    assign cfg_ready=phase==COLD && run_ok;
    assign job_ready=configured && phase==SCAN && !owned && !stop_pending && !stop_valid &&
        guard_state==1 && a_job_ready && run_ok;
    assign verified_ready=configured && owned && retire_seen && !verification_seen && !quarantined &&
        !external_fault && a_state!=5 && !sink_fault && guard_state!=5;

    // FAIL overrides command selection, never the identity datapath. Keeping
    // sequence selection independent avoids a verify-compare -> fault ->
    // sequence-mux -> guard sequence-compare chain on the same clock edge.
    assign guard_sequence=(phase==STOP_SEND || phase==PEER_SEND) ? stop_q : seq_q;
    always_comb begin
        guard_command_valid=0;guard_command=0;
        if(quarantined || fault_now) begin
            if(guard_state!=0 && guard_state!=5) begin guard_command_valid=1;guard_command=7;end
        end else case(phase)
            SUBMIT_SEND:begin guard_command_valid=1;guard_command=1;end
            STOP_SEND:begin guard_command_valid=1;guard_command=3;end
            COMPLETE_SEND:begin guard_command_valid=1;guard_command=2;end
            PEER_SEND:begin guard_command_valid=1;guard_command=4;end
            default:;
        endcase
    end
    asmcehnk_rx25_session_guard guard(
        .clk(clk),.rst(rst),.open_valid(config_pulse),
        .local_epoch(local_q),.peer_epoch(peer_q),.session_id(session_q),.buffer_id(buffer_q),
        .dma_address(base_q),.buffer_bytes(32'd8192),.peer_caps(32'h10f),
        .command_valid(guard_command_valid),.command(guard_command),
        .message_local_epoch(local_q),.message_peer_epoch(peer_q),.message_session_id(session_q),
        .sequence_id(guard_sequence),.request_id(rid_q),.generation(gen_q),.target_offset(target_q),.length(len_q),
        .reply_valid(guard_reply),.result(guard_result),.state(guard_state),.can_close(guard_can_close),
        .dispatch_valid(guard_dispatch),.data_address(guard_data_address),.cq_address(guard_cq_address),.active(guard_active));
    asmcehnk_rx25_initiator_v2 #(.WAIT_LIMIT(A_WAIT_LIMIT)) initiator(
        .clk(clk),.rst(rst),.cfg_valid(config_pulse),.cfg_ready(a_cfg_ready),
        .cfg_local_epoch(local_q),.cfg_peer_epoch(peer_q),.cfg_session(session_q),.cfg_window(window_q),.cfg_base(base_q),
        .cfg_bytes(32'd8192),.cfg_caps(32'h10f),.cfg_accepted(a_cfg_accepted),.cfg_rejected(a_cfg_rejected),
        .job_valid(a_job_valid),.job_ready(a_job_ready),.job_sequence(seq_q),.job_rid(rid_q),.job_generation(gen_q),
        .job_source_offset(source_q),.job_target_offset(target_q),.job_length(len_q),
        .job_accepted(a_job_accepted),.job_rejected(a_job_rejected),
        .stop_valid(stop_pending && !a_stop_sent && phase!=SUBMIT_SEND && phase!=SUBMIT_REPLY && phase!=HANDOFF && run_ok),
        .stop_sequence(stop_q),.stop_accepted(a_stop_accepted),.stop_rejected(a_stop_rejected),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_last(tx_last),.tx_ready(tx_ready),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_last(rx_last),.rx_ready(rx_ready),
        .write_valid(write_valid),.write_ready(write_ready),.write_address(write_address),.write_cq_address(write_cq_address),
        .write_sequence(write_sequence),.write_length(write_length),.write_rid(write_rid),.write_generation(write_generation),
        .payload_data(payload_data),.payload_valid(payload_valid),.payload_last(payload_last),.payload_ready(payload_ready),
        .retire_valid(retire_valid),.retire_success(retire_success),.retire_sequence(retire_sequence),.retire_bytes(retire_bytes),
        .retired(a_retired),.peer_stop_valid(a_peer_valid),
        .peer_stop_ready(phase==PEER_REPLY && guard_reply &&
            (guard_result==1 || (guard_state==4 && !guard_active)) && run_ok),
        .peer_stop_sequence(a_peer_sequence),.state(a_state),.active(a_active),
        .rejected_frames(a_rejected_frames),.rejected_retirements(a_rejected_retirements));
    asmcehnk_rx25_writeback_v2 #(.WAIT_LIMIT(SINK_WAIT_LIMIT)) sink(
        .clk(clk),.rst(rst),.cfg_valid(config_pulse),.cfg_ready(sink_cfg_ready),
        .cfg_base(base_q),.cfg_buffer_id(buffer_q),.cfg_bytes(32'd8192),
        .cfg_accepted(sink_cfg_accepted),.cfg_rejected(sink_cfg_rejected),
        .write_valid(write_valid),.write_ready(write_ready),.write_address(write_address),.write_cq_address(write_cq_address),
        .write_sequence(write_sequence),.write_length(write_length),.write_rid(write_rid),.write_generation(write_generation),
        .payload_data(payload_data),.payload_valid(payload_valid),.payload_last(payload_last),.payload_ready(payload_ready),
        .retire_valid(retire_valid),.retire_success(retire_success),.retire_sequence(retire_sequence),.retire_bytes(retire_bytes),
        .fault(sink_fault),.state(sink_state),.tlps_out(tlps_out));

    always_ff @(posedge clk) begin
        if(rst) begin
            phase<=COLD;configured<=0;quarantined<=0;owned<=0;peer_confirmed<=0;
            local_q<=0;peer_q<=0;session_q<=0;window_q<=0;base_q<=0;buffer_q<=0;
            seq_q<=0;stop_q<=0;last_sequence<=0;last_generation<=0;
            rid_q<=0;gen_q<=0;source_q<=0;target_q<=0;len_q<=0;
            retire_seen<=0;verification_seen<=0;stop_pending<=0;guard_stop_sent<=0;a_stop_sent<=0;a_job_valid<=0;
            verify_cycles<=0;cfg_accepted<=0;cfg_rejected<=0;job_accepted<=0;job_rejected<=0;
            stop_accepted<=0;stop_rejected<=0;verified_accepted<=0;verified_rejected<=0;completed<=0;
        end else begin
            cfg_accepted<=0;cfg_rejected<=0;job_accepted<=0;job_rejected<=0;
            stop_accepted<=0;stop_rejected<=0;verified_accepted<=0;verified_rejected<=0;completed<=0;
            // Any offered A job remains stable through fault until handshake;
            // mappings remain owned. No newly accepted external job follows it.
            if(a_job_valid && a_job_ready) a_job_valid<=0;
            if(a_stop_accepted) a_stop_sent<=1;
            if(retire_valid && retire_sequence==seq_q && retire_success && retire_bytes==len_q) retire_seen<=1;
            if(owned && retire_seen && !verification_seen && !quarantined) verify_cycles<=verify_cycles+1;
            else verify_cycles<=0;
            if(verified_valid && verified_ready) begin
                if(verify_matches && verified_success && !fault_now) begin
                    verification_seen<=1;verified_accepted<=1;
                end else verified_rejected<=1;
            end
            if(cfg_valid && !cfg_ready) cfg_rejected<=1;
            if(stop_valid) begin
                if(configured && stop_sequence!=0 && run_ok && (!stop_pending || stop_q==stop_sequence)) begin
                    stop_pending<=1;stop_q<=stop_sequence;stop_accepted<=1;
                end else stop_rejected<=1;
            end
            if(fault_now || quarantined) begin
                quarantined<=1;phase<=ISOLATED;
            end else case(phase)
                COLD:if(cfg_valid && cfg_ready) begin
                    if(configuration_ok) begin
                        local_q<=cfg_local_epoch;peer_q<=cfg_peer_epoch;session_q<=cfg_session;
                        window_q<=cfg_window;base_q<=cfg_base;buffer_q<=cfg_buffer_id;phase<=CONFIG_SEND;
                    end else cfg_rejected<=1;
                end
                CONFIG_SEND:phase<=CONFIG_REPLY;
                CONFIG_REPLY:if(guard_reply) begin
                    if(guard_result==1 && a_cfg_accepted && sink_cfg_accepted && !a_cfg_rejected && !sink_cfg_rejected)
                        phase<=OPEN_WAIT;
                    else begin quarantined<=1;phase<=ISOLATED;end
                end
                OPEN_WAIT:if(a_state==2) begin configured<=1;cfg_accepted<=1;phase<=SCAN;end
                SCAN:begin
                    if(stop_pending && !guard_stop_sent) phase<=STOP_SEND;
                    else if(owned && retire_seen && verification_seen) phase<=COMPLETE_SEND;
                    else if(stop_pending && guard_stop_sent && !owned && a_peer_valid && !peer_confirmed) begin
                        if(a_peer_sequence==stop_q) phase<=PEER_SEND;
                        else begin quarantined<=1;phase<=ISOLATED;end
                    end else if(job_valid && job_ready) begin
                        if(job_ok) begin
                            seq_q<=job_sequence;rid_q<=job_rid;gen_q<=job_generation;
                            source_q<=job_source_offset;target_q<=job_target_offset;len_q<=job_length;
                            last_sequence<=job_sequence;last_generation<=job_generation;
                            owned<=1;retire_seen<=0;verification_seen<=0;job_accepted<=1;phase<=SUBMIT_SEND;
                        end else job_rejected<=1;
                    end
                end
                SUBMIT_SEND:phase<=SUBMIT_REPLY;
                SUBMIT_REPLY:if(guard_reply) begin
                    if(guard_result==1 && guard_dispatch && guard_data_address==base_q+{32'd0,target_q} &&
                       guard_cq_address==base_q+{32'd0,target_q}+4096) begin a_job_valid<=1;phase<=HANDOFF;end
                    else begin quarantined<=1;phase<=ISOLATED;end
                end
                HANDOFF:if(a_job_valid && a_job_ready) phase<=SCAN;
                STOP_SEND:phase<=STOP_REPLY;
                STOP_REPLY:if(guard_reply) begin
                    if(guard_result==1) begin guard_stop_sent<=1;phase<=SCAN;end
                    else begin quarantined<=1;phase<=ISOLATED;end
                end
                COMPLETE_SEND:phase<=COMPLETE_REPLY;
                COMPLETE_REPLY:if(guard_reply) begin
                    if(guard_result==1) begin owned<=0;completed<=1;phase<=SCAN;end
                    else begin quarantined<=1;phase<=ISOLATED;end
                end
                PEER_SEND:phase<=PEER_REPLY;
                PEER_REPLY:if(guard_reply) begin
                    if(guard_result==1 || (guard_state==4 && !guard_active)) begin peer_confirmed<=1;phase<=SCAN;end
                    else begin quarantined<=1;phase<=ISOLATED;end
                end
                default:;
            endcase
        end
    end
endmodule
`default_nettype wire
