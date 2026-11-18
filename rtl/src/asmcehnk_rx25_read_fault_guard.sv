// Single-use, single-owner native-RC fault guard for the real-read candidate.
// Integrator MUST gate new task acceptance with request_allowed, pulse
// request_issued from the actual native RQ handshake, and supply read_complete
// only after complete parser/data validation. Already asserted TX is not revoked.
// This guard is not connected to board RTL and never grants mapping release.
`resetall
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_read_fault_guard #(
    parameter integer C_WAIT_LIMIT=1000000,
    // C_MULTI_TASK=0 keeps the original one-shot-per-reset contract.  =1
    // reopens the owner after a validated completion and tag release, so a
    // host driver can issue a sequence of reads without resetting the core.
    parameter bit C_MULTI_TASK=1'b0,
    parameter integer C_QUIESCE=256
)(
    input wire logic clk,rst,
    input wire logic arm_valid,
    output wire logic arm_ready,
    output logic arm_accepted,arm_rejected,
    input wire logic [63:0] arm_epoch,arm_task,
    input wire logic [15:0] arm_requester,
    input wire logic [7:0] arm_tag,
    input wire logic link_ok,external_fault,
    input wire logic request_issued,read_complete,read_error,
    output wire logic request_allowed,stop_new_requests,spent,
    // Consumer-side acknowledgement for task_fail.  The responder asserts it on
    // the cycle it actually takes a record, or when it is idle (nothing in
    // flight to fail).  Without this the held level gets re-used as the done
    // for the *next* request and terminates it before its MRd is even issued.
    input wire logic task_fail_ack,
    // No engine/arm/reader activity in the pipeline.  Reopening before the old
    // transaction's output has drained would let stale data be attributed to
    // the next task.
    input wire logic pipeline_idle,
    taxi_axis_if.snk s_axis_rc,
    IfAXIS128.source tlps_out,
    output wire logic [7:0] tag_release,
    output logic tag_release_valid,
    output logic faulted,
    // Held until the consumer acknowledges it.  Never AND it into a done signal.
    output logic task_fail,
    output logic [15:0] first_causes,
    output logic first_descriptor_valid,
    output logic [95:0] first_descriptor,
    output logic [74:0] first_user,
    output logic [7:0] first_keep,
    output logic first_last,
    output logic [63:0] result_epoch,result_task,
    output wire logic release_allowed
);
    localparam logic [15:0] F_NATIVE=16'h1,F_STATUS=16'h2,F_POISON=16'h4,
        F_FORMAT=16'h8,F_IDENTITY=16'h10,F_TIMEOUT=16'h20,
        F_CONTEXT=16'h40,F_READER=16'h80;
    localparam integer AGE_W=(C_WAIT_LIMIT>1)?$clog2(C_WAIT_LIMIT):1;
    localparam logic [2:0] ST_OK=3'b000,ST_UR=3'b001,ST_CRS=3'b010,ST_CA=3'b100;
    logic armed_q,issued_q,completed_q,release_pending_q,release_sent_q,frame_q;
    logic [AGE_W-1:0] age_q;
    logic [15:0] quiesce_q;
    logic [15:0] requester_q;
    logic [7:0] tag_q;
    logic [95:0] packet_descriptor_q;
    logic packet_descriptor_valid_q;
    wire [7:0] raw_release;
    wire raw_release_valid;
    asmcehnk_pcie_us_rc_to_tlps128 converter(
        .clk(clk),.rst(rst),.s_axis_rc(s_axis_rc),.tlps_out(tlps_out),
        .tag_release(raw_release),.tag_release_valid(raw_release_valid));
    wire rc_fire=s_axis_rc.tvalid && s_axis_rc.tready;
    wire header_fire=rc_fire && !frame_q;
    wire keep_contiguous=(s_axis_rc.tkeep!=0) &&
        ((s_axis_rc.tkeep & (s_axis_rc.tkeep+8'd1))==0);
    wire [2:0] hdr_status=s_axis_rc.tdata[45:43];
    wire [3:0] hdr_native=s_axis_rc.tdata[15:12];
    wire [10:0] hdr_len_dw=s_axis_rc.tdata[42:32];
    wire hdr_rc=s_axis_rc.tdata[30];
    wire bad_native=header_fire && hdr_native!=0;
    wire bad_status=header_fire && hdr_status!=0;
    wire bad_poison=header_fire && s_axis_rc.tdata[46];
    wire bad_format=rc_fire && (!keep_contiguous || s_axis_rc.tuser[42] ||
        (!frame_q && s_axis_rc.tkeep[2:0]!=3'b111));
    // The converter emits its own release one or more cycles after the frame,
    // so a release arriving once the task is retired is expected residue of the
    // task we just reported, not an identity crime.  Only a release while a task
    // is still owned and whose tag disagrees is a real fault.
    wire bad_identity=(header_fire && (!issued_q || completed_q ||
        s_axis_rc.tdata[63:48]!=requester_q || s_axis_rc.tdata[71:64]!=tag_q)) ||
        (raw_release_valid && issued_q && raw_release!=tag_q);
    // A stray engine error after the task has already been retired must not be
    // able to latch the guard: that is the self-exciting loop that turns one
    // recoverable failure into a permanent one.  This is the only suppression
    // applied; every other fatal condition stays live at all times.
    wire bad_context=(armed_q && (!link_ok || external_fault)) ||
        (request_issued && !request_allowed) ||
        ((read_complete || read_error) && issued_q && completed_q);
    // Absolute age never restarts on unrelated or malformed traffic.
    // Completion at the exact deadline is conservatively a timeout.
    wire deadline=issued_q && !completed_q && age_q>=AGE_W'(C_WAIT_LIMIT-1);
    // A terminal error completion is a single beat that carries no payload,
    // reports UR or CA, and sets Request Completed.  CRS is not terminal: it
    // tells the requester to come back, so the tag must stay owned.
    //
    // The Error Code whitelist is the part that matters, and it comes straight
    // from PG213 (v1.3) Table 55, bits [15:12]:
    //   0000 normal           0001 poisoned
    //   0010 terminated by a Completion with UR, CA or CRS status
    //   0011 terminated by a Completion with no data / byte count too high
    //   0100 identity mismatch 0101 start address error 0110 invalid tag
    //   1000 terminated by FLR  1001 terminated by Completion timeout
    // Only 0010 and 0011 describe a Completion that actually came off the link.
    // 1000 and 1001 are fabricated descriptors: PG213 states every other field
    // except [30], [55:48] and [71:64] is invalid for them, so their status and
    // dword count must never be trusted as a terminal-error signature.
    wire err_code_from_link = (hdr_native==4'd2) || (hdr_native==4'd3);
    wire terminal_completion=header_fire && issued_q && s_axis_rc.tlast &&
        (hdr_len_dw==11'd0) && hdr_rc && !s_axis_rc.tdata[46] &&
        err_code_from_link &&
        ((hdr_status==ST_UR) || (hdr_status==ST_CA));
    // Fatal bits are computed independently of the recoverable decision so a
    // single recoverable reason can never veto a concurrent real fault.
    wire [15:0] fatal_bits=
        (bad_poison?F_POISON:0)|
        (bad_format?F_FORMAT:0)|
        (bad_identity?F_IDENTITY:0)|
        (bad_context?F_CONTEXT:0)|
        (deadline?F_TIMEOUT:0)|
        ((read_error&&issued_q)?F_READER:0)|
        ((bad_native&&!terminal_completion)?F_NATIVE:0)|
        ((bad_status&&!terminal_completion)?F_STATUS:0);
    // cause vector for diagnostics: keeps both bits even when a status is the
    // reason the beat was classified, so a captured value is never ambiguous.
    wire [15:0] causes=fatal_bits |
        (terminal_completion?F_STATUS:0) | (bad_native?F_NATIVE:0);
    // Fatal wins.  Local deadline is deliberately NOT recoverable: a missing
    // completion may still be in flight and there is no orphan tag set yet, so
    // timeout isolation belongs to a later stage and stays latched here.
    wire fatal_any=|fatal_bits;
    wire recoverable=terminal_completion && !fatal_any && !task_fail;
    wire arm_ok=arm_epoch!=0 && arm_task!=0 && arm_requester!=0 && arm_requester!=16'hffff;
    assign arm_ready=!armed_q && !faulted && link_ok && !external_fault && !rc_fire &&
                     !request_issued && !release_sent_q && !task_fail &&
                     (!C_MULTI_TASK || quiesce_q==0);
    assign request_allowed=armed_q && !issued_q && !faulted && link_ok && !external_fault;
    assign stop_new_requests=!request_allowed;
    assign spent=faulted || issued_q || (C_MULTI_TASK && quiesce_q!=0);
    assign tag_release=tag_q;
    // Tag accounting is separate from host-memory ownership/drain evidence.
    assign release_allowed=1'b0;
    initial if(C_WAIT_LIMIT<1) $fatal(1,"C_WAIT_LIMIT must be positive");
    always_ff @(posedge clk) begin
        if(rst) begin
            armed_q<=0;issued_q<=0;completed_q<=0;release_pending_q<=0;release_sent_q<=0;
            frame_q<=0;packet_descriptor_q<=0;packet_descriptor_valid_q<=0;
            age_q<=0;requester_q<=0;tag_q<=0;quiesce_q<=0;
            arm_accepted<=0;arm_rejected<=0;tag_release_valid<=0;faulted<=0;task_fail<=0;
            first_causes<=0;first_descriptor_valid<=0;first_descriptor<=0;
            first_user<=0;first_keep<=0;first_last<=0;result_epoch<=0;result_task<=0;
        end else begin
            arm_accepted<=0;arm_rejected<=0;tag_release_valid<=0;
            if(arm_valid) begin
                if(arm_ready && arm_ok) begin
                    armed_q<=1;result_epoch<=arm_epoch;result_task<=arm_task;
                    requester_q<=arm_requester;tag_q<=arm_tag;arm_accepted<=1;
                end else arm_rejected<=1;
            end
            if(request_issued && request_allowed) begin issued_q<=1;age_q<=0;end
            else if(issued_q && !completed_q && !faulted && !deadline) age_q<=age_q+1'b1;
            if(rc_fire) begin
                frame_q<=!s_axis_rc.tlast;
                if(!frame_q) begin
                    packet_descriptor_q<=s_axis_rc.tdata[95:0];
                    packet_descriptor_valid_q<=s_axis_rc.tkeep[2:0]==3'b111;
                end
            end
            if(raw_release_valid) release_pending_q<=1;
            if(read_complete && issued_q) completed_q<=1;
            if(!faulted && fatal_any) begin
                faulted<=1;first_causes<=causes;
                first_descriptor_valid<=rc_fire && (frame_q?packet_descriptor_valid_q:(s_axis_rc.tkeep[2:0]==3'b111));
                first_descriptor<=rc_fire ? (frame_q?packet_descriptor_q:s_axis_rc.tdata[95:0]) : 96'd0;
                first_user<=rc_fire?s_axis_rc.tuser:75'd0;
                first_keep<=rc_fire?s_axis_rc.tkeep:8'd0;
                first_last<=rc_fire?s_axis_rc.tlast:1'b0;
            end
            // Terminal error completion: report the failure once, retire the
            // task, and leave the owner reopenable.  The tag is safe to release
            // because a UR/CA completion is the one and only completion this
            // request will ever receive.
            if(recoverable) begin
                task_fail<=1'b1;
                first_causes<=causes;
                first_descriptor_valid<=1'b1;
                first_descriptor<=s_axis_rc.tdata[95:0];
                first_user<=s_axis_rc.tuser;
                first_keep<=s_axis_rc.tkeep;
                first_last<=s_axis_rc.tlast;
                // Retire immediately: no later completion is legal for this
                // request, and issued_q must drop so a delayed abort-induced
                // reader error cannot be re-judged as a new fault.
                armed_q<=0;issued_q<=0;completed_q<=0;age_q<=0;
                if(!release_sent_q) begin
                    tag_release_valid<=1'b1;release_sent_q<=1'b1;release_pending_q<=1'b1;
                end
            end
            // Consumer took the failure (or there was no record to fail).
            if(task_fail && task_fail_ack) task_fail<=1'b0;
            // Never forward a raw converter release before validated full data.
            if(issued_q && !release_sent_q && !faulted && causes==0 &&
               (completed_q || read_complete) && (release_pending_q || raw_release_valid)) begin
                tag_release_valid<=1;release_sent_q<=1;
            end
            // Reopen only after the tag was released, the failure was consumed,
            // the RC stream is quiet and the pipeline has drained.
            if(C_MULTI_TASK && !faulted) begin
                if(release_sent_q && !task_fail && !rc_fire && pipeline_idle) begin
                    armed_q<=0;issued_q<=0;completed_q<=0;
                    release_sent_q<=0;release_pending_q<=0;age_q<=0;
                    quiesce_q<=16'(C_QUIESCE);
                end else if(quiesce_q!=0) begin
                    quiesce_q<=rc_fire?16'(C_QUIESCE):(quiesce_q-16'd1);
                end
            end
        end
    end
endmodule
`default_nettype wire
