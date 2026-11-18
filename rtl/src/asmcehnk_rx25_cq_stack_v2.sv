// OFFLINE / default-off native CQ + observed converter + BAR candidate stack.
// A fault never changes raw ready: preserve converter stability, block dispatch
// through the independent same-edge fault input instead. No board instance.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_cq_stack_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter int C_WAIT_LIMIT=1000000
)(
    input wire clk,rst,session_alive,external_fault,bar_en,
    input wire [15:0] pcie_id,
    taxi_axis_if.snk native_cq,
    taxi_axis_if.src error_cc,
    IfAXIS128.source_lite legacy_requests,
    IfAXIS128.sink legacy_completions,
    IfAXIS128.source completions_out,
    output wire fault_now,faulted,
    output wire [31:0] cq_reasons,
    output wire [31:0] accepted_packets,delivered_packets,
    output wire bridge_wr_en,bridge_rd_en,
    output wire [11:0] bridge_wr_addr,bridge_rd_addr,
    output wire [31:0] bridge_wr_data,
    output wire [3:0] bridge_wr_be,
    input wire [31:0] bridge_rd_data
);
    IfAXIS128 raw_stream(),events_in();
    wire guard_now,guard_fault,stack_now,stack_fault;
    asmcehnk_pcie_us_cq_to_tlps128 converter(.clk(clk),.rst(rst),.pcie_id(pcie_id),
        .s_axis_cq(native_cq),.tlps_out(raw_stream),.m_axis_cc_error(error_cc));
    assign raw_stream.tready=1'b1;
    assign events_in.tdata=raw_stream.tdata;assign events_in.tkeepdw=raw_stream.tkeepdw;
    assign events_in.tuser=raw_stream.tuser;assign events_in.tlast=raw_stream.tlast;
    assign events_in.tvalid=raw_stream.tvalid && raw_stream.tready;
    asmcehnk_rx25_cq_guard_v2 #(.C_ENABLE(C_ENABLE),.C_WAIT_LIMIT(C_WAIT_LIMIT)) guard(
        .clk(clk),.rst(rst),.session_alive(session_alive),.external_fault(external_fault),
        .cq_data(native_cq.tdata),.cq_keep(native_cq.tkeep),.cq_user(native_cq.tuser),
        .cq_valid(native_cq.tvalid),.cq_ready(native_cq.tready),.cq_last(native_cq.tlast),
        .raw_data(raw_stream.tdata),.raw_keep(raw_stream.tkeepdw),.raw_user(raw_stream.tuser),
        .raw_valid(raw_stream.tvalid),.raw_ready(raw_stream.tready),.raw_last(raw_stream.tlast),
        .faulted(guard_fault),.fault_now(guard_now),.fault_reasons(cq_reasons),
        .accepted_packets(accepted_packets),.delivered_packets(delivered_packets));
    asmcehnk_rx25_bar_stack_v2 #(.C_ENABLE(C_ENABLE),.C_RX25_MODE(1),.C_WAIT_LIMIT(C_WAIT_LIMIT)) stack(
        .clk(clk),.rst(rst),.bar_en(bar_en),.external_fault(external_fault),.upstream_loss(guard_now),.pcie_id(pcie_id),
        .events_in(events_in),.legacy_requests(legacy_requests),.legacy_completions(legacy_completions),
        .completions_out(completions_out),.fault_now(stack_now),.faulted(stack_fault),
        .ingress_ready(),.ingress_accepted(),.route_reasons(),.front_reasons(),
        .bridge_wr_en(bridge_wr_en),.bridge_rd_en(bridge_rd_en),.bridge_wr_addr(bridge_wr_addr),
        .bridge_rd_addr(bridge_rd_addr),.bridge_wr_data(bridge_wr_data),.bridge_wr_be(bridge_wr_be),.bridge_rd_data(bridge_rd_data));
    assign fault_now=guard_now || stack_now;assign faulted=guard_fault || stack_fault;
endmodule
`default_nettype wire
