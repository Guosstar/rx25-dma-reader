// AS02MC04 line-rate UDP transport.
// Taxi owns the board MAC/GTY; Corundum owns Ethernet/ARP/IPv4/UDP parsing.
// This file contains only the asmcehnk payload and last-peer adaptation.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module asmcehnk_eth_axis_udp_25g #(
    parameter logic [47:0] PARAM_LOCAL_MAC = 48'h02_00_00_00_00_de,
    parameter logic [31:0] PARAM_LOCAL_IP  = 32'hc0a800de,
    parameter logic [15:0] PARAM_UDP_PORT  = 16'h6f3a,
    parameter bit PARAM_RX25_BATCH_DIAG = 1'b0,
    parameter bit PARAM_RX25_REMOTE_CONTROL = 1'b0,
    parameter bit PARAM_RX25_RESPONDER = 1'b0
)(
    input  wire logic   clk,
    input  wire logic   rst,

    taxi_axis_if.snk    s_axis_rx,
    taxi_axis_if.src    m_axis_tx,

    output wire [63:0]  com_rx_data,
    output wire         com_rx_valid,
    input  wire [255:0] com_tx_data,
    input  wire         com_tx_valid,
    output wire         com_tx_ready,
    // Net-clock command/status only. No asynchronous register sampling here.
    input  wire         diag_arm_valid,
    input  wire         diag_capture_valid,
    input  wire [31:0]  diag_command_nonce,
    output wire         diag_arm_accepted,
    output wire         diag_command_rejected,
    output wire         diag_snapshot_valid,
    output wire [511:0] diag_registers,
    output wire [511:0] diag_peer_registers,
    output wire        diag_peer_fault
);

    // Ethernet frame splitter output.
    wire        rx_eth_hdr_valid;
    wire        rx_eth_hdr_ready;
    wire [47:0] rx_eth_dest_mac;
    wire [47:0] rx_eth_src_mac;
    wire [15:0] rx_eth_type;
    wire [63:0] rx_eth_payload_tdata;
    wire [7:0]  rx_eth_payload_tkeep;
    wire        rx_eth_payload_tvalid;
    wire        rx_eth_payload_tready;
    wire        rx_eth_payload_tlast;
    wire        rx_eth_payload_tuser;

    // Ethernet frame merger input.
    wire        tx_eth_hdr_valid;
    wire        tx_eth_hdr_ready;
    wire [47:0] tx_eth_dest_mac;
    wire [47:0] tx_eth_src_mac;
    wire [15:0] tx_eth_type;
    wire [63:0] tx_eth_payload_tdata;
    wire [7:0]  tx_eth_payload_tkeep;
    wire        tx_eth_payload_tvalid;
    wire        tx_eth_payload_tready;
    wire        tx_eth_payload_tlast;
    wire        tx_eth_payload_tuser;

    // Raw Ethernet boundary. The default personality is an exact direct wire;
    // remote diagnostics insert native frame demux/arbiter only when enabled.
    wire ingress_hdr_valid,ingress_hdr_ready,ingress_valid,ingress_ready,ingress_last,ingress_user;
    wire [47:0] ingress_dest,ingress_src;
    wire [15:0] ingress_type;
    wire [63:0] ingress_data;
    wire [7:0] ingress_keep;
    wire egress_hdr_valid,egress_hdr_ready,egress_valid,egress_ready,egress_last,egress_user;
    wire [47:0] egress_dest,egress_src;
    wire [15:0] egress_type;
    wire [63:0] egress_data;
    wire [7:0] egress_keep;

    // Corundum UDP receive interface.
    wire        rx_udp_hdr_valid;
    wire        rx_udp_hdr_ready;
    wire [31:0] rx_udp_ip_source_ip;
    wire [31:0] rx_udp_ip_dest_ip;
    wire [2:0]  rx_udp_ip_flags;
    wire [12:0] rx_udp_ip_fragment_offset;
    wire [15:0] rx_udp_source_port;
    wire [15:0] rx_udp_dest_port;
    wire [15:0] rx_udp_length;
    wire [63:0] rx_udp_payload_tdata;
    wire [7:0]  rx_udp_payload_tkeep;
    wire        rx_udp_payload_tvalid;
    wire        rx_udp_payload_tready;
    wire        rx_udp_payload_tlast;
    wire        rx_udp_payload_tuser;

    // Corundum UDP transmit interface.
    wire        tx_udp_hdr_valid;
    wire        tx_udp_hdr_ready;
    wire [15:0] tx_udp_length;
    wire [63:0] tx_udp_payload_tdata;
    wire [7:0]  tx_udp_payload_tkeep;
    wire        tx_udp_payload_tvalid;
    wire        tx_udp_payload_tready;
    wire        tx_udp_payload_tlast;

    // Last legal peer and current RX frame classification.
    logic [31:0] peer_ip_reg = 32'd0;
    logic [15:0] peer_port_reg = 16'd0;
    logic        peer_valid_reg = 1'b0;
    logic        rx_payload_active_reg = 1'b0;
    logic        rx_payload_accept_reg = 1'b0;

    wire rx_hdr_match;
    wire rx_hdr_fire;
    wire rx_payload_fire;

    assign rx_hdr_match = (rx_udp_ip_dest_ip == PARAM_LOCAL_IP) &&
                          (rx_udp_dest_port == PARAM_UDP_PORT) &&
                          (rx_udp_length >= 16'd16) &&
                          (rx_udp_length[2:0] == 3'd0) &&
                          (rx_udp_ip_fragment_offset == 13'd0) &&
                          !rx_udp_ip_flags[0];
    assign rx_udp_hdr_ready = !rx_payload_active_reg;
    assign rx_udp_payload_tready = 1'b1;
    assign rx_hdr_fire = rx_udp_hdr_valid && rx_udp_hdr_ready;
    assign rx_payload_fire = rx_udp_payload_tvalid && rx_udp_payload_tready;

    // LeechCore RawUDP sends each 64-bit command in NeTV2 byte order. Ethernet
    // AXIS lane 0 is the first wire byte, while asmcehnk expects that byte at
    // bit 63 and the trailing 0x77 magic at bit 7:0.
    assign com_rx_data = {
        rx_udp_payload_tdata[7:0],
        rx_udp_payload_tdata[15:8],
        rx_udp_payload_tdata[23:16],
        rx_udp_payload_tdata[31:24],
        rx_udp_payload_tdata[39:32],
        rx_udp_payload_tdata[47:40],
        rx_udp_payload_tdata[55:48],
        rx_udp_payload_tdata[63:56]
    };
    assign com_rx_valid = rx_payload_active_reg && rx_payload_accept_reg &&
                          rx_udp_payload_tvalid && (rx_udp_payload_tkeep == 8'hff) &&
                          !rx_udp_payload_tuser;

    always_ff @(posedge clk) begin
        if (rst) begin
            peer_ip_reg <= 32'd0;
            peer_port_reg <= 16'd0;
            peer_valid_reg <= 1'b0;
            rx_payload_active_reg <= 1'b0;
            rx_payload_accept_reg <= 1'b0;
        end else begin
            if (rx_hdr_fire) begin
                rx_payload_active_reg <= 1'b1;
                rx_payload_accept_reg <= rx_hdr_match;

                if (rx_hdr_match) begin
                    peer_ip_reg <= rx_udp_ip_source_ip;
                    peer_port_reg <= rx_udp_source_port;
                    peer_valid_reg <= 1'b1;
                end
            end

            if (rx_payload_fire && rx_udp_payload_tlast) begin
                rx_payload_active_reg <= 1'b0;
                rx_payload_accept_reg <= 1'b0;
            end
        end
    end

    // Packetize the native 256-bit mux output before the generic width/frame
    // FIFO.  A descriptor FIFO keeps the variable UDP length aligned with each
    // committed payload frame.
    wire [255:0] leechcore_tx_data;
    wire [255:0] packet_axis_tdata;
    wire [31:0]  packet_axis_tkeep;
    wire         packet_axis_tvalid;
    wire         packet_axis_tready;
    wire         packet_axis_tlast;
    wire [15:0]  packet_desc_length;
    wire         packet_desc_valid;
    wire         packet_desc_ready;
    wire         packetizer_data_ready;

    // Bootstrap path.  peer_valid_reg only rises after a legal packet arrives,
    // and com_tx_ready used to be gated on it -- so both ends sat waiting for a
    // first packet neither could send.  In the original PCILeech flow the host
    // broke the tie by sending UDP; the RX25 host never does, it talks over
    // BAR0, so the deadlock was permanent.
    //
    // Fall back to our own address while the peer is unknown.  The link is
    // point-to-point and both cards deliberately share one MAC/IP (see the
    // rx_hdr_match bootstrap), so the ARP request goes out on broadcast, the
    // far end answers, and that reply sets peer_valid_reg.  From then on the
    // learned address is used and behaviour is unchanged.
    wire [31:0] tx_dest_ip   = peer_valid_reg ? peer_ip_reg   : PARAM_LOCAL_IP;
    wire [15:0] tx_dest_port = peer_valid_reg ? peer_port_reg : PARAM_UDP_PORT;

    assign com_tx_ready = packetizer_data_ready;

    // AMDUSB4 emits status in bits 255:224 followed by data0..data6. The old
    // 256->32 FIFO read the most-significant DWORD first and NeTV2 serialized
    // every DWORD most-significant byte first. Full byte reversal recreates
    // that RawUDP wire stream before the generic AXIS width adapter.
    assign leechcore_tx_data = {
        com_tx_data[7:0],
        com_tx_data[15:8],
        com_tx_data[23:16],
        com_tx_data[31:24],
        com_tx_data[39:32],
        com_tx_data[47:40],
        com_tx_data[55:48],
        com_tx_data[63:56],
        com_tx_data[71:64],
        com_tx_data[79:72],
        com_tx_data[87:80],
        com_tx_data[95:88],
        com_tx_data[103:96],
        com_tx_data[111:104],
        com_tx_data[119:112],
        com_tx_data[127:120],
        com_tx_data[135:128],
        com_tx_data[143:136],
        com_tx_data[151:144],
        com_tx_data[159:152],
        com_tx_data[167:160],
        com_tx_data[175:168],
        com_tx_data[183:176],
        com_tx_data[191:184],
        com_tx_data[199:192],
        com_tx_data[207:200],
        com_tx_data[215:208],
        com_tx_data[223:216],
        com_tx_data[231:224],
        com_tx_data[239:232],
        com_tx_data[247:240],
        com_tx_data[255:248]
    };

    // Payload size is the throughput lever, not a cosmetic setting.  Measured on
    // image 0xA5021008 (2026-11-01): the PCIe side finishes a 4 KB read in
    // ~1.7 us (~2.4 GB/s equivalent, see hw/ila_analyze.py), yet end-to-end only
    // reaches ~170 MB/s because a 4 KB read turns into ~7 UDP datagrams of
    // 1024 B, and the host tops out around 280k datagrams/s.
    //
    //   25G line rate = 2.45 GB/s payload -> 2.3M datagrams/s at 1 KB (8x too many)
    //                                    ->  300k datagrams/s at 8 KB (feasible)
    //
    // So raise the frame to 256 x 256 bit = 8192 B.  The MAC already allows it:
    // fpga_core.sv drives cfg_tx_max_pkt_len = 9217.  The UDP checksum payload
    // FIFO must grow with it (it is 8 bit wide, so depth == bytes).
    // C_IDLE_CYCLES: 16 cycles (40 ns) closes a frame on the first gap, which
    // would cap every frame at the ~4.3 KB a single MRd produces; 4096 cycles
    // (10 us) lets consecutive completions coalesce into full 8 KB frames.
    //
    // Lowered to 1024 (2.54 us at 402.832 MHz) for latency.  This timeout is
    // paid on EVERY frame whose tail is not already full, and it sits directly
    // in the per-chunk round trip: measured floor with window=1 is ~27 us, of
    // which 10.2 us was this timeout.  Throughput scales as window / RTT, and
    // the host now caps the in-flight window at 12, so latency *is* the
    // throughput lever: 12 / 50 us = 1.0 GB/s, 12 / 40 us = 1.2 GB/s.
    // 1024 still leaves 2.5 us for consecutive completions to coalesce.
    //
    // p16 measured: RTT floor 27.2 -> 19.3 us, throughput at window 12
    // 990 -> 1190 MB/s.  Now 256 (0.636 us).  The measured floor is now
    // ~19.3 us and this timeout is still 2.54 us of it, so cutting it to 0.64
    // should take the floor to ~17.4 us; at a fixed window of 12 that is
    // 12/19.3us -> 12/17.4us, roughly +11% throughput and -10% latency.
    // Going lower than 256 is pointless: the NIC/driver alone costs more.
    asmcehnk_udp_tx_packetizer_256 #(
        .C_MAX_WORDS  (PARAM_RX25_BATCH_DIAG ? 1 : 256),
        .C_IDLE_CYCLES(1024)
    ) tx_packetizer_inst (
        .i_clk         (clk),
        .i_rstn        (!rst),
        .i_data        (leechcore_tx_data),
        .i_data_valid  (com_tx_valid),
        .o_data_ready  (packetizer_data_ready),
        .o_axis_tdata  (packet_axis_tdata),
        .o_axis_tkeep  (packet_axis_tkeep),
        .o_axis_tvalid (packet_axis_tvalid),
        .i_axis_tready (packet_axis_tready),
        .o_axis_tlast  (packet_axis_tlast),
        .o_desc_length (packet_desc_length),
        .o_desc_valid  (packet_desc_valid),
        .i_desc_ready  (packet_desc_ready)
    );

    wire [63:0] payload_fifo_tdata;
    wire [7:0]  payload_fifo_tkeep;
    wire        payload_fifo_tvalid;
    wire        payload_fifo_tready;
    wire        payload_fifo_tlast;

    axis_fifo_adapter #(
        .DEPTH              (16384),
        .S_DATA_WIDTH       (256),
        .S_KEEP_ENABLE      (1),
        .S_KEEP_WIDTH       (32),
        .M_DATA_WIDTH       (64),
        .M_KEEP_ENABLE      (1),
        .M_KEEP_WIDTH       (8),
        .ID_ENABLE          (0),
        .DEST_ENABLE        (0),
        .USER_ENABLE        (0),
        .RAM_PIPELINE       (2),
        .OUTPUT_FIFO_ENABLE (1),
        .FRAME_FIFO         (1),
        .DROP_OVERSIZE_FRAME(0),
        .DROP_BAD_FRAME     (0),
        .DROP_WHEN_FULL     (0)
    ) tx_payload_fifo_inst (
        .clk                 (clk),
        .rst                 (rst),
        .s_axis_tdata        (packet_axis_tdata),
        .s_axis_tkeep        (packet_axis_tkeep),
        .s_axis_tvalid       (packet_axis_tvalid),
        .s_axis_tready       (packet_axis_tready),
        .s_axis_tlast        (packet_axis_tlast),
        .s_axis_tid          (8'd0),
        .s_axis_tdest        (8'd0),
        .s_axis_tuser        (1'b0),
        .m_axis_tdata        (payload_fifo_tdata),
        .m_axis_tkeep        (payload_fifo_tkeep),
        .m_axis_tvalid       (payload_fifo_tvalid),
        .m_axis_tready       (payload_fifo_tready),
        .m_axis_tlast        (payload_fifo_tlast),
        .m_axis_tid          (),
        .m_axis_tdest        (),
        .m_axis_tuser        (),
        .pause_req           (1'b0),
        .pause_ack           (),
        .status_depth        (),
        .status_depth_commit (),
        .status_overflow     (),
        .status_bad_frame    (),
        .status_good_frame   ()
    );

    wire [15:0] desc_fifo_tdata;
    wire        desc_fifo_tvalid;
    wire        desc_fifo_tready;

    axis_fifo #(
        .DEPTH              (256),
        .DATA_WIDTH         (16),
        .KEEP_ENABLE        (0),
        .KEEP_WIDTH         (1),
        .LAST_ENABLE        (0),
        .ID_ENABLE          (0),
        .DEST_ENABLE        (0),
        .USER_ENABLE        (0),
        .RAM_PIPELINE       (1),
        .OUTPUT_FIFO_ENABLE (1),
        .FRAME_FIFO         (0)
    ) tx_desc_fifo_inst (
        .clk                 (clk),
        .rst                 (rst),
        .s_axis_tdata        (packet_desc_length),
        .s_axis_tkeep        (1'b1),
        .s_axis_tvalid       (packet_desc_valid),
        .s_axis_tready       (packet_desc_ready),
        .s_axis_tlast        (1'b0),
        .s_axis_tid          (8'd0),
        .s_axis_tdest        (8'd0),
        .s_axis_tuser        (1'b0),
        .m_axis_tdata        (desc_fifo_tdata),
        .m_axis_tkeep        (),
        .m_axis_tvalid       (desc_fifo_tvalid),
        .m_axis_tready       (desc_fifo_tready),
        .m_axis_tlast        (),
        .m_axis_tid          (),
        .m_axis_tdest        (),
        .m_axis_tuser        (),
        .pause_req           (1'b0),
        .pause_ack           (),
        .status_depth        (),
        .status_depth_commit (),
        .status_overflow     (),
        .status_bad_frame    (),
        .status_good_frame   ()
    );

    logic tx_payload_active_reg = 1'b0;
    wire  tx_hdr_fire;
    wire  tx_payload_fire;

    wire ip_rx_busy;
    wire ip_tx_busy;
    wire udp_rx_busy;
    wire udp_tx_busy;
    wire ip_rx_error_header_early_termination;
    wire ip_rx_error_payload_early_termination;
    wire ip_rx_error_invalid_header;
    wire ip_rx_error_invalid_checksum;
    wire ip_tx_error_payload_early_termination;
    wire ip_tx_error_arp_failed;
    wire udp_rx_error_header_early_termination;
    wire udp_rx_error_payload_early_termination;
    wire udp_tx_error_payload_early_termination;

    // Same bootstrap reasoning as com_tx_ready: the header has to be allowed out
    // before the peer is known, otherwise the very packet that would teach us
    // the peer can never leave the chip.
    assign tx_udp_hdr_valid = desc_fifo_tvalid &&
                              payload_fifo_tvalid && !tx_payload_active_reg;
    assign desc_fifo_tready = tx_udp_hdr_ready && tx_udp_hdr_valid;
    assign tx_hdr_fire = tx_udp_hdr_valid && tx_udp_hdr_ready;

    assign tx_udp_length = desc_fifo_tdata;
    assign tx_udp_payload_tdata = payload_fifo_tdata;
    assign tx_udp_payload_tkeep = payload_fifo_tkeep;
    assign tx_udp_payload_tvalid = tx_payload_active_reg && payload_fifo_tvalid;
    assign tx_udp_payload_tlast = payload_fifo_tlast;
    assign payload_fifo_tready = tx_payload_active_reg && tx_udp_payload_tready;
    assign tx_payload_fire = tx_udp_payload_tvalid && tx_udp_payload_tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_payload_active_reg <= 1'b0;
        end else begin
            if (tx_hdr_fire) begin
                tx_payload_active_reg <= 1'b1;
            end
            if (tx_payload_fire && tx_udp_payload_tlast) begin
                tx_payload_active_reg <= 1'b0;
            end
        end
    end

    // Full Ethernet frame ingress/egress around the Corundum protocol stack.
    eth_axis_rx #(
        .DATA_WIDTH (64),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH (8)
    ) eth_axis_rx_inst (
        .clk                           (clk),
        .rst                           (rst),
        .s_axis_tdata                  (s_axis_rx.tdata),
        .s_axis_tkeep                  (s_axis_rx.tkeep),
        .s_axis_tvalid                 (s_axis_rx.tvalid),
        .s_axis_tready                 (s_axis_rx.tready),
        .s_axis_tlast                  (s_axis_rx.tlast),
        .s_axis_tuser                  (s_axis_rx.tuser[0]),
        .m_eth_hdr_valid               (ingress_hdr_valid),
        .m_eth_hdr_ready               (ingress_hdr_ready),
        .m_eth_dest_mac                (ingress_dest),
        .m_eth_src_mac                 (ingress_src),
        .m_eth_type                    (ingress_type),
        .m_eth_payload_axis_tdata      (ingress_data),
        .m_eth_payload_axis_tkeep      (ingress_keep),
        .m_eth_payload_axis_tvalid     (ingress_valid),
        .m_eth_payload_axis_tready     (ingress_ready),
        .m_eth_payload_axis_tlast      (ingress_last),
        .m_eth_payload_axis_tuser      (ingress_user),
        .busy                          (),
        .error_header_early_termination()
    );

    eth_axis_tx #(
        .DATA_WIDTH (64),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH (8)
    ) eth_axis_tx_inst (
        .clk                      (clk),
        .rst                      (rst),
        .s_eth_hdr_valid          (egress_hdr_valid),
        .s_eth_hdr_ready          (egress_hdr_ready),
        .s_eth_dest_mac           (egress_dest),
        .s_eth_src_mac            (egress_src),
        .s_eth_type               (egress_type),
        .s_eth_payload_axis_tdata (egress_data),
        .s_eth_payload_axis_tkeep (egress_keep),
        .s_eth_payload_axis_tvalid(egress_valid),
        .s_eth_payload_axis_tready(egress_ready),
        .s_eth_payload_axis_tlast (egress_last),
        .s_eth_payload_axis_tuser (egress_user),
        .m_axis_tdata             (m_axis_tx.tdata),
        .m_axis_tkeep             (m_axis_tx.tkeep),
        .m_axis_tvalid            (m_axis_tx.tvalid),
        .m_axis_tready            (m_axis_tx.tready),
        .m_axis_tlast             (m_axis_tx.tlast),
        .m_axis_tuser             (m_axis_tx.tuser),
        .busy                     ()
    );

    assign m_axis_tx.tstrb = m_axis_tx.tkeep;
    assign m_axis_tx.tid = '0;
    assign m_axis_tx.tdest = '0;

    wire rx25_diag_pause, rx25_diag_idle;
    wire [9:0] rx25_diag_events;
    wire pressure_arm,pressure_capture,pressure_ack,pressure_reject,pressure_snapshot;
    wire [31:0] pressure_nonce;
    generate
    if(PARAM_RX25_REMOTE_CONTROL) begin : g_remote_control
        if(!PARAM_RX25_BATCH_DIAG) begin : g_invalid_personality
            AS02_REMOTE_DIAGNOSTIC_REQUIRES_BATCH u_invalid_personality();
        end
        wire chv,chr,cv,cr,cl,cu,thv,thr,tv,tr,tl,tu;
        wire [47:0] cdest,csrc,tdest,tsrc;
        wire [15:0] ctype,ttype;
        wire [63:0] cdata,tdata;
        wire [7:0] ckeep,tkeep;
        wire msg_rx_valid,msg_rx_ready,msg_tx_valid,msg_tx_ready;
        wire [7:0] msg_rx_op,msg_tx_op;
        wire [31:0] msg_rx_nonce,msg_rx_status,msg_tx_nonce,msg_tx_status;
        wire [511:0] msg_rx_bank,msg_tx_bank;
        eth_demux #(.M_COUNT(2),.DATA_WIDTH(64),.KEEP_WIDTH(8)) control_demux(
            .clk(clk),.rst(rst),.enable(1'b1),.drop(1'b0),.select(ingress_type==16'h88b5),
            .s_eth_hdr_valid(ingress_hdr_valid),.s_eth_hdr_ready(ingress_hdr_ready),
            .s_eth_dest_mac(ingress_dest),.s_eth_src_mac(ingress_src),.s_eth_type(ingress_type),
            .s_eth_payload_axis_tdata(ingress_data),.s_eth_payload_axis_tkeep(ingress_keep),
            .s_eth_payload_axis_tvalid(ingress_valid),.s_eth_payload_axis_tready(ingress_ready),
            .s_eth_payload_axis_tlast(ingress_last),.s_eth_payload_axis_tuser(ingress_user),
            .s_eth_payload_axis_tid(8'd0),.s_eth_payload_axis_tdest(8'd0),
            .m_eth_hdr_valid({chv,rx_eth_hdr_valid}),.m_eth_hdr_ready({chr,rx_eth_hdr_ready}),
            .m_eth_dest_mac({cdest,rx_eth_dest_mac}),.m_eth_src_mac({csrc,rx_eth_src_mac}),.m_eth_type({ctype,rx_eth_type}),
            .m_eth_payload_axis_tdata({cdata,rx_eth_payload_tdata}),.m_eth_payload_axis_tkeep({ckeep,rx_eth_payload_tkeep}),
            .m_eth_payload_axis_tvalid({cv,rx_eth_payload_tvalid}),.m_eth_payload_axis_tready({cr,rx_eth_payload_tready}),
            .m_eth_payload_axis_tlast({cl,rx_eth_payload_tlast}),.m_eth_payload_axis_tuser({cu,rx_eth_payload_tuser}));
        eth_arb_mux #(.S_COUNT(2),.DATA_WIDTH(64),.KEEP_WIDTH(8),.ARB_TYPE_ROUND_ROBIN(1)) control_mux(
            .clk(clk),.rst(rst),
            .s_eth_hdr_valid({thv,tx_eth_hdr_valid}),.s_eth_hdr_ready({thr,tx_eth_hdr_ready}),
            .s_eth_dest_mac({tdest,tx_eth_dest_mac}),.s_eth_src_mac({tsrc,tx_eth_src_mac}),.s_eth_type({ttype,tx_eth_type}),
            .s_eth_payload_axis_tdata({tdata,tx_eth_payload_tdata}),.s_eth_payload_axis_tkeep({tkeep,tx_eth_payload_tkeep}),
            .s_eth_payload_axis_tvalid({tv,tx_eth_payload_tvalid}),.s_eth_payload_axis_tready({tr,tx_eth_payload_tready}),
            .s_eth_payload_axis_tlast({tl,tx_eth_payload_tlast}),.s_eth_payload_axis_tuser({tu,tx_eth_payload_tuser}),
            .s_eth_payload_axis_tid(16'd0),.s_eth_payload_axis_tdest(16'd0),
            .m_eth_hdr_valid(egress_hdr_valid),.m_eth_hdr_ready(egress_hdr_ready),
            .m_eth_dest_mac(egress_dest),.m_eth_src_mac(egress_src),.m_eth_type(egress_type),
            .m_eth_payload_axis_tdata(egress_data),.m_eth_payload_axis_tkeep(egress_keep),
            .m_eth_payload_axis_tvalid(egress_valid),.m_eth_payload_axis_tready(egress_ready),
            .m_eth_payload_axis_tlast(egress_last),.m_eth_payload_axis_tuser(egress_user));
        asmcehnk_rx25_diag_link #(.C_RESPONDER(PARAM_RX25_RESPONDER),.C_MAC(PARAM_LOCAL_MAC)) codec(
            .clk(clk),.rst(rst),.s_hdr_valid(chv),.s_hdr_ready(chr),.s_dest_mac(cdest),.s_src_mac(csrc),.s_type(ctype),
            .s_data(cdata),.s_keep(ckeep),.s_valid(cv),.s_ready(cr),.s_last(cl),.s_user(cu),
            .rx_valid(msg_rx_valid),.rx_ready(msg_rx_ready),.rx_opcode(msg_rx_op),.rx_nonce(msg_rx_nonce),.rx_status(msg_rx_status),.rx_bank(msg_rx_bank),
            .tx_valid(msg_tx_valid),.tx_ready(msg_tx_ready),.tx_opcode(msg_tx_op),.tx_nonce(msg_tx_nonce),.tx_status(msg_tx_status),.tx_bank(msg_tx_bank),
            .m_hdr_valid(thv),.m_hdr_ready(thr),.m_dest_mac(tdest),.m_src_mac(tsrc),.m_type(ttype),
            .m_data(tdata),.m_keep(tkeep),.m_valid(tv),.m_ready(tr),.m_last(tl),.m_user(tu));
        asmcehnk_rx25_peer_control #(.C_RESPONDER(PARAM_RX25_RESPONDER)) controller(
            .clk(clk),.rst(rst),.arm_valid(diag_arm_valid),.capture_valid(diag_capture_valid),.command_nonce(diag_command_nonce),
            .arm_accepted(diag_arm_accepted),.command_rejected(diag_command_rejected),.snapshot_valid(diag_snapshot_valid),
            .peer_registers(diag_peer_registers),.fault(diag_peer_fault),
            .local_arm_valid(pressure_arm),.local_capture_valid(pressure_capture),.local_nonce(pressure_nonce),
            .local_arm_accepted(pressure_ack),.local_rejected(pressure_reject),.local_snapshot_valid(pressure_snapshot),.local_registers(diag_registers),
            .tx_valid(msg_tx_valid),.tx_ready(msg_tx_ready),.tx_opcode(msg_tx_op),.tx_nonce(msg_tx_nonce),.tx_status(msg_tx_status),.tx_bank(msg_tx_bank),
            .rx_valid(msg_rx_valid),.rx_ready(msg_rx_ready),.rx_opcode(msg_rx_op),.rx_nonce(msg_rx_nonce),.rx_status(msg_rx_status),.rx_bank(msg_rx_bank));
    end else begin : g_no_remote_control
        assign {rx_eth_hdr_valid,rx_eth_dest_mac,rx_eth_src_mac,rx_eth_type}={ingress_hdr_valid,ingress_dest,ingress_src,ingress_type};
        assign ingress_hdr_ready=rx_eth_hdr_ready;
        assign {rx_eth_payload_tdata,rx_eth_payload_tkeep,rx_eth_payload_tvalid,rx_eth_payload_tlast,rx_eth_payload_tuser}=
            {ingress_data,ingress_keep,ingress_valid,ingress_last,ingress_user};
        assign ingress_ready=rx_eth_payload_tready;
        assign {egress_hdr_valid,egress_dest,egress_src,egress_type}={tx_eth_hdr_valid,tx_eth_dest_mac,tx_eth_src_mac,tx_eth_type};
        assign tx_eth_hdr_ready=egress_hdr_ready;
        assign {egress_data,egress_keep,egress_valid,egress_last,egress_user}=
            {tx_eth_payload_tdata,tx_eth_payload_tkeep,tx_eth_payload_tvalid,tx_eth_payload_tlast,tx_eth_payload_tuser};
        assign tx_eth_payload_tready=egress_ready;
        assign pressure_arm=diag_arm_valid;assign pressure_capture=diag_capture_valid;assign pressure_nonce=diag_command_nonce;
        assign diag_arm_accepted=pressure_ack;assign diag_command_rejected=pressure_reject;assign diag_snapshot_valid=pressure_snapshot;
        assign diag_peer_registers=0;assign diag_peer_fault=0;
    end
    if (PARAM_RX25_BATCH_DIAG) begin : g_batch_pressure
        asmcehnk_rx25_udp_pressure pressure_inst (
            .clk(clk), .rst(rst), .arm_valid(pressure_arm),
            .capture_valid(pressure_capture), .command_nonce(pressure_nonce),
            .path_idle(rx25_diag_idle), .events(rx25_diag_events),
            .pause_output(rx25_diag_pause), .arm_accepted(pressure_ack),
            .command_rejected(pressure_reject), .snapshot_valid(pressure_snapshot),
            .registers(diag_registers)
        );
    end else begin : g_no_batch_pressure
        assign rx25_diag_pause = 1'b0;
        assign pressure_ack = 1'b0;
        assign pressure_reject = 1'b0;
        assign pressure_snapshot = 1'b0;
        assign diag_registers = 512'd0;
    end
    endgenerate

    udp_complete_64 #(
        .RX25_DIAG_ENABLE                 (PARAM_RX25_BATCH_DIAG),
        .ARP_CACHE_ADDR_WIDTH             (9),
        .ARP_REQUEST_RETRY_COUNT          (4),
        .ARP_REQUEST_RETRY_INTERVAL       (781250000),
        .ARP_REQUEST_TIMEOUT              (1953125000),
        .UDP_CHECKSUM_GEN_ENABLE          (1),
        // 8-bit wide inside udp_checksum_gen, so depth is in bytes: it must hold
        // one whole payload.  2048 was sized for the old 1024 B frames and would
        // silently overflow at 8 KB.
        .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH  (8192),
        .UDP_CHECKSUM_HEADER_FIFO_DEPTH   (8)
    ) udp_complete_inst (
        .clk                                      (clk),
        .rst                                      (rst),
        .rx25_diag_pause                          (rx25_diag_pause),
        .rx25_diag_idle                           (rx25_diag_idle),
        .rx25_diag_events                         (rx25_diag_events),
        .s_eth_hdr_valid                          (rx_eth_hdr_valid),
        .s_eth_hdr_ready                          (rx_eth_hdr_ready),
        .s_eth_dest_mac                           (rx_eth_dest_mac),
        .s_eth_src_mac                            (rx_eth_src_mac),
        .s_eth_type                               (rx_eth_type),
        .s_eth_payload_axis_tdata                 (rx_eth_payload_tdata),
        .s_eth_payload_axis_tkeep                 (rx_eth_payload_tkeep),
        .s_eth_payload_axis_tvalid                (rx_eth_payload_tvalid),
        .s_eth_payload_axis_tready                (rx_eth_payload_tready),
        .s_eth_payload_axis_tlast                 (rx_eth_payload_tlast),
        .s_eth_payload_axis_tuser                 (rx_eth_payload_tuser),
        .m_eth_hdr_valid                          (tx_eth_hdr_valid),
        .m_eth_hdr_ready                          (tx_eth_hdr_ready),
        .m_eth_dest_mac                           (tx_eth_dest_mac),
        .m_eth_src_mac                            (tx_eth_src_mac),
        .m_eth_type                               (tx_eth_type),
        .m_eth_payload_axis_tdata                 (tx_eth_payload_tdata),
        .m_eth_payload_axis_tkeep                 (tx_eth_payload_tkeep),
        .m_eth_payload_axis_tvalid                (tx_eth_payload_tvalid),
        .m_eth_payload_axis_tready                (tx_eth_payload_tready),
        .m_eth_payload_axis_tlast                 (tx_eth_payload_tlast),
        .m_eth_payload_axis_tuser                 (tx_eth_payload_tuser),
        .s_ip_hdr_valid                           (1'b0),
        .s_ip_hdr_ready                           (),
        .s_ip_dscp                                (6'd0),
        .s_ip_ecn                                 (2'd0),
        .s_ip_length                              (16'd0),
        .s_ip_ttl                                 (8'd0),
        .s_ip_protocol                            (8'd0),
        .s_ip_source_ip                           (32'd0),
        .s_ip_dest_ip                             (32'd0),
        .s_ip_payload_axis_tdata                  (64'd0),
        .s_ip_payload_axis_tkeep                  (8'd0),
        .s_ip_payload_axis_tvalid                 (1'b0),
        .s_ip_payload_axis_tready                 (),
        .s_ip_payload_axis_tlast                  (1'b0),
        .s_ip_payload_axis_tuser                  (1'b0),
        .m_ip_hdr_valid                           (),
        .m_ip_hdr_ready                           (1'b1),
        .m_ip_eth_dest_mac                        (),
        .m_ip_eth_src_mac                         (),
        .m_ip_eth_type                            (),
        .m_ip_version                             (),
        .m_ip_ihl                                 (),
        .m_ip_dscp                                (),
        .m_ip_ecn                                 (),
        .m_ip_length                              (),
        .m_ip_identification                      (),
        .m_ip_flags                               (),
        .m_ip_fragment_offset                     (),
        .m_ip_ttl                                 (),
        .m_ip_protocol                            (),
        .m_ip_header_checksum                     (),
        .m_ip_source_ip                           (),
        .m_ip_dest_ip                             (),
        .m_ip_payload_axis_tdata                  (),
        .m_ip_payload_axis_tkeep                  (),
        .m_ip_payload_axis_tvalid                 (),
        .m_ip_payload_axis_tready                 (1'b1),
        .m_ip_payload_axis_tlast                  (),
        .m_ip_payload_axis_tuser                  (),
        .s_udp_hdr_valid                          (tx_udp_hdr_valid),
        .s_udp_hdr_ready                          (tx_udp_hdr_ready),
        .s_udp_ip_dscp                            (6'd0),
        .s_udp_ip_ecn                             (2'd0),
        .s_udp_ip_ttl                             (8'd64),
        .s_udp_ip_source_ip                       (PARAM_LOCAL_IP),
        .s_udp_ip_dest_ip                         (tx_dest_ip),
        .s_udp_source_port                        (PARAM_UDP_PORT),
        .s_udp_dest_port                          (tx_dest_port),
        .s_udp_length                             (tx_udp_length),
        .s_udp_checksum                           (16'd0),
        .s_udp_payload_axis_tdata                 (tx_udp_payload_tdata),
        .s_udp_payload_axis_tkeep                 (tx_udp_payload_tkeep),
        .s_udp_payload_axis_tvalid                (tx_udp_payload_tvalid),
        .s_udp_payload_axis_tready                (tx_udp_payload_tready),
        .s_udp_payload_axis_tlast                 (tx_udp_payload_tlast),
        .s_udp_payload_axis_tuser                 (1'b0),
        .m_udp_hdr_valid                          (rx_udp_hdr_valid),
        .m_udp_hdr_ready                          (rx_udp_hdr_ready),
        .m_udp_eth_dest_mac                       (),
        .m_udp_eth_src_mac                        (),
        .m_udp_eth_type                           (),
        .m_udp_ip_version                         (),
        .m_udp_ip_ihl                             (),
        .m_udp_ip_dscp                            (),
        .m_udp_ip_ecn                             (),
        .m_udp_ip_length                          (),
        .m_udp_ip_identification                  (),
        .m_udp_ip_flags                           (rx_udp_ip_flags),
        .m_udp_ip_fragment_offset                 (rx_udp_ip_fragment_offset),
        .m_udp_ip_ttl                             (),
        .m_udp_ip_protocol                        (),
        .m_udp_ip_header_checksum                 (),
        .m_udp_ip_source_ip                       (rx_udp_ip_source_ip),
        .m_udp_ip_dest_ip                         (rx_udp_ip_dest_ip),
        .m_udp_source_port                        (rx_udp_source_port),
        .m_udp_dest_port                          (rx_udp_dest_port),
        .m_udp_length                             (rx_udp_length),
        .m_udp_checksum                           (),
        .m_udp_payload_axis_tdata                 (rx_udp_payload_tdata),
        .m_udp_payload_axis_tkeep                 (rx_udp_payload_tkeep),
        .m_udp_payload_axis_tvalid                (rx_udp_payload_tvalid),
        .m_udp_payload_axis_tready                (rx_udp_payload_tready),
        .m_udp_payload_axis_tlast                 (rx_udp_payload_tlast),
        .m_udp_payload_axis_tuser                 (rx_udp_payload_tuser),
        .ip_rx_busy                               (ip_rx_busy),
        .ip_tx_busy                               (ip_tx_busy),
        .udp_rx_busy                              (udp_rx_busy),
        .udp_tx_busy                              (udp_tx_busy),
        .ip_rx_error_header_early_termination     (ip_rx_error_header_early_termination),
        .ip_rx_error_payload_early_termination    (ip_rx_error_payload_early_termination),
        .ip_rx_error_invalid_header               (ip_rx_error_invalid_header),
        .ip_rx_error_invalid_checksum             (ip_rx_error_invalid_checksum),
        .ip_tx_error_payload_early_termination    (ip_tx_error_payload_early_termination),
        .ip_tx_error_arp_failed                   (ip_tx_error_arp_failed),
        .udp_rx_error_header_early_termination    (udp_rx_error_header_early_termination),
        .udp_rx_error_payload_early_termination   (udp_rx_error_payload_early_termination),
        .udp_tx_error_payload_early_termination   (udp_tx_error_payload_early_termination),
        .local_mac                                (PARAM_LOCAL_MAC),
        .local_ip                                 (PARAM_LOCAL_IP),
        .gateway_ip                               ({PARAM_LOCAL_IP[31:8], 8'd1}),
        .subnet_mask                              (32'hffffff00),
        .clear_arp_cache                          (1'b0)
    );

`ifdef AS02_HW_DEBUG
    logic [31:0] dbg_cnt_mac_rx_frames = 32'd0;
    logic [31:0] dbg_cnt_udp_headers = 32'd0;
    logic [31:0] dbg_cnt_udp_accept = 32'd0;
    logic [31:0] dbg_cnt_udp_reject = 32'd0;
    logic [31:0] dbg_cnt_udp_rx_words = 32'd0;
    logic [31:0] dbg_cnt_com_tx_words = 32'd0;
    logic [31:0] dbg_cnt_udp_tx_frames = 32'd0;
    logic [31:0] dbg_cnt_errors = 32'd0;
    // TX-side vs RX-side error event counters, packed into one 32-bit word as
    // {tx[15:0], rx[15:0]}. A sticky bitmap was tried first and failed: bit2
    // (invalid header) is already set at boot by ordinary ARP traffic, so later
    // events of other kinds were indistinguishable. Counters can be diffed
    // across a traffic burst, which is what actually answers the question.
    logic [15:0] dbg_tx_err_cnt = 16'd0;
    logic [15:0] dbg_rx_err_cnt = 16'd0;

    wire dbg_udp_error_event;
    wire dbg_udp_partial_event;
    (* mark_debug = "true", keep = "true" *) wire [63:0] dbg_udp_control;
    (* mark_debug = "true", keep = "true" *) wire [127:0] dbg_udp_metadata;
    (* mark_debug = "true", keep = "true" *) wire [63:0] dbg_udp_peer;
    (* mark_debug = "true", keep = "true" *) wire [255:0] dbg_udp_counters;

    assign dbg_udp_error_event = ip_rx_error_header_early_termination |
                                 ip_rx_error_payload_early_termination |
                                 ip_rx_error_invalid_header |
                                 ip_rx_error_invalid_checksum |
                                 ip_tx_error_payload_early_termination |
                                 ip_tx_error_arp_failed |
                                 udp_rx_error_header_early_termination |
                                 udp_rx_error_payload_early_termination |
                                 udp_tx_error_payload_early_termination;
    assign dbg_udp_partial_event = rx_payload_fire &&
                                   ((rx_udp_payload_tkeep != 8'hff) |
                                    rx_udp_payload_tuser);

    always_ff @(posedge clk) begin
        if (rst) begin
            dbg_cnt_mac_rx_frames <= 32'd0;
            dbg_cnt_udp_headers <= 32'd0;
            dbg_cnt_udp_accept <= 32'd0;
            dbg_cnt_udp_reject <= 32'd0;
            dbg_cnt_udp_rx_words <= 32'd0;
            dbg_cnt_com_tx_words <= 32'd0;
            dbg_cnt_udp_tx_frames <= 32'd0;
            dbg_cnt_errors <= 32'd0;
            dbg_tx_err_cnt <= 16'd0;
            dbg_rx_err_cnt <= 16'd0;
        end else begin
            if (ip_tx_error_payload_early_termination |
                ip_tx_error_arp_failed |
                udp_tx_error_payload_early_termination |
                (com_tx_valid && !peer_valid_reg)) begin
                dbg_tx_err_cnt <= dbg_tx_err_cnt + 16'd1;
            end
            if (ip_rx_error_header_early_termination |
                ip_rx_error_payload_early_termination |
                ip_rx_error_invalid_header |
                ip_rx_error_invalid_checksum |
                udp_rx_error_header_early_termination |
                udp_rx_error_payload_early_termination) begin
                dbg_rx_err_cnt <= dbg_rx_err_cnt + 16'd1;
            end
            if (s_axis_rx.tvalid && s_axis_rx.tready && s_axis_rx.tlast) begin
                dbg_cnt_mac_rx_frames <= dbg_cnt_mac_rx_frames + 32'd1;
            end
            if (rx_hdr_fire) begin
                dbg_cnt_udp_headers <= dbg_cnt_udp_headers + 32'd1;
            end
            if (rx_hdr_fire && rx_hdr_match) begin
                dbg_cnt_udp_accept <= dbg_cnt_udp_accept + 32'd1;
            end
            if (rx_hdr_fire && !rx_hdr_match) begin
                dbg_cnt_udp_reject <= dbg_cnt_udp_reject + 32'd1;
            end
            if (com_rx_valid) begin
                dbg_cnt_udp_rx_words <= dbg_cnt_udp_rx_words + 32'd1;
            end
            if (com_tx_valid && com_tx_ready) begin
                dbg_cnt_com_tx_words <= dbg_cnt_com_tx_words + 32'd1;
            end
            if (tx_payload_fire && tx_udp_payload_tlast) begin
                dbg_cnt_udp_tx_frames <= dbg_cnt_udp_tx_frames + 32'd1;
            end
            if (dbg_udp_error_event || dbg_udp_partial_event) begin
                dbg_cnt_errors <= dbg_cnt_errors + 32'd1;
            end
        end
    end

    assign dbg_udp_control[0] = rst;
    assign dbg_udp_control[1] = rx_eth_hdr_valid;
    assign dbg_udp_control[2] = rx_eth_hdr_ready;
    assign dbg_udp_control[3] = rx_udp_hdr_valid;
    assign dbg_udp_control[4] = rx_udp_hdr_ready;
    assign dbg_udp_control[5] = rx_hdr_match;
    assign dbg_udp_control[6] = rx_hdr_fire;
    assign dbg_udp_control[7] = rx_payload_active_reg;
    assign dbg_udp_control[8] = rx_payload_accept_reg;
    assign dbg_udp_control[9] = rx_udp_payload_tvalid;
    assign dbg_udp_control[10] = rx_udp_payload_tready;
    assign dbg_udp_control[11] = rx_udp_payload_tlast;
    assign dbg_udp_control[12] = rx_udp_payload_tuser;
    assign dbg_udp_control[13] = com_rx_valid;
    assign dbg_udp_control[14] = peer_valid_reg;
    assign dbg_udp_control[15] = com_tx_valid;
    assign dbg_udp_control[16] = com_tx_ready;
    assign dbg_udp_control[17] = packet_axis_tvalid;
    assign dbg_udp_control[18] = packet_axis_tready;
    assign dbg_udp_control[19] = packet_axis_tlast;
    assign dbg_udp_control[20] = packet_desc_valid;
    assign dbg_udp_control[21] = packet_desc_ready;
    assign dbg_udp_control[22] = payload_fifo_tvalid;
    assign dbg_udp_control[23] = payload_fifo_tready;
    assign dbg_udp_control[24] = desc_fifo_tvalid;
    assign dbg_udp_control[25] = desc_fifo_tready;
    assign dbg_udp_control[26] = tx_udp_hdr_valid;
    assign dbg_udp_control[27] = tx_udp_hdr_ready;
    assign dbg_udp_control[28] = tx_udp_payload_tvalid;
    assign dbg_udp_control[29] = tx_udp_payload_tready;
    assign dbg_udp_control[30] = tx_udp_payload_tlast;
    assign dbg_udp_control[31] = dbg_udp_error_event;
    assign dbg_udp_control[32] = ip_rx_busy;
    assign dbg_udp_control[33] = ip_tx_busy;
    assign dbg_udp_control[34] = udp_rx_busy;
    assign dbg_udp_control[35] = udp_tx_busy;
    assign dbg_udp_control[36] = ip_rx_error_header_early_termination;
    assign dbg_udp_control[37] = ip_rx_error_payload_early_termination;
    assign dbg_udp_control[38] = ip_rx_error_invalid_header;
    assign dbg_udp_control[39] = ip_rx_error_invalid_checksum;
    assign dbg_udp_control[40] = ip_tx_error_payload_early_termination;
    assign dbg_udp_control[41] = ip_tx_error_arp_failed;
    assign dbg_udp_control[42] = udp_rx_error_header_early_termination;
    assign dbg_udp_control[43] = udp_rx_error_payload_early_termination;
    assign dbg_udp_control[44] = udp_tx_error_payload_early_termination;
    assign dbg_udp_control[45] = tx_payload_active_reg;
    assign dbg_udp_control[46] = rx_hdr_fire && !rx_hdr_match;
    assign dbg_udp_control[47] = dbg_udp_partial_event;
    assign dbg_udp_control[48] = com_tx_valid && !peer_valid_reg;
    assign dbg_udp_control[63:49] = 15'd0;

    assign dbg_udp_metadata = {
        rx_udp_ip_fragment_offset,
        rx_udp_ip_flags,
        rx_udp_length,
        rx_udp_dest_port,
        rx_udp_source_port,
        rx_udp_ip_dest_ip,
        rx_udp_ip_source_ip
    };
    assign dbg_udp_peer = {
        15'd0, peer_valid_reg, peer_port_reg, peer_ip_reg
    };
    assign dbg_udp_counters = {
        dbg_cnt_errors,
        dbg_cnt_udp_tx_frames,
        dbg_cnt_com_tx_words,
        dbg_cnt_udp_rx_words,
        {dbg_tx_err_cnt, dbg_rx_err_cnt},
        dbg_cnt_udp_accept,
        dbg_cnt_udp_headers,
        dbg_cnt_mac_rx_frames
    };

    as02_net_vio as02_net_vio_inst (
        .clk      (clk),
        .probe_in0(dbg_udp_control),
        .probe_in1(dbg_udp_counters),
        .probe_in2(dbg_udp_metadata),
        .probe_in3(dbg_udp_peer)
    );
`endif

endmodule

`resetall
