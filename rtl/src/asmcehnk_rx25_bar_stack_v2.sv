// OFFLINE/default-off integration candidate; not instantiated on the board.
// Caller supplies post-handshake raw CQ events and a synchronous sticky loss
// indication covering any drop before them. No authentication/CDC is provided.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_bar_stack_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter bit C_RX25_MODE=1'b0,
    parameter int C_LEGACY_SLOTS=8,
    parameter int C_QUEUE_LOG2=5,
    parameter int C_WAIT_LIMIT=1000000
)(
    input wire clk,rst,bar_en,external_fault,upstream_loss,
    input wire [15:0] pcie_id,
    IfAXIS128.sink_lite events_in,
    IfAXIS128.source_lite legacy_requests,
    IfAXIS128.sink legacy_completions,
    IfAXIS128.source completions_out,
    output wire fault_now,faulted,ingress_ready,ingress_accepted,
    output wire [31:0] route_reasons,front_reasons,
    output wire bridge_wr_en,bridge_rd_en,
    output wire [11:0] bridge_wr_addr,bridge_rd_addr,
    output wire [31:0] bridge_wr_data,
    output wire [3:0] bridge_wr_be,
    input wire [31:0] bridge_rd_data
);
    localparam bit FRONT_ENABLE=C_ENABLE && C_RX25_MODE && C_LEGACY_SLOTS>=1 && C_LEGACY_SLOTS<=64;
    IfAXIS128 diagnostic_requests(),diagnostic_completions(),legacy_stream();
    wire route_fault,route_fault_now,front_fault,front_fault_now,mux_fault,mux_fault_now,legacy_fault,legacy_fault_now,layout_error;
    wire wr_valid,rd_req_valid,rd_rsp_valid;
    wire [6:0] wr_bar,rd_req_bar;
    wire [31:0] wr_addr,wr_data,rd_req_addr,rd_rsp_data;
    wire [3:0] wr_be;
    wire [87:0] rd_req_ctx,rd_rsp_ctx;
    asmcehnk_rx25_bar_route_v2 #(.C_ENABLE(C_ENABLE),.C_RX25_MODE(C_RX25_MODE),
        .C_LEGACY_SLOTS(C_LEGACY_SLOTS),.C_PACKET_WAIT(C_WAIT_LIMIT)) route(
        .clk(clk),.rst(rst),.bar_en(bar_en),.external_fault(external_fault || front_fault || mux_fault_now || legacy_fault_now),
        .upstream_loss(upstream_loss),.events_in(events_in),.legacy_out(legacy_requests),.diagnostic_out(diagnostic_requests),
        .faulted(route_fault),.fault_now(route_fault_now),.fault_reasons(route_reasons),.diagnostic_selected());
    asmcehnk_rx25_tlp_front_v2 #(.C_ENABLE(FRONT_ENABLE),.C_QUEUE_LOG2(C_QUEUE_LOG2),.C_WAIT_LIMIT(C_WAIT_LIMIT)) front(
        .clk(clk),.rst(rst),.external_fault(route_fault_now),.pcie_id(pcie_id),
        .tlps_in(diagnostic_requests),.tlps_in_valid(diagnostic_requests.tvalid),
        .ingress_ready(ingress_ready),.ingress_accepted(ingress_accepted),
        .faulted(front_fault),.fault_now(front_fault_now),.fault_reasons(front_reasons),
        .wr_valid(wr_valid),.rd_req_valid(rd_req_valid),.wr_bar(wr_bar),.rd_req_bar(rd_req_bar),
        .wr_addr(wr_addr),.wr_data(wr_data),.rd_req_addr(rd_req_addr),.wr_be(wr_be),.rd_req_ctx(rd_req_ctx),
        .rd_rsp_valid(rd_rsp_valid),.rd_rsp_data(rd_rsp_data),.rd_rsp_ctx(rd_rsp_ctx),.tlps_out(diagnostic_completions));
    // Always keep the DWORD adapter enabled for already accepted requests.
    // Falling bar_en quarantines through route_fault_now before dispatch.
    asmcehnk_rx25_bar_port_v2 #(.C_ENABLE(FRONT_ENABLE),.C_RX25_MODE(C_RX25_MODE),.C_LEGACY_SLOTS(C_LEGACY_SLOTS)) port_adapter(
        .clk(clk),.rst(rst),.bar_en(1'b1),.wr_bar(wr_bar),.rd_req_bar(rd_req_bar),
        .wr_valid(wr_valid),.rd_req_valid(rd_req_valid),.wr_addr(wr_addr),.wr_data(wr_data),.rd_req_addr(rd_req_addr),
        .wr_be(wr_be),.rd_req_ctx(rd_req_ctx),.wr_claim(),.rd_claim(),.layout_error(layout_error),
        .rd_rsp_valid(rd_rsp_valid),.rd_rsp_ctx(rd_rsp_ctx),.rd_rsp_data(rd_rsp_data),
        .bridge_wr_en(bridge_wr_en),.bridge_rd_en(bridge_rd_en),.bridge_wr_addr(bridge_wr_addr),.bridge_rd_addr(bridge_rd_addr),
        .bridge_wr_data(bridge_wr_data),.bridge_wr_be(bridge_wr_be),.bridge_rd_data(bridge_rd_data));
    generate if(C_ENABLE) begin:enabled_mux
        asmcehnk_rx25_legacy_cpl_v2 #(.C_WAIT_LIMIT(C_WAIT_LIMIT)) adapter(
            .clk(clk),.rst(rst),.legacy_fifo(legacy_completions),.stream_out(legacy_stream),
            .faulted(legacy_fault),.fault_now(legacy_fault_now));
        asmcehnk_rx25_cpl_mux_v2 #(.C_WAIT_LIMIT(C_WAIT_LIMIT)) mux(
            .clk(clk),.rst(rst),.diagnostic_in(diagnostic_completions),.legacy_in(legacy_stream),
            .completions_out(completions_out),.faulted(mux_fault),.fault_now(mux_fault_now));
    end else begin:legacy_bypass
        assign completions_out.tdata=legacy_completions.tdata;
        assign completions_out.tkeepdw=legacy_completions.tkeepdw;
        assign completions_out.tuser=legacy_completions.tuser;
        assign completions_out.tlast=legacy_completions.tlast;
        assign completions_out.tvalid=legacy_completions.tvalid;
        assign completions_out.has_data=legacy_completions.has_data;
        assign legacy_completions.tready=completions_out.tready;
        assign diagnostic_completions.tready=0;
        assign mux_fault=0;assign mux_fault_now=0;
        assign legacy_fault=0;assign legacy_fault_now=0;
    end endgenerate
    assign fault_now=C_ENABLE && (route_fault_now || front_fault_now || mux_fault_now || legacy_fault_now || layout_error);
    assign faulted=C_ENABLE && (route_fault || front_fault || mux_fault || legacy_fault);
endmodule
`default_nettype wire
