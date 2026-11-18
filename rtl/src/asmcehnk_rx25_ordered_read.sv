// One-use diagnostic ordered-read primitive, NOT a DMA-drain certificate.
// No board instance or driver IOCTL is enabled by adding this source file.
// Trusted integration must close ALL writers/queues, reserve tag 1e and the
// scratch DWORD [base+0x7c,base+0x80), audit TC0/RO0/IDO0/no-straddle, and
// preserve the mapping across fault/reset/PnP. Never wire observed to release.
`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_ordered_read #(
    parameter integer C_WAIT_LIMIT = 1000000
)(
    input wire logic clk, rst,
    input wire logic session_alive, profile_locked, external_fault,
    input wire logic cfg_valid,
    output wire logic cfg_ready,
    output logic cfg_accepted, cfg_rejected,
    input wire logic [63:0] cfg_buffer_base, cfg_token,
    input wire logic [15:0] cfg_requester_id,
    input wire logic [31:0] cfg_cookie,
    input wire logic start_valid,
    output wire logic start_ready,
    output logic start_accepted, start_rejected,
    input wire logic [63:0] start_token,
    input wire logic producers_stopped,
    IfAXIS128.source request_out,
    // Observe the actual hard-IP handshake, NOT raw acceptance or RQ ACK.
    input wire logic rq_fire,
    input wire logic [255:0] rq_data,
    input wire logic [7:0] rq_keep,
    input wire logic [61:0] rq_user,
    input wire logic rq_last,
    // 256-bit non-straddled native RC handshake, before lossy raw conversion.
    input wire logic rc_fire,
    input wire logic [255:0] rc_data,
    input wire logic [7:0] rc_keep,
    input wire logic [74:0] rc_user,
    input wire logic rc_last,
    output wire logic observed,
    output logic faulted,
    output logic [31:0] reasons,
    output wire logic busy, spent,
    output wire logic release_allowed,
    output wire logic [63:0] result_token, probe_address
);
    localparam logic [7:0] TAG = 8'h1e;
    localparam logic [31:0] F_CONTEXT=1, F_TIMEOUT=2, F_RQ=4, F_RC=8;
    localparam integer TIMER_W = (C_WAIT_LIMIT>1) ? $clog2(C_WAIT_LIMIT) : 1;
    typedef enum logic [2:0] {UNCONFIGURED, READY, TRANSMIT,
        WAIT_RQ, WAIT_RC, OBSERVED, QUARANTINE} state_t;
    state_t state_q;
    logic [63:0] base_q, token_q;
    logic [15:0] requester_q;
    logic [31:0] cookie_q;
    logic [TIMER_W-1:0] age_q;
    logic pending_q, spent_q, rq_packet_q;
    wire active = state_q==TRANSMIT || state_q==WAIT_RQ || state_q==WAIT_RC;
    wire context_bad = external_fault || !session_alive || !profile_locked ||
        ((active || state_q==OBSERVED) && !producers_stopped);
    wire deadline = active && age_q >= TIMER_W'(C_WAIT_LIMIT-1);
    wire [63:0] address = base_q + 64'h7c;
    wire [127:0] read_header = {address[31:0], address[63:32],
        requester_q, TAG, 8'h0f, 32'h20000001};
    // Only the sequence bits may vary in the existing RQ adapter's tuser.
    localparam logic [61:0] RQ_SEQUENCE_MASK = (62'hf << 24) | (62'h3 << 60);
    logic [127:0] expected_desc;
    always_comb begin
        expected_desc=0;
        expected_desc[63:2]=address[63:2];
        expected_desc[74:64]=11'd1;
        expected_desc[95:80]=requester_q;
        expected_desc[103:96]=TAG;
        // Requester-ID-enable stays zero; the audited runtime BDF is required
        // in the Completion as well. TC/Attr/AT/poison/force-ECRC stay zero.
    end
    wire rq_matches = rq_data=={128'd0,expected_desc} && rq_keep==8'h0f &&
        rq_last && ((rq_user & ~RQ_SEQUENCE_MASK)==62'hf);
    wire rc_matches = rc_last && rc_keep==8'h0f &&
        rc_data[11:0]==address[11:0] && rc_data[15:12]==0 &&
        rc_data[28:16]==13'd4 && !rc_data[29] && rc_data[30] && !rc_data[31] &&
        rc_data[42:32]==11'd1 && rc_data[47:43]==0 &&
        rc_data[63:48]==requester_q && rc_data[71:64]==TAG &&
        rc_data[95:88]==0 && rc_data[127:96]==cookie_q &&
        rc_user[31:0]==32'h0000f000 && !rc_user[42];
    // The normal writer profile is monitored at native packet headers. This
    // is NOT a prevention/window filter: an invalid write may already have
    // reached the core when it is reported, so the mapping must stay pinned.
    wire [63:0] write_address={rq_data[63:2],2'b00};
    wire [10:0] write_dw=rq_data[74:64];
    wire [64:0] write_end={1'b0,write_address}+({54'd0,write_dw}<<2);
    wire normal_header_ok = rq_keep[3:0]==4'hf && rq_data[1:0]==0 &&
        rq_data[78:75]==4'd1 && !rq_data[79] && rq_data[127:104]==0 &&
        write_dw!=0 && write_dw<=32 && write_address>=base_q &&
        write_end<=({1'b0,base_q}+65'd8192) && !rq_user[11];
    wire rq_bad = rq_fire && (
        (state_q==READY && !rq_packet_q && !normal_header_ok) ||
        (state_q==TRANSMIT) ||
        (state_q==WAIT_RQ && !rq_matches) ||
        (state_q==WAIT_RC) || (state_q==OBSERVED));
    // An earlier, duplicate, unexpected-tag or malformed native Completion
    // quarantines the one-use object. It cannot be retried/reopened here.
    wire rc_bad = rc_fire && state_q!=UNCONFIGURED && state_q!=QUARANTINE &&
        (state_q!=WAIT_RC || !rc_matches);
    wire [31:0] faults = (context_bad ? F_CONTEXT : 0) |
        (deadline ? F_TIMEOUT : 0) | (rq_bad ? F_RQ : 0) | (rc_bad ? F_RC : 0);
    wire cfg_ok = cfg_buffer_base!=0 && cfg_buffer_base[11:0]==0 &&
        cfg_buffer_base<=64'hffffffffffffdfff && cfg_token!=0 &&
        cfg_requester_id!=0 && cfg_requester_id!=16'hffff && cfg_cookie!=0 &&
        !rq_fire && !rc_fire;
    assign cfg_ready=state_q==UNCONFIGURED && !faulted &&
        session_alive && profile_locked && !external_fault;
    assign start_ready=state_q==READY && !faulted && !context_bad;
    assign request_out.tdata=read_header;
    assign request_out.tkeepdw=4'hf;
    assign request_out.tlast=1;
    assign request_out.tuser=9'd1;
    assign request_out.tvalid=pending_q;
    assign request_out.has_data=pending_q;
    assign observed=state_q==OBSERVED && !faulted && !context_bad;
    assign busy=active || pending_q;
    assign spent=spent_q;
    assign release_allowed=1'b0;
    assign result_token=token_q;
    assign probe_address=address;
    initial if(C_WAIT_LIMIT<1) $fatal(1,"C_WAIT_LIMIT must be positive");
    always_ff @(posedge clk) begin
        if(rst) begin
            state_q<=UNCONFIGURED;base_q<=0;token_q<=0;requester_q<=0;cookie_q<=0;
            age_q<=0;pending_q<=0;spent_q<=0;rq_packet_q<=0;
            faulted<=0;reasons<=0;cfg_accepted<=0;cfg_rejected<=0;
            start_accepted<=0;start_rejected<=0;
        end else begin
            cfg_accepted<=0;cfg_rejected<=0;start_accepted<=0;start_rejected<=0;
            // Once offered, keep valid and all request fields stable even on
            // timeout/fault. Draining this offer is not evidence of completion.
            if(pending_q && request_out.tready) pending_q<=0;
            if(active && !deadline) age_q<=age_q+1'b1;
            if(rq_fire && state_q==READY) rq_packet_q<=!rq_last;
            if(state_q!=UNCONFIGURED && faults!=0) begin
                state_q<=QUARANTINE;faulted<=1;reasons<=reasons | faults;
            end else if(state_q==UNCONFIGURED) begin
                if(external_fault) begin state_q<=QUARANTINE;faulted<=1;reasons<=F_CONTEXT;end
                else if(cfg_valid && cfg_ready) begin
                    if(!cfg_ok) cfg_rejected<=1;
                    else begin
                        base_q<=cfg_buffer_base;token_q<=cfg_token;
                        requester_q<=cfg_requester_id;cookie_q<=cfg_cookie;
                        cfg_accepted<=1;state_q<=READY;
                    end
                end
            end else if(state_q==READY) begin
                if(start_valid && start_ready) begin
                    if(start_token!=token_q || !producers_stopped || rq_packet_q || rq_fire)
                        start_rejected<=1;
                    else begin
                        start_accepted<=1;spent_q<=1;pending_q<=1;age_q<=0;state_q<=TRANSMIT;
                    end
                end
            end else if(state_q==TRANSMIT) begin
                if(pending_q && request_out.tready) state_q<=WAIT_RQ;
            end else if(state_q==WAIT_RQ) begin
                if(rq_fire && rq_matches) state_q<=WAIT_RC;
            end else if(state_q==WAIT_RC) begin
                if(rc_fire && rc_matches) state_q<=OBSERVED;
            end
        end
    end
endmodule
`default_nettype wire
