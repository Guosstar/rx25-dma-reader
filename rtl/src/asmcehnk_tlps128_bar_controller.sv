//
// asmcehnk FPGA.
//
// PCIe BAR PIO controller.
//
// The asmcehnk BAR PIO controller allows for easy user-implementation on top
// of the asmcehnk AXIS128 PCIe TLP streaming interface.
// The controller consists of a read engine and a write engine and pluggable
// user-implemented PCIe BAR implementations (found at bottom of the file).
//
// Considerations:
// - The core handles 1 DWORD read + 1 DWORD write per CLK max. If a lot of
//   data is written / read from the TLP streaming interface the core may
//   drop packet silently.
// - The core reads 1 DWORD of data (without byte enable) per CLK.
// - The core writes 1 DWORD of data (with byte enable) per CLK.
// - All user-implemented cores must have the same latency in CLKs for the
//   returned read data or else undefined behavior will take place.
// - 32-bit addresses are passed for read/writes. Larger BARs than 4GB are
//   not supported due to addressing constraints. Lower bits (LSBs) are the
//   BAR offset, Higher bits (MSBs) are the 32-bit base address of the BAR.
// - DO NOT edit read/write engines.
// - DO edit asmcehnk_tlps128_bar_controller (to swap bar implementations).
// - DO edit the bar implementations (at bottom of the file, if neccessary).
//
// Example implementations exists below, swap out any of the example cores
// against a core of your use case, or modify existing cores.
// Following test cores exist (see below in this file):
// - asmcehnk_bar_impl_zerowrite4k = zero-initialized read/write BAR.
//     It's possible to modify contents by use of .coe file.
// - asmcehnk_bar_impl_loopaddr = test core that loops back the 32-bit
//     address of the current read. Does not support writes.
// - asmcehnk_bar_impl_none = core without any reply.
// 
// (c) Ulf Frisk, 2024
// Author: Ulf Frisk, asmcehnk@frizk.net
//

`timescale 1ns / 1ps
`include "asmcehnk_header.svh"

module asmcehnk_tlps128_bar_controller #(
    parameter bit C_FIRST16 = 1'b0,
    parameter bit C_BATCH_DIAG = 1'b0,
    // BAR0 personality.  0 keeps the PCILeech identity block of the target-side
    // build.  1 swaps in the RX25 host ABI (asmcehnk_rx25_bar) so the stock
    // leechcore receiver backend and the NetUIO driver work unmodified.
    parameter bit C_RX25_MODE  = 1'b0,
    // 1 = this image is the link responder.  Only visible to the host, as
    // CAPS bit 8: two cards that enumerate identically are otherwise
    // indistinguishable, and flashing the initiator image onto both is a
    // failure mode that looks exactly like a dead link.
    parameter bit C_RX25_RESPONDER = 1'b0,
    parameter bit C_RX25_REAL_MEM = 1'b0,
    parameter int C_RX25_SLOTS = 8,
    // 1 = descriptor engine armed from reset (see asmcehnk_rx25_bar.C_ARM_ALWAYS)
    parameter bit C_RX25_ARM_ALWAYS = 1'b0
) (
    input rst,
    input clk,
    input bar_en,
    input wire [383:0] first16_registers,
    input wire [511:0] batch_registers,batch_owner_registers,
    input wire [1023:0] batch_pressure_registers,
    output wire [6:0] batch_payload_index,
    input wire [31:0] batch_payload_data,

    output                            int_enable,
    output                     [31:0] o_addr,
    output                     [31:0] o_data,
    input                      [31:0] base_address_register,
    input                      [15:0] pcie_id,
    // dbg_signal
    output                            dbg_rd_valid,
    output                     [63:0] dbg_rd_info,
    output                            dbg_wr_valid,
    output                     [63:0] dbg_wr_info,
           IfAXIS128.sink_lite        tlps_in,
           IfAXIS128.source           tlps_out,

    // DMA engine control (BAR offset 0x600).  Host writes target address, length
    // and a start pulse; the engine issues Memory Writes at that address.
    output bit [63:0] dma_addr,
    output bit [31:0] dma_len,
    output bit        dma_start,
    input      [31:0] dma_done,
    input             dma_busy,
    input             dma_error,

    // RX25 host ABI.  Only driven when C_RX25_MODE; in the default build every
    // output below is tied low so the identity path stays bit-identical to p22.
    output bit        rx25_enabled,
    input      [2:0]  rx25_link,          // {fatal, link_peer, link_up}
    input      [31:0] rx25_obs_tx_pkt,
    input      [31:0] rx25_obs_rx_pkt,
    input      [31:0] rx25_obs_status,
    input      [31:0] rx25_dbg_len,
    input      [31:0] rx25_dbg_remain,
    input             rx25_dbg_hdr_ok,
    input      [31:0] rx25_dbg_requests,
    input      [63:0] rx25_dbg_hdr0,
    input      [63:0] rx25_dbg_hdr1,
    input      [63:0] rx25_dbg_hdr2,
    input      [31:0] rx25_dbg_frames,
    input      [31:0] rx25_dbg_bad,
    input      [31:0] rx25_dbg_first,
    input      [31:0] rx25_dbg_magic,
    input      [31:0] rx25_dbg_start,
    input      [31:0] rx25_dbg_gate0,
    input      [31:0] rx25_dbg_gate1,
    output wire [7:0] rx25_bus_override,
    input      [31:0] rx25_init_bad,
    input      [31:0] rx25_init_tmo,
    input      [31:0] rx25_dbg_rx_magic,
    input      [31:0] rx25_dbg_rx_type,
    input      [31:0] rx25_dbg_rx_rid,
    input      [31:0] rx25_dbg_rx_len,
    input      [2:0]  rx25_dbg_state,
    input      [5:0]  rx25_dbg_buf_n,
    input      [31:0] rx25_dbg_rec_len,
    input      [2:0]  rx25_init_tmo_state,
    input      [31:0] rx25_dbg_buf_w0_lo,
    input      [31:0] rx25_dbg_buf_w0_hi,
    input      [31:0] rx25_dbg_buf_w1_lo,
    input      [31:0] rx25_dbg_buf_w1_hi,
    input      [63:0] rx25_mwr_addr_reg,
    input      [63:0] rx25_mwr_cfg_addr,
    input             rx25_dbg_in_frame,
    input      [7:0]  rx25_dbg_beats_in_frame,
    input      [31:0] rx25_dbg_rx_words,
    input      [31:0] rx25_dbg_rx_frames,
    output bit        rx25_job_valid,
    input             rx25_job_ready,
    output bit [7:0]  rx25_job_slot,
    output bit [31:0] rx25_job_request_id,
    output bit [15:0] rx25_job_generation,
    output bit [15:0] rx25_job_length,
    output bit [63:0] rx25_job_remote_pa,
    output bit [63:0] rx25_job_host_iova,
    input             rx25_cq_valid,
    input      [7:0]  rx25_cq_slot,
    input      [15:0] rx25_cq_status,
    input      [31:0] rx25_cq_bytes,
    input      [31:0] rx25_cq_detail,
    output bit        rx25_cqw_valid,
    output bit [63:0] rx25_cqw_addr,
    output bit [31:0] rx25_cqw_data,
    output bit [2:0]  rx25_cqw_index,
    input             rx25_cqw_done
);
    // ------------------------------------------------------------------------
    // 1: TLP RECEIVE:
    // Receive incoming BAR requests from the TLP stream:
    // send them onwards to read and write FIFOs
    // ------------------------------------------------------------------------
    wire in_is_wr_ready;
    bit in_is_wr_last;
    wire in_is_first = tlps_in.tuser[0];
    wire in_is_bar = bar_en && (tlps_in.tuser[8:2] != 0);
    wire in_is_rd       = (in_is_first && tlps_in.tlast && ((tlps_in.tdata[31:25] == 7'b0000000) || (tlps_in.tdata[31:25] == 7'b0010000) || (tlps_in.tdata[31:24] == 8'b00000010)));
    wire in_is_wr       = in_is_wr_last || (in_is_first && in_is_wr_ready && ((tlps_in.tdata[31:25] == 7'b0100000) || (tlps_in.tdata[31:25] == 7'b0110000) || (tlps_in.tdata[31:24] == 8'b01000010)));

    always @(posedge clk)
        if (rst) begin
            in_is_wr_last <= 0;
        end else if (tlps_in.tvalid) begin
            in_is_wr_last <= !tlps_in.tlast && in_is_wr;
        end

    wire [ 6:0] wr_bar;
    wire [31:0] wr_addr;
    wire [ 3:0] wr_be;
    wire [31:0] wr_data;
    wire        wr_valid;
    wire [87:0] rd_req_ctx;
    wire [ 6:0] rd_req_bar;
    wire [31:0] rd_req_addr;
    wire        rd_req_valid;
    wire [87:0] rd_rsp_ctx;
    wire [31:0] rd_rsp_data;
    wire        rd_rsp_valid;

    asmcehnk_tlps128_bar_rdengine i_asmcehnk_tlps128_bar_rdengine (
        .rst          (rst),
        .clk          (clk),
        // TLPs:
        .pcie_id      (pcie_id),
        .tlps_in      (tlps_in),
        .tlps_in_valid(tlps_in.tvalid && in_is_bar && in_is_rd),
        .tlps_out     (tlps_out),
        // BAR reads:
        .rd_req_ctx   (rd_req_ctx),
        .rd_req_bar   (rd_req_bar),
        .rd_req_addr  (rd_req_addr),
        .rd_req_valid (rd_req_valid),
        .rd_rsp_ctx   (rd_rsp_ctx),
        .rd_rsp_data  (rd_rsp_data),
        .rd_rsp_valid (rd_rsp_valid)
    );

    asmcehnk_tlps128_bar_wrengine i_asmcehnk_tlps128_bar_wrengine (
        .rst          (rst),
        .clk          (clk),
        // TLPs:
        .tlps_in      (tlps_in),
        .tlps_in_valid(tlps_in.tvalid && in_is_bar && in_is_wr),
        .tlps_in_ready(in_is_wr_ready),
        // outgoing BAR writes:
        .wr_bar       (wr_bar),
        .wr_addr      (wr_addr),
        .wr_be        (wr_be),
        .wr_data      (wr_data),
        .wr_valid     (wr_valid)
    );

    wire [87:0] bar_rsp_ctx  [7];
    wire [31:0] bar_rsp_data [7];
    wire        bar_rsp_valid[7];

    assign rd_rsp_ctx = bar_rsp_valid[0] ? bar_rsp_ctx[0] :
                        bar_rsp_valid[1] ? bar_rsp_ctx[1] :
                        bar_rsp_valid[2] ? bar_rsp_ctx[2] :
                        bar_rsp_valid[3] ? bar_rsp_ctx[3] :
                        bar_rsp_valid[4] ? bar_rsp_ctx[4] :
                        bar_rsp_valid[5] ? bar_rsp_ctx[5] :
                        bar_rsp_valid[6] ? bar_rsp_ctx[6] : 0;
    assign rd_rsp_data = bar_rsp_valid[0] ? bar_rsp_data[0] :
                        bar_rsp_valid[1] ? bar_rsp_data[1] :
                        bar_rsp_valid[2] ? bar_rsp_data[2] :
                        bar_rsp_valid[3] ? bar_rsp_data[3] :
                        bar_rsp_valid[4] ? bar_rsp_data[4] :
                        bar_rsp_valid[5] ? bar_rsp_data[5] :
                        bar_rsp_valid[6] ? bar_rsp_data[6] : 0;
    assign rd_rsp_valid = bar_rsp_valid[0] || bar_rsp_valid[1] || bar_rsp_valid[2] || bar_rsp_valid[3] || bar_rsp_valid[4] || bar_rsp_valid[5] || bar_rsp_valid[6];
    // assign dbg_rd_valid = rd_req_valid && rd_req_bar[0];

    // ------------------------------------------------------------------------
    // RX25 HOST ABI (BAR0 personality 2):
    // The register file and the eight descriptor slots are plain BAR0 dwords,
    // so the decode has to sit inside the BAR engine: the host writes a 32-byte
    // descriptor as eight consecutive dword writes and expects each one to land
    // in the slot.  asmcehnk_rx25_bar owns that state; i_bar0 only routes.
    // ------------------------------------------------------------------------
    wire        rx25_rd_sel;    // registered with the drd_* pipeline stage
    wire [13:0] rx25_rd_off;
    wire        rx25_wr_sel;    // registered with the dwr_* pipeline stage
    wire [13:0] rx25_wr_off;
    wire [31:0] rx25_wr_data;
    wire [31:0] rx25_rd_data;

    generate
        if (C_RX25_MODE) begin : g_rx25_bar
            asmcehnk_rx25_bar #(
                .C_FIRST16(C_FIRST16),
                .C_BATCH_DIAG(C_BATCH_DIAG),
                .C_ARM_ALWAYS(C_RX25_ARM_ALWAYS),
                .C_SLOTS(C_RX25_SLOTS),
                // bit8 = responder.  leechcore only looks at bit0 (DMA), so
                // this is free information for the host side.
                .C_CAPS (C_RX25_RESPONDER ? (C_RX25_REAL_MEM ? 32'h0000_030F : 32'h0000_010F) : 32'h0000_000F)
            ) i_rx25_bar (
                .first16_registers(first16_registers),
                .batch_registers(batch_registers),.batch_pressure_registers(batch_pressure_registers),
                .batch_owner_registers(batch_owner_registers),.batch_payload_index(batch_payload_index),
                .batch_payload_data(batch_payload_data),
                .clk            (clk),
                .rst            (rst),
                .bar_rd_off     (rx25_rd_off),
                .bar_wr_off     (rx25_wr_off),
                .bar_wr_en      (rx25_wr_sel),
                .bar_wr_data    (rx25_wr_data),
                .bar_rd_en      (rx25_rd_sel),
                .bar_rd_data    (rx25_rd_data),
                .job_valid      (rx25_job_valid),
                .job_ready      (rx25_job_ready),
                .job_slot       (rx25_job_slot),
                .job_request_id (rx25_job_request_id),
                .job_generation (rx25_job_generation),
                .job_length     (rx25_job_length),
                .job_remote_pa  (rx25_job_remote_pa),
                .job_host_iova  (rx25_job_host_iova),
                .cq_valid       (rx25_cq_valid),
                .cq_slot        (rx25_cq_slot),
                .cq_status      (rx25_cq_status),
                .cq_bytes       (rx25_cq_bytes),
                .cq_detail      (rx25_cq_detail),
                .cqw_valid      (rx25_cqw_valid),
                .cqw_addr       (rx25_cqw_addr),
                .cqw_data       (rx25_cqw_data),
                .cqw_index      (rx25_cqw_index),
                .cqw_done       (rx25_cqw_done),
                .obs_tx_pkt     (rx25_obs_tx_pkt),
                .obs_rx_pkt     (rx25_obs_rx_pkt),
                .obs_status     (rx25_obs_status),
                .dbg_len        (rx25_dbg_len),
                .dbg_remain     (rx25_dbg_remain),
                .dbg_hdr_ok     (rx25_dbg_hdr_ok),
                .dbg_requests   (rx25_dbg_requests),
                .dbg_hdr0       (rx25_dbg_hdr0),
                .dbg_hdr1       (rx25_dbg_hdr1),
                .dbg_hdr2       (rx25_dbg_hdr2),
                .dbg_frames     (rx25_dbg_frames),
                .dbg_bad        (rx25_dbg_bad),
                .dbg_first      (rx25_dbg_first),
                .dbg_magic      (rx25_dbg_magic),
                .dbg_start      (rx25_dbg_start),
                .dbg_gate0      (rx25_dbg_gate0),
                .dbg_gate1      (rx25_dbg_gate1),
                .bus_override   (rx25_bus_override),
                .init_bad       (rx25_init_bad),
                .init_tmo       (rx25_init_tmo),
                .rx_magic       (rx25_dbg_rx_magic),
                .rx_type        (rx25_dbg_rx_type),
                .rx_rid         (rx25_dbg_rx_rid),
                .rx_len         (rx25_dbg_rx_len),
                .rec_state      (rx25_dbg_state),
                .buf_n          (rx25_dbg_buf_n),
                .rec_len        (rx25_dbg_rec_len),
                .tmo_state      (rx25_init_tmo_state),
                .buf_w0_lo      (rx25_dbg_buf_w0_lo),
                .buf_w0_hi      (rx25_dbg_buf_w0_hi),
                .buf_w1_lo      (rx25_dbg_buf_w1_lo),
                .buf_w1_hi      (rx25_dbg_buf_w1_hi),
                .mwr_addr_lo    (rx25_mwr_addr_reg[31:0]),
                .mwr_addr_hi    (rx25_mwr_addr_reg[63:32]),
                .mwr_cfg_lo     (rx25_mwr_cfg_addr[31:0]),
                .mwr_cfg_hi     (rx25_mwr_cfg_addr[63:32]),
                .in_frame       (rx25_dbg_in_frame),
                .beats_in_frame (rx25_dbg_beats_in_frame),
                .rx_words       (rx25_dbg_rx_words),
                .rx_frames_cnt  (rx25_dbg_rx_frames),
                .link_peer      (rx25_link[1]),
                .link_up        (rx25_link[0]),
                .fatal_in       (rx25_link[2]),
                .enabled        (rx25_enabled)
            );
        end else begin : g_no_rx25_bar
            assign batch_payload_index=0;
            assign rx25_rd_data     = 32'd0;
            assign rx25_enabled     = 1'b0;
            assign rx25_job_valid   = 1'b0;
            assign rx25_job_slot    = 8'd0;
            assign rx25_job_request_id = 32'd0;
            assign rx25_job_generation = 16'd0;
            assign rx25_job_length  = 16'd0;
            assign rx25_job_remote_pa = 64'd0;
            assign rx25_job_host_iova = 64'd0;
            assign rx25_cqw_valid   = 1'b0;
            assign rx25_cqw_addr    = 64'd0;
            assign rx25_cqw_data    = 32'd0;
            assign rx25_cqw_index   = 3'd0;
        end
    endgenerate

    asmcehnk_bar_impl_asmusb #(
        .C_RX25_MODE     (C_RX25_MODE),
        .C_BATCH_DIAG(C_BATCH_DIAG),
        .C_RX25_RESPONDER(C_RX25_RESPONDER),
        .C_RX25_SLOTS    (C_RX25_SLOTS)
    ) i_bar0 (
        .rst                  (rst),
        .clk                  (clk),
        // dbg_info
        .dbg_rd_valid         (dbg_rd_valid),
        .dbg_rd_info          (dbg_rd_info),
        .dbg_wr_valid         (dbg_wr_valid),
        .dbg_wr_info          (dbg_wr_info),
        .wr_addr              (wr_addr),
        .wr_be                (wr_be),
        .wr_data              (wr_data),
        .wr_valid             (wr_valid && wr_bar[0]),
        .rd_req_ctx           (rd_req_ctx),
        .rd_req_addr          (rd_req_addr),
        .rd_req_valid         (rd_req_valid && rd_req_bar[0]),
        .int_enable           (int_enable),
        .base_address_register(base_address_register),
        .msix_addr            (o_addr),
        .msix_data            (o_data),
        .rd_rsp_ctx           (bar_rsp_ctx[0]),
        .rd_rsp_data          (bar_rsp_data[0]),
        .rd_rsp_valid         (bar_rsp_valid[0]),
        .dma_addr             (dma_addr),
        .dma_len              (dma_len),
        .dma_start            (dma_start),
        .dma_done             (dma_done),
        .dma_busy             (dma_busy),
        .dma_error            (dma_error),
        .rx25_sel             (rx25_rd_sel),
        .rx25_rd_off          (rx25_rd_off),
        .rx25_wr              (rx25_wr_sel),
        .rx25_wr_off          (rx25_wr_off),
        .rx25_wr_data         (rx25_wr_data),
        .rx25_rd_data         (rx25_rd_data)
    );

    asmcehnk_bar_impl_loopaddr i_bar1 (
        .rst         (rst),
        .clk         (clk),
        .wr_addr     (wr_addr),
        .wr_be       (wr_be),
        .wr_data     (wr_data),
        .wr_valid    (wr_valid && wr_bar[1]),
        .rd_req_ctx  (rd_req_ctx),
        .rd_req_addr (rd_req_addr),
        .rd_req_valid(rd_req_valid && rd_req_bar[1]),
        .rd_rsp_ctx  (bar_rsp_ctx[1]),
        .rd_rsp_data (bar_rsp_data[1]),
        .rd_rsp_valid(bar_rsp_valid[1])
    );

    asmcehnk_bar_impl_none i_bar2 (
        .rst         (rst),
        .clk         (clk),
        .wr_addr     (wr_addr),
        .wr_be       (wr_be),
        .wr_data     (wr_data),
        .wr_valid    (wr_valid && wr_bar[2]),
        .rd_req_ctx  (rd_req_ctx),
        .rd_req_addr (rd_req_addr),
        .rd_req_valid(rd_req_valid && rd_req_bar[2]),
        .rd_rsp_ctx  (bar_rsp_ctx[2]),
        .rd_rsp_data (bar_rsp_data[2]),
        .rd_rsp_valid(bar_rsp_valid[2])
    );

    asmcehnk_bar_impl_none i_bar3 (
        .rst         (rst),
        .clk         (clk),
        .wr_addr     (wr_addr),
        .wr_be       (wr_be),
        .wr_data     (wr_data),
        .wr_valid    (wr_valid && wr_bar[3]),
        .rd_req_ctx  (rd_req_ctx),
        .rd_req_addr (rd_req_addr),
        .rd_req_valid(rd_req_valid && rd_req_bar[3]),
        .rd_rsp_ctx  (bar_rsp_ctx[3]),
        .rd_rsp_data (bar_rsp_data[3]),
        .rd_rsp_valid(bar_rsp_valid[3])
    );

    asmcehnk_bar_impl_none i_bar4 (
        .rst         (rst),
        .clk         (clk),
        .wr_addr     (wr_addr),
        .wr_be       (wr_be),
        .wr_data     (wr_data),
        .wr_valid    (wr_valid && wr_bar[4]),
        .rd_req_ctx  (rd_req_ctx),
        .rd_req_addr (rd_req_addr),
        .rd_req_valid(rd_req_valid && rd_req_bar[4]),
        .rd_rsp_ctx  (bar_rsp_ctx[4]),
        .rd_rsp_data (bar_rsp_data[4]),
        .rd_rsp_valid(bar_rsp_valid[4])
    );

    asmcehnk_bar_impl_none i_bar5 (
        .rst         (rst),
        .clk         (clk),
        .wr_addr     (wr_addr),
        .wr_be       (wr_be),
        .wr_data     (wr_data),
        .wr_valid    (wr_valid && wr_bar[5]),
        .rd_req_ctx  (rd_req_ctx),
        .rd_req_addr (rd_req_addr),
        .rd_req_valid(rd_req_valid && rd_req_bar[5]),
        .rd_rsp_ctx  (bar_rsp_ctx[5]),
        .rd_rsp_data (bar_rsp_data[5]),
        .rd_rsp_valid(bar_rsp_valid[5])
    );

    asmcehnk_bar_impl_none i_bar6_optrom (
        .rst         (rst),
        .clk         (clk),
        .wr_addr     (wr_addr),
        .wr_be       (wr_be),
        .wr_data     (wr_data),
        .wr_valid    (wr_valid && wr_bar[6]),
        .rd_req_ctx  (rd_req_ctx),
        .rd_req_addr (rd_req_addr),
        .rd_req_valid(rd_req_valid && rd_req_bar[6]),
        .rd_rsp_ctx  (bar_rsp_ctx[6]),
        .rd_rsp_data (bar_rsp_data[6]),
        .rd_rsp_valid(bar_rsp_valid[6])
    );


endmodule



// ------------------------------------------------------------------------
// BAR WRITE ENGINE:
// Receives BAR WRITE TLPs and output BAR WRITE requests.
// Holds a 2048-byte buffer.
// Input flow rate is 16bytes/CLK (max).
// Output flow rate is 4bytes/CLK.
// If write engine overflows incoming TLP is completely discarded silently.
// ------------------------------------------------------------------------
module asmcehnk_tlps128_bar_wrengine (
    input                             rst,
    input                             clk,
    // TLPs:
           IfAXIS128.sink_lite        tlps_in,
    input                             tlps_in_valid,
    output                            tlps_in_ready,
    // outgoing BAR writes:
    output bit                 [ 6:0] wr_bar,
    output bit                 [31:0] wr_addr,
    output bit                 [ 3:0] wr_be,
    output bit                 [31:0] wr_data,
    output bit                        wr_valid
);

    wire         f_rd_en;
    wire [127:0] f_tdata;
    wire [  3:0] f_tkeepdw;
    wire [  8:0] f_tuser;
    wire         f_tvalid;

    bit  [127:0] tdata;
    bit  [  3:0] tkeepdw;
    bit          tlast;

    bit  [  3:0] be_first;
    bit  [  3:0] be_last;
    bit          first_dw;
    bit  [ 31:0] addr;

    fifo_141_141_clk1_bar_wr i_fifo_141_141_clk1_bar_wr (
        .srst      (rst),
        .clk       (clk),
        .wr_en     (tlps_in_valid),
        .din       ({tlps_in.tuser[8:0], tlps_in.tkeepdw, tlps_in.tdata}),
        .full      (),
        .prog_empty(tlps_in_ready),
        .rd_en     (f_rd_en),
        .dout      ({f_tuser, f_tkeepdw, f_tdata}),
        .empty     (),
        .valid     (f_tvalid)
    );

    // STATE MACHINE:
    `define S_ENGINE_IDLE 3'h0
    `define S_ENGINE_FIRST 3'h1
    `define S_ENGINE_4DW_REQDATA 3'h2
    `define S_ENGINE_TX0 3'h4
    `define S_ENGINE_TX1 3'h5
    `define S_ENGINE_TX2 3'h6
    `define S_ENGINE_TX3 3'h7
    (* KEEP = "TRUE" *) bit [3:0] state = `S_ENGINE_IDLE;

    assign f_rd_en = (state == `S_ENGINE_IDLE) ||
                     (state == `S_ENGINE_4DW_REQDATA) ||
                     (state == `S_ENGINE_TX3) ||
                     ((state == `S_ENGINE_TX2 && !tkeepdw[3])) ||
                     ((state == `S_ENGINE_TX1 && !tkeepdw[2])) ||
                     ((state == `S_ENGINE_TX0 && !f_tkeepdw[1]));

    always @(posedge clk) begin
        wr_addr <= addr;
        wr_valid    <= ((state == `S_ENGINE_TX0) && f_tvalid) || (state == `S_ENGINE_TX1) || (state == `S_ENGINE_TX2) || (state == `S_ENGINE_TX3);

    end

    always @(posedge clk)
        if (rst) begin
            state <= `S_ENGINE_IDLE;
        end else
            case (state)
                `S_ENGINE_IDLE: begin
                    state <= `S_ENGINE_FIRST;
                end
                `S_ENGINE_FIRST: begin
                    if (f_tvalid && f_tuser[0]) begin
                        wr_bar   <= f_tuser[8:2];
                        tdata    <= f_tdata;
                        tkeepdw  <= f_tkeepdw;
                        tlast    <= f_tuser[1];
                        first_dw <= 1;
                        be_first <= f_tdata[35:32];
                        be_last  <= f_tdata[39:36];
                        if (f_tdata[31:29] == 8'b010) begin  // 3 DW header, with data
                            addr  <= {f_tdata[95:66], 2'b00};
                            state <= `S_ENGINE_TX3;
                        end else if (f_tdata[31:29] == 8'b011) begin  // 4 DW header, with data
                            addr  <= {f_tdata[127:98], 2'b00};
                            state <= `S_ENGINE_4DW_REQDATA;
                        end
                    end else begin
                        state <= `S_ENGINE_IDLE;
                    end
                end
                `S_ENGINE_4DW_REQDATA: begin
                    state <= `S_ENGINE_TX0;
                end
                `S_ENGINE_TX0: begin
                    tdata <= f_tdata;
                    tkeepdw <= f_tkeepdw;
                    tlast <= f_tuser[1];
                    addr <= addr + 4;
                    wr_data <= {
                        f_tdata[0+00+:8], f_tdata[0+08+:8], f_tdata[0+16+:8], f_tdata[0+24+:8]
                    };
                    first_dw <= 0;
                    wr_be <= first_dw ? be_first : (f_tkeepdw[1] ? 4'hf : be_last);
                    state       <= f_tvalid ? (f_tkeepdw[1] ? `S_ENGINE_TX1 : `S_ENGINE_FIRST) : `S_ENGINE_IDLE;
                end
                `S_ENGINE_TX1: begin
                    addr <= addr + 4;
                    wr_data <= {tdata[32+00+:8], tdata[32+08+:8], tdata[32+16+:8], tdata[32+24+:8]};
                    first_dw <= 0;
                    wr_be <= first_dw ? be_first : (tkeepdw[2] ? 4'hf : be_last);
                    state <= tkeepdw[2] ? `S_ENGINE_TX2 : `S_ENGINE_FIRST;
                end
                `S_ENGINE_TX2: begin
                    addr <= addr + 4;
                    wr_data <= {tdata[64+00+:8], tdata[64+08+:8], tdata[64+16+:8], tdata[64+24+:8]};
                    first_dw <= 0;
                    wr_be <= first_dw ? be_first : (tkeepdw[3] ? 4'hf : be_last);
                    state <= tkeepdw[3] ? `S_ENGINE_TX3 : `S_ENGINE_FIRST;
                end
                `S_ENGINE_TX3: begin
                    addr <= addr + 4;
                    wr_data <= {tdata[96+00+:8], tdata[96+08+:8], tdata[96+16+:8], tdata[96+24+:8]};
                    first_dw <= 0;
                    wr_be <= first_dw ? be_first : (!tlast ? 4'hf : be_last);
                    state <= !tlast ? `S_ENGINE_TX0 : `S_ENGINE_FIRST;
                end
            endcase

endmodule



// ------------------------------------------------------------------------
// BAR READ ENGINE:
// Receives BAR READ TLPs and output BAR READ requests.
// ------------------------------------------------------------------------
module asmcehnk_tlps128_bar_rdengine (
    input                             rst,
    input                             clk,
    // TLPs:
    input                      [15:0] pcie_id,
           IfAXIS128.sink_lite        tlps_in,
    input                             tlps_in_valid,
           IfAXIS128.source           tlps_out,
    // BAR reads:
    output                     [87:0] rd_req_ctx,
    output                     [ 6:0] rd_req_bar,
    output                     [31:0] rd_req_addr,
    output                            rd_req_valid,
    input                      [87:0] rd_rsp_ctx,
    input                      [31:0] rd_rsp_data,
    input                             rd_rsp_valid
);

    // ------------------------------------------------------------------------
    // 1: PROCESS AND QUEUE INCOMING READ TLPs:
    // ------------------------------------------------------------------------
    wire [10:0] rd1_in_dwlen = (tlps_in.tdata[9:0] == 0) ? 11'd1024 : {1'b0, tlps_in.tdata[9:0]};
    wire [6:0] rd1_in_bar = tlps_in.tuser[8:2];
    wire [15:0] rd1_in_reqid = tlps_in.tdata[63:48];
    wire [7:0] rd1_in_tag = tlps_in.tdata[47:40];
    wire [31:0] rd1_in_addr = {
        ((tlps_in.tdata[31:29] == 3'b000) ? tlps_in.tdata[95:66] : tlps_in.tdata[127:98]), 2'b00
    };
    wire [73:0] rd1_in_data;
    assign rd1_in_data[73:63] = rd1_in_dwlen;
    assign rd1_in_data[62:56] = rd1_in_bar;
    assign rd1_in_data[55:48] = rd1_in_tag;
    assign rd1_in_data[47:32] = rd1_in_reqid;
    assign rd1_in_data[31:0]  = rd1_in_addr;

    wire        rd1_out_rden;
    wire [73:0] rd1_out_data;
    wire        rd1_out_valid;

    fifo_74_74_clk1_bar_rd1 i_fifo_74_74_clk1_bar_rd1 (
        .srst (rst),
        .clk  (clk),
        .wr_en(tlps_in_valid),
        .din  (rd1_in_data),
        .full (),
        .rd_en(rd1_out_rden),
        .dout (rd1_out_data),
        .empty(),
        .valid(rd1_out_valid)
    );

    // ------------------------------------------------------------------------
    // 2: PROCESS AND SPLIT READ TLPs INTO RESPONSE TLP READ REQUESTS AND QUEUE:
    //    (READ REQUESTS LARGER THAN 128-BYTES WILL BE SPLIT INTO MULTIPLE).
    // ------------------------------------------------------------------------

    wire [10:0] rd1_out_dwlen = rd1_out_data[73:63];
    wire [4:0] rd1_out_dwlen5 = rd1_out_data[67:63];
    wire [4:0] rd1_out_addr5 = rd1_out_data[6:2];

    // 1st "instant" packet:
    wire [4:0]  rd2_pkt1_dwlen_pre  = ((rd1_out_addr5 + rd1_out_dwlen5 > 6'h20) || ((rd1_out_addr5 != 0) && (rd1_out_dwlen5 == 0))) ? (6'h20 - rd1_out_addr5) : rd1_out_dwlen5;
    wire [5:0] rd2_pkt1_dwlen = (rd2_pkt1_dwlen_pre == 0) ? 6'h20 : rd2_pkt1_dwlen_pre;
    wire [10:0] rd2_pkt1_dwlen_next = rd1_out_dwlen - rd2_pkt1_dwlen;
    wire rd2_pkt1_large = (rd1_out_dwlen > 32) || (rd1_out_dwlen != rd2_pkt1_dwlen);
    wire rd2_pkt1_tiny = (rd1_out_dwlen == 1);
    wire [11:0] rd2_pkt1_bc = rd1_out_dwlen << 2;
    wire [85:0] rd2_pkt1;
    assign rd2_pkt1[85:74] = rd2_pkt1_bc;
    assign rd2_pkt1[73:63] = rd2_pkt1_dwlen;
    assign rd2_pkt1[62:0]  = rd1_out_data[62:0];

    // Nth packet (if split should take place):
    bit [10:0] rd2_total_dwlen;
    wire [10:0] rd2_total_dwlen_next = rd2_total_dwlen - 11'h20;

    bit [85:0] rd2_pkt2;
    wire [10:0] rd2_pkt2_dwlen = rd2_pkt2[73:63];
    wire rd2_pkt2_large = (rd2_total_dwlen > 11'h20);

    wire rd2_out_rden;

    // STATE MACHINE:
    `define S2_ENGINE_REQDATA 1'h0
    `define S2_ENGINE_PROCESSING 1'h1
    (* KEEP = "TRUE" *) bit [0:0] state2 = `S2_ENGINE_REQDATA;

    always @(posedge clk)
        if (rst) begin
            state2 <= `S2_ENGINE_REQDATA;
        end else
            case (state2)
                `S2_ENGINE_REQDATA: begin
                    if (rd1_out_valid && rd2_pkt1_large) begin
                        rd2_total_dwlen <= rd2_pkt1_dwlen_next;  // dwlen (total remaining)
                        rd2_pkt2[85:74] <= rd2_pkt1_dwlen_next << 2;  // byte-count
                        rd2_pkt2[73:63] <= (rd2_pkt1_dwlen_next > 11'h20) ? 11'h20 : rd2_pkt1_dwlen_next;   // dwlen next
                        rd2_pkt2[62:12] <= rd1_out_data[62:12];  // various data
                        rd2_pkt2[11:0]  <= rd1_out_data[11:0] + (rd2_pkt1_dwlen << 2);      // base address (within 4k page)
                        state2 <= `S2_ENGINE_PROCESSING;
                    end
                end
                `S2_ENGINE_PROCESSING: begin
                    if (rd2_out_rden) begin
                        rd2_total_dwlen <= rd2_total_dwlen_next;  // dwlen (total remaining)
                        rd2_pkt2[85:74] <= rd2_total_dwlen_next << 2;  // byte-count
                        rd2_pkt2[73:63] <= (rd2_total_dwlen_next > 11'h20) ? 11'h20 : rd2_total_dwlen_next;   // dwlen next
                        rd2_pkt2[62:12] <= rd2_pkt2[62:12];  // various data
                        rd2_pkt2[11:0]  <= rd2_pkt2[11:0] + (rd2_pkt2_dwlen << 2);              // base address (within 4k page)
                        if (!rd2_pkt2_large) begin
                            state2 <= `S2_ENGINE_REQDATA;
                        end
                    end
                end
            endcase

    assign rd1_out_rden = rd2_out_rden && (((state2 == `S2_ENGINE_REQDATA) && (!rd1_out_valid || rd2_pkt1_tiny)) || ((state2 == `S2_ENGINE_PROCESSING) && !rd2_pkt2_large));

    wire [85:0] rd2_in_data = (state2 == `S2_ENGINE_REQDATA) ? rd2_pkt1 : rd2_pkt2;
    wire rd2_in_valid = rd1_out_valid || ((state2 == `S2_ENGINE_PROCESSING) && rd2_out_rden);

    bit [85:0] rd2_out_data;
    bit rd2_out_valid;
    always @(posedge clk) begin
        rd2_out_data  <= rd2_in_valid ? rd2_in_data : rd2_out_data;
        rd2_out_valid <= rd2_in_valid && !rst;
    end

    // ------------------------------------------------------------------------
    // 3: PROCESS EACH READ REQUEST PACKAGE PER INDIVIDUAL 32-bit READ DWORDS:
    // ------------------------------------------------------------------------

    wire [4:0] rd2_out_dwlen = rd2_out_data[67:63];
    wire rd2_out_last = (rd2_out_dwlen == 1);
    wire [9:0] rd2_out_dwaddr = rd2_out_data[11:2];

    wire rd3_enable;

    bit rd3_process_valid;
    bit rd3_process_first;
    bit rd3_process_last;
    bit [4:0] rd3_process_dwlen;
    bit [9:0] rd3_process_dwaddr;
    bit [85:0] rd3_process_data;
    wire rd3_process_next_last = (rd3_process_dwlen == 2);
    wire rd3_process_nextnext_last = (rd3_process_dwlen <= 3);

    assign rd_req_ctx   = {rd3_process_first, rd3_process_last, rd3_process_data};
    assign rd_req_bar   = rd3_process_data[62:56];
    assign rd_req_addr  = {rd3_process_data[31:12], rd3_process_dwaddr, 2'b00};
    assign rd_req_valid = rd3_process_valid;

    // STATE MACHINE:
    `define S3_ENGINE_REQDATA 1'h0
    `define S3_ENGINE_PROCESSING 1'h1
    (* KEEP = "TRUE" *) bit [0:0] state3 = `S3_ENGINE_REQDATA;

    always @(posedge clk)
        if (rst) begin
            rd3_process_valid <= 1'b0;
            state3            <= `S3_ENGINE_REQDATA;
        end else
            case (state3)
                `S3_ENGINE_REQDATA: begin
                    if (rd2_out_valid) begin
                        rd3_process_valid <= 1'b1;
                        rd3_process_first <= 1'b1;  // FIRST
                        rd3_process_last        <= rd2_out_last;            // LAST (low 5 bits of dwlen == 1, [max pktlen = 0x20))
                        rd3_process_dwlen <= rd2_out_dwlen;  // PKT LENGTH IN DW
                        rd3_process_dwaddr <= rd2_out_dwaddr;  // DWADDR OF THIS DWORD
                        rd3_process_data[85:0] <= rd2_out_data[85:0];  // FORWARD / SAVE DATA
                        if (!rd2_out_last) begin
                            state3 <= `S3_ENGINE_PROCESSING;
                        end
                    end else begin
                        rd3_process_valid <= 1'b0;
                    end
                end
                `S3_ENGINE_PROCESSING: begin
                    rd3_process_first  <= 1'b0;  // FIRST
                    rd3_process_last   <= rd3_process_next_last;  // LAST
                    rd3_process_dwlen  <= rd3_process_dwlen - 1;  // LEN DEC
                    rd3_process_dwaddr <= rd3_process_dwaddr + 1;  // ADDR INC
                    if (rd3_process_next_last) begin
                        state3 <= `S3_ENGINE_REQDATA;
                    end
                end
            endcase

    assign rd2_out_rden = rd3_enable && (
        ((state3 == `S3_ENGINE_REQDATA) && (!rd2_out_valid || rd2_out_last)) ||
        ((state3 == `S3_ENGINE_PROCESSING) && rd3_process_nextnext_last));

    // ------------------------------------------------------------------------
    // 4: PROCESS RESPONSES:
    // ------------------------------------------------------------------------

    wire rd_rsp_first = rd_rsp_ctx[87];
    wire rd_rsp_last = rd_rsp_ctx[86];

    wire [9:0] rd_rsp_dwlen = rd_rsp_ctx[72:63];
    wire [11:0] rd_rsp_bc = rd_rsp_ctx[85:74];
    wire [15:0] rd_rsp_reqid = rd_rsp_ctx[47:32];
    wire [7:0] rd_rsp_tag = rd_rsp_ctx[55:48];
    wire [6:0] rd_rsp_lowaddr = rd_rsp_ctx[6:0];
    wire [31:0] rd_rsp_addr = rd_rsp_ctx[31:0];
    wire [31:0] rd_rsp_data_bs = {
        rd_rsp_data[7:0], rd_rsp_data[15:8], rd_rsp_data[23:16], rd_rsp_data[31:24]
    };

    // 1: 32-bit -> 128-bit state machine:
    bit [127:0] tdata;
    bit [3:0] tkeepdw = 0;
    bit tlast;
    bit first = 1;
    wire tvalid = tlast || tkeepdw[3];

    always @(posedge clk)
        if (rst) begin
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 0;
        end else if (rd_rsp_valid && rd_rsp_first) begin
            tkeepdw <= 4'b1111;
            tlast <= rd_rsp_last;
            first <= 1'b1;
            tdata[31:0] <= {22'b0100101000000000000000, rd_rsp_dwlen};  // format, type, length
            tdata[63:32] <= {pcie_id[7:0], pcie_id[15:8], 4'b0, rd_rsp_bc};  // pcie_id, byte_count
            tdata[95:64] <= {
                rd_rsp_reqid, rd_rsp_tag, 1'b0, rd_rsp_lowaddr
            };  // req_id, tag, lower_addr
            tdata[127:96] <= rd_rsp_data_bs;
        end else begin
            tlast <= rd_rsp_valid && rd_rsp_last;
            tkeepdw <= tvalid ? (rd_rsp_valid ? 4'b0001 : 4'b0000) : (rd_rsp_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            first <= 0;
            if (rd_rsp_valid) begin
                if (tvalid || !tkeepdw[0]) tdata[31:0] <= rd_rsp_data_bs;
                if (!tkeepdw[1]) tdata[63:32] <= rd_rsp_data_bs;
                if (!tkeepdw[2]) tdata[95:64] <= rd_rsp_data_bs;
                if (!tkeepdw[3]) tdata[127:96] <= rd_rsp_data_bs;
            end
        end

    // 2.1 - submit to output fifo - will feed into mux/pcie core.
    fifo_134_134_clk1_bar_rdrsp i_fifo_134_134_clk1_bar_rdrsp (
        .srst      (rst),
        .clk       (clk),
        .din       ({first, tlast, tkeepdw, tdata}),
        .wr_en     (tvalid),
        .rd_en     (tlps_out.tready),
        .dout      ({tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata}),
        .full      (),
        .empty     (),
        .prog_empty(rd3_enable),
        .valid     (tlps_out.tvalid)
    );

    assign tlps_out.tuser[1]   = tlps_out.tlast;
    assign tlps_out.tuser[8:2] = 0;

    // 2.2 - packet count:
    bit [10:0] pkt_count = 0;
    wire pkt_count_dec = tlps_out.tvalid && tlps_out.tlast;
    wire pkt_count_inc = tvalid && tlast;
    wire [10:0] pkt_count_next = pkt_count + pkt_count_inc - pkt_count_dec;
    assign tlps_out.has_data = (pkt_count_next > 0);

    always @(posedge clk) begin
        pkt_count <= rst ? 0 : pkt_count_next;
    end

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation that does nothing but drop any read/writes
// silently without generating a response.
// This is only recommended for placeholder designs.
// Latency = N/A.
// ------------------------------------------------------------------------
module asmcehnk_bar_impl_none (
    input             rst,
    input             clk,
    // incoming BAR writes:
    input      [31:0] wr_addr,
    input      [ 3:0] wr_be,
    input      [31:0] wr_data,
    input             wr_valid,
    // incoming BAR reads:
    input      [87:0] rd_req_ctx,
    input      [31:0] rd_req_addr,
    input             rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0] rd_rsp_ctx,
    output bit [31:0] rd_rsp_data,
    output bit        rd_rsp_valid
);

    initial rd_rsp_ctx = 0;
    initial rd_rsp_data = 0;
    initial rd_rsp_valid = 0;

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation of "address loopback" which can be useful
// for testing. Any read to a specific BAR address will result in the
// address as response.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module asmcehnk_bar_impl_loopaddr (
    input             rst,
    input             clk,
    // incoming BAR writes:
    input      [31:0] wr_addr,
    input      [ 3:0] wr_be,
    input      [31:0] wr_data,
    input             wr_valid,
    // incoming BAR reads:
    input      [87:0] rd_req_ctx,
    input      [31:0] rd_req_addr,
    input             rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0] rd_rsp_ctx,
    output bit [31:0] rd_rsp_data,
    output bit        rd_rsp_valid
);

    bit [87:0] rd_req_ctx_1;
    bit [31:0] rd_req_addr_1;
    bit        rd_req_valid_1;

    always @(posedge clk) begin
        rd_req_ctx_1   <= rd_req_ctx;
        rd_req_addr_1  <= rd_req_addr;
        rd_req_valid_1 <= rd_req_valid;
        rd_rsp_ctx     <= rd_req_ctx_1;
        rd_rsp_data    <= rd_req_addr_1;
        rd_rsp_valid   <= rd_req_valid_1;
    end

endmodule



// ------------------------------------------------------------------------
// Example BAR implementation of a 4kB writable initial-zero BAR.
// Latency = 2CLKs.
// ------------------------------------------------------------------------
module asmcehnk_bar_impl_zerowrite4k (
    input             rst,
    input             clk,
    // incoming BAR writes:
    input      [31:0] wr_addr,
    input      [ 3:0] wr_be,
    input      [31:0] wr_data,
    input             wr_valid,
    // incoming BAR reads:
    input      [87:0] rd_req_ctx,
    input      [31:0] rd_req_addr,
    input             rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0] rd_rsp_ctx,
    output bit [31:0] rd_rsp_data,
    output bit        rd_rsp_valid
);

    bit  [87:0] drd_req_ctx;
    bit         drd_req_valid;
    wire [31:0] doutb;

    always @(posedge clk) begin
        drd_req_ctx   <= rd_req_ctx;
        drd_req_valid <= rd_req_valid;
        rd_rsp_ctx    <= drd_req_ctx;
        rd_rsp_valid  <= drd_req_valid;
        rd_rsp_data   <= doutb;
    end

    bram_bar_zero4k i_bram_bar_zero4k (
        // Port A - write:
        .addra(wr_addr[11:2]),
        .clka (clk),
        .dina (wr_data),
        .ena  (wr_valid),
        .wea  (wr_be),
        // Port A - read (2 CLK latency):
        .addrb(rd_req_addr[11:2]),
        .clkb (clk),
        .doutb(doutb),
        .enb  (rd_req_valid)
    );

endmodule

`define BAR_ADDR_WIDTH 14
module asmcehnk_bar_impl_asmusb #(
    parameter bit C_RX25_MODE  = 1'b0,
    parameter bit C_BATCH_DIAG = 1'b0,
    parameter bit C_RX25_RESPONDER = 1'b0,
    parameter int C_RX25_SLOTS = 8
) (
    input              rst,
    input              clk,
    // interrupt enable
    output wire        int_enable,
    output bit  [31:0] msix_addr,
    output bit  [31:0] msix_data,

    // incoming BAR writes:
    input      [31:0] wr_addr,
    input      [ 3:0] wr_be,
    input      [31:0] wr_data,
    input             wr_valid,
    // incoming BAR reads:
    input      [87:0] rd_req_ctx,
    input      [31:0] rd_req_addr,
    input      [ 3:0] rd_req_be,
    input             rd_req_valid,
    input      [31:0] base_address_register,
    // dbg signal,
    output            dbg_rd_valid,
    output     [63:0] dbg_rd_info,
    output            dbg_wr_valid,
    output     [63:0] dbg_wr_info,
    // outgoing BAR read replies:
    output bit [87:0] rd_rsp_ctx,
    output bit [31:0] rd_rsp_data,
    output bit        rd_rsp_valid,

    // DMA engine control.  At BAR offset 0x600: 0x000-0x460 is the PCILeech
    // identity block and 0x1000+ is outside the 4 KB window, so 0x600 is the
    // free block that is actually reachable from the host.
    output bit [63:0] dma_addr,
    output bit [31:0] dma_len,
    output bit        dma_start,
    input      [31:0] dma_done,
    input             dma_busy,
    input             dma_error,

    // RX25 window.  rx25_sel / rx25_wr are registered on the request cycle, so
    // they line up exactly with the drd_* / dwr_* pipeline stage below.  The
    // read and write offsets are separate because a write can land while a read
    // reply is still in flight.
    output bit        rx25_sel,
    output bit [13:0] rx25_rd_off,
    output bit        rx25_wr,
    output bit [13:0] rx25_wr_off,
    output bit [31:0] rx25_wr_data,
    input      [31:0] rx25_rd_data
);

    bit  [87:0] drd_req_ctx;
    bit  [31:0] drd_req_addr;
    bit  [ 3:0] drd_req_be;
    bit         drd_req_valid;
    bit  [31:0] rd_rsp_addr;
    bit  [ 3:0] dwr_be;
    bit  [31:0] dwr_addr;
    bit  [31:0] dwr_data;
    bit         dwr_valid;
    //  bit [31:0]      efuseaddr;
    bit  [31:0] data_32;
    bit  [31:0] last_addr;
    bit  [31:0] off_20;
    bit  [31:0] off_24;
    bit  [31:0] dma_addr_lo;
    bit  [31:0] dma_addr_hi;
    bit  [31:0] dma_len_reg;
    //   bit [32:0]      data_record;
    //   bit [31:0]      wr_record;
    wire [31:0] doutb;

    // ---- RX25 window decode -------------------------------------------------
    // 0x000-0x1FF is the register page, 0x1000 + n*0x20 the descriptor slots.
    // In RX25 mode the PCILeech identity block (0x200-0x5FF and 0x640-0xFFF) is
    // masked to zero instead of leaking identity words into the RX25 register
    // file.  0x600-0x63F stays reachable: that is the AS02 DMA debug block, not
    // part of the identity, and dmatest has to keep working on the RX25 image.
    localparam logic [13:0] RX25_REG_END   = 14'h0200;
    localparam logic [13:0] RX25_SLOT_BASE = 14'h1000;
    localparam logic [13:0] RX25_SLOT_END  = RX25_SLOT_BASE + 14'(C_RX25_SLOTS * 32);
    localparam logic [13:0] DMA_BLK_BASE   = 14'h0600;
    localparam logic [13:0] DMA_BLK_END    = 14'h0640;

    // RX25 must not depend on base_address_register.  That value is captured
    // from cfg_mgmt and stays 0 on the AS02 shell, so the subtraction below
    // turns a BAR0+0 access at base 0x824FE000 into offset 0x2000 -- which
    // falls into the MSI-X window, where writes disappear into the msix
    // registers and every RX25 read comes back zero.  BAR0 is 8 KB and
    // therefore naturally 8 KB aligned, so on the RX25 personalities the low
    // address bits already are the register offset.
    wire [13:0] rd_off = C_RX25_MODE
        ? {1'b0, rd_req_addr[12:0]}
        : rd_req_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00 };
    wire [13:0] wr_off = C_RX25_MODE
        ? {1'b0, wr_addr[12:0]}
        : wr_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00 };
    // The identity read mux below samples rd_req_addr rather than drd_req_addr,
    // so the mask has to look at the same signal or the two disagree mid-burst.
    wire [13:0] mux_off = C_RX25_MODE
        ? {1'b0, rd_req_addr[12:0]}
        : rd_req_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00 };
    wire        dma_hit_rd = (mux_off >= DMA_BLK_BASE) && (mux_off < DMA_BLK_END);
    wire        dma_hit_wr = (wr_off  >= DMA_BLK_BASE) && (wr_off  < DMA_BLK_END);

    function automatic bit rx25_hit(input logic [13:0] off);
        rx25_hit = C_RX25_MODE &&
                   ((off < RX25_REG_END) ||
                    (C_BATCH_DIAG && off >= 14'h0800 && off < 14'h0c00) ||
                    ((off >= RX25_SLOT_BASE) && (off < RX25_SLOT_END)));
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            rx25_sel     <= 1'b0;
            rx25_rd_off  <= 14'd0;
            rx25_wr      <= 1'b0;
            rx25_wr_off  <= 14'd0;
            rx25_wr_data <= 32'd0;
        end else begin
            rx25_sel     <= rd_req_valid && rx25_hit(rd_off);
            rx25_rd_off  <= rd_off;
            rx25_wr      <= wr_valid && rx25_hit(wr_off);
            rx25_wr_off  <= wr_off;
            rx25_wr_data <= wr_data;
        end
    end

    assign dma_addr = {dma_addr_hi, dma_addr_lo};
    assign dma_len  = dma_len_reg;

    assign dbg_rd_valid = rd_rsp_valid;
    assign dbg_rd_info = {
        (rd_rsp_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}) | 32'hB0000000,
        rd_rsp_data
    };
    assign dbg_wr_valid = wr_valid;
    assign dbg_wr_info = {
        (wr_addr[`BAR_ADDR_WIDTH-1:0] - {base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}),
        wr_data
    };
    // The MSI-X window sits above 0x2000 in the AMDF/USB personalities, but
    // the RX25 BAR is 8 KB and has none, and with base_address_register stuck
    // at 0 this comparison is always true -- which is what swallowed the RX25
    // writes into the msix registers.  Disable the whole path in RX25 mode.
    wire msix_rden = !C_RX25_MODE && rd_req_valid && (rd_req_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}) >= 32'h2000;
    wire msix_wren = !C_RX25_MODE && wr_valid && (wr_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}) >=  32'h2000;
    wire [31:0] msix_wr_addr = (wr_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00})- 32'h2000;
    wire [31:0] msix_rd_addr = (rd_req_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}) - 32'h2000;
    wire msix_out_en = !C_RX25_MODE && drd_req_valid && (drd_req_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}) >= 32'h2000;

    always @(posedge clk) begin
        drd_req_ctx   <= rd_req_ctx;
        drd_req_valid <= rd_req_valid;
        drd_req_addr  <= rd_req_addr;
        dwr_valid     <= wr_valid;
        dwr_addr      <= wr_addr;
        dwr_data      <= wr_data;
        rd_rsp_ctx    <= drd_req_ctx;
        rd_rsp_valid  <= drd_req_valid;
        rd_rsp_addr   <= drd_req_addr;
    end
    always @(posedge clk) begin
        if (rst) begin
            msix_addr <= 0;
            msix_data <= 0;
        end
        if ( wr_valid && ((wr_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00})==  32'h2000) && msix_addr == 32'h0) begin
            msix_addr <= wr_data;
        end
        if (wr_valid && ((wr_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00})==  32'h2008)) begin
            msix_data <= {wr_data[7:0], wr_data[15:8], wr_data[23:16], wr_data[31:24]};
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            off_24 <= 32'h19;
            last_addr <= 32'hf;
            off_20 <= 32'h0;
        end
        if (rx25_sel) begin
            // RX25 register file / descriptor slots.  rx25_rd_off was registered
            // on the request cycle, so this sits in the same pipeline slot as
            // the identity case below and keeps the 2-CLK reply latency.
            rd_rsp_data <= rx25_rd_data;
        end else if (msix_out_en) begin
            rd_rsp_data <= doutb;
        end else begin
            if (drd_req_valid) begin
                if (C_RX25_MODE && !dma_hit_rd) begin
                    // Identity masked: only the DMA debug block answers.
                    rd_rsp_data <= 32'h0;
                end else case (rd_req_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00})
                    32'h0: begin
                        rd_rsp_data <= 32'h1000020;
                    end
                    32'h4: begin
                        rd_rsp_data <= 32'h5000420;
                    end
                    32'h8: begin
                        rd_rsp_data <= 32'hFC000031;
                    end
                    32'hC: begin
                        rd_rsp_data <= 32'hE70004;
                    end
                    32'h10: begin
                        rd_rsp_data <= 32'h2841EB;
                    end
                    32'h14: begin
                        rd_rsp_data <= 32'h100;
                    end
                    32'h18: begin
                        rd_rsp_data <= 32'h200;
                    end
                    // 32'h28: rd_rsp_data <= 32'h1;
                    32'h24: begin
                        case (off_20)
                            32'h4:   rd_rsp_data <= 32'h19;
                            32'h5:   rd_rsp_data <= 32'h8;
                            32'h2:   rd_rsp_data <= 32'h1;
                            32'h0:   rd_rsp_data <= 32'h11;
                            default: rd_rsp_data <= 32'h11;
                        endcase
                    end
                    32'h20: begin
                        case (off_20)
                            32'h1:   rd_rsp_data <= 32'h1;
                            32'h5:   rd_rsp_data <= 32'h5;
                            default: rd_rsp_data <= 32'h0;
                        endcase
                    end
                    32'h28: begin
                        rd_rsp_data <= 32'h1;
                    end
                    32'h54: begin
                        rd_rsp_data <= 32'h1;
                    end
                    32'hA0: begin
                        rd_rsp_data <= 32'h401;
                    end
                    32'hA4: begin
                        rd_rsp_data <= 32'h40010000;
                    end
                    32'hB0: begin
                        rd_rsp_data <= 32'h20000802;
                    end
                    32'hB4: begin
                        rd_rsp_data <= 32'h20425355;
                    end
                    32'hB8: begin
                        rd_rsp_data <= 32'h10060101;
                    end
                    32'hC0: begin
                        rd_rsp_data <= 32'h1E00023;
                    end
                    32'hD0: begin
                        rd_rsp_data <= 32'h3008C02;
                    end
                    32'hD4: begin
                        rd_rsp_data <= 32'h20425355;
                    end
                    32'hD8: begin
                        rd_rsp_data <= 32'h10000402;
                    end
                    32'hE0: begin
                        rd_rsp_data <= 32'h50134;
                    end
                    32'h200: begin
                        rd_rsp_data <= 32'h37;
                    end
                    32'h220: begin
                        rd_rsp_data <= 32'h2;
                    end
                    32'h224: begin
                        rd_rsp_data <= 32'hFA0;
                    end
                    32'h23C: begin
                        rd_rsp_data <= 32'h2;
                    end
                    32'h244: begin
                        rd_rsp_data <= 32'hFA0;
                    end
                    32'h264: begin
                        rd_rsp_data <= 32'hFA0;
                    end
                    32'h284: begin
                        rd_rsp_data <= 32'hFA0;
                    end
                    32'h300: begin
                        rd_rsp_data <= 32'h1000A;
                    end
                    32'h328: begin
                        rd_rsp_data <= 32'hA0;
                    end
                    32'h420: begin
                        rd_rsp_data <= 32'h40000E63;
                    end
                    32'h430: begin
                        rd_rsp_data <= 32'h2A0;
                    end
                    32'h440: begin
                        rd_rsp_data <= 32'h2A0;
                    end
                    32'h450: begin
                        rd_rsp_data <= 32'h2A0;
                    end
                    32'h460: begin
                        rd_rsp_data <= 32'h2A0;
                    end
                    32'h10A0: begin
                        rd_rsp_data <= 32'h401;
                    end
                    32'h10A4: begin
                        rd_rsp_data <= 32'h40010000;
                    end
                    32'h10B0: begin
                        rd_rsp_data <= 32'h20000802;
                    end
                    32'h10B8: begin
                        rd_rsp_data <= 32'h10060101;
                    end
                    32'h10C0: begin
                        rd_rsp_data <= 32'h1E00023;
                    end
                    32'h10D0: begin
                        rd_rsp_data <= 32'h3008C02;
                    end
                    32'h10E0: begin
                        rd_rsp_data <= 32'h50134;
                    end
                    32'h1224: begin
                        rd_rsp_data <= 32'hFA0;
                    end
                    32'h1238: begin
                        rd_rsp_data <= 32'h5A55008;
                    end
                    32'h1420: begin
                        rd_rsp_data <= 32'h40000E63;
                    end
                    // 0x600/0x604/0x608 must read back.  Without these three
                    // the host cannot tell "the write landed" from "the image
                    // has no DMA block at all", and a perfectly good p18 image
                    // looks dead (that is exactly what happened on 2026-11-02).
                    32'h600: begin
                        rd_rsp_data <= dma_addr_lo;
                    end
                    32'h604: begin
                        rd_rsp_data <= dma_addr_hi;
                    end
                    32'h608: begin
                        rd_rsp_data <= dma_len_reg;
                    end
                    32'h610: begin
                        // bit0 busy, bit1 done (all bytes written), bit2 error
                        rd_rsp_data <= {29'd0, dma_error,
                                        (dma_done != 32'd0) && (dma_done == dma_len_reg),
                                        dma_busy};
                    end
                    32'h614: begin
                        rd_rsp_data <= dma_done;
                    end
                    32'h618: begin
                        // image tag: 'D' 'M' 'A' '1'.  p19 and later return this,
                        // p16/p18 decode 0x618 into the default case and return 0.
                        rd_rsp_data <= 32'h444D4131;
                    end
                    default: begin
                        rd_rsp_data <= 32'h0;
                    end
                endcase
            end else if (dwr_valid && (!C_RX25_MODE || dma_hit_wr)) begin
                off_20 <= (dwr_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}) == 32'h20 ? dwr_data : off_20;
                case (dwr_addr[`BAR_ADDR_WIDTH-1:0] - { base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00})
                    32'h600: dma_addr_lo <= dwr_data;
                    32'h604: dma_addr_hi <= dwr_data;
                    32'h608: dma_len_reg <= dwr_data;
                    default: ;
                endcase
            end
        end
    end
    bram_bar_zero4k i_bram_bar_zero4k (
        // Port A - write:
        .addra(msix_wr_addr[11:2]),
        .clka (clk),
        .dina (wr_data),
        .ena  (msix_wren),
        .wea  (wr_be),
        // Port A - read (2 CLK latency):
        .addrb(msix_rd_addr[11:2]),
        .clkb (clk),
        .doutb(doutb),
        .enb  (msix_rden)
    );

    // Start is a one-cycle pulse: the host writes 1, the register clears itself
    // next cycle, so one write cannot retrigger the engine.
    always @(posedge clk) begin
        if (rst) begin
            dma_start <= 1'b0;
        end else begin
            dma_start <= 1'b0;
            if (dwr_valid &&
                ((dwr_addr[`BAR_ADDR_WIDTH-1:0] -
                  {base_address_register[`BAR_ADDR_WIDTH-1:3], 3'b00}) == 32'h60C) &&
                dwr_data[0]) begin
                dma_start <= 1'b1;
            end
        end
    end

    bit [31:0] int_start_cnt = 0;
    always @(posedge clk) begin
        if (rst) begin
            int_start_cnt <= 0;
        end else if (int_start_cnt <= 32'd1600000000) begin
            int_start_cnt <= int_start_cnt + 1'b1;
        end
    end
    assign int_enable = int_start_cnt >= 32'd1600000000;
endmodule
`undef BAR_ADDR_WIDTH


