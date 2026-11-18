// Offline/default-off native CQ -> guarded BAR stack -> shared native CC.
// Unsupported CQ globally quarantines dispatch; original converter UR remains
// eligible for CC arbitration. A CQ fault is NOT an instruction to discard CC.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_endpoint_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter int C_WAIT_LIMIT=1000000
)(
    input wire clk,rst,session_alive,external_fault,bar_en,
    input wire [15:0] pcie_id,
    taxi_axis_if.snk native_cq,
    taxi_axis_if.src native_cc,
    IfAXIS128.source_lite legacy_requests,
    IfAXIS128.sink legacy_completions,
    output wire fault_now,faulted,
    output wire [31:0] cq_reasons,cc_reasons,
    output wire [31:0] accepted_packets,delivered_packets,
    output wire bridge_wr_en,bridge_rd_en,
    output wire [11:0] bridge_wr_addr,bridge_rd_addr,
    output wire [31:0] bridge_wr_data,
    output wire [3:0] bridge_wr_be,
    input wire [31:0] bridge_rd_data
);
    IfAXIS128 raw_cpl();
    taxi_axis_if #(.DATA_W(256),.KEEP_W(8),.USER_EN(1),.USER_W(33)) error_cc(),error_native(),normal_cc(),normal_native();
    wire cq_now,cq_fault,cc_now,cc_fault;
    asmcehnk_rx25_cq_stack_v2 #(.C_ENABLE(C_ENABLE),.C_WAIT_LIMIT(C_WAIT_LIMIT)) cq_stack(
        .clk(clk),.rst(rst),.session_alive(session_alive),.external_fault(external_fault || cc_now),
        .bar_en(bar_en),.pcie_id(pcie_id),.native_cq(native_cq),.error_cc(error_cc),
        .legacy_requests(legacy_requests),.legacy_completions(legacy_completions),.completions_out(raw_cpl),
        .fault_now(cq_now),.faulted(cq_fault),.cq_reasons(cq_reasons),
        .accepted_packets(accepted_packets),.delivered_packets(delivered_packets),
        .bridge_wr_en(bridge_wr_en),.bridge_rd_en(bridge_rd_en),.bridge_wr_addr(bridge_wr_addr),
        .bridge_rd_addr(bridge_rd_addr),.bridge_wr_data(bridge_wr_data),.bridge_wr_be(bridge_wr_be),.bridge_rd_data(bridge_rd_data));
    asmcehnk_tlps128_to_axis_cc_us packetizer(.clk(clk),.rst(rst),.tlps_in(raw_cpl),.m_axis_cc(normal_cc));
    asmcehnk_rx25_cc_count_v2 #(.C_ENABLE(C_ENABLE)) counts(.clk(clk),.rst(rst),.cc_in(normal_cc),.cc_out(normal_native));
    // cfg_us publishes the historical internal {devfn,bus} pcie_id. Raw
    // Completion builders swap it; converter UR did not. Swap the CAPTURED
    // descriptor field, never the live ID, so a stalled beat stays stable.
    assign error_native.tdata=C_ENABLE ? {error_cc.tdata[255:88],error_cc.tdata[79:72],
        error_cc.tdata[87:80],error_cc.tdata[71:0]} : error_cc.tdata;
    assign error_native.tkeep=error_cc.tkeep;assign error_native.tstrb=error_cc.tstrb;
    assign error_native.tuser=error_cc.tuser;assign error_native.tlast=error_cc.tlast;
    assign error_native.tid=error_cc.tid;assign error_native.tdest=error_cc.tdest;
    assign error_native.tvalid=error_cc.tvalid;assign error_cc.tready=error_native.tready;
    asmcehnk_rx25_cc_mux_v2 #(.C_ENABLE(C_ENABLE),.C_WAIT_LIMIT(C_WAIT_LIMIT)) cc_mux(
        .clk(clk),.rst(rst),.external_fault(external_fault),.error_in(error_native),.normal_in(normal_native),
        .cc_out(native_cc),.fault_now(cc_now),.faulted(cc_fault),.reasons(cc_reasons));
    assign fault_now=cq_now || cc_now;
    assign faulted=cq_fault || cc_fault;
endmodule
`default_nettype wire
