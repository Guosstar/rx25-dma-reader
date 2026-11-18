// Offline BAR DWORD-port adapter. NOT connected to the board controller.
// Same PCIe clock/reset as the bridge; no CDC, TLP completion, or MSI logic.
// Default off. Only the RX25 8KiB BAR0 personality with <=64 legacy slots
// may reserve 0x1800..0x1BFF. All other transactions remain unclaimed.
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_bar_port_v2 #(
    parameter bit C_ENABLE=1'b0,
    parameter bit C_RX25_MODE=1'b0,
    parameter int C_LEGACY_SLOTS=8
)(
    input wire clk,rst,bar_en,
    input wire [6:0] wr_bar,rd_req_bar,
    input wire wr_valid,rd_req_valid,
    input wire [31:0] wr_addr,wr_data,rd_req_addr,
    input wire [3:0] wr_be,
    input wire [87:0] rd_req_ctx,
    output wire wr_claim,rd_claim,layout_error,
    output logic rd_rsp_valid,
    output logic [87:0] rd_rsp_ctx,
    output logic [31:0] rd_rsp_data,
    output wire bridge_wr_en,bridge_rd_en,
    output wire [11:0] bridge_wr_addr,bridge_rd_addr,
    output wire [31:0] bridge_wr_data,
    output wire [3:0] bridge_wr_be,
    input wire [31:0] bridge_rd_data
);
    localparam bit LAYOUT_OK=C_RX25_MODE && C_LEGACY_SLOTS>=1 && C_LEGACY_SLOTS<=64;
    assign layout_error=C_ENABLE && !LAYOUT_OK;
    // BAR hit is already decoded upstream. An 8KiB BAR is 8KiB aligned,
    // including above 4GiB; no cfg_mgmt BAR-base subtraction is needed.
    // Reject non-one-hot BAR selects instead of letting two slaves claim.
    assign wr_claim=C_ENABLE && LAYOUT_OK && bar_en && !rst && wr_valid &&
        wr_bar==7'b0000001 && wr_addr[12:10]==3'b110;
    assign rd_claim=C_ENABLE && LAYOUT_OK && bar_en && !rst && rd_req_valid &&
        rd_req_bar==7'b0000001 && rd_req_addr[12:10]==3'b110;
    assign bridge_wr_en=wr_claim;
    assign bridge_rd_en=rd_claim;
    // Preserve low alignment bits and byte enables: the bridge must see
    // malformed/partial accesses, not an adapter-repaired transaction.
    assign bridge_wr_addr={2'b00,wr_addr[9:0]};
    assign bridge_rd_addr={2'b00,rd_req_addr[9:0]};
    assign bridge_wr_data=wr_data;
    assign bridge_wr_be=wr_be;
    logic valid_q;
    logic [87:0] context_q;
    logic [31:0] data_q;
    // Same two register stages as the legacy BAR response contract.
    // Sample data and context together at acceptance, never from next read.
    // A read concurrent with a write observes pre-edge register state;
    // a read accepted on a later edge observes the earlier write's effect.
    always @(posedge clk) begin
        if(rst) begin
            valid_q<=0;context_q<=0;data_q<=0;
            rd_rsp_valid<=0;rd_rsp_ctx<=0;rd_rsp_data<=0;
        end else begin
            valid_q<=rd_claim;
            context_q<=rd_req_ctx;
            data_q<=bridge_rd_data;
            rd_rsp_valid<=valid_q;
            rd_rsp_ctx<=context_q;
            rd_rsp_data<=data_q;
        end
    end
endmodule
`default_nettype wire
