// ---------------------------------------------------------------------------
// asmcehnk_rx25_tlp_shim
//
// Binds PL11 frames to the asmcehnk TLP channel without adding a wire type.
//
// Why the TLP channel (type 00) and not the command/loopback channel:
//   * it is the only multi-lane channel in asmcehnk_mux -- dtlp.rx carries four
//     32-bit lanes per beat while every other channel is a single 32-bit word,
//     and the mux spends one status word per eight, so the TLP path gets the
//     full 7/8 of the wire rate;
//   * it terminates before the RQ packetizer, so a frame never pays the
//     sequence-credit round trip that costs ~100 clocks per TLP;
//   * mixing firmware versions is safe: a PL11 frame starts with 'PL11', whose
//     Fmt field (101) is neither MRd nor MWr, so an old peer drains it instead
//     of corrupting memory.  A fifth type code would need a wider type field
//     and would break the host-side COM protocol.
//
// Clock domains: both halves run on clk.  The receive half deliberately starts
// *after* asmcehnk_tlps128_src_fifo's 134-bit clock-crossing FIFO, because
// dtlp.tx lives in clk_sys -- tapping it directly (the first version of this
// module did) is a clock-domain violation that simulates cleanly and fails on
// hardware.
//
// Receive side: a packet whose first dword is 'PL11' is swallowed and re-emitted
// as 64-bit frame words; everything else passes through untouched.  PL11 frames
// are 12 + 2N dwords, i.e. always a whole number of 4-dword beats, so the
// decision is made at beat granularity with tuser[0] as the packet boundary --
// no dword-level state machine and no one-cycle lookahead.
//
// Transmit side: frame words are packed two per beat into a 128-bit AXIS stream
// (`first` on the beat that starts a frame, `last` on the beat that ends it),
// which is the input format asmcehnk_tlps128_dst_fifo_us expects.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"
`include "asmcehnk_rx25_pl11.svh"

module asmcehnk_rx25_tlp_shim (
    input  wire logic        rst,
    input  wire logic        clk,

    // ---- from the wire, after the src FIFO's clock crossing ----------------
    input  wire logic [127:0] rx_tdata,
    input  wire logic [3:0]   rx_tkeepdw,
    input  wire logic         rx_tfirst,      // tuser[0]
    input  wire logic         rx_tlast,
    input  wire logic         rx_tvalid,
    output logic              rx_tready,

    // ---- pass-through for packets that are not PL11 frames ----------------
    output logic [127:0]      pass_tdata,
    output logic [3:0]        pass_tkeepdw,
    output logic              pass_tfirst,
    output logic              pass_tlast,
    output logic              pass_tvalid,
    input  wire logic         pass_tready,

    // ---- PL11 frames, pushed one beat (two words) per cycle ----------------
    // The upstream stream cannot be stalled (see asmcehnk_frame_fifo128), so
    // this side never refuses a beat; the buffer behind it is what absorbs the
    // rate difference, and it reports overflow instead of losing a word.
    output logic [127:0]     frame_wr_data,
    output logic             frame_wr_last,
    output logic             frame_wr_en,
    input  wire logic        frame_wr_full,

    input  wire logic [63:0] frame_tx_data,
    input  wire logic        frame_tx_valid,
    input  wire logic        frame_tx_last,
    output logic             frame_tx_ready,

    // ---- to the wire, as a 128-bit TLP-shaped beat -------------------------
    output logic [127:0]     tx_tdata,
    output logic [3:0]       tx_tkeepdw,
    output logic [8:0]       tx_tuser,      // [0] = first beat of the frame
    output logic             tx_tlast,
    output logic             tx_tvalid,
    input  wire logic        tx_tready,

    // ---- diagnostics -------------------------------------------------------
    output logic [31:0]      cnt_rx_frames,
    output logic [31:0]      cnt_rx_bad,
    output logic [31:0]      cnt_rx_first,
    output logic [31:0]      cnt_rx_magic,
    output logic [31:0]      cnt_rx_start,
    // Framing state.  The responder stops recognising new requests after the
    // first one, and this state machine is the only place that can explain it:
    // start_frame is gated on !in_frame, so a frame that never closes swallows
    // every following magic.  Exposing the two counters costs nothing.
    output logic             dbg_in_frame,
    output logic [7:0]       dbg_beats_in_frame,
    // Repurposed: the transmit-side counter was never connected and always read
    // zero.  The receive beat count is what this build needs, so it drives the
    // existing port rather than adding another one through five layers.
    output logic [31:0]      cnt_tx_frames,
    // Accepted-beat count.  A separate port: cnt_tx_frames is already driven by
    // tx_frames below, and reusing it produced a multiple-driver DRC error.
    output logic [31:0]      dbg_rx_beats
);

    // ========================================================================
    // Receive side
    //
    // One beat carries four dwords, i.e. two frame words, and a PL11 frame is
    // 12 + 2N dwords -- always a whole number of beats.  So the decision is
    // purely combinational: a beat whose first dword is MAGIC and which starts
    // a packet opens a frame, every following beat belongs to it until tlast.
    // ========================================================================
    logic        in_frame;
    logic [31:0] rx_frames;
    logic [31:0] rx_bad;

    assign cnt_rx_frames = rx_frames;
    assign cnt_rx_bad    = rx_bad;
    // Three counters that answer "why was the first beat skipped" without an
    // ILA: how often a beat claimed to start a packet, how often its first
    // dword was the magic, and how often both coincided.
    logic [31:0] rx_first_cnt;   // rx_tfirst seen
    logic [31:0] rx_magic_cnt;   // rx_tdata[31:0] == MAGIC
    logic [31:0] rx_start_cnt;   // start_frame fired
    // Accepted beats.  Everything upstream reports zero while frames still get
    // built, so the ONLY trustworthy observation point is this port pair --
    // rx_tvalid/rx_tready are top-level module ports, not interface members, and
    // cannot be duplicated by the synthesiser.  Counting here answers the one
    // question that matters: does a second frame's data ever arrive?
    logic [31:0] rx_beat_cnt;
    assign cnt_rx_first = rx_first_cnt;
    assign cnt_rx_magic = rx_magic_cnt;
    assign cnt_rx_start = rx_start_cnt;

    wire magic_here    = (rx_tdata[31:0] == `PL11_MAGIC);

    // Opening a frame no longer requires rx_tfirst.  first comes out of the src
    // FIFO's packet counter and is only correct while every tlast survives; a
    // single dropped tlast leaves it stuck low and every later frame is then
    // skipped or joined late.  The magic is unique enough to resynchronise on
    // its own, and it is only consulted while no frame is open, so a payload
    // dword that happens to equal the magic cannot split a frame.

    // Belt and braces: a frame that never ends would otherwise swallow the link
    // forever.  A real frame is 6 header words plus at most 256 payload bytes,
    // i.e. far under 160 beats.
    logic [7:0] beats_in_frame;

    // A frame opens on the magic only while none is open.  An earlier attempt
    // also resynchronised on magic inside a frame, using a beat-count threshold
    // to tell payload from a new header.  That cannot work: PL11 payload may
    // contain any dword, including one equal to the magic, so any threshold
    // either misses real headers or splits frames that were intact.  The actual
    // fault was upstream -- a duplicated first beat -- and is fixed in
    // asmcehnk_fifo's bypass buffer.
    wire start_frame   = magic_here && !in_frame;
    wire is_frame_beat = in_frame || start_frame;

    assign dbg_rx_beats       = rx_beat_cnt;
    assign dbg_in_frame       = in_frame;
    assign dbg_beats_in_frame = beats_in_frame;
    wire        frame_timeout = in_frame && (beats_in_frame == 8'd200);
    // A frame is beat-aligned by construction; a short beat inside one means the
    // peer is broken, and merging it would shift every following word.
    wire beat_full     = (rx_tkeepdw == 4'b1111);
    wire frame_take    = rx_tvalid && is_frame_beat;
    wire frame_ok      = frame_take && beat_full && !frame_wr_full;

    assign pass_tdata   = rx_tdata;
    assign pass_tkeepdw = rx_tkeepdw;
    assign pass_tfirst  = rx_tfirst;
    assign pass_tlast   = rx_tlast;
    assign pass_tvalid  = rx_tvalid && !is_frame_beat;

    // Never refuse a frame beat: a dropped beat loses two words and the whole
    // frame is garbage, while the buffer behind this port degrades gracefully.
    assign rx_tready = is_frame_beat ? 1'b1 : pass_tready;

    assign frame_wr_en   = frame_ok;
    assign frame_wr_data = rx_tdata;
    assign frame_wr_last = rx_tlast;

    always_ff @(posedge clk) begin
        if (rst) begin
            in_frame       <= 1'b0;
            rx_frames      <= 32'd0;
            rx_bad         <= 32'd0;
            rx_first_cnt   <= 32'd0;
            rx_beat_cnt    <= 32'd0;
            rx_magic_cnt   <= 32'd0;
            rx_start_cnt   <= 32'd0;
            beats_in_frame <= 8'd0;
        end else begin
            // Diagnostics run on every accepted beat, independent of framing.
            if (rx_tvalid && rx_tready) begin
                rx_beat_cnt <= rx_beat_cnt + 32'd1;
                if (rx_tfirst)    rx_first_cnt <= rx_first_cnt + 32'd1;
                if (magic_here)   rx_magic_cnt <= rx_magic_cnt + 32'd1;
                if (start_frame)  rx_start_cnt <= rx_start_cnt + 32'd1;
            end

            if (frame_take) begin
                if (!beat_full || frame_wr_full) begin
                    // Malformed beat or a full buffer: drop the beat and
                    // resynchronise on the next packet boundary.
                    in_frame       <= 1'b0;
                    beats_in_frame <= 8'd0;
                    rx_bad         <= rx_bad + 32'd1;
                end else if (rx_tlast || frame_timeout) begin
                    in_frame       <= 1'b0;
                    beats_in_frame <= 8'd0;
                    if (rx_tlast) rx_frames <= rx_frames + 32'd1;
                end else begin
                    in_frame       <= 1'b1;
                    beats_in_frame <= beats_in_frame + 8'd1;
                end
            end else if (frame_timeout) begin
                in_frame       <= 1'b0;
                beats_in_frame <= 8'd0;
            end
        end
    end

    // ========================================================================
    // Transmit side: frame words -> 128-bit beats
    //
    // Two frame words fill one beat (four 32-bit lanes, little endian), which is
    // exactly how asmcehnk_tlps128_dst_fifo_us serializes a TLP: lane 0 carries
    // the first dword.  A frame is 6 header words plus an even number of payload
    // words, so every beat is full; the partial path only keeps a malformed
    // frame from wedging the channel.
    // ========================================================================
    logic [63:0] wq [0:1];
    logic [1:0]  wn;            // words buffered for the beat under assembly
    logic        wlast;         // buffered words include the frame's last
    logic        tx_pending;    // a beat is on the output, waiting for tready
    logic        next_first;    // the next beat starts a frame
    logic [31:0] tx_frames;

    assign cnt_tx_frames = tx_frames;

    wire will_emit = !tx_pending && ((wn == 2'd2) || (wlast && (wn != 2'd0)));
    assign frame_tx_ready = !tx_pending && !will_emit && (wn < 2'd2);

    assign tx_tdata   = {wq[1], wq[0]};
    assign tx_tkeepdw = (wn == 2'd2) ? 4'b1111 : 4'b0011;
    assign tx_tuser   = {8'd0, tx_pending && next_first};
    assign tx_tlast   = tx_pending && wlast;
    assign tx_tvalid  = tx_pending;

    integer k;
    always_ff @(posedge clk) begin
        if (rst) begin
            wn           <= 2'd0;
            wlast        <= 1'b0;
            tx_pending   <= 1'b0;
            next_first   <= 1'b1;
            tx_frames    <= 32'd0;
            for (k = 0; k < 2; k++) wq[k] <= 64'd0;
        end else begin
            if (tx_pending && tx_tready) begin
                tx_pending <= 1'b0;
                wn         <= 2'd0;
                wlast      <= 1'b0;
                next_first <= wlast;        // the next beat starts a new frame
            end else if (will_emit) begin
                tx_pending <= 1'b1;
            end

            if (frame_tx_valid && frame_tx_ready) begin
                wq[wn] <= frame_tx_data;
                wn     <= wn + 2'd1;
                if (frame_tx_last) begin
                    wlast     <= 1'b1;
                    tx_frames <= tx_frames + 32'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
