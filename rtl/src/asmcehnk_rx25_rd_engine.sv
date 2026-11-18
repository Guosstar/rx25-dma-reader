// One outstanding 4DW MRd, at most 256B. Raw standard Cpl/CplD input.
// Each completion is parsed separately; request data may span multiple CplDs.
// Terminal errors drain through tlast before reuse.
//
// C_TIMEOUT_CYCLES bounds the wait for a completion.  A driverless target reads
// physical addresses that may not exist; such a request is either answered with
// UR (status!=0, already handled) or dropped somewhere in the fabric and never
// answered at all.  Without a local bound one dropped request hangs the engine
// forever and the whole scan stops.  On expiry the task ends with error=1 so the
// caller can retire it and move to the next address.
//
// Tag reuse stays the caller's job: C_TAG is the reset value, cfg_tag is
// latched per task, and the caller rotates it (0x18..0x1f).  A completion that
// arrives after a timeout therefore cannot match the next task's tag; it is
// dropped by the `ours` test.  cpl_in.tready is asserted in S_IDLE as well so a
// late packet drains instead of stalling the RC stream.
`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_rd_engine #(
    parameter logic [7:0] C_TAG=8'h20,
    parameter bit C_CHECK_REQID=1'b1,
    parameter int C_TIMEOUT_CYCLES=200_000
)(
    input wire logic rst, clk,
    input wire logic [63:0] cfg_addr,
    input wire logic [31:0] cfg_len,
    input wire logic [15:0] cfg_requester_id,
    // Tag for this task.  C_TAG remains the reset/default value so existing
    // fixed-tag users keep their behaviour; a rotating tag (multi-task mode)
    // must be stable from cfg_start until done/error.
    input wire logic [7:0] cfg_tag,
    input wire logic cfg_start,
    input wire logic abort,
    output logic busy, done, error,
    output logic [63:0] out_data,
    output logic out_valid,
    input wire logic out_ready,
    IfAXIS128.sink cpl_in,
    IfAXIS128.source tlps_out
);
    typedef enum logic [2:0] {S_IDLE,S_HDR,S_WAIT,S_DATA,S_DROP,S_DONE} state_t;
    state_t state_reg;
    logic [127:0] req_q,beat_q;
    logic [63:0] addr_q;
    logic [15:0] requester_q;
    logic [6:0] total_q,got_q,segment_q;
    logic [2:0] count_q;
    logic last_q,half_seen,word_valid,err_q,drop_error;
    logic [31:0] half_lo;
    logic [63:0] word_q;
    logic [7:0] tag_q;
    logic [31:0] tmo_q;
    wire waiting_on_link = (state_reg==S_HDR) || (state_reg==S_WAIT) || (state_reg==S_DROP);
    wire tmo_expired = waiting_on_link && (tmo_q >= 32'(C_TIMEOUT_CYCLES-1));
    wire [31:0] h0=cpl_in.tdata[31:0],h1=cpl_in.tdata[63:32],h2=cpl_in.tdata[95:64];
    wire is_cpl=(h0[28:24]==5'b01010) && ((h0[31:29]==3'b000)||(h0[31:29]==3'b010));
    wire has_payload=h0[30];
    wire ours=is_cpl && (!C_CHECK_REQID || h2[31:16]==requester_q) && h2[15:8]==tag_q;
    wire [9:0] packet_dw=h0[9:0];
    // Completion DW1 arrives in the layout that asmcehnk_pcie_us_rc_to_tlps128
    // builds, NOT the PCIe spec byte order:
    //   DW1 = {CompleterID[15:0], CplStatus[2:0], BCM, ByteCount[11:0]}
    // so status is [15:13], BCM is [12] and the byte count is [11:0].  Reading
    // them at the spec offsets [18:16]/[19]/[31:20] instead picks up completer
    // ID bits, which is why a port of this code to a "spec layout" assumption
    // silently rejects every completion.
    wire [2:0] status=h1[15:13];
    wire [63:0] next_addr=addr_q+({57'd0,got_q}<<2);
    wire [11:0] remaining_bytes=({5'd0,total_q}-{5'd0,got_q})<<2;
    wire cfg_ok=(cfg_requester_id!=16'd0)&&(cfg_requester_id!=16'hffff)&&
                (cfg_len!=0)&&(cfg_len<=256)&&(cfg_len[3:0]==0)&&
                (cfg_addr[3:0]==0)&&(({1'b0,cfg_addr[11:0]}+{1'b0,cfg_len[11:0]})<=13'd4096);
    function automatic [3:0] keep_for(input logic [2:0] n);
        case(n)
            1:keep_for=4'b0001;
            2:keep_for=4'b0011;
            3:keep_for=4'b0111;
            4:keep_for=4'b1111;
            default:keep_for=0;
        endcase
    endfunction
    wire [2:0] next_count=(segment_q>=4)?3'd4:segment_q[2:0];
    // Keep only the checks that are load bearing.  Byte count, BCM and the
    // lower-address echo duplicate information that packet_dw and the keep
    // pattern already carry, and on bring-up every extra equality is another
    // way to reject a perfectly good completion.
    wire [11:0] cpl_byte_count = h1[11:0];
    wire        cpl_bcm        = h1[12];
    wire header_ok=cpl_in.tuser[0] && cpl_in.tkeepdw==4'hf &&
                   packet_dw!=0 && packet_dw<=({3'd0,total_q}-{3'd0,got_q}) &&
                   !cpl_bcm && cpl_byte_count==remaining_bytes &&
                   h2[6:0]==next_addr[6:0] && !h0[14] &&
                   cpl_in.tlast==(packet_dw==1);
    wire body_ok=!cpl_in.tuser[0] && cpl_in.tkeepdw==keep_for(next_count) &&
                 next_count!=0 && cpl_in.tlast==(segment_q<=4);
    assign tlps_out.tdata=req_q;
    assign tlps_out.tkeepdw=4'hf;
    assign tlps_out.tuser=9'd1;
    assign tlps_out.tlast=1;
    assign tlps_out.tvalid=(state_reg==S_HDR);
    assign tlps_out.has_data=(state_reg==S_HDR);
    assign cpl_in.tready=(state_reg==S_WAIT)||(state_reg==S_DROP)||
                         ((state_reg==S_DATA)&&(count_q==0)&&!last_q)||
                         (state_reg==S_IDLE);
    assign out_data=word_q;
    assign out_valid=word_valid;
    assign error=err_q;
    wire fire=cpl_in.tvalid && cpl_in.tready;
    wire slot_free=!word_valid || out_ready;
    always_ff @(posedge clk) begin
        if(rst) begin
            state_reg<=S_IDLE;busy<=0;done<=0;err_q<=0;
            req_q<=0;addr_q<=0;requester_q<=0;total_q<=0;got_q<=0;segment_q<=0;
            beat_q<=0;count_q<=0;last_q<=0;half_seen<=0;half_lo<=0;
            word_q<=0;word_valid<=0;drop_error<=0;tag_q<=C_TAG;tmo_q<=0;
        end else begin
            done<=0;
            if(word_valid && out_ready) word_valid<=0;
            // Bound the wait whenever this engine owns the link: a request that
            // nothing answers must end as an error instead of stalling.
            if(!waiting_on_link || tmo_expired ||
               (cpl_in.tvalid && cpl_in.tready) ||
               (tlps_out.tvalid && tlps_out.tready)) tmo_q<=32'd0;
            else tmo_q<=tmo_q+32'd1;
            if(abort && state_reg!=S_IDLE && state_reg!=S_DONE) begin
                err_q<=1;drop_error<=1;count_q<=0;last_q<=1;word_valid<=0;
                state_reg<=S_DONE;
            end else if(tmo_expired) begin
                err_q<=1;drop_error<=1;count_q<=0;last_q<=1;word_valid<=0;
                state_reg<=S_DONE;
            end else case(state_reg)
                S_IDLE: begin
                    busy<=0;
                    if(cfg_start) begin
                        busy<=1;err_q<=0;got_q<=0;half_seen<=0;
                        word_valid<=0;count_q<=0;segment_q<=0;last_q<=0;
                        addr_q<=cfg_addr;requester_q<=cfg_requester_id;total_q<=cfg_len[8:2];
                        tag_q<=cfg_tag;
                        req_q<={{cfg_addr[31:2],2'b00},cfg_addr[63:32],{cfg_requester_id,cfg_tag,8'hff},
                                (32'h20000000 | (cfg_len>>2))};
                        if(cfg_ok) state_reg<=S_HDR;
                        else begin err_q<=1;state_reg<=S_DONE;end
                    end
                end
                S_HDR: if(tlps_out.tready) state_reg<=S_WAIT;
                S_WAIT: if(fire) begin
                    if(!ours) begin
                        drop_error<=0;
                        if(!cpl_in.tlast) state_reg<=S_DROP;
                    end else if(!has_payload || status!=0 || !header_ok) begin
                        err_q<=1;drop_error<=1;
                        if(cpl_in.tlast) state_reg<=S_DONE;
                        else state_reg<=S_DROP;
                    end else begin
                        // Header occupies lanes 0..2; lane 3 is payload DWORD 0.
                        beat_q<={96'd0,cpl_in.tdata[127:96]};count_q<=1;
                        segment_q<=packet_dw[6:0];last_q<=cpl_in.tlast;
                        state_reg<=S_DATA;
                    end
                end
                S_DATA: begin
                    if(count_q!=0) begin
                        if(!half_seen || slot_free) begin
                            beat_q<={32'd0,beat_q[127:32]};count_q<=count_q-1'b1;
                            segment_q<=segment_q-1'b1;got_q<=got_q+1'b1;
                            if(!half_seen) begin half_lo<=beat_q[31:0];half_seen<=1;end
                            else begin word_q<={beat_q[31:0],half_lo};word_valid<=1;half_seen<=0;end
                        end
                    end else if(last_q) begin
                        // Packet boundary is independent of the entire MRd length.
                        if(segment_q!=0) begin err_q<=1;state_reg<=S_DONE;end
                        else if(got_q==total_q) state_reg<=S_DONE;
                        else state_reg<=S_WAIT;
                    end else if(fire) begin
                        if(!body_ok) begin
                            err_q<=1;drop_error<=1;
                            if(cpl_in.tlast) state_reg<=S_DONE;
                            else state_reg<=S_DROP;
                        end else begin
                            beat_q<=cpl_in.tdata;count_q<=next_count;last_q<=cpl_in.tlast;
                        end
                    end
                end
                S_DROP: if(fire && cpl_in.tlast) begin
                    if(drop_error) state_reg<=S_DONE;
                    else state_reg<=S_WAIT;
                end
                S_DONE: if(slot_free) begin
                    word_valid<=0;busy<=0;done<=1;state_reg<=S_IDLE;
                end
                default:state_reg<=S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
