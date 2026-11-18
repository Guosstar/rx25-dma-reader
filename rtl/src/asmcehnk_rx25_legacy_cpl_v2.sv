// Adapt the UNCHANGED legacy rdengine's standard-FIFO output contract:
// tready is a READ ENABLE, tvalid is a later one-cycle READ RESULT, and
// has_data advertises complete packets. This is NOT an ordinary AXI sink.
// At most one read is outstanding; capture into a stable ready/valid register.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_legacy_cpl_v2 #(
    parameter int C_WAIT_LIMIT=1000000
)(
    input wire clk,rst,
    IfAXIS128.sink legacy_fifo,
    IfAXIS128.source stream_out,
    output logic faulted,
    output wire fault_now
);
    logic pending,valid,advertised;
    logic [141:0] bundle;
    logic [31:0] wait_cycles;
    wire unexpected=legacy_fifo.tvalid && (!pending || valid);
    wire timeout_now=(pending || valid) && wait_cycles>=C_WAIT_LIMIT-1;
    assign fault_now=!rst && (faulted || unexpected || timeout_now || C_WAIT_LIMIT<=0);
    // pkt_count_next includes the write arriving at THIS edge. The standard
    // FIFO cannot read that first word while empty; qualify the advertisement
    // for one edge before issuing its single outstanding read.
    wire request_pop=!rst && !fault_now && !pending && !valid && advertised && legacy_fifo.has_data;
    assign legacy_fifo.tready=request_pop;
    assign stream_out.tdata=bundle[127:0];assign stream_out.tkeepdw=bundle[131:128];
    assign stream_out.tlast=bundle[132];assign stream_out.tuser=bundle[141:133];
    assign stream_out.tvalid=valid && !rst;assign stream_out.has_data=valid || pending;
    wire result_received=legacy_fifo.tvalid && pending && !valid;
    wire consumed=stream_out.tvalid && stream_out.tready;
    always @(posedge clk) begin
        if(rst) begin pending<=0;valid<=0;advertised<=0;bundle<=0;faulted<=0;wait_cycles<=0;end
        else begin
            advertised<=legacy_fifo.has_data;
            if(fault_now) faulted<=1;
            if(request_pop) pending<=1;
            // A result requested before a fault is still captured. It cannot
            // overwrite a held beat or authorize a new FIFO pop after fault.
            if(result_received) begin
                pending<=0;valid<=1;
                bundle<={legacy_fifo.tuser,legacy_fifo.tlast,legacy_fifo.tkeepdw,legacy_fifo.tdata};
            end else if(consumed) valid<=0;
            if(result_received || consumed || !(pending || valid)) wait_cycles<=0;
            else if(wait_cycles<32'hffffffff) wait_cycles<=wait_cycles+1'b1;
        end
    end
endmodule
`default_nettype wire
