// ---------------------------------------------------------------------------
// asmcehnk_mwr_stream
//
// Memory Write engine whose payload comes from a stream instead of from the
// target address.  asmcehnk_mwr_engine is a self-test generator (every dword
// equals the address it lands on), which is useless for real data; this is the
// data-path half of the RX25 request engine: the peer card sends read data
// back, this module writes it to host_iova.
//
// Host interface (same shape as asmcehnk_mwr_engine):
//   cfg_addr     64-bit host physical address (NetUIO/virt2phys gives a bare PA)
//   cfg_len      bytes, must be a multiple of 16 (one 128-bit beat)
//   cfg_start    one-cycle pulse; refused while busy or when len is illegal
//   done_bytes   bytes committed to the TLP stream
//   busy         high from accept until the last payload beat is taken
//
// Payload stream: 128-bit beats, tkeepdw must be 4'b1111 (the caller only ever
// sends whole beats).  Exactly cfg_len/16 beats are consumed, then busy drops.
//
// TLP format: 4DW Memory Writes, at most 256 bytes each (root complex
// MaxPayload on both machines).  A 1-dword TLP needs First BE only; everything
// longer uses First/Last BE = 0xF.
//
// Payload dwords are byte-swapped on the way out: the RQ packetizer swaps every
// payload dword (raw_dwN_swap in asmcehnk_tlps128_to_axis_rq_us), so without
// the pre-swap the host reads 0x04030201 instead of 0x01020304.  Same
// convention as asmcehnk_mwr_engine and asmcehnk_cq_writer.
//
// Status: not yet bound to a wire protocol.  The RX25 peer-side responder and
// the PL11 frame layer are separate modules; this one only owns the
// stream -> host-memory step.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"

module asmcehnk_mwr_stream #(
    parameter int C_PAYLOAD_BYTES = 256,
    parameter int C_PAYLOAD_DW    = C_PAYLOAD_BYTES / 4,          // 64
    parameter int C_PAYLOAD_BEATS = C_PAYLOAD_DW / 4,             // 16
    parameter logic [15:0] C_REQID = 16'h0100
)(
    input  wire logic        rst,
    input  wire logic        clk,

    input  wire logic [63:0] cfg_addr,
    input  wire logic [31:0] cfg_len,
    input  wire logic        cfg_start,

    output logic [31:0]      done_bytes,
    output logic             busy,
    output logic             error,
    // Snapshot of what the write engine actually latched, versus what it was
    // handed.  Hardware kept writing to the first job's address while cfg_addr
    // carried the new one, and the state machine reads correct -- so the
    // question is whether the sample or the source is wrong.  addr_reg is a
    // plain flop, so exposing it costs nothing.
    output logic [63:0]      dbg_addr_reg,
    output logic [63:0]      dbg_cfg_addr,

    // Payload stream from the request engine.
    input  wire logic [127:0] s_tdata,
    input  wire logic [3:0]   s_tkeepdw,
    input  wire logic         s_tvalid,
    output logic              s_tready,
    input  wire logic         s_tlast,

    IfAXIS128.source         tlps_out
);

    localparam int BEAT_IDX_W = $clog2(C_PAYLOAD_BEATS);

    typedef enum logic [1:0] {
        S_IDLE,
        S_HEADER,
        S_PAYLOAD
    } state_t;

    state_t  state_reg;
    logic [63:0] addr_reg;      // address of the current TLP
    logic [31:0] remain_reg;    // bytes left in the whole transfer
    logic [BEAT_IDX_W-1:0] beat_reg;
    logic [31:0] done_reg;

    wire len_ok = (cfg_len != 32'd0) && ((cfg_len % 32'd16) == 32'd0);
    wire start_ok = cfg_start && len_ok && (state_reg == S_IDLE);

    // Chunk size: whole 256-byte payloads, the tail may be shorter but is
    // always a whole number of 16-byte beats.
    wire [31:0] payload_limit = (remain_reg > 32'(C_PAYLOAD_BYTES))
                              ? 32'(C_PAYLOAD_BYTES) : remain_reg;
    wire [31:0] page_left = 32'd4096 - {20'd0,addr_reg[11:0]};
    wire [31:0] chunk_bytes = (payload_limit > page_left) ? page_left : payload_limit;
    wire [10:0] chunk_dw    = chunk_bytes[10:2];
    wire [4:0]  chunk_beats = chunk_bytes[8:4];   // 256 B -> 0x100 -> 16 beats

    wire last_chunk   = (remain_reg == chunk_bytes);
    wire last_beat    = (beat_reg == BEAT_IDX_W'(chunk_beats - 5'd1));
    wire single_dword = (chunk_dw == 11'd1);

    // ---- TLP header --------------------------------------------------------
    wire [31:0] hdr_dw0 = 32'h6000_0000 | {21'd0, chunk_dw};
    wire [31:0] hdr_dw1 = {C_REQID, 8'h00,
                           single_dword ? 4'h0 : 4'hF,   // last BE
                           4'hF};                        // first BE
    wire [31:0] hdr_dw2 = addr_reg[63:32];
    wire [31:0] hdr_dw3 = {addr_reg[31:2], 2'b00};

    function automatic [31:0] bswap32(input logic [31:0] d);
        return {d[7:0], d[15:8], d[23:16], d[31:24]};
    endfunction

    wire [127:0] pay_beat = {bswap32(s_tdata[127:96]), bswap32(s_tdata[95:64]),
                             bswap32(s_tdata[63:32]),  bswap32(s_tdata[31:0])};

    // ---- output mux --------------------------------------------------------
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
                out_tuser[0] = 1'b1;
                out_tlast    = 1'b0;              // payload always follows
                out_tvalid   = 1'b1;
                out_has_data = 1'b1;
            end
            S_PAYLOAD: begin
                out_tdata    = pay_beat;
                out_tkeepdw  = 4'b1111;
                out_tuser    = 9'd0;
                // tlast ends THIS TLP, not the transfer: the RQ packetizer
                // returns to its idle state on it, and without it the next
                // header gets folded into a payload beat.
                out_tlast    = last_beat;
                out_tvalid   = s_tvalid;      // never invent a payload beat
                out_has_data = s_tvalid;
            end
            default: ;
        endcase
    end

    assign tlps_out.tdata    = out_tdata;
    assign tlps_out.tkeepdw  = out_tkeepdw;
    assign tlps_out.tuser    = out_tuser;
    assign tlps_out.tlast    = out_tlast;
    assign dbg_addr_reg = addr_reg;
    assign dbg_cfg_addr = cfg_addr;

    assign tlps_out.tvalid   = out_tvalid;
    assign tlps_out.has_data = out_has_data;

    wire beat_fire = out_tvalid && tlps_out.tready;

    // The payload stream is only read while a payload beat is on the bus.
    assign s_tready = (state_reg == S_PAYLOAD) && tlps_out.tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg  <= S_IDLE;
            addr_reg   <= 64'd0;
            remain_reg <= 32'd0;
            beat_reg   <= '0;
            done_reg   <= 32'd0;
            done_bytes <= 32'd0;
            busy       <= 1'b0;
            error      <= 1'b0;
        end else begin
            case (state_reg)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (cfg_start && !len_ok) begin
                        // Refuse rather than write a partial beat the host did
                        // not ask for.
                        error      <= 1'b1;
                        done_bytes <= done_bytes;
                    end else if (start_ok) begin
                        addr_reg   <= cfg_addr;
                        remain_reg <= cfg_len;
                        beat_reg   <= '0;
                        done_reg   <= 32'd0;
                        done_bytes <= 32'd0;
                        error      <= 1'b0;
                        busy       <= 1'b1;
                        state_reg  <= S_HEADER;
                    end
                end

                S_HEADER: begin
                    if (beat_fire) begin
                        beat_reg  <= '0;
                        state_reg <= S_PAYLOAD;
                    end
                end

                S_PAYLOAD: begin
                    if (beat_fire) begin
                        done_reg   <= done_reg + 32'd16;
                        done_bytes <= done_reg + 32'd16;
                        if (!last_beat) begin
                            beat_reg <= beat_reg + 1'b1;
                        end else if (last_chunk) begin
                            busy      <= 1'b0;
                            state_reg <= S_IDLE;
                        end else begin
                            // Next TLP: advance the address, shrink the tail.
                            addr_reg   <= addr_reg + {32'd0,chunk_bytes};
                            remain_reg <= remain_reg - chunk_bytes;
                            beat_reg   <= '0;
                            state_reg  <= S_HEADER;
                        end
                    end
                end

                default: state_reg <= S_IDLE;
            endcase
        end
    end

    // s_tlast is informational only: the beat count is authoritative, so a
    // truncated stream stalls the TLP instead of silently writing less.
    // verilator lint_off UNUSED
    wire unused_s_tlast = s_tlast;
    wire unused_s_keep  = ^s_tkeepdw;
    // verilator lint_on UNUSED

endmodule

`default_nettype wire
