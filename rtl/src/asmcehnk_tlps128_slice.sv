// ---------------------------------------------------------------------------
// asmcehnk_tlps128_slice -- two-deep AXIS-128 slice that breaks the ready path.
//
// The TX merge tree is a chain of packet-locked muxes, and each stage forwards
// tready combinationally.  Three stages of that chain land on the clock enable
// of asmcehnk_tlps128_src_elastic_us/stage_head_reg, which is the longest
// combinatorial path in the 250 MHz PCIe clock domain -- routed at 13 logic
// levels with a mux tree, 4.5 ns against a 4.0 ns budget.  Adding one more mux
// stage for the responder's MRds pushed the whole domain negative.
//
// This queue removes the chain from that path: `in.tready` here depends only on
// the write pointer, never on what the merge tree is doing downstream, so the
// elastic stage sees a two-level ready instead of thirteen.  It costs two beats
// of latency, which no part of this design is sensitive to -- PL11 frames and
// host commands are both latency-tolerant and neither is throughput-bound.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"

module asmcehnk_tlps128_slice (
    input  wire logic clk,
    input  wire logic rst,

    IfAXIS128.sink   tlps_in,
    IfAXIS128.source tlps_out
);

    logic [133:0] q0, q1;
    logic [1:0]   count;

    wire [133:0] in_word = {tlps_in.tuser[0], tlps_in.tlast,
                            tlps_in.tkeepdw, tlps_in.tdata};

    wire push = tlps_in.tvalid && (count != 2'd2);
    wire pop  = tlps_out.tvalid && tlps_out.tready;

    // The whole point of this module: ready depends on the local count only.
    assign tlps_in.tready = (count != 2'd2);

    assign tlps_out.tdata   = q0[127:0];
    assign tlps_out.tkeepdw = q0[131:128];
    assign tlps_out.tlast   = q0[132];
    assign tlps_out.tuser   = {8'd0, q0[133]};
    assign tlps_out.tvalid  = (count != 2'd0);
    assign tlps_out.has_data = (count != 2'd0) || push;

    always_ff @(posedge clk) begin
        if (rst) begin
            q0    <= 134'd0;
            q1    <= 134'd0;
            count <= 2'd0;
        end else begin
            case ({push, pop})
                2'b10: begin
                    if (count == 2'd0) q0 <= in_word;
                    else               q1 <= in_word;
                    count <= count + 2'd1;
                end
                2'b01: begin
                    q0    <= q1;
                    count <= count - 2'd1;
                end
                2'b11: begin
                    // One in, one out.  With a single entry queued q1 holds stale
                    // data, so the new word has to land in q0 or it is lost.
                    if (count == 2'd1) begin
                        q0 <= in_word;
                    end else begin
                        q0 <= q1;
                        q1 <= in_word;
                    end
                    count <= count;
                end
                default: count <= count;
            endcase
        end
    end

endmodule

`resetall
