// Offline candidate for an EXCLUSIVELY ROUTED trusted diagnostic stream.
// Not connected to board. Strict one-DWORD 3DW MRd/MWr only; no general PCIe
// completer claim. Upstream must route whole packets and report any loss.
// A single ordered queue prevents a read from overtaking earlier writes.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_tlp_front_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter int C_QUEUE_LOG2=5,
    parameter int C_WAIT_LIMIT=1000000,
    parameter logic [63:0] C_TOKEN_START=64'd1
)(
    input wire clk,rst,external_fault,
    input wire [15:0] pcie_id,
    IfAXIS128.sink_lite tlps_in,
    input wire tlps_in_valid,
    output wire ingress_ready,ingress_accepted,
    output logic faulted,
    output wire fault_now,
    output logic [31:0] fault_reasons,
    output wire wr_valid,rd_req_valid,
    output wire [6:0] wr_bar,rd_req_bar,
    output wire [31:0] wr_addr,wr_data,rd_req_addr,
    output wire [3:0] wr_be,
    output wire [87:0] rd_req_ctx,
    input wire rd_rsp_valid,
    input wire [31:0] rd_rsp_data,
    input wire [87:0] rd_rsp_ctx,
    IfAXIS128.source tlps_out
);
    localparam int INDEX_W=(C_QUEUE_LOG2>=1 && C_QUEUE_LOG2<=8)?C_QUEUE_LOG2:1;
    localparam int DEPTH=2**INDEX_W;
    localparam bit LAYOUT_OK=C_QUEUE_LOG2>=1 && C_QUEUE_LOG2<=8 && C_WAIT_LIMIT>0 && C_TOKEN_START!=0;
    logic [127:0] queue[0:DEPTH-1];
    logic [INDEX_W-1:0] head,tail;
    logic [INDEX_W:0] count;
    logic read_wait,completion_valid;
    logic [127:0] pending,completion_data;
    logic [87:0] expected_context;
    logic [63:0] token;
    logic [31:0] wait_cycles;
    wire selected=C_ENABLE && !rst && tlps_in_valid;
    wire is_write=tlps_in.tdata[31:0]==32'h40000001;
    wire is_read=tlps_in.tdata[31:0]==32'h00000001;
    // Strict profile: TC/attributes/prefix/digest/poison/reserved all zero;
    // length exactly one, LastBE zero, all reads full DWORD. Other requests
    // are quarantined, not turned into a successful partial transaction.
    wire shape_ok=tlps_in.tvalid && tlps_in.tlast && tlps_in.tuser==9'b000000111 &&
        (is_write || is_read) && tlps_in.tkeepdw==(is_write?4'hf:4'h7) &&
        tlps_in.tdata[39:36]==0 &&
        (is_write || tlps_in.tdata[35:32]==4'hf) &&
        tlps_in.tdata[65:64]==0 && tlps_in.tdata[76:74]==3'b110;
    // FirstBE nonzero, including masks whose lowest two bits are zero.
    wire byte_enable_ok=tlps_in.tdata[35:32]!=0;
    wire can_dispatch=C_ENABLE && !rst && count!=0 && !read_wait && !completion_valid;
    wire token_exhausted=can_dispatch && !queue[head][30] && token==64'hffffffffffffffff;
    wire malformed=selected && (!shape_ok || !byte_enable_ok);
    // Conservatively reject a beat arriving while full, even if a pop could
    // have happened on that edge. The same-edge fault also blocks that pop.
    wire overflow=selected && count==DEPTH;
    wire bad_response=C_ENABLE && !rst && rd_rsp_valid &&
        (!read_wait || rd_rsp_ctx!=expected_context);
    wire timeout_now=C_ENABLE && !rst && (read_wait || completion_valid) && wait_cycles>=C_WAIT_LIMIT-1;
    wire [31:0] causes=(external_fault?32'd1:0)|(malformed?32'd2:0)|
        (overflow?32'd4:0)|(bad_response?32'd8:0)|(timeout_now?32'd16:0)|(token_exhausted?32'd32:0)|
        (!LAYOUT_OK?32'd64:0);
    assign fault_now=C_ENABLE && !rst && (faulted || causes!=0);
    assign ingress_ready=C_ENABLE && !rst && !fault_now && count<DEPTH;
    assign ingress_accepted=selected && !fault_now;
    wire pop=can_dispatch && !fault_now;
    assign wr_valid=pop && queue[head][30];
    assign rd_req_valid=pop && !queue[head][30];
    assign wr_bar=7'b1;assign rd_req_bar=7'b1;
    assign wr_addr=queue[head][95:64];assign rd_req_addr=queue[head][95:64];
    assign wr_data={queue[head][103:96],queue[head][111:104],queue[head][119:112],queue[head][127:120]};
    assign wr_be=queue[head][35:32];
    assign rd_req_ctx={24'h525832,token};
    assign tlps_out.tdata=completion_data;assign tlps_out.tvalid=completion_valid && !rst;
    assign tlps_out.tkeepdw=4'hf;assign tlps_out.tlast=1;
    assign tlps_out.tuser=9'b11;assign tlps_out.has_data=completion_valid && !rst;
    // Once offered, a Completion stays stable through fault/backpressure.
    // It describes a read sampled earlier; it does not certify a later fault
    // was absent. No NEW register dispatch is permitted once fault is known.
    always @(posedge clk) begin
        if(rst) begin
            head<=0;tail<=0;count<=0;faulted<=0;fault_reasons<=0;
            read_wait<=0;completion_valid<=0;completion_data<=0;pending<=0;
            expected_context<=0;token<=C_TOKEN_START;wait_cycles<=0;
        end else if(C_ENABLE) begin
            if(fault_now) begin faulted<=1;fault_reasons<=fault_reasons|causes;end
            if(ingress_accepted) begin queue[tail]<=tlps_in.tdata;tail<=tail+1'b1;end
            if(pop) head<=head+1'b1;
            case({ingress_accepted,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:;
            endcase
            if(rd_req_valid) begin
                pending<=queue[head];expected_context<=rd_req_ctx;
                token<=token+1'b1;read_wait<=1;
            end
            if(rd_rsp_valid && read_wait && !fault_now) begin
                read_wait<=0;completion_valid<=1;
                completion_data<={rd_rsp_data[7:0],rd_rsp_data[15:8],rd_rsp_data[23:16],rd_rsp_data[31:24],
                    pending[63:40],1'b0,pending[70:64],pcie_id[7:0],pcie_id[15:8],16'h0004,32'h4a000001};
            end
            if(completion_valid && tlps_out.tready) completion_valid<=0;
            if((read_wait || completion_valid) && !faulted) begin
                if(wait_cycles<32'hffffffff) wait_cycles<=wait_cycles+1'b1;
            end else wait_cycles<=0;
        end
    end
endmodule
`default_nettype wire
