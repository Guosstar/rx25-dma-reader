// ---------------------------------------------------------------------------
// asmcehnk_rx25_bar -- host-side register + descriptor ABI of the RX25
// receiver, implemented from the published header so that the stock
// leechcore receiver device backend (device_fpga_rx.c) and the KDMA NetUIO
// driver work unmodified.
//
// Layout is fixed by that ABI, not by us:
//   BAR0+0x0000 .. 0x0088   register file
//   BAR0+0x1000 + n*0x20    descriptor slot n        (n < SLOT_COUNT)
//   host_iova + 0x0000      4 KiB page holding the read data
//   host_iova + 0x1000      32-byte CQ entry, published by writing the
//                           generation/status dword LAST
//
// The descriptor's host_iova is a bare physical address on Windows (the
// vendor driver supplies it through virt2phys) and an IOVA under VFIO; this
// module never translates it, it just hands the 64-bit value to the DMA
// engine.
//
// Descriptor (32 B, little endian, flags at +0x18 is the doorbell):
//   +0x00 u64 remote_pa
//   +0x08 u64 host_iova
//   +0x10 u32 request_id
//   +0x14 u16 generation
//   +0x16 u16 length
//   +0x18 u32 flags          bit0 VALID must be set by the last write
//   +0x1c u32 reserved
//
// CQ entry (32 B):
//   +0x00 u32 request_id
//   +0x04 u16 generation | u16 status   <-- written last
//   +0x08 u32 bytes
//   +0x0c u32 sequence
//   +0x10 u32 error_detail
//   +0x14 u32 reserved[3]
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"

module asmcehnk_rx25_bar #(
    parameter bit C_FIRST16 = 1'b0,
    parameter bit C_BATCH_DIAG = 1'b0,
    // 1 = the descriptor engine is armed from reset and the CONTROL.ENABLE bit
    // is ignored.  Needed because on this board writing a *non-zero* control
    // word reliably wedges the BAR responder (one AER Unsupported Request per
    // write, then every MMIO access fails until the FPGA is reloaded).  With
    // this set the host never has to touch 0x0C at all.
    parameter bit C_ARM_ALWAYS = 1'b0,
    parameter int C_SLOTS   = 8,
    parameter logic [31:0] C_MAGIC   = 32'h3532_5852,  // 'RX25'
    parameter logic [31:0] C_VERSION = 32'd1,
    // DMA | CQ_AT_4K | MRD64 | PL11.  PL11 describes the card-to-card frame
    // format, which never leaves our own two boards -- leechcore only checks
    // that the bit is advertised and then reads the CQ status we publish.
    parameter logic [31:0] C_CAPS    = 32'h0000_000F
)(
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic [383:0] first16_registers,
    input wire logic [511:0] batch_registers,batch_owner_registers,
    input wire logic [1023:0] batch_pressure_registers,
    output wire logic [6:0] batch_payload_index,
    input wire logic [31:0] batch_payload_data,

    // BAR0 slave, offsets already relative to the BAR base.  Read and write
    // offsets are separate on purpose: the BAR engine registers them at
    // different pipeline stages, and a write can land while a read reply is
    // still travelling, so one shared offset would mis-decode the write.
    input  wire logic [13:0] bar_rd_off,
    input  wire logic [13:0] bar_wr_off,
    input  wire logic        bar_wr_en,
    input  wire logic [31:0] bar_wr_data,
    input  wire logic        bar_rd_en,
    // 25G observation counters, counted in the PHY clock domain.
    input  wire logic [31:0] obs_tx_pkt,
    input  wire logic [31:0] obs_rx_pkt,
    input  wire logic [31:0] obs_status,

    // Responder header diagnostics.  These answer "why does the record loop
    // never terminate": rx_len far above the requested length means the header
    // decoded wrong, remain stuck high means rec_is_last never fires.
    input  wire logic [31:0] dbg_len,
    input  wire logic [31:0] dbg_remain,
    input  wire logic        dbg_hdr_ok,
    input  wire logic [31:0] dbg_requests,
    input  wire logic [63:0] dbg_hdr0,
    input  wire logic [63:0] dbg_hdr1,
    input  wire logic [63:0] dbg_hdr2,
    input  wire logic [31:0] dbg_frames,
    input  wire logic [31:0] dbg_bad,
    input  wire logic [31:0] dbg_first,
    input  wire logic [31:0] dbg_magic,
    input  wire logic [31:0] dbg_start,
    input  wire logic [31:0] dbg_gate0,
    input  wire logic [31:0] dbg_gate1,
    // Bus-number override written by the host at BAR+0xF0.  Non-zero replaces
    // the requester ID used for MRd, because pcie4 EP mode reports 0.
    output wire logic [7:0]  bus_override,
    // initiator-side header rejection diagnostics (see rx25_req_engine)
    input  wire logic [31:0] init_bad,
    input  wire logic [31:0] init_tmo,
    input  wire logic [31:0] rx_magic,
    input  wire logic [31:0] rx_type,
    input  wire logic [31:0] rx_rid,
    input  wire logic [31:0] rx_len,
    input  wire logic [2:0]  rec_state,
    input  wire logic [5:0]  buf_n,
    input  wire logic [31:0] rec_len,
    input  wire logic [2:0]  tmo_state,
    input  wire logic [31:0] buf_w0_lo,
    input  wire logic [31:0] buf_w0_hi,
    input  wire logic [31:0] buf_w1_lo,
    input  wire logic [31:0] buf_w1_hi,
    input  wire logic [31:0] mwr_addr_lo,
    input  wire logic [31:0] mwr_addr_hi,
    input  wire logic [31:0] mwr_cfg_lo,
    input  wire logic [31:0] mwr_cfg_hi,
    input  wire logic        in_frame,
    input  wire logic [7:0]  beats_in_frame,
    input  wire logic [31:0] rx_words,
    input  wire logic [31:0] rx_frames_cnt,
    output logic [31:0]      bar_rd_data,

    // Job hand-off to the request engine.
    output logic             job_valid,
    input  wire logic        job_ready,
    output logic [7:0]       job_slot,
    output logic [31:0]      job_request_id,
    output logic [15:0]      job_generation,
    output logic [15:0]      job_length,
    output logic [63:0]      job_remote_pa,
    output logic [63:0]      job_host_iova,

    // Completion back from the request engine.
    input  wire logic        cq_valid,
    input  wire logic [7:0]  cq_slot,
    input  wire logic [15:0] cq_status,
    input  wire logic [31:0] cq_bytes,
    input  wire logic [31:0] cq_detail,

    // CQ publish: one dword per beat, index 0..7, target address fixed per
    // entry.  Dword 1 carries generation/status and is issued last so a host
    // polling that dword never sees a half-built entry.
    output logic             cqw_valid,
    output logic [63:0]      cqw_addr,
    output logic [31:0]      cqw_data,
    output logic [2:0]       cqw_index,
    input  wire logic        cqw_done,

    // Link state from the 25G side.
    input  wire logic        link_peer,
    input  wire logic        link_up,
    input  wire logic        fatal_in,
    output logic             enabled
);

    localparam int SLOT_W    = (C_SLOTS > 1) ? $clog2(C_SLOTS) : 1;
    localparam logic [13:0] SLOT_BASE   = 14'h1000;
    localparam logic [13:0] SLOT_STRIDE = 14'h0020;
    localparam logic [13:0] SLOT_END    = SLOT_BASE + 14'(C_SLOTS * 32);

    // ---- register file -----------------------------------------------------
    logic [31:0] control_reg;
    logic [7:0]  bus_override_reg;
    assign bus_override = bus_override_reg;
    logic        control_qd8;
    logic        control_enable;

    logic [31:0] cnt_success;
    logic [31:0] cnt_parser_err;
    logic [31:0] cnt_desc_reject;
    logic [31:0] cnt_timeout;
    logic [31:0] cnt_stale;
    logic [31:0] cnt_rx_good;
    logic [31:0] cnt_rx_bad;
    logic [31:0] cnt_rx_ovf;
    logic [31:0] sequence_reg;

    // ---- descriptor slots --------------------------------------------------
    logic [31:0] d_lo   [0:C_SLOTS-1];
    logic [31:0] d_hi   [0:C_SLOTS-1];
    logic [31:0] i_lo   [0:C_SLOTS-1];
    logic [31:0] i_hi   [0:C_SLOTS-1];
    logic [31:0] d_rid  [0:C_SLOTS-1];
    logic [31:0] d_genlen[0:C_SLOTS-1];
    logic        slot_pending [0:C_SLOTS-1];
    logic        slot_busy    [0:C_SLOTS-1];

    // ---- write decode ------------------------------------------------------
    wire wr_in_slot_window = (bar_wr_off >= SLOT_BASE) && (bar_wr_off < SLOT_END);
    wire [13:0] wr_slot_rel = bar_wr_off - SLOT_BASE;
    wire [SLOT_W-1:0] wr_slot_idx = wr_slot_rel[SLOT_W+4:5];
    wire [2:0]        wr_slot_dw  = wr_slot_rel[6:2];   // dword index in the slot

    wire wr_in_slot  = bar_wr_en && wr_in_slot_window;
    wire wr_doorbell = wr_in_slot && (wr_slot_dw == 5'd6) && bar_wr_data[0];

    // ---- read decode -------------------------------------------------------
    wire rd_in_slot_window = (bar_rd_off >= SLOT_BASE) && (bar_rd_off < SLOT_END);
    wire [13:0] rd_slot_rel = bar_rd_off - SLOT_BASE;
    wire [SLOT_W-1:0] rd_slot_idx = rd_slot_rel[SLOT_W+4:5];
    wire [2:0]        rd_slot_dw  = rd_slot_rel[6:2];

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            control_reg <= 32'd0;
            bus_override_reg <= 8'd0;
            sequence_reg <= 32'd0;
            cnt_success     <= 32'd0;
            cnt_parser_err  <= 32'd0;
            cnt_desc_reject <= 32'd0;
            cnt_timeout     <= 32'd0;
            cnt_stale       <= 32'd0;
            cnt_rx_good     <= 32'd0;
            cnt_rx_bad      <= 32'd0;
            cnt_rx_ovf      <= 32'd0;
            for (i = 0; i < C_SLOTS; i++) begin
                d_lo[i] <= 32'd0;  d_hi[i] <= 32'd0;
                i_lo[i] <= 32'd0;  i_hi[i] <= 32'd0;
                d_rid[i] <= 32'd0; d_genlen[i] <= 32'd0;
                slot_pending[i] <= 1'b0;
                slot_busy[i] <= 1'b0;
            end
        end else begin
            // CONTROL: bit0 ENABLE, bit1 RESET_ERRORS (self-clearing), bit2 QD8.
            if (bar_wr_en && (bar_wr_off == 14'h000C)) begin
                control_reg <= bar_wr_data & 32'h0000_0005;
            end
            // Bus-number override.  UltraScale+ pcie4 does not report the
            // endpoint's captured bus number (cfg_bus_number reads 0 in EP
            // mode), so the target firmware has no way to form a legal
            // requester ID.  The host writes it here with one setpci/python
            // MMIO store; zero keeps the old behaviour.
            if (bar_wr_en && (bar_wr_off == 14'h00F0)) begin
                bus_override_reg <= bar_wr_data[7:0];
            end

            if (wr_in_slot) begin
                case (wr_slot_dw)
                    5'd0: d_lo[wr_slot_idx]     <= bar_wr_data;
                    5'd1: d_hi[wr_slot_idx]     <= bar_wr_data;
                    5'd2: i_lo[wr_slot_idx]     <= bar_wr_data;
                    5'd3: i_hi[wr_slot_idx]     <= bar_wr_data;
                    5'd4: d_rid[wr_slot_idx]    <= bar_wr_data;
                    5'd5: d_genlen[wr_slot_idx] <= bar_wr_data;
                    5'd6: ;  // flags: doorbell only, never stored
                    default: ;
                endcase
            end

            // The doorbell write is the last dword, so every other field is
            // already latched.  Refuse it while the slot is still in flight.
            if (wr_doorbell) begin
                if (!slot_busy[wr_slot_idx] && control_enable) begin
                    slot_pending[wr_slot_idx] <= 1'b1;
                    slot_busy[wr_slot_idx]    <= 1'b1;
                end else begin
                    slot_pending[wr_slot_idx] <= 1'b0;
                    cnt_desc_reject <= cnt_desc_reject + 32'd1;
                end
            end

            if (job_valid && job_ready) begin
                slot_pending[job_slot[SLOT_W-1:0]] <= 1'b0;
            end

            if (cq_valid) begin
                slot_busy[cq_slot[SLOT_W-1:0]] <= 1'b0;
                case (cq_status)
                    16'd1: cnt_success    <= cnt_success + 32'd1;
                    16'd2,
                    16'd3: cnt_parser_err <= cnt_parser_err + 32'd1;
                    16'd4: cnt_timeout    <= cnt_timeout + 32'd1;
                    default: cnt_parser_err <= cnt_parser_err + 32'd1;
                endcase
                sequence_reg <= sequence_reg + 32'd1;
            end

            if (control_reg[1]) begin
                cnt_success     <= 32'd0;
                cnt_parser_err  <= 32'd0;
                cnt_desc_reject <= 32'd0;
                cnt_timeout     <= 32'd0;
                cnt_stale       <= 32'd0;
                cnt_rx_good     <= 32'd0;
                cnt_rx_bad      <= 32'd0;
                cnt_rx_ovf      <= 32'd0;
            end
        end
    end

    // Arm gating.  C_ARM_ALWAYS makes the engine permanently armed so the host
    // never writes the control word; otherwise ENABLE comes from the register.
    wire arm_ok = C_ARM_ALWAYS ? 1'b1 : control_reg[0];
    assign control_enable = arm_ok;
    assign control_qd8    = control_reg[2];
    assign enabled        = control_enable;

    // ---- job arbiter: lowest pending slot wins -----------------------------
    logic             job_sel_valid;
    logic [SLOT_W-1:0] job_sel;

    always_comb begin
        job_sel_valid = 1'b0;
        job_sel       = '0;
        for (int k = C_SLOTS - 1; k >= 0; k--) begin
            if (slot_pending[k]) begin
                job_sel_valid = 1'b1;
                job_sel       = SLOT_W'(k);
            end
        end
    end

    assign job_valid      = job_sel_valid && control_enable;
    assign job_slot       = 8'(job_sel);
    assign job_request_id = d_rid[job_sel];
    assign job_generation = d_genlen[job_sel][15:0];
    assign job_length     = d_genlen[job_sel][31:16];
    assign job_remote_pa  = {d_hi[job_sel], d_lo[job_sel]};
    assign job_host_iova  = {i_hi[job_sel], i_lo[job_sel]};

    // ---- CQ publish --------------------------------------------------------
    // Snapshot the completion because the source may move on next cycle.
    logic        cqw_active;
    logic [7:0]  cqw_slot_q;
    logic [31:0] cqw_rid_q;
    logic [15:0] cqw_gen_q;
    logic [15:0] cqw_stat_q;
    logic [31:0] cqw_bytes_q;
    logic [31:0] cqw_seq_q;
    logic [31:0] cqw_detail_q;
    logic [63:0] cqw_base_q;
    logic [2:0]  cqw_idx_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            cqw_active <= 1'b0;
            cqw_idx_q  <= 3'd0;
        end else begin
            if (cq_valid && !cqw_active) begin
                cqw_active  <= 1'b1;
                cqw_slot_q  <= cq_slot;
                cqw_rid_q   <= d_rid[cq_slot[SLOT_W-1:0]];
                cqw_gen_q   <= d_genlen[cq_slot[SLOT_W-1:0]][15:0];
                cqw_stat_q  <= cq_status;
                cqw_bytes_q <= cq_bytes;
                cqw_seq_q   <= sequence_reg;
                cqw_detail_q<= cq_detail;
                cqw_base_q  <= {i_hi[cq_slot[SLOT_W-1:0]], i_lo[cq_slot[SLOT_W-1:0]]} + 64'h1000;
                cqw_idx_q   <= 3'd0;
            end else if (cqw_active && cqw_done) begin
                if (cqw_idx_q == 3'd7) begin
                    cqw_active <= 1'b0;
                    cqw_idx_q  <= 3'd0;
                end else begin
                    cqw_idx_q <= cqw_idx_q + 3'd1;
                end
            end
        end
    end

    // Dword 1 must go last: emit 0,2,3,4,5,6,7,1 in that order.
    function automatic [2:0] cq_order(input [2:0] step);
        case (step)
            3'd0: cq_order = 3'd0;
            3'd1: cq_order = 3'd2;
            3'd2: cq_order = 3'd3;
            3'd3: cq_order = 3'd4;
            3'd4: cq_order = 3'd5;
            3'd5: cq_order = 3'd6;
            3'd6: cq_order = 3'd7;
            default: cq_order = 3'd1;
        endcase
    endfunction

    always_comb begin
        cqw_index = cq_order(cqw_idx_q);
        cqw_addr  = cqw_base_q + {59'd0, cqw_index, 2'b00};
        case (cqw_index)
            3'd0: cqw_data = cqw_rid_q;
            3'd1: cqw_data = {cqw_stat_q, cqw_gen_q};
            3'd2: cqw_data = cqw_bytes_q;
            3'd3: cqw_data = cqw_seq_q;
            3'd4: cqw_data = cqw_detail_q;
            default: cqw_data = 32'd0;
        endcase
    end

    assign cqw_valid = cqw_active;

    assign batch_payload_index=7'((bar_rd_off-14'h900)>>2);
    // ---- read mux ----------------------------------------------------------
    always_comb begin
        bar_rd_data = 32'd0;
        if(C_BATCH_DIAG && bar_rd_off >= 14'h800 && bar_rd_off < 14'h840) begin
            bar_rd_data=batch_registers[bar_rd_off[5:2]*32+:32];
        end else if(C_BATCH_DIAG && bar_rd_off >= 14'h840 && bar_rd_off < 14'h8c0) begin
            bar_rd_data=batch_pressure_registers[((bar_rd_off-14'h840)>>2)*32+:32];
        end else if(C_BATCH_DIAG && bar_rd_off >= 14'h8c0 && bar_rd_off < 14'h900) begin
            bar_rd_data=batch_owner_registers[bar_rd_off[5:2]*32+:32];
        end else if(C_BATCH_DIAG && bar_rd_off >= 14'h900 && bar_rd_off < 14'hb00) begin
            bar_rd_data=batch_payload_data;
        end else if (C_FIRST16 && bar_rd_off >= 14'h1c0 && bar_rd_off <= 14'h1ec) begin
            bar_rd_data = first16_registers[((bar_rd_off - 14'h1c0) >> 2)*32 +: 32];
        end else if (rd_in_slot_window) begin
            case (rd_slot_dw)
                5'd0: bar_rd_data = d_lo[rd_slot_idx];
                5'd1: bar_rd_data = d_hi[rd_slot_idx];
                5'd2: bar_rd_data = i_lo[rd_slot_idx];
                5'd3: bar_rd_data = i_hi[rd_slot_idx];
                5'd4: bar_rd_data = d_rid[rd_slot_idx];
                5'd5: bar_rd_data = d_genlen[rd_slot_idx];
                5'd6: bar_rd_data = {31'd0, slot_busy[rd_slot_idx]};
                default: bar_rd_data = 32'd0;
            endcase
        end else begin
            case (bar_rd_off)
                14'h0000: bar_rd_data = C_MAGIC;
                14'h0004: bar_rd_data = C_VERSION;
                14'h0008: bar_rd_data = C_CAPS;
                14'h000C: bar_rd_data = control_reg;
                14'h0010: bar_rd_data = {23'd0,
                                         slot_busy[0] | slot_pending[0],  // CORE_BUSY
                                         4'd0,
                                         control_qd8,                     // QD8_ACTIVE
                                         fatal_in,                        // FATAL
                                         link_peer && link_up,            // LINK_PEER
                                         link_up && control_enable};      // READY
                14'h0014: bar_rd_data = 32'(C_SLOTS);
                14'h0018: bar_rd_data = 32'h0000_0020;
                14'h001C: bar_rd_data = 32'h0000_1000;
                14'h0024: bar_rd_data = cnt_success;
                14'h0028: bar_rd_data = cnt_parser_err;
                14'h002C: bar_rd_data = cnt_desc_reject;
                14'h0030: bar_rd_data = 32'h8000_1000 | {19'd0, link_up, 12'd0};
                14'h0034: bar_rd_data = cnt_timeout;
                14'h0038: bar_rd_data = cnt_stale;
                14'h003C: bar_rd_data = cnt_rx_good;
                14'h0040: bar_rd_data = cnt_rx_bad;
                14'h0044: bar_rd_data = cnt_rx_ovf;
                // 25G wire observation.  If obs_tx_pkt stays at zero after
                // a job, the frame never reached the PHY: look at the mux
                // and the UDP layer, not at the link.
                14'h0048: bar_rd_data = obs_tx_pkt;
                14'h004C: bar_rd_data = obs_rx_pkt;
                // bit0 rx_block_lock, bit1 rx_high_ber
                14'h0050: bar_rd_data = obs_status;
                // Responder header diagnostics (0x54..0x60)
                14'h0054: bar_rd_data = dbg_len;
                14'h0058: bar_rd_data = dbg_remain;
                14'h005C: bar_rd_data = {31'd0, dbg_hdr_ok};
                14'h0060: bar_rd_data = dbg_requests;
                // hdr[0..2] verbatim: 64-bit each, low dword first
                14'h0064: bar_rd_data = dbg_hdr0[31:0];
                14'h0068: bar_rd_data = dbg_hdr0[63:32];
                14'h006C: bar_rd_data = dbg_hdr1[31:0];
                14'h0070: bar_rd_data = dbg_hdr1[63:32];
                14'h0074: bar_rd_data = dbg_hdr2[31:0];
                14'h0078: bar_rd_data = dbg_hdr2[63:32];
                // Shim framing counters (0x7C..0x8C)
                14'h007C: bar_rd_data = dbg_frames;
                14'h0080: bar_rd_data = dbg_bad;
                14'h0084: bar_rd_data = dbg_first;
                14'h0088: bar_rd_data = dbg_magic;
                14'h008C: bar_rd_data = dbg_start;
                14'h00F0: bar_rd_data = {24'd0, bus_override_reg};
                14'h00F4: bar_rd_data = dbg_gate0;
                14'h00F8: bar_rd_data = dbg_gate1;
                // Initiator header rejection snapshot (0x90..0xA4)
                14'h0090: bar_rd_data = init_bad;
                14'h0094: bar_rd_data = init_tmo;
                14'h0098: bar_rd_data = rx_magic;
                14'h009C: bar_rd_data = rx_type;
                14'h00A0: bar_rd_data = rx_rid;
                14'h00A4: bar_rd_data = rx_len;
                // Record-loop position and payload accounting (0xA8..0xB4)
                14'h00A8: bar_rd_data = {29'd0, rec_state};
                14'h00AC: bar_rd_data = {26'd0, buf_n};
                14'h00B0: bar_rd_data = rec_len;
                14'h00B4: bar_rd_data = {29'd0, tmo_state};
                // Buffered payload words (0xB8..0xC4)
                14'h00B8: bar_rd_data = buf_w0_lo;
                14'h00BC: bar_rd_data = buf_w0_hi;
                14'h00C0: bar_rd_data = buf_w1_lo;
                14'h00C4: bar_rd_data = buf_w1_hi;
                // Write engine address snapshot (0xC8..0xD4)
                14'h00C8: bar_rd_data = mwr_addr_lo;
                14'h00CC: bar_rd_data = mwr_addr_hi;
                14'h00D0: bar_rd_data = mwr_cfg_lo;
                14'h00D4: bar_rd_data = mwr_cfg_hi;
                // Frame reception state (0xD8..0xDC)
                14'h00D8: bar_rd_data = {31'd0, in_frame};
                14'h00DC: bar_rd_data = {24'd0, beats_in_frame};
                // Words accepted by the TLP bridge vs frames carrying last
                14'h00E0: bar_rd_data = rx_words;
                14'h00E4: bar_rd_data = rx_frames_cnt;
                default:  bar_rd_data = 32'd0;
            endcase
        end
    end

endmodule

`default_nettype wire
