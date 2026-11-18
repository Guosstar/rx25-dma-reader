// ---------------------------------------------------------------------------
// asmcehnk_rx25_loop_mem
//
// Drop-in replacement for asmcehnk_rx25_rd_engine that answers reads from an
// on-chip pattern instead of the host's physical memory.
//
// Why this exists: the responder's read engine issues a real 4DW Memory Read
// against host_iova.  Until a validated physical address exists that MRd either
// faults or returns nothing, and asmcehnk_rx25_responder then announces
// rec_bytes = 0 (see its `rec_bytes = rec_err ? {23'd0, buf_n, 3'd0} : rec_len`).
// A zero length fails the initiator's header check (`rx_len != 0`), so the
// frame is discarded and the link looks broken even though it is not.
//
// This module removes that dependency so the PL11 path can be proven end to
// end: if the initiator sees the pattern below, framing, byte order, lane
// mapping and length accounting are all correct, and any remaining failure is
// unambiguously in the host-memory direction.
//
// Pattern: word k = 0xA5A5_0000_0000_0000 | k.  The high tag makes a stray
// TLP or a stale beat obvious, and the low counter exposes reordering or a
// dropped word immediately.
//
// Interface is identical to asmcehnk_rx25_rd_engine, so the instantiation is a
// one-line swap and no other logic changes.
// ---------------------------------------------------------------------------
module asmcehnk_rx25_loop_mem #(
    // Separate batch-diagnostic personality; legacy reads still restart at k=0.
    parameter bit C_ADDRESS_PATTERN = 1'b0
)(
    input  wire logic        rst,
    input  wire logic        clk,

    // Request side, same meaning as the real engine.
    input  wire logic [63:0] cfg_addr,
    input  wire logic [31:0] cfg_len,          // bytes, multiple of 16, <= 512
    input  wire logic        cfg_start,

    output logic             busy,
    output logic             done,
    output logic             error,            // only address-personality validation can fail

    output logic [63:0]      out_data,
    output logic             out_valid,
    input  wire logic        out_ready
);

    // 512 bytes covers two full 256-byte records; the responder never asks for
    // more than C_MAX_RECORD per request.
    localparam int unsigned C_MAX_WORDS = 64;

    logic [15:0] word_idx;    // next word to present
    logic [15:0] word_total;  // words requested, derived from cfg_len
    logic        active;
    logic [15:0] word_base;
    logic address_error;

    assign busy  = active;
    assign error = C_ADDRESS_PATTERN ? address_error : 1'b0;

    // Word index k, tagged so a wrong or repeated beat is visible on the host.
    function automatic logic [63:0] pattern_of(input logic [15:0] k);
        pattern_of = 64'hA5A5_0000_0000_0000 | {48'd0, k};
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            active     <= 1'b0;
            done       <= 1'b0;
            out_valid  <= 1'b0;
            out_data   <= 64'd0;
            word_idx   <= 16'd0;
            word_total <= 16'd0;
            word_base  <= 16'd0;
            address_error <= 1'b0;
        end else begin
            done <= 1'b0;

            if (cfg_start && !active) begin
                active     <= 1'b1;
                word_idx   <= 16'd0;
                word_base  <= C_ADDRESS_PATTERN ? {10'd0,cfg_addr[8:3]} : 16'd0;
                // This personality can address only its 512B on-chip source.
                address_error <= C_ADDRESS_PATTERN &&
                    (cfg_addr[63:9] != 0 || cfg_addr[3:0] != 0 || cfg_len == 0 ||
                     cfg_len[3:0] != 0 || cfg_len > 512 || cfg_addr[8:0] > 512-cfg_len);
                // cfg_len is a byte count; the stream is 64-bit words.  Clamp so
                // a bogus length cannot run past the counter width.
                word_total <= (C_ADDRESS_PATTERN &&
                    (cfg_addr[63:9] != 0 || cfg_addr[3:0] != 0 || cfg_len == 0 ||
                     cfg_len[3:0] != 0 || cfg_len > 512 || cfg_addr[8:0] > 512-cfg_len)) ? 16'd0 :
                              (cfg_len[31:3] > 32'(C_MAX_WORDS))
                              ? 16'(C_MAX_WORDS)
                              : 16'(cfg_len[18:3]);
                out_valid  <= 1'b0;
            end else if (active) begin
                // Accept a new word whenever the current one has been taken (or
                // none is outstanding).  Keeping this as a plain handshake means
                // the responder's out_ready back-pressure is honoured verbatim.
                if (!out_valid || out_ready) begin
                    if (word_idx < word_total) begin
                        out_data  <= pattern_of(word_base + word_idx);
                        out_valid <= 1'b1;
                        word_idx  <= word_idx + 16'd1;
                    end else begin
                        // Every word has been presented and the last one taken.
                        out_valid <= 1'b0;
                        active    <= 1'b0;
                        done      <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
