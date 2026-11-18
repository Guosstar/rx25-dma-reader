// Registered, packet-locked round-robin Completion arbiter. Select by VALID,
// not speculative has_data. Lock on capture until LAST; hold output on stall.
// Local timeout quarantines new capture but never withdraws an offered beat.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_cpl_mux_v2 #(
    parameter int C_WAIT_LIMIT=1000000
)(
    input wire clk,rst,
    IfAXIS128.sink diagnostic_in,legacy_in,
    IfAXIS128.source completions_out,
    output logic faulted,
    output wire fault_now
);
    logic locked,owner,prefer_legacy,out_valid;
    logic [141:0] out_bundle;
    logic [31:0] wait_cycles;
    wire choose_legacy=locked?owner:(legacy_in.tvalid && (!diagnostic_in.tvalid || prefer_legacy));
    wire source_valid=choose_legacy?legacy_in.tvalid:diagnostic_in.tvalid;
    wire source_last=choose_legacy?legacy_in.tlast:diagnostic_in.tlast;
    wire space=!out_valid || completions_out.tready;
    assign fault_now=!rst && (faulted || C_WAIT_LIMIT<=0 ||
        ((locked || out_valid) && wait_cycles>=C_WAIT_LIMIT-1));
    wire capture=source_valid && space && !fault_now && !rst;
    assign diagnostic_in.tready=!rst && !fault_now && space && !choose_legacy;
    assign legacy_in.tready=!rst && !fault_now && space && choose_legacy;
    assign completions_out.tdata=out_bundle[127:0];
    assign completions_out.tkeepdw=out_bundle[131:128];
    assign completions_out.tlast=out_bundle[132];
    assign completions_out.tuser=out_bundle[141:133];
    assign completions_out.tvalid=out_valid && !rst;
    assign completions_out.has_data=out_valid || locked;
    wire output_fire=completions_out.tvalid && completions_out.tready;
    always @(posedge clk) begin
        if(rst) begin
            locked<=0;owner<=0;prefer_legacy<=0;out_valid<=0;out_bundle<=0;faulted<=0;wait_cycles<=0;
        end else begin
            if(fault_now) faulted<=1;
            if(capture) begin
                out_bundle<=choose_legacy?{legacy_in.tuser,legacy_in.tlast,legacy_in.tkeepdw,legacy_in.tdata}:
                    {diagnostic_in.tuser,diagnostic_in.tlast,diagnostic_in.tkeepdw,diagnostic_in.tdata};
                out_valid<=1;locked<=!source_last;owner<=choose_legacy;
                if(source_last) prefer_legacy<=!choose_legacy;
            end else if(output_fire) out_valid<=0;
            if(capture || output_fire || !(locked || out_valid)) wait_cycles<=0;
            else if(wait_cycles<32'hffffffff) wait_cycles<=wait_cycles+1'b1;
        end
    end
endmodule
`default_nettype wire
