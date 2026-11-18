// ---------------------------------------------------------------------------
// asmcehnk_cq_writer
//
// Publishes one RX25 completion-queue dword as a 4DW Memory Write to
// host_iova + 0x1000 + index*4.  asmcehnk_rx25_bar hands out eight of these per
// completion, in the order 0,2,3,4,5,6,7,1, so the host polling the
// generation/status dword never sees a half-built entry.
//
// Two reasons this is its own module instead of a mode of asmcehnk_mwr_engine:
//   * mwr_engine only accepts lengths that are whole 256-byte payloads, and a
//     CQ dword is 4 bytes;
//   * mwr_engine's payload is self-describing (every dword is its own
//     address), while here the payload is whatever the BAR wrote.
//
// Stream convention (same as asmcehnk_mwr_engine, which p22 proved on the
// board): header beat first with tuser[0], then payload beats.  Header dwords
// go out unswapped, payload dwords must be pre-swapped -- the RQ packetizer
// byte-swaps every payload dword on the way into the descriptor
// (raw_dwN_swap in asmcehnk_tlps128_to_axis_rq_us), and the host would
// otherwise read 0x04030201 instead of 0x01020304.
//
// The 4DW header is required: the target address is a 64-bit host physical
// address on Windows (the NetUIO driver passes a bare PA through virt2phys).
//
// TLP: Fmt=011 (4DW, with data), Type=00000 (memory), Length=1 dword,
//      First BE = 0xF, Last BE = 0x0 (PCIe requires Last BE = 0 for a single
//      dword TLP; the single dword is enabled by First BE).
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"

module asmcehnk_cq_writer #(
    parameter logic [15:0] C_REQID = 16'h0100
)(
    input  wire logic        rst,
    input  wire logic        clk,

    // Straight from asmcehnk_rx25_bar.
    input  wire logic        cqw_valid,
    input  wire logic [63:0] cqw_addr,
    input  wire logic [31:0] cqw_data,
    input  wire logic [2:0]  cqw_index,
    output logic             cqw_done,

    IfAXIS128.source         tlps_out
);

    typedef enum logic [1:0] {
        S_IDLE,
        S_HEADER,
        S_PAYLOAD,
        S_ACK
    } state_t;

    state_t      state_reg;
    logic [63:0] addr_reg;
    logic [31:0] data_reg;

    function automatic [31:0] bswap32(input logic [31:0] d);
        return {d[7:0], d[15:8], d[23:16], d[31:24]};
    endfunction

    // ---- TLP header --------------------------------------------------------
    wire [31:0] hdr_dw0 = 32'h6000_0001;                        // 4DW MWr, 1 dword
    wire [31:0] hdr_dw1 = {C_REQID, 8'h00, 4'h0, 4'hF};         // reqid, tag, last BE, first BE
    wire [31:0] hdr_dw2 = addr_reg[63:32];
    wire [31:0] hdr_dw3 = {addr_reg[31:2], 2'b00};

    // ---- output ------------------------------------------------------------
    logic [127:0] out_tdata;
    logic [3:0]   out_tkeepdw;
    logic [8:0]   out_tuser;
    logic         out_tlast;
    logic         out_tvalid;
    logic         out_has_data;

    always_comb begin
        out_tdata    = 128'd0;
        out_tkeepdw  = 4'd0;
        out_tuser    = 9'd0;
        out_tlast    = 1'b0;
        out_tvalid   = 1'b0;
        out_has_data = 1'b0;

        unique case (state_reg)
            S_HEADER: begin
                out_tdata    = {hdr_dw3, hdr_dw2, hdr_dw1, hdr_dw0};
                out_tkeepdw  = 4'b1111;
                out_tuser[0] = 1'b1;              // [0] = first: header present
                out_tlast    = 1'b0;              // payload always follows
                out_tvalid   = 1'b1;
                out_has_data = 1'b1;
            end
            S_PAYLOAD: begin
                out_tdata    = {96'd0, bswap32(data_reg)};
                out_tkeepdw  = 4'b0001;           // one dword, lane 0
                out_tuser    = 9'd0;
                out_tlast    = 1'b1;
                out_tvalid   = 1'b1;
                out_has_data = 1'b1;
            end
            default: ;
        endcase
    end

    assign tlps_out.tdata    = out_tdata;
    assign tlps_out.tkeepdw  = out_tkeepdw;
    assign tlps_out.tuser    = out_tuser;
    assign tlps_out.tlast    = out_tlast;
    assign tlps_out.tvalid   = out_tvalid;
    assign tlps_out.has_data = out_has_data;

    wire beat_fire = out_tvalid && tlps_out.tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg <= S_IDLE;
            addr_reg  <= 64'd0;
            data_reg  <= 32'd0;
            cqw_done  <= 1'b0;
        end else begin
            // Single-cycle pulse: asmcehnk_rx25_bar advances on it.
            cqw_done <= 1'b0;

            case (state_reg)
                S_IDLE: begin
                    if (cqw_valid) begin
                        addr_reg  <= cqw_addr;
                        data_reg  <= cqw_data;
                        state_reg <= S_HEADER;
                    end
                end
                S_HEADER: begin
                    if (beat_fire) begin
                        state_reg <= S_PAYLOAD;
                    end
                end
                S_PAYLOAD: begin
                    if (beat_fire) begin
                        cqw_done  <= 1'b1;
                        state_reg <= S_ACK;
                    end
                end
                // BAR samples the registered done pulse on this edge and
                // advances its held request in NBA.  Do not re-latch the old
                // request until the following edge, when the update is visible.
                S_ACK: state_reg <= S_IDLE;
                default: state_reg <= S_IDLE;
            endcase
        end
    end

    // cqw_index is only for debug visibility (which CQ dword this is).
    // verilator lint_off UNUSED
    wire [2:0] index_unused = cqw_index;
    // verilator lint_on UNUSED

endmodule

`default_nettype wire
