// Default-off raw CQ EVENT demultiplexer. Input is a one-cycle event after
// upstream handshake, NOT a ready/valid stream. No bus backpressure is added.
// Reserve the WHOLE memory request if its DWORD span intersects 1800..1bff.
// Unsupported reserved requests go to the strict frontend for quarantine;
// they must never fall back into the old BAR engines.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_bar_route_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter bit C_RX25_MODE=1'b0,
    parameter int C_LEGACY_SLOTS=8,
    parameter int C_PACKET_WAIT=1000000
)(
    input wire clk,rst,bar_en,external_fault,upstream_loss,
    IfAXIS128.sink_lite events_in,
    IfAXIS128.source_lite legacy_out,diagnostic_out,
    output logic faulted,
    output wire fault_now,
    output logic [31:0] fault_reasons,
    output wire diagnostic_selected
);
    localparam bit LAYOUT_OK=C_RX25_MODE && C_LEGACY_SLOTS>=1 && C_LEGACY_SLOTS<=64 && C_PACKET_WAIT>0;
    logic packet_open,packet_diagnostic,armed;
    logic [31:0] packet_cycles;
    wire event_valid=events_in.tvalid && !rst;
    wire first=events_in.tuser[0];
    wire [6:0] bars=events_in.tuser[8:2];
    wire bar0=bars[0];
    wire multi_bar=bars!=0 && (bars & (bars-1'b1))!=0;
    wire four_dw=events_in.tdata[29];
    wire memory_request=events_in.tdata[28:24]==0 && !events_in.tdata[31];
    wire header_present=events_in.tkeepdw[2:0]==7 && (!four_dw || events_in.tkeepdw[3]);
    wire [31:0] address=four_dw?events_in.tdata[127:96]:events_in.tdata[95:64];
    wire [10:0] length_dw=events_in.tdata[9:0]==0?11'd1024:{1'b0,events_in.tdata[9:0]};
    wire [11:0] end_dw={1'b0,address[12:2]}+{1'b0,length_dw};
    wire [10:0] page_end={1'b0,address[11:2]}+length_dw;
    wire intersects={1'b0,address[12:2]}<12'd1792 && end_dw>12'd1536;
    wire header_diagnostic=bar_en && bar0 && memory_request && header_present && intersects;
    wire selected=packet_open?packet_diagnostic:header_diagnostic;
    wire framing_error=event_valid && (first==packet_open || events_in.tuser[1]!=events_in.tlast);
    // Never decode a truncated/ambiguous BAR header or a cross-4KiB memory
    // request by guessing payload bits. BAR0 non-memory requests quarantine.
    wire header_error=event_valid && first && bar_en && (multi_bar ||
        (bar0 && (!memory_request || !header_present || page_end>11'd1024)));
    wire packet_timeout=packet_open && packet_cycles>=C_PACKET_WAIT-1;
    wire [31:0] causes=(external_fault?32'd1:0)|(upstream_loss?32'd2:0)|
        (framing_error?32'd4:0)|(header_error?32'd8:0)|(packet_timeout?32'd16:0)|
        ((armed && !bar_en)?32'd32:0)|(!LAYOUT_OK?32'd64:0);
    assign fault_now=C_ENABLE && !rst && (faulted || causes!=0);
    assign diagnostic_selected=C_ENABLE && LAYOUT_OK && selected;
    // No feedback from diagnostic's combinational fault into its own valid.
    // Stack feeds its REGISTERED fault here; bridge also sees frontend's
    // same-edge fault directly. This avoids a ready/valid/fault logic loop.
    assign diagnostic_out.tvalid=event_valid && C_ENABLE && LAYOUT_OK && !fault_now && selected;
    assign legacy_out.tvalid=event_valid && (!C_ENABLE || (!fault_now && !selected));
    assign diagnostic_out.tdata=events_in.tdata;assign legacy_out.tdata=events_in.tdata;
    assign diagnostic_out.tkeepdw=events_in.tkeepdw;assign legacy_out.tkeepdw=events_in.tkeepdw;
    assign diagnostic_out.tuser=events_in.tuser;assign legacy_out.tuser=events_in.tuser;
    assign diagnostic_out.tlast=events_in.tlast;assign legacy_out.tlast=events_in.tlast;
    always @(posedge clk) begin
        if(rst) begin
            packet_open<=0;packet_diagnostic<=0;packet_cycles<=0;armed<=0;faulted<=0;fault_reasons<=0;
        end else if(C_ENABLE) begin
            if(bar_en && LAYOUT_OK) armed<=1;
            if(fault_now) begin faulted<=1;fault_reasons<=fault_reasons|causes;end
            if(event_valid && !fault_now) begin
                packet_open<=!events_in.tlast;
                if(first) packet_diagnostic<=header_diagnostic;
            end
            if(packet_open && !faulted) begin
                if(packet_cycles<32'hffffffff) packet_cycles<=packet_cycles+1'b1;
            end else packet_cycles<=0;
        end
    end
endmodule
`default_nettype wire
