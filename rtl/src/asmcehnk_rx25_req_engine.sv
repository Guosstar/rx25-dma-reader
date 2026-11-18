// ---------------------------------------------------------------------------
// asmcehnk_rx25_req_engine
//
// The control-side half of RX25: turn a descriptor job from asmcehnk_rx25_bar
// into a PL11 request, take the DATA records that come back, and push their
// payload into host memory through asmcehnk_mwr_stream.  One job in flight at a
// time; the remaining descriptors stay queued inside asmcehnk_rx25_bar, which
// is enough for bring-up and keeps tag/offset bookkeeping single-threaded.
//
// The write engine is deliberately not started until the first DATA record
// arrives, so a descriptor that is never answered times out with nothing in
// flight -- no half-emitted Memory Write is left in the RQ stream.  A response
// that dies mid-record is a link fault: the engine stalls, the slot stays busy
// and the host's own descriptor timeout takes over.  Raising STATUS.FATAL for
// that case belongs with the link-fault work, not here.
//
// Frame format: see asmcehnk_rx25_pl11.svh.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"
`include "asmcehnk_rx25_pl11.svh"

module asmcehnk_rx25_req_engine #(
    parameter int C_TIMEOUT_CYCLES = 200_000,
    parameter int C_SLOT_W         = 3
)(
    input  wire logic        rst,
    input  wire logic        clk,

    // ---- job from asmcehnk_rx25_bar ---------------------------------------
    input  wire logic        job_valid,
    output logic             job_ready,
    input  wire logic [7:0]  job_slot,
    input  wire logic [31:0] job_request_id,
    input  wire logic [15:0] job_generation,
    input  wire logic [15:0] job_length,
    input  wire logic [63:0] job_remote_pa,
    input  wire logic [63:0] job_host_iova,

    // ---- completion back to asmcehnk_rx25_bar -----------------------------
    output logic             cq_valid,
    input  wire logic        cq_ready,
    output logic [7:0]       cq_slot,
    output logic [15:0]      cq_status,
    output logic [31:0]      cq_bytes,
    output logic [31:0]      cq_detail,

    // ---- payload into host memory -----------------------------------------
    output logic [63:0]      mwr_addr,
    output logic [31:0]      mwr_len,
    output logic             mwr_start,
    input  wire logic [31:0] mwr_done,
    input  wire logic        mwr_busy,
    input  wire logic        mwr_error,
    output logic [127:0]     mwr_tdata,
    output logic [3:0]       mwr_tkeepdw,
    output logic             mwr_tvalid,
    input  wire logic        mwr_tready,

    // ---- PL11 frames, 64-bit words ----------------------------------------
    output logic             tx_valid,
    input  wire logic        tx_ready,
    output logic [63:0]      tx_data,
    output logic             tx_last,

    input  wire logic        rx_valid,
    input  wire logic [63:0] rx_data,
    output logic             rx_ready,

    // ---- diagnostics -------------------------------------------------------
    output logic [31:0]      cnt_frames_bad,
    output logic [31:0]      cnt_timeout,
    // Latched on the cycle a header completes, so the reason a frame was
    // rejected can be read back instead of inferred.  hdr_ok tests six fields
    // and these four cover all of them; a zero length is distinguishable from a
    // wrong rid or a wrong type without another build.
    output logic [31:0]      dbg_rx_magic,
    output logic [31:0]      dbg_rx_type,
    output logic [31:0]      dbg_rx_rid,
    output logic [31:0]      dbg_rx_len,
    // Which state was waiting when the last timeout expired: 2 = S_WAIT_DATA
    // (no header), 3 = S_DATA (header ok, payload short).  Without this the two
    // cases are indistinguishable and both just bump cnt_timeout.
    output logic [2:0]       dbg_tmo_state
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_REQ_TX,
        S_WAIT_DATA,
        S_DATA,
        S_DRAIN,
        S_CQ,
        S_FAULT
    } state_t;

    state_t state_reg;

    // job snapshot
    logic [7:0]  slot_q;
    logic [31:0] rid_q;
    logic [15:0] gen_q;
    logic [15:0] len_q;
    logic [63:0] rpa_q;
    logic [63:0] iova_q;

    logic [2:0]  tx_idx;        // request header word index
    logic [2:0]  hdr_idx;       // incoming header word index
    logic [63:0] hdr [0:5];

    logic [15:0] rec_words;     // payload words left in this record
    logic        beat_phase;    // 0 = waiting for the low half of a beat
    logic [63:0] beat_word0;
    logic [15:0] flags_q;
    logic [31:0] committed_q, record_len_q;
    logic [15:0] sequence_q;
    logic record_short_q;

    logic [31:0] frames_bad;
    logic [31:0] timeouts;

    // Header snapshot for the rejection path.
    logic [31:0] dbg_magic_q;
    logic [31:0] dbg_type_q;
    logic [31:0] dbg_rid_q;
    logic [31:0] dbg_len_q;
    logic [2:0]  dbg_tmo_q;
    logic [31:0] timeout_cnt;

    assign cnt_frames_bad = frames_bad;
    assign cnt_timeout    = timeouts;
    assign dbg_rx_magic   = dbg_magic_q;
    assign dbg_rx_type    = dbg_type_q;
    assign dbg_rx_rid     = dbg_rid_q;
    assign dbg_rx_len     = dbg_len_q;
    assign dbg_tmo_state  = dbg_tmo_q;

    // ---- request header ----------------------------------------------------
    wire [63:0] req_w0 = {`PL11_TYPE_REQ, `PL11_VERSION, `PL11_MAGIC};
    wire [63:0] req_w1 = {16'd0, 16'd0, rid_q};
    wire [63:0] req_w2 = {32'd0, len_q};
    wire [63:0] req_w3 = rpa_q;
    wire [63:0] req_w4 = iova_q;
    wire [63:0] req_w5 = 64'd0;

    always_comb begin
        unique case (tx_idx)
            3'd0:    tx_data = req_w0;
            3'd1:    tx_data = req_w1;
            3'd2:    tx_data = req_w2;
            3'd3:    tx_data = req_w3;
            3'd4:    tx_data = req_w4;
            default: tx_data = req_w5;
        endcase
    end

    assign tx_valid = (state_reg == S_REQ_TX);
    assign tx_last  = (state_reg == S_REQ_TX) && (tx_idx == 3'd5);

    // ---- incoming header decode -------------------------------------------
    wire [31:0] rx_magic = hdr[0][31:0];
    wire [15:0] rx_ver   = hdr[0][47:32];
    wire [15:0] rx_type  = hdr[0][63:48];
    wire [31:0] rx_rid   = hdr[1][31:0];
    wire [15:0] rx_seq   = hdr[1][47:32];
    wire [15:0] rx_flags = hdr[1][63:48];
    wire [31:0] rx_len   = hdr[2][31:0];
    // hdr[0..4] are already latched when hdr[5] arrives, so these are valid
    // exactly in the cycle the header completes.
    wire        hdr_ok   = (rx_magic == `PL11_MAGIC) &&
                           (rx_ver   == `PL11_VERSION) &&
                           (rx_type  == `PL11_TYPE_DATA) &&
                           (rx_rid   == rid_q) && (rx_seq == sequence_q) && (rx_data == 0) &&
                           (hdr[3] == rpa_q + {32'd0,committed_q}) &&
                           (hdr[4] == iova_q) && (rx_flags[15:1] == 0) &&
                           (rx_len <= `PL11_MAX_RECORD) &&
                           (committed_q + rx_len <= {16'd0,len_q}) &&
                           (rx_len[3:0] == 0) &&
                           (((hdr[2][63:32] == `PL11_STATUS_OK) && (rx_len != 0) &&
                             (rx_flags[0] == (committed_q + rx_len == {16'd0,len_q}))) ||
                            ((hdr[2][63:32] == `PL11_STATUS_SHORT) && rx_flags[0]));

    // ---- handshakes --------------------------------------------------------
    assign job_ready = (state_reg == S_IDLE);

    // A word is taken when the engine can consume it: header words always, a
    // payload low half always, a payload high half only once the write engine
    // has room for the assembled beat.
    wire beat_ready = (state_reg == S_DATA) && beat_phase && mwr_tready;
    assign rx_ready = (state_reg == S_WAIT_DATA) ||
                      ((state_reg == S_DATA) && (!beat_phase || mwr_tready));
    wire rx_take = rx_valid && rx_ready;

    // Commit one complete responder record at a time. A later SHORT/0B record
    // cannot leave a full-job MWr waiting for data that will never arrive.
    assign mwr_addr    = iova_q + {32'd0,committed_q};
    assign mwr_len     = record_len_q;
    assign mwr_tdata   = {rx_data, beat_word0};
    assign mwr_tkeepdw = 4'b1111;
    // The beat is complete in the cycle the high half is on rx_data.
    assign mwr_tvalid  = (state_reg == S_DATA) && beat_phase && rx_valid;

    assign cq_slot   = slot_q;
    assign cq_bytes  = committed_q;
    assign cq_detail = 32'd0;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg   <= S_IDLE;
            slot_q      <= 8'd0;
            rid_q       <= 32'd0;
            gen_q       <= 16'd0;
            len_q       <= 16'd0;
            rpa_q       <= 64'd0;
            iova_q      <= 64'd0;
            tx_idx      <= 3'd0;
            hdr_idx     <= 3'd0;
            rec_words   <= 16'd0;
            beat_phase  <= 1'b0;
            beat_word0  <= 64'd0;
            flags_q     <= 16'd0;
            committed_q <= 0; record_len_q <= 0; sequence_q <= 0; record_short_q <= 0;
            frames_bad  <= 32'd0;
            timeouts    <= 32'd0;
            dbg_magic_q <= 32'd0;
            dbg_type_q  <= 32'd0;
            dbg_rid_q   <= 32'd0;
            dbg_len_q   <= 32'd0;
            dbg_tmo_q   <= 3'd0;
            timeout_cnt <= 32'd0;
            cq_valid    <= 1'b0;
            cq_status   <= 16'd0;
            mwr_start   <= 1'b0;
            for (int i = 0; i < 6; i++) hdr[i] <= 64'd0;
        end else begin
            mwr_start <= 1'b0;

            case (state_reg)
                // ------------------------------------------------------------
                S_IDLE: begin
                    if (job_valid) begin
                        slot_q      <= job_slot;
                        rid_q       <= job_request_id;
                        gen_q       <= job_generation;
                        len_q       <= job_length;
                        rpa_q       <= job_remote_pa;
                        iova_q      <= job_host_iova;
                        tx_idx      <= 3'd0;
                        hdr_idx     <= 3'd0;
                        rec_words   <= 16'd0;
                        beat_phase  <= 1'b0;
                        committed_q <= 0; sequence_q <= 0; record_len_q <= 0; record_short_q <= 0;
                        timeout_cnt <= 32'd0;
                        state_reg   <= S_REQ_TX;
                    end
                end

                // ------------------------------------------------------------
                S_REQ_TX: begin
                    if (tx_ready) begin
                        if (tx_idx == 3'd5) begin
                            state_reg   <= S_WAIT_DATA;
                            hdr_idx     <= 3'd0;
                            timeout_cnt <= 32'd0;
                        end else begin
                            tx_idx <= tx_idx + 3'd1;
                        end
                    end
                end

                // ------------------------------------------------------------
                S_WAIT_DATA: begin
                    if (rx_take) begin
                        // Only a word that is actually the magic may open a
                        // header.  Previously the first word seen was latched as
                        // w0 unconditionally; when the transport repeated a beat
                        // the header check failed but the payload words behind it
                        // were then consumed as the next header, so the engine
                        // stayed permanently one frame out of step (perr without
                        // any valid completion).
                        if ((hdr_idx == 3'd0) && (rx_data[31:0] != `PL11_MAGIC)) begin
                            // Not a header start: drop the word and keep hunting.
                            // timeout_cnt is deliberately NOT cleared here, so a
                            // stream of junk still eventually trips the timeout.
                        end else begin
                            timeout_cnt <= 32'd0;
                            begin
                                // Magic inside an ID/address is ordinary data.
                                hdr[hdr_idx] <= rx_data;
                                if (hdr_idx == 3'd5) begin
                                    hdr_idx <= 3'd0;
                                    // Snapshot the decoded fields before hdr[]
                                    // is overwritten by the next frame.
                                    dbg_magic_q <= rx_magic;
                                    dbg_type_q  <= {16'd0, rx_type};
                                    dbg_rid_q   <= rx_rid;
                                    dbg_len_q   <= rx_len;
                                    if (hdr_ok) begin
                                        // payload words left = bytes / 8 (NOT /2:
                                        // a word is 64 bits, and getting this wrong
                                        // makes the engine eat the next header as data)
                                        rec_words  <= {1'b0, rx_len[15:3]};
                                        beat_phase <= 1'b0;
                                        flags_q    <= rx_flags;
                                        record_len_q <= rx_len;
                                        record_short_q <= (hdr[2][63:32] == `PL11_STATUS_SHORT);
                                        mwr_start  <= (rx_len != 0);
                                        state_reg  <= (rx_len == 0) ? S_DRAIN : S_DATA;
                                    end else begin
                                        frames_bad <= frames_bad + 32'd1;
                                        state_reg  <= S_WAIT_DATA;
                                    end
                                end else begin
                                    hdr_idx <= hdr_idx + 3'd1;
                                end
                            end
                        end
                    end else if (timeout_cnt >= 32'(C_TIMEOUT_CYCLES)) begin
                        timeouts  <= timeouts + 32'd1;
                        dbg_tmo_q <= 3'd2;
                        cq_status <= 16'd4;              // LC_FPGA_RX_CQ_NO_COMPLETION
                        cq_valid  <= 1'b1;
                        state_reg <= S_CQ;
                    end else begin
                        timeout_cnt <= timeout_cnt + 32'd1;
                    end
                end

                // ------------------------------------------------------------
                S_DATA: begin
                    if (rx_take) begin
                        timeout_cnt <= 32'd0;
                        rec_words   <= rec_words - 16'd1;
                        if (!beat_phase) begin
                            beat_word0 <= rx_data;
                            beat_phase <= 1'b1;
                        end else begin
                            // The assembled beat was handed to the write engine
                            // this cycle (mwr_tvalid && mwr_tready).
                            beat_phase <= 1'b0;
                            if (rec_words == 16'd1) begin
                                state_reg <= S_DRAIN;
                            end
                        end
                    end else if (timeout_cnt >= 32'(C_TIMEOUT_CYCLES)) begin
                        timeouts  <= timeouts + 32'd1;
                        dbg_tmo_q <= 3'd3;
                        cq_status <= 16'd6;              // LC_FPGA_RX_CQ_PROTOCOL_ERROR
                        // A partially emitted posted TLP cannot be cancelled.
                        // Stop accepting jobs until reset instead of reusing it.
                        state_reg <= S_FAULT;
                    end else begin
                        timeout_cnt <= timeout_cnt + 32'd1;
                    end
                end

                // ------------------------------------------------------------
                S_DRAIN: begin
                    if (!mwr_busy) begin
                        committed_q <= committed_q + record_len_q;
                        if (flags_q[0] || mwr_error) begin
                            cq_status <= (mwr_error || record_short_q) ? 16'd5 : 16'd1;
                            cq_valid <= 1'b1;
                            state_reg <= S_CQ;
                        end else begin
                            sequence_q <= sequence_q + 1'b1;
                            hdr_idx <= 0;
                            timeout_cnt <= 0;
                            state_reg <= S_WAIT_DATA;
                        end
                    end
                end

                S_CQ: if (cq_ready) begin cq_valid <= 1'b0; state_reg <= S_IDLE; end
                S_FAULT: ; // reset is required to flush an incomplete posted TLP
                default: state_reg <= S_IDLE;
            endcase
        end
    end

    // gen_q is echoed in the CQ by asmcehnk_rx25_bar (it keeps its own copy).
    // verilator lint_off UNUSED
    wire [15:0] unused_gen  = gen_q;
    wire [15:0] unused_seq  = rx_seq;
    wire        unused_done = mwr_done[31];
    wire        unused_brdy = beat_ready;
    // verilator lint_on UNUSED

endmodule

`default_nettype wire
