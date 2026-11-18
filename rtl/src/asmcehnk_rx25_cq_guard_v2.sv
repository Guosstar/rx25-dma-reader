// Passive, default-OFF audit of the unchanged 256/88 CQ converter contract.
// Same clock observations. fault_now MUST reach the bridge before dispatch.
// Not a DMA fence, generic PCIe checker, payload authenticator, or CDC.
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_cq_guard_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter int C_WAIT_LIMIT=1000000
)(
    input wire clk,rst,session_alive,external_fault,
    input wire [255:0] cq_data,
    input wire [7:0] cq_keep,
    input wire [87:0] cq_user,
    input wire cq_valid,cq_ready,cq_last,
    input wire [127:0] raw_data,
    input wire [3:0] raw_keep,
    input wire [8:0] raw_user,
    input wire raw_valid,raw_ready,raw_last,
    output logic faulted,
    output wire fault_now,
    output logic [31:0] fault_reasons,
    output logic [31:0] accepted_packets,delivered_packets
);
    // Reason bits: native shape, unsupported descriptor, native protocol,
    // raw shape/context/order, raw protocol, deadline, lifecycle, external/config.
    logic busy,native_open,first_raw,first_flush,write_q,armed,cq_held,raw_held;
    logic [10:0] native_remaining,raw_remaining;
    logic [95:0] header_q;
    logic [6:0] bar_q;
    logic [352:0] cq_hold;
    logic [141:0] raw_hold;
    logic [31:0] wait_cycles;
    wire cq_fire=cq_valid && cq_ready;
    wire raw_fire=raw_valid && raw_ready;
    wire [10:0] length_dw=cq_data[74:64];
    wire is_write=cq_data[78:75]==4'd1;
    wire is_read=cq_data[78:75]==4'd0;
    wire [10:0] first_payload=length_dw>=4?11'd4:length_dw;
    wire [10:0] next_payload=native_remaining>=8?11'd8:native_remaining;
    wire [11:0] page_end={2'b0,cq_data[11:2]}+{1'b0,length_dw};
    wire supported=(is_read || is_write) && cq_data[63:32]==0 && cq_data[1:0]==0 &&
        length_dw!=0 && length_dw<=(is_write?11'd128:11'd1024) && page_end<=12'd1024 &&
        cq_data[114:112]<=6 && !cq_data[79] && cq_user[52:42]==0;
    function automatic [7:0] keep8(input logic [10:0] n);
        case(n)
            1:keep8=1;2:keep8=3;3:keep8=7;4:keep8=15;
            5:keep8=31;6:keep8=63;7:keep8=127;8:keep8=255;
            default:keep8=0;
        endcase
    endfunction
    wire [7:0] native_expected_keep=native_open?keep8(next_payload):
        (is_write?(8'h0f | (keep8(first_payload)<<4)):8'h0f);
    wire native_expected_last=native_open?(native_remaining<=8):(!is_write || length_dw<=4);
    wire native_shape=cq_fire && ((cq_keep!=native_expected_keep) || (cq_last!=native_expected_last));
    wire descriptor_error=cq_fire && !native_open && !supported;
    // PG213 256-bit nonstraddled CQ: SOP[40], discontinue[41].
    wire native_protocol=(cq_held && (!cq_valid || {cq_user,cq_last,cq_keep,cq_data}!=cq_hold)) ||
        (cq_fire && (cq_user[40]==native_open || cq_user[41] || (busy && !native_open)));
    wire [2:0] raw_dw_count=first_raw?(write_q?3'd4:3'd3):
        (raw_remaining>=(first_flush?11'd3:11'd4)?(first_flush?3'd3:3'd4):raw_remaining[2:0]);
    wire [3:0] raw_expected_keep=keep8({8'b0,raw_dw_count});
    wire raw_expected_last=raw_remaining=={8'b0,raw_dw_count};
    wire [8:0] raw_expected_user={first_raw?bar_q:7'd0,raw_expected_last,first_raw};
    // Inspect offered raw beats even while stalled, before downstream accepts.
    wire raw_shape=raw_valid && (!busy || native_open || raw_keep!=raw_expected_keep ||
        raw_last!=raw_expected_last || raw_user!=raw_expected_user ||
        (first_raw && raw_data[95:0]!=header_q));
    wire raw_protocol=raw_held && (!raw_valid || {raw_user,raw_last,raw_keep,raw_data}!=raw_hold);
    wire timeout_now=(busy || cq_held) && wait_cycles>=C_WAIT_LIMIT-1;
    wire lifecycle=armed && !session_alive;
    wire [31:0] causes=(native_shape?32'd1:0)|(descriptor_error?32'd2:0)|
        (native_protocol?32'd4:0)|(raw_shape?32'd8:0)|(raw_protocol?32'd16:0)|
        (timeout_now?32'd32:0)|(lifecycle?32'd64:0)|
        ((external_fault || C_WAIT_LIMIT<=0 || (!session_alive && cq_valid))?32'd128:0);
    assign fault_now=C_ENABLE && !rst && (faulted || causes!=0);
    wire [31:0] header0={is_write?3'b010:3'b000,5'b0,1'b0,cq_data[123:121],1'b0,cq_data[126],
        4'b0,cq_data[125:124],2'b0,length_dw[9:0]};
    always @(posedge clk) begin
        if(rst) begin
            busy<=0;native_open<=0;first_raw<=0;first_flush<=0;write_q<=0;armed<=0;
            cq_held<=0;raw_held<=0;native_remaining<=0;raw_remaining<=0;header_q<=0;bar_q<=0;
            cq_hold<=0;raw_hold<=0;wait_cycles<=0;faulted<=0;fault_reasons<=0;
            accepted_packets<=0;delivered_packets<=0;
        end else if(C_ENABLE) begin
            if(session_alive) armed<=1;
            if(fault_now) begin faulted<=1;fault_reasons<=fault_reasons|causes;end
            if(!faulted) begin
                cq_held<=cq_valid && !cq_ready;raw_held<=raw_valid && !raw_ready;
                if(cq_valid && !cq_ready) cq_hold<={cq_user,cq_last,cq_keep,cq_data};
                if(raw_valid && !raw_ready) raw_hold<={raw_user,raw_last,raw_keep,raw_data};
                if(busy || cq_held) begin
                    if(wait_cycles!=32'hffffffff) wait_cycles<=wait_cycles+1'b1;
                end else wait_cycles<=0;
                if(cq_fire && !fault_now) begin
                    if(!native_open) begin
                        busy<=1;native_open<=!cq_last;write_q<=is_write;first_raw<=1;first_flush<=0;
                        native_remaining<=length_dw-first_payload;
                        raw_remaining<=is_write?length_dw+11'd3:11'd3;
                        header_q<={cq_data[31:2],2'b0,cq_data[95:80],cq_data[103:96],cq_user[7:0],header0};
                        bar_q<=7'b1<<cq_data[114:112];
                        if(accepted_packets!=32'hffffffff) accepted_packets<=accepted_packets+1'b1;
                    end else begin
                        native_open<=!cq_last;native_remaining<=native_remaining-next_payload;
                    end
                end
                if(raw_fire && !fault_now) begin
                    first_raw<=0;first_flush<=first_raw && write_q;
                    raw_remaining<=raw_remaining-{8'b0,raw_dw_count};
                    if(raw_last) begin
                        busy<=0;wait_cycles<=0;
                        if(delivered_packets!=32'hffffffff) delivered_packets<=delivered_packets+1'b1;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
