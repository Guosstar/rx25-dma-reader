// ---------------------------------------------------------------------------
// asmcehnk_rx25_responder
//
// The target-side half of RX25: it answers a PL11 request by reading the
// requested physical span out of the host it sits in and returning it as PL11
// DATA records.
//
// One request at a time.  A request is 1..N records of at most 256 bytes; each
// record is read into a 256-byte buffer first and only then transmitted, so the
// header states the length that was actually obtained.  Streaming straight from
// the read engine would force the header out before the result was known, and a
// failed read would desynchronise the receiver's frame parser.
//
// Record header (see asmcehnk_rx25_pl11.svh):
//   w0 magic/version/type=DATA
//   w1 {flags, sequence, request_id}
//   w2 {status, length}          length = bytes actually returned
//   w3 remote_pa  (echo)
//   w4 host_iova  (echo)
//   w5 reserved
// The last record carries PL11_FLAG_LAST_RECORD.  A read error ends the transfer
// early with PL11_STATUS_SHORT, so the receiver reports a short read instead of
// waiting for records that will never arrive.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"
`include "asmcehnk_rx25_pl11.svh"

module asmcehnk_rx25_responder #(
    parameter int C_MAX_RECORD = `PL11_MAX_RECORD,
    parameter int C_MAX_REQUEST_BYTES = 0,
    parameter bit C_REQUIRE_ALIGNED = 1'b0,
    parameter logic [63:0] C_TEST_ADDR = 64'd0,
    parameter bit C_CHECK_TEST_ADDR = 1'b0
)(
    input  wire logic        rst,
    input  wire logic        clk,

    // ---- PL11 frames in ----------------------------------------------------
    input  wire logic [63:0] rx_data,
    input  wire logic        rx_valid,
    input  wire logic        rx_last,
    output logic             rx_ready,

    // ---- PL11 frames out ---------------------------------------------------
    output logic [63:0]      tx_data,
    output logic             tx_valid,
    output logic             tx_last,
    input  wire logic        tx_ready,

    // ---- read engine -------------------------------------------------------
    output logic [63:0]      rd_addr,
    output logic [31:0]      rd_len,
    output logic             rd_start,
    input  wire logic        rd_busy,
    input  wire logic        rd_done,
    input  wire logic        rd_error,
    input  wire logic [63:0] rd_data,
    input  wire logic        rd_valid,
    output logic             rd_ready,
    // Consumed-once acknowledgement for the guard's task_fail token.  Asserted
    // when this record actually takes the failure, or when a genuinely new
    // request starts arriving, so a stale token can never be mistaken for the
    // completion of the following request.
    output logic             fail_ack,

    // ---- diagnostics -------------------------------------------------------
    output logic [31:0]      cnt_requests,
    output logic [31:0]      cnt_errors,

    // Live view of the fields that drive the record loop.  Without these the
    // only symptom of a bad header is "the responder never stops": remain_q
    // underflows and rec_is_last stays false, with nothing to read back.
    output logic [31:0]      dbg_len,       // rx_len as decoded from hdr[2]
    output logic [31:0]      dbg_remain,    // bytes still owed on this request
    output logic             dbg_hdr_ok,    // last header verdict
    // The first three header words verbatim.  hdr[2] decoding wrong can only be
    // resolved by seeing what actually arrived, not by re-reading the packing
    // code: magic in hdr[0] with iova in hdr[2] means the peer filled w2 wrong,
    // while a shifted magic means the beat split is off.
    output logic [63:0]      dbg_hdr0,
    output logic [63:0]      dbg_hdr1,
    output logic [63:0]      dbg_hdr2,
    // Where the record loop actually is, and how much the read engine handed
    // over.  A frame that stops after two beats is either buf_n short of the
    // requested span or stuck in one of these states.
    output logic [2:0]       dbg_state,
    output logic [5:0]       dbg_buf_n,
    output logic [31:0]      dbg_rec_len,
    // First two buffered payload words.  The initiator's write-back contains
    // header fields where the pattern belongs, so the question is whether the
    // read stand-in's data ever landed in rec_buf at all.  If word0 holds
    // 0xA5A5_0000_0000_0000 the store path is fine and the fault is in the
    // frame's word indexing; if it holds something else the store is wrong.
    output logic [31:0]      dbg_buf_w0_lo,
    output logic [31:0]      dbg_buf_w0_hi,
    output logic [31:0]      dbg_buf_w1_lo,
    output logic [31:0]      dbg_buf_w1_hi
);

    localparam int BUF_WORDS = C_MAX_RECORD / 8;      // 32 words

    typedef enum logic [2:0] {
        S_IDLE,
        S_HDR,          // collect the six request header words
        S_NEXT,         // decide the record span, start the read
        S_COLLECT,      // fill the record buffer from the read engine
        S_TX_HDR,       // emit the six record header words
        S_TX_DATA,      // emit the buffered payload words
        S_DROP          // discard an invalid frame through its actual boundary
    } state_t;

    state_t state_reg;

    logic [63:0] hdr [0:5];
    logic [2:0]  hdr_idx;

    logic [31:0] rid_q;
    logic [63:0] addr_q;             // running read pointer
    logic [63:0] iova_q;
    logic [31:0] remain_q;           // bytes left in the request
    logic [15:0] seq_q;

    logic [63:0] rec_buf [0:BUF_WORDS-1];
    logic [5:0]  buf_n;              // words stored for this record
    // Bound each request by record capacity and the next PCIe 4KB boundary.
    wire [31:0] record_limit = (remain_q > 32'(C_MAX_RECORD)) ? 32'(C_MAX_RECORD) : remain_q;
    wire [31:0] page_left = 32'd4096 - {20'd0, addr_q[11:0]};
    wire [31:0] rec_len = (record_limit > page_left) ? page_left : record_limit;
    logic [63:0] rec_addr;           // address announced for this record
    logic [15:0] tx_idx;
    logic        rec_err;
    logic        test_request_spent;

    logic [31:0] req_cnt, err_cnt;
    assign cnt_requests = req_cnt;
    assign cnt_errors   = err_cnt;

    // ---- request decode ----------------------------------------------------
    wire [31:0] rx_magic = hdr[0][31:0];
    wire [15:0] rx_ver   = hdr[0][47:32];
    wire [15:0] rx_type  = hdr[0][63:48];
    wire [31:0] rx_rid   = hdr[1][31:0];
    wire [31:0] rx_len   = hdr[2][31:0];
    wire [63:0] rx_pa    = hdr[3];
    wire [63:0] rx_iova  = hdr[4];
    wire request_length_ok = rx_len != 0 && (rx_len % 32'd16) == 0 &&
        (C_MAX_REQUEST_BYTES == 0 || rx_len <= 32'(C_MAX_REQUEST_BYTES));
    wire request_address_ok = !C_REQUIRE_ALIGNED ||
        (rx_pa[3:0] == 0 && rx_pa[11:0] <= 12'hff0);
    wire request_test_address_ok = !C_CHECK_TEST_ADDR || rx_pa == C_TEST_ADDR;
    wire request_available = !C_CHECK_TEST_ADDR || !test_request_spent;
    wire        hdr_ok   = (rx_magic == `PL11_MAGIC) &&
                           (rx_ver   == `PL11_VERSION) &&
                           (rx_type  == `PL11_TYPE_REQ) &&
                           request_length_ok && request_address_ok && request_test_address_ok && request_available &&
                           (hdr[1][63:32] == 0) && (hdr[2][63:32] == 0) && (rx_data == 0);

    initial begin
        if (C_MAX_RECORD < 16 || (C_MAX_RECORD % 16) != 0)
            $fatal(1, "C_MAX_RECORD must be a multiple of 16 and at least 16");
        if (C_MAX_REQUEST_BYTES != 0 &&
            (C_MAX_REQUEST_BYTES < 16 || (C_MAX_REQUEST_BYTES % 16) != 0))
            $fatal(1, "C_MAX_REQUEST_BYTES must be zero or a positive multiple of 16");
        if (C_CHECK_TEST_ADDR &&
            (C_TEST_ADDR == 0 || C_TEST_ADDR[3:0] != 0 || C_TEST_ADDR[11:0] > 12'hff0 ||
             !C_REQUIRE_ALIGNED || C_MAX_RECORD != 16 || C_MAX_REQUEST_BYTES != 16))
            $fatal(1, "real-read first16 profile requires a nonzero aligned single-page 16B test address");
    end

    assign rx_ready = (state_reg == S_IDLE) || (state_reg == S_HDR) || (state_reg == S_DROP);

    // Two ways the guard's task_fail token stops being relevant: this record
    // consumed it, or a fresh request header has started arriving.  The second
    // arm is what prevents a stale level from terminating the next request
    // before its MRd is even issued.
    assign fail_ack = ((state_reg == S_COLLECT) && rd_done && !rd_valid) ||
                      ((state_reg == S_HDR) && rx_valid && (hdr_idx == 3'd0));

    // Diagnostics.  hdr_ok is a combinational verdict valid only on the cycle
    // the sixth header word lands, so latch it for reading through the BAR.
    logic hdr_ok_q = 1'b0;
    always_ff @(posedge clk) begin
        if (rst) hdr_ok_q <= 1'b0;
        else if (rx_valid && (state_reg == S_HDR) && (hdr_idx == 3'd5)) hdr_ok_q <= hdr_ok;
    end

    assign dbg_len    = rx_len;
    assign dbg_remain = remain_q;
    assign dbg_hdr_ok = hdr_ok_q;
    assign dbg_hdr0   = hdr[0];
    assign dbg_hdr1   = hdr[1];
    assign dbg_hdr2   = hdr[2];
    assign dbg_state  = state_reg;
    assign dbg_buf_n  = buf_n;
    // Bisect probe: report remain_q verbatim.  rec_len reads back as 0 on
    // hardware while remain_q (0x58) reads 0x100, and the expression above only
    // depends on remain_q -- so either the wire itself is broken or the BAR path
    // is.  Wiring the debug port straight to remain_q separates those two.
    assign dbg_rec_len = remain_q;
    assign dbg_buf_w0_lo = rec_buf[0][31:0];
    assign dbg_buf_w0_hi = rec_buf[0][63:32];
    assign dbg_buf_w1_lo = rec_buf[1][31:0];
    assign dbg_buf_w1_hi = rec_buf[1][63:32];

    // ---- record composition ------------------------------------------------
    wire        rec_is_last = rec_err || (remain_q == rec_len);
    wire [15:0] rec_flags   = rec_is_last ? `PL11_FLAG_LAST_RECORD : 16'd0;
    wire [31:0] rec_status  = rec_err ? `PL11_STATUS_SHORT : `PL11_STATUS_OK;
    // The initiator writes whole 16B beats. A partial trailing 64b word on an
    // error is discarded; no uninitialised padding reaches host memory.
    wire [5:0] send_words = rec_err ? {buf_n[5:1],1'b0} : buf_n;
    wire [31:0] rec_bytes   = rec_err ? {23'd0, send_words, 3'd0} : rec_len;
    wire [15:0] last_idx    = 16'd5 + {10'd0, send_words};

    wire [5:0] pay_idx = tx_idx[5:0] - 6'd6;

    logic [63:0] tx_word;
    always_comb begin
        tx_word = 64'd0;
        if (tx_idx < 16'd6) begin
            case (tx_idx)
                16'd0: tx_word = {`PL11_TYPE_DATA, `PL11_VERSION, `PL11_MAGIC};
                16'd1: tx_word = {rec_flags, seq_q, rid_q};
                16'd2: tx_word = {rec_status, rec_bytes};
                16'd3: tx_word = rec_addr;
                16'd4: tx_word = iova_q;
                default: tx_word = 64'd0;
            endcase
        end else if (pay_idx < 6'(BUF_WORDS)) begin
            tx_word = rec_buf[pay_idx];
        end
    end

    assign tx_data  = tx_word;
    assign tx_valid = (state_reg == S_TX_HDR) || (state_reg == S_TX_DATA);
    assign tx_last  = tx_valid && (tx_idx == last_idx);

    assign rd_addr  = rec_addr;
    assign rd_len   = rec_len;
    assign rd_ready = (state_reg == S_COLLECT);

    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg <= S_IDLE;
            hdr_idx   <= 3'd0;
            rid_q     <= 32'd0;
            addr_q    <= 64'd0;
            iova_q    <= 64'd0;
            remain_q  <= 32'd0;
            seq_q     <= 16'd0;
            buf_n     <= 6'd0;
            rec_addr  <= 64'd0;
            tx_idx    <= 16'd0;
            rec_err   <= 1'b0;
            test_request_spent <= 1'b0;
            req_cnt   <= 32'd0;
            err_cnt   <= 32'd0;
            rd_start  <= 1'b0;
            for (i = 0; i < 6; i++) hdr[i] <= 64'd0;
        end else begin
            rd_start <= 1'b0;

            case (state_reg)
                S_IDLE: begin
                    hdr_idx <= 3'd0;
                    // Only a word that actually is the frame magic may open a
                    // header.  Without this check a stray word -- a beat whose
                    // leading pair was lost, or the tail of a truncated frame --
                    // was latched as w0 and the whole header shifted, which is
                    // how hdr[2] ended up holding iova instead of the length.
                    // A rejected word is simply dropped; the next magic
                    // resynchronises.
                    if (rx_valid && !rx_last && (rx_data[31:0] == `PL11_MAGIC)) begin
                        hdr[0]    <= rx_data;
                        hdr_idx   <= 3'd1;
                        state_reg <= S_HDR;
                    end else if (rx_valid && !rx_last) begin
                        state_reg <= S_DROP;
                    end
                end

                S_HDR: begin
                    if (rx_valid) begin
                        // Magic is legal in IDs/addresses. Only rx_last defines
                        // the frame boundary; never resynchronise inside it.
                        if (rx_last && hdr_idx != 3'd5) begin
                            state_reg <= S_IDLE;
                            hdr_idx <= 0;
                        end else begin
                            hdr[hdr_idx] <= rx_data;
                            if (hdr_idx == 3'd5) begin
                                hdr_idx <= 3'd0;
                                if (!rx_last) begin
                                    state_reg <= S_DROP;
                                end else if (hdr_ok) begin
                                    if (C_CHECK_TEST_ADDR) test_request_spent <= 1'b1;
                                    rid_q     <= rx_rid;
                                    addr_q    <= rx_pa;
                                    iova_q    <= rx_iova;
                                    remain_q  <= rx_len;
                                    seq_q     <= 16'd0;
                                    rec_err   <= 1'b0;
                                    req_cnt   <= req_cnt + 32'd1;
                                    state_reg <= S_NEXT;
                                end else begin
                                    // Not a request this build understands: drop it
                                    // and resynchronise on the next magic.
                                    state_reg <= S_IDLE;
                                end
                            end else begin
                                hdr_idx <= hdr_idx + 3'd1;
                            end
                        end
                    end
                end

                S_DROP: if (rx_valid && rx_last) state_reg <= S_IDLE;

                S_NEXT: if (!rd_busy) begin
                    rec_addr  <= addr_q;
                    buf_n     <= 6'd0;
                    tx_idx    <= 16'd0;
                    rd_start  <= 1'b1;
                    state_reg <= S_COLLECT;
                end

                S_COLLECT: begin
                    if (rd_valid && rd_ready) begin
                        if (buf_n < 6'(BUF_WORDS)) rec_buf[buf_n] <= rd_data;
                        buf_n <= buf_n + 6'd1;
                    end
                    // done only arrives once the last word has been taken, but
                    // require the interface to be idle as well: acting on done
                    // in the same cycle a word is accepted drops that word.
                    if (rd_done && !rd_valid) begin
                        rec_err   <= rd_error || ({23'd0,buf_n,3'd0} != rec_len);
                        if (rd_error || ({23'd0,buf_n,3'd0} != rec_len)) err_cnt <= err_cnt + 32'd1;
                        tx_idx    <= 16'd0;
                        state_reg <= S_TX_HDR;
                    end
                end

                S_TX_HDR, S_TX_DATA: begin
                    if (tx_valid && tx_ready) begin
                        if (tx_idx == last_idx) begin
                            if (rec_is_last) begin
                                state_reg <= S_IDLE;
                            end else begin
                                addr_q    <= addr_q + {32'd0,rec_len};
                                remain_q  <= remain_q - rec_len;
                                seq_q     <= seq_q + 16'd1;
                                state_reg <= S_NEXT;
                            end
                        end else begin
                            tx_idx <= tx_idx + 16'd1;
                            if (tx_idx == 16'd5) state_reg <= S_TX_DATA;
                        end
                    end
                end

                default: state_reg <= S_IDLE;
            endcase
        end
    end

    // verilator lint_off UNUSED
    // verilator lint_on UNUSED

endmodule

`default_nettype wire
