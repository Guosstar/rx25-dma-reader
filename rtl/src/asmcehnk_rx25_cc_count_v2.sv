// Native CC uses 11/13-bit explicit counts; raw PCIe TLP uses zero for
// 1024 DWORD / 4096 bytes. Expand only a first beat containing payload.
// No-data Completion (three descriptor DWORDs) is not reinterpreted.
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_cc_count_v2 #(
    parameter bit C_ENABLE=1'b0
)(
    input wire clk,rst,
    taxi_axis_if.snk cc_in,
    taxi_axis_if.src cc_out
);
    logic first_beat=1;
    wire payload_first=C_ENABLE && first_beat && cc_in.tkeep[3];
    assign cc_out.tdata={cc_in.tdata[255:43],
        (payload_first && cc_in.tdata[42:32]==0?11'd1024:cc_in.tdata[42:32]),
        cc_in.tdata[31:29],
        (payload_first && cc_in.tdata[28:16]==0?13'd4096:cc_in.tdata[28:16]),cc_in.tdata[15:0]};
    assign cc_out.tkeep=cc_in.tkeep;assign cc_out.tstrb=cc_in.tstrb;
    assign cc_out.tuser=cc_in.tuser;assign cc_out.tid=cc_in.tid;assign cc_out.tdest=cc_in.tdest;
    assign cc_out.tvalid=cc_in.tvalid;assign cc_out.tlast=cc_in.tlast;assign cc_in.tready=cc_out.tready;
    always @(posedge clk) begin
        if(rst) first_beat<=1;
        else if(cc_in.tvalid && cc_in.tready) first_beat<=cc_in.tlast;
    end
endmodule
`default_nettype wire
