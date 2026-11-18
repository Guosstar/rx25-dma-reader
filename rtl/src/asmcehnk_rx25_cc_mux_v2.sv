// Offline native CC candidate. Registered full-bundle, packet-locked RR.
// Fault stops new capture; an already offered beat survives until handshake.
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_cc_mux_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter int C_WAIT_LIMIT=1000000
)(
    input wire clk,rst,external_fault,
    taxi_axis_if.snk error_in,normal_in,
    taxi_axis_if.src cc_out,
    output wire fault_now,
    output logic faulted,
    output logic [31:0] reasons
);
    generate if(!C_ENABLE) begin: bypass
        asmcehnk_pcie_us_axis_cc_mux2 original(.clk(clk),.rst(rst),
            .s_axis_cc_error(error_in),.s_axis_cc_normal(normal_in),.m_axis_cc(cc_out));
        assign fault_now=0;
        always_comb begin faulted=0;reasons=0;end
    end else begin: enabled
        logic locked,owner,prefer_normal,out_valid;
        logic [321:0] out_bundle,error_held,normal_held;
        logic error_stalled,normal_stalled;
        logic [31:0] age;
        logic [7:0] packet_beats;
        wire [321:0] eb={error_in.tdest,error_in.tid,error_in.tuser,error_in.tlast,
            error_in.tstrb,error_in.tkeep,error_in.tdata};
        wire [321:0] nb={normal_in.tdest,normal_in.tid,normal_in.tuser,normal_in.tlast,
            normal_in.tstrb,normal_in.tkeep,normal_in.tdata};
        // Keep the full 322-bit, same-cycle stall check off long carry chains.
        // Three bit pairs fit one LUT6; explicit kept OR groups bound each
        // subsequent level. The two padding bits are constant on both sides.
        wire [323:0] error_compare={2'b0,eb},normal_compare={2'b0,nb};
        wire [323:0] error_reference={2'b0,error_held},normal_reference={2'b0,normal_held};
        (* keep="true" *) wire [107:0] error_changed_l1,normal_changed_l1;
        (* keep="true" *) wire [17:0] error_changed_l2,normal_changed_l2;
        (* keep="true" *) wire [2:0] error_changed_l3,normal_changed_l3;
        for(genvar group=0;group<108;group++) begin: compare_group
            assign error_changed_l1[group]=error_compare[group*3+:3]!=error_reference[group*3+:3];
            assign normal_changed_l1[group]=normal_compare[group*3+:3]!=normal_reference[group*3+:3];
        end
        for(genvar group=0;group<18;group++) begin: compare_reduce_l2
            assign error_changed_l2[group]=|error_changed_l1[group*6+:6];
            assign normal_changed_l2[group]=|normal_changed_l1[group*6+:6];
        end
        for(genvar group=0;group<3;group++) begin: compare_reduce_l3
            assign error_changed_l3[group]=|error_changed_l2[group*6+:6];
            assign normal_changed_l3[group]=|normal_changed_l2[group*6+:6];
        end
        wire error_bundle_changed=|error_changed_l3;
        wire normal_bundle_changed=|normal_changed_l3;
        wire choose_normal=locked?owner:(normal_in.tvalid && (!error_in.tvalid || prefer_normal));
        wire source_valid=choose_normal?normal_in.tvalid:error_in.tvalid;
        wire source_last=choose_normal?normal_in.tlast:error_in.tlast;
        wire [7:0] source_keep=choose_normal?normal_in.tkeep:error_in.tkeep;
        wire space=!out_valid || cc_out.tready;
        wire protocol_error=(error_stalled && (!error_in.tvalid || error_bundle_changed)) ||
            (normal_stalled && (!normal_in.tvalid || normal_bundle_changed));
        // DWORD-aligned nonstraddled CC. No Completion status/payload authentication.
        wire shape_error=source_valid && (source_keep==0 ||
            ((source_keep & (source_keep+8'd1))!=0) || (!source_last && source_keep!=8'hff));
        wire too_long=source_valid && packet_beats>=128 && !source_last;
        wire timeout_now=(locked || out_valid) && age>=C_WAIT_LIMIT-1;
        localparam bit BAD_WIDTHS=$bits(error_in.tdata)!=256 || $bits(normal_in.tdata)!=256 ||
            $bits(cc_out.tdata)!=256 || $bits(error_in.tkeep)!=8 || $bits(normal_in.tkeep)!=8 ||
            $bits(cc_out.tkeep)!=8 || $bits(error_in.tstrb)!=8 || $bits(normal_in.tstrb)!=8 ||
            $bits(cc_out.tstrb)!=8 || $bits(error_in.tuser)!=33 || $bits(normal_in.tuser)!=33 ||
            $bits(cc_out.tuser)!=33 || $bits(error_in.tid)!=8 || $bits(normal_in.tid)!=8 ||
            $bits(cc_out.tid)!=8 || $bits(error_in.tdest)!=8 || $bits(normal_in.tdest)!=8 || $bits(cc_out.tdest)!=8;
        wire [31:0] causes=(external_fault || C_WAIT_LIMIT<2 || BAD_WIDTHS?32'd1:0) |
            (protocol_error?32'd2:0) | (shape_error?32'd4:0) |
            (timeout_now?32'd8:0) | (too_long?32'd16:0);
        assign fault_now=!rst && (faulted || causes!=0);
        wire capture=!rst && !fault_now && space && source_valid;
        assign error_in.tready=!rst && !fault_now && space && !choose_normal;
        assign normal_in.tready=!rst && !fault_now && space && choose_normal;
        assign {cc_out.tdest,cc_out.tid,cc_out.tuser,cc_out.tlast,
            cc_out.tstrb,cc_out.tkeep,cc_out.tdata}=out_bundle;
        assign cc_out.tvalid=out_valid && !rst;
        wire output_fire=cc_out.tvalid && cc_out.tready;
        always @(posedge clk) begin
            if(rst) begin
                locked<=0;owner<=0;prefer_normal<=0;out_valid<=0;out_bundle<=0;
                error_stalled<=0;normal_stalled<=0;error_held<=0;normal_held<=0;
                age<=0;packet_beats<=0;faulted<=0;reasons<=0;
            end else begin
                if(fault_now) begin faulted<=1;reasons<=reasons|causes;end
                if(!faulted) begin
                    error_stalled<=error_in.tvalid && !error_in.tready;
                    normal_stalled<=normal_in.tvalid && !normal_in.tready;
                    error_held<=eb;normal_held<=nb;
                end
                if(capture) begin
                    out_bundle<=choose_normal?nb:eb;out_valid<=1;
                    locked<=!source_last;owner<=choose_normal;
                    if(source_last) begin prefer_normal<=!choose_normal;packet_beats<=0;end
                    else packet_beats<=packet_beats+1'b1;
                end else if(output_fire) out_valid<=0;
                // Whole-packet deadline, including source gaps and sink stalls.
                if(output_fire && cc_out.tlast || !(locked || out_valid)) age<=0;
                else if(age!=32'hffffffff) age<=age+1'b1;
            end
        end
    end endgenerate
endmodule
`default_nettype wire
