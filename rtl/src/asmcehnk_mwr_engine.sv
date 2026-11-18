// ---------------------------------------------------------------------------
// asmcehnk_mwr_engine
//
// The card in the control host has to write received data straight into host
// memory.  That is a Memory Write request: posted, no completion, no tag to
// match.  Everything needed to build one already exists upstream --
// asmcehnk_tlps128_to_axis_rq_us turns a tlps128 stream into RQ descriptors and
// already handles REQ_MEM_WRITE -- so this module only has to emit the TLP.
//
// Host interface (BAR, mapped in asmcehnk_tlps128_bar_controller):
//   +0x600  target address low
//   +0x604  target address high
//   +0x608  length in bytes      (must be a multiple of C_PAYLOAD_BYTES)
//   +0x60C  control              bit0 = start (self-clearing)
//   +0x610  status               bit0 busy, bit1 done, bit2 error
//   +0x614  bytes written so far
//   +0x618  image tag            0x444D4131 ('DMA1'), p19+ only
//
// Payload content is self-describing: every dword equals the low 32 bits of
// the address it is written to.  A host-side checker reads the buffer back and
// compares against the address, which catches wrong target addresses, dropped
// beats and byte-order mistakes in one shot.
//
// Why C_PAYLOAD_BYTES is 256: the root complex caps MaxPayload at 256 bytes on
// both machines, so a larger write would be split by the fabric anyway.  Matching
// it here keeps one TLP per 256 bytes and makes the beat count predictable.
//
// Status: integrated into asmcehnk_pcie_tlp_us; not yet built or simulated.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"

module asmcehnk_mwr_engine #(
    parameter int C_PAYLOAD_BYTES = 256,
    parameter int C_PAYLOAD_DW    = C_PAYLOAD_BYTES / 4,          // 64
    parameter int C_PAYLOAD_BEATS = C_PAYLOAD_DW / 4,             // 16
    parameter logic [15:0] C_REQID = 16'h0100
)(
    input  wire logic        rst,
    input  wire logic        clk,

    // configuration, straight from the BAR registers
    input  wire logic [63:0] cfg_addr,
    input  wire logic [31:0] cfg_len,
    input  wire logic        cfg_start,

    output logic [31:0]      done_bytes,
    output logic             busy,

    IfAXIS128.source         tlps_out
);

    localparam int BEAT_IDX_W = $clog2(C_PAYLOAD_BEATS);

    typedef enum logic [1:0] {
        S_IDLE,
        S_HEADER,
        S_PAYLOAD
    } state_t;

    state_t             state_reg;
    logic [63:0]        addr_reg;
    logic [31:0]        remain_reg;
    logic [BEAT_IDX_W-1:0] beat_reg;
    logic               error_reg;

    // ---- derived -----------------------------------------------------------
    // Length must be whole payloads.  A partial tail would write past the end of
    // the buffer the host allocated, which is worse than refusing to run.
    wire len_ok   = (cfg_len != 32'd0) && ((cfg_len % C_PAYLOAD_BYTES) == 0);
    wire start_ok = cfg_start && len_ok && !busy;

    // ---- TLP header --------------------------------------------------------
    // 4DW Memory Write, no data in the header beat:
    //   dw0[31:29] Fmt = 011 (4DW with data)
    //   dw0[28:24] Type = 00000 (memory)
    //   dw0[9:0]   Length in dwords
    //   dw1[31:16] Requester ID, dw1[15:8] Tag, dw1[7:0] First/Last BE
    //   dw2        Address[63:32]
    //   dw3        Address[31:2], 2'b00
    // Tag is zero: a posted write never comes back, so nothing has to match it.
    // 3+5 bits of Fmt/Type, then 24 zeros to fill the dword.  An earlier version
    // used 22'd0, which is 30 bits: the concat was left-extended and pushed Fmt
    // and Type one byte too high, so the TLP came out as Fmt=000 Type=11000.
    wire [31:0] hdr_dw0 = 32'h6000_0000 | (C_PAYLOAD_DW[9:0]);
    wire [31:0] hdr_dw1 = {C_REQID, 8'h00, 8'hFF};
    wire [31:0] hdr_dw2 = addr_reg[63:32];
    wire [31:0] hdr_dw3 = {addr_reg[31:2], 2'b00};

    // ---- payload beat ------------------------------------------------------
    // The tlps128 payload path byte-swaps every dword on the way into the RQ
    // descriptor (see raw_dwN_swap in asmcehnk_pcie_tlps128_to_axis_rq_us), so
    // the source has to pre-swap.  Without this the host reads 0x03020100
    // instead of 0x00010203.
    function automatic [31:0] bswap32(input [31:0] d);
        return {d[7:0], d[15:8], d[23:16], d[31:24]};
    endfunction

    // Four pre-incremented dword addresses, one per lane of the 128-bit beat.
    //
    // p18 computed pay_base = addr_reg + (beat_reg << 4) and then added 0/4/8/12
    // in front of the byte swap, so a single 402.8 MHz clock had to swallow a
    // barrel shift, four 32-bit adds, four byte swaps and the 128-bit output
    // mux.  That alone took WNS from -0.324 (p16) to -0.492 with 9031 failing
    // endpoints.  Keeping the value in registers leaves nothing but wires
    // between the flop and tlps_out.tdata, and the four adds move to the flop
    // inputs where they only have to reach the next flop.
    logic [31:0] pdw0_q, pdw1_q, pdw2_q, pdw3_q;

    wire [127:0] pay_beat = {bswap32(pdw3_q), bswap32(pdw2_q),
                             bswap32(pdw1_q), bswap32(pdw0_q)};

    wire last_payload_beat = (beat_reg == BEAT_IDX_W'(C_PAYLOAD_BEATS - 1));
    wire last_tlp          = (remain_reg <= C_PAYLOAD_BYTES);

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
                out_tuser[0] = 1'b1;                 // [0] = first: header present
                out_tlast    = 1'b0;                 // payload always follows
                out_tvalid   = 1'b1;
                out_has_data = 1'b1;
            end
            S_PAYLOAD: begin
                out_tdata    = pay_beat;
                out_tkeepdw  = 4'b1111;
                out_tuser    = 9'd0;
                out_tlast    = last_payload_beat;
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

    // ---- state machine -----------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg  <= S_IDLE;
            addr_reg   <= 64'd0;
            remain_reg <= 32'd0;
            beat_reg   <= '0;
            error_reg  <= 1'b0;
            done_bytes <= 32'd0;
            busy       <= 1'b0;
            pdw0_q     <= 32'd0;
            pdw1_q     <= 32'd4;
            pdw2_q     <= 32'd8;
            pdw3_q     <= 32'd12;
        end else begin
            case (state_reg)
                S_IDLE: begin
                    if (cfg_start && !len_ok) begin
                        // Refuse rather than write past the end of the buffer.
                        error_reg  <= 1'b1;
                        done_bytes <= 32'd0;
                        busy       <= 1'b0;
                    end else if (start_ok) begin
                        addr_reg   <= cfg_addr;
                        remain_reg <= cfg_len;
                        beat_reg   <= '0;
                        error_reg  <= 1'b0;
                        done_bytes <= 32'd0;
                        busy       <= 1'b1;
                        pdw0_q     <= cfg_addr[31:0];
                        pdw1_q     <= cfg_addr[31:0] + 32'd4;
                        pdw2_q     <= cfg_addr[31:0] + 32'd8;
                        pdw3_q     <= cfg_addr[31:0] + 32'd12;
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
                        done_bytes <= done_bytes + 32'd16;
                        // Every beat advances all four lanes by 16 bytes, which
                        // also carries across the 256-byte TLP boundary: 16 beats
                        // x 16 bytes = the same 256 addr_reg adds below.
                        pdw0_q     <= pdw0_q + 32'd16;
                        pdw1_q     <= pdw1_q + 32'd16;
                        pdw2_q     <= pdw2_q + 32'd16;
                        pdw3_q     <= pdw3_q + 32'd16;
                        if (!last_payload_beat) begin
                            beat_reg <= beat_reg + 1'b1;
                        end else if (last_tlp) begin
                            busy      <= 1'b0;
                            state_reg <= S_IDLE;
                        end else begin
                            addr_reg   <= addr_reg + C_PAYLOAD_BYTES;
                            remain_reg <= remain_reg - C_PAYLOAD_BYTES;
                            beat_reg   <= '0;
                            state_reg  <= S_HEADER;
                        end
                    end
                end

                default: state_reg <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
