// AS02 wrapper around unmodified asmcehnk protocol interfaces.

`resetall
`timescale 1ns / 1ps
`default_nettype none

`include "asmcehnk_header.svh"

module asmcehnk_as02_core #(
    parameter logic [47:0] PARAM_LOCAL_MAC = 48'h02_00_00_00_00_de,
    parameter logic [31:0] PARAM_LOCAL_IP  = 32'hc0a800de,
    parameter logic [15:0] PARAM_UDP_PORT  = 16'h6f3a,
    parameter PARAM_DEVICE_ID = 8'd5,
    parameter PARAM_VERSION_NUMBER_MAJOR = 8'd4,
    parameter PARAM_VERSION_NUMBER_MINOR = 8'd13,
    parameter PARAM_CUSTOM_VALUE = 32'hffffffff,
    // 1 = RX25 control-side BAR0 personality.  Set from the build generic
    // PARAM_RX25_MODE; the default keeps the target-side PCILeech identity.
    parameter bit PARAM_RX25_MODE = 1'b0,
    // 1 = this image is the link responder (the far card).  Must match the
    // partner: two initiator images wait for each other and every request times
    // out, which is indistinguishable from a dead link.
    parameter bit PARAM_RX25_RESPONDER = 1'b0,
    parameter bit PARAM_RX25_REAL_MEM = 1'b0,
    parameter logic [63:0] PARAM_RX25_REAL_MEM_TEST_ADDR = 64'd0,
    parameter bit PARAM_RX25_ADDR_MODE = 1'b0,
    parameter bit PARAM_RX25_DIAGNOSTIC_V2 = 1'b0,
    parameter bit PARAM_RX25_BATCH_DIAG = 1'b0,
    parameter RQ_SEQ_NUM_W = 6,
    parameter MAC_DATA_W = 64,
    parameter MAC_RX_USER_W = 49
)(
    input  wire logic                    clk_100mhz,
    input  wire logic                    rst_100mhz,

    // SFP0 is the 25G transport port (AS02_TRANSPORT_SFP_INDEX = 0).  This is
    // the ethernet PHY's parallel-detect result: 1 = valid link.  It used to be
    // left dangling, which is why rx25_link was a constant and the BAR's
    // LINK_PEER bit was meaningless.
    input  wire logic                    sfp0_rx_status,

    // 25G observation, counted in the PHY clock domain and published through
    // the RX25 BAR so the link can be diagnosed without an ILA.
    input  wire logic [31:0]             obs_tx_pkt,
    input  wire logic [31:0]             obs_rx_pkt,
    input  wire logic [31:0]             obs_status,

    input  wire logic                    pcie_clk,
    input  wire logic                    pcie_rst,
    taxi_axis_if.snk                     s_axis_pcie_cq,
    taxi_axis_if.src                     m_axis_pcie_cc,
    taxi_axis_if.src                     m_axis_pcie_rq,
    taxi_axis_if.snk                     s_axis_pcie_rc,

    input  wire logic [RQ_SEQ_NUM_W-1:0] pcie_rq_seq_num0,
    input  wire logic                    pcie_rq_seq_num_vld0,
    input  wire logic [RQ_SEQ_NUM_W-1:0] pcie_rq_seq_num1,
    input  wire logic                    pcie_rq_seq_num_vld1,

    input  wire logic                    pcie_user_lnk_up,
    input  wire logic                    cfg_phy_link_down,
    input  wire logic [1:0]              cfg_phy_link_status,
    input  wire logic [2:0]              cfg_negotiated_width,
    input  wire logic [1:0]              cfg_current_speed,
    input  wire logic [15:0]             cfg_function_status,
    input  wire logic [11:0]             cfg_function_power_state,
    input  wire logic [1:0]              cfg_link_power_state,
    input  wire logic [5:0]              cfg_ltssm_state,
    input  wire logic [1:0]              cfg_rx_pm_state,
    input  wire logic [1:0]              cfg_tx_pm_state,
    input  wire logic [7:0]              cfg_bus_number,

    input  wire logic [1:0]              cfg_max_payload,
    input  wire logic [2:0]              cfg_max_read_req,
    input  wire logic [3:0]              cfg_rcb_status,

    output wire logic [9:0]              cfg_mgmt_addr,
    output wire logic [7:0]              cfg_mgmt_function_number,
    output wire logic                    cfg_mgmt_write,
    output wire logic [31:0]             cfg_mgmt_write_data,
    output wire logic [3:0]              cfg_mgmt_byte_enable,
    output wire logic                    cfg_mgmt_read,
    input  wire logic [31:0]             cfg_mgmt_read_data,
    input  wire logic                    cfg_mgmt_read_write_done,
    output wire logic [63:0]             cfg_dsn,

    input  wire logic [7:0]              cfg_fc_ph,
    input  wire logic [11:0]             cfg_fc_pd,
    input  wire logic [7:0]              cfg_fc_nph,
    input  wire logic [11:0]             cfg_fc_npd,
    input  wire logic [7:0]              cfg_fc_cplh,
    input  wire logic [11:0]             cfg_fc_cpld,
    output wire logic [2:0]              cfg_fc_sel,

    input  wire logic [3:0]              cfg_interrupt_msi_enable,
    input  wire logic [11:0]             cfg_interrupt_msi_mmenable,
    input  wire logic                    cfg_interrupt_msi_mask_update,
    input  wire logic [31:0]             cfg_interrupt_msi_data,
    output wire logic [1:0]              cfg_interrupt_msi_select,
    output wire logic [31:0]             cfg_interrupt_msi_int,
    output wire logic [31:0]             cfg_interrupt_msi_pending_status,
    output wire logic                    cfg_interrupt_msi_pending_status_data_enable,
    output wire logic [1:0]              cfg_interrupt_msi_pending_status_function_num,
    input  wire logic                    cfg_interrupt_msi_sent,
    input  wire logic                    cfg_interrupt_msi_fail,
    output wire logic [2:0]              cfg_interrupt_msi_attr,
    output wire logic                    cfg_interrupt_msi_tph_present,
    output wire logic [1:0]              cfg_interrupt_msi_tph_type,
    output wire logic [7:0]              cfg_interrupt_msi_tph_st_tag,
    output wire logic [7:0]              cfg_interrupt_msi_function_number,

    input  wire logic                    mac_tx_clk[2],
    input  wire logic                    mac_tx_rst[2],
    taxi_axis_if.src                     mac_axis_tx[2],
    taxi_axis_if.snk                     mac_axis_tx_cpl[2],

    input  wire logic                    mac_rx_clk[2],
    input  wire logic                    mac_rx_rst[2],
    taxi_axis_if.snk                     mac_axis_rx[2]
);

    // AS02 board silkscreen / Taxi array mapping:
    //   physical SFP1 -> index 0 -> asmcehnk UDP transport
    //   physical SFP2 -> index 1 -> intentionally idle/safe
    localparam int AS02_TRANSPORT_SFP_INDEX = 32'd0;
    localparam int AS02_IDLE_SFP_INDEX      = 32'd1;

    IfComToFifo    dcom_fifo();
    IfPCIeFifoCfg  dcfg();
    IfPCIeFifoTlp  dtlp();
    IfPCIeFifoCore dpcie();
    IfShadow2Fifo  dshadow2fifo();

    wire [15:0] pcie_id;
    wire [31:0] base_address_register;
    wire        net_clk;
    wire        net_rst;
    wire        net_rst_fifo;
    wire        net_rst_com;
    wire        net_rst_rx;
    wire        net_rst_pcie;
    wire        pcie_rst_net;
    wire        pcie_path_rst;
    wire        pcie_path_rst_pcie;
    wire        tick_100mhz_toggle_sync;
    wire        tick_100mhz_ce;
    wire        rx_cdc_status_overflow;
    wire        rx_cdc_status_bad_frame;
    wire        rx_cdc_status_good_frame;
    wire [11:0] pcie_tlp_rq_flow_status;
    logic       pcie_rst_bridge = 1'b1;
    logic       reg_pcie_path_rst_pcie = 1'b1;
    logic       tick_100mhz_toggle_reg = 1'b0;
    logic       tick_100mhz_toggle_sync_d = 1'b0;

    assign net_clk = mac_tx_clk[AS02_TRANSPORT_SFP_INDEX];

    // sfp0_rx_status is sampled in the 25G PHY's own receive clock, but
    // rx25_link is read on pcie_clk.  Wiring it straight through shows up as a
    // gtwiz_userclk_rx_srcclk_out -> pcie_user_clk crossing at WNS -1.24.  A
    // status bit needs nothing more than two flops.
    wire sfp0_rx_status_sync;
    taxi_sync_signal #(
        .WIDTH(1),
        .N    (2)
    ) sfp0_link_sync_inst (
        .clk (pcie_clk),
        .in  (sfp0_rx_status),
        .out (sfp0_rx_status_sync)
    );

    // The 25G observation counters are clocked by the PHY (clk_125mhz) but read
    // by the BAR on pcie_clk.  Without this the crossing shows up as a -1.67 ns
    // violation.  These are diagnostic counters, so a mid-transition read is
    // acceptable -- the point is to see whether they move at all.
    wire [31:0] obs_tx_pkt_sync;
    wire [31:0] obs_rx_pkt_sync;
    wire [31:0] obs_status_sync;
    taxi_sync_signal #(
        .WIDTH(32),
        .N    (2)
    ) obs_tx_sync_inst (
        .clk (pcie_clk), .in (obs_tx_pkt), .out (obs_tx_pkt_sync)
    );
    taxi_sync_signal #(
        .WIDTH(32),
        .N    (2)
    ) obs_rx_sync_inst (
        .clk (pcie_clk), .in (obs_rx_pkt), .out (obs_rx_pkt_sync)
    );
    taxi_sync_signal #(
        .WIDTH(32),
        .N    (2)
    ) obs_st_sync_inst (
        .clk (pcie_clk), .in (obs_status), .out (obs_status_sync)
    );


    // Keep the AMDUSB4 100 MHz uptime, inactivity-timer, and command pacing
    // semantics while the 64/256-bit transport remains in the 25G MAC domain.
    always_ff @(posedge clk_100mhz) begin
        if (rst_100mhz) begin
            tick_100mhz_toggle_reg <= 1'b0;
        end else begin
            tick_100mhz_toggle_reg <= !tick_100mhz_toggle_reg;
        end
    end

    taxi_sync_signal #(
        .WIDTH(1),
        .N(2)
    ) tick_100mhz_sync_inst (
        .clk (net_clk),
        .in  (tick_100mhz_toggle_reg),
        .out (tick_100mhz_toggle_sync)
    );

    always_ff @(posedge net_clk) begin
        if (net_rst) begin
            tick_100mhz_toggle_sync_d <= 1'b0;
        end else begin
            tick_100mhz_toggle_sync_d <= tick_100mhz_toggle_sync;
        end
    end

    assign tick_100mhz_ce = !net_rst &&
        (tick_100mhz_toggle_sync != tick_100mhz_toggle_sync_d);

    // A dedicated bridge register isolates the PCIe IP's internal user_reset
    // fan-out before the reset crosses into the SFP1 TX domain.  Only resets
    // from the same domain are merged; the UDP/asmcehnk datapath stays in the
    // SFP1 TX domain throughout.
    always_ff @(posedge pcie_clk or posedge pcie_rst) begin
        if (pcie_rst) begin
            pcie_rst_bridge <= 1'b1;
        end else begin
            pcie_rst_bridge <= 1'b0;
        end
    end

    // pcie_rst_bridge lives in the PCIe user clock; sample it as a level in
    // the network domain.  Driving the preset pin from a foreign clock is what
    // report_cdc flags as CDC-10 Critical on this path.
    taxi_sync_reset #(
        .N(4),
        .C_ASYNC_ASSERT(1'b0)
    ) pcie_reset_to_net_sync_inst (
        .clk (net_clk),
        .rst (pcie_rst_bridge),
        .out (pcie_rst_net)
    );

    // net_rst feeds three large blocks. A single synchronizer drove ~700 loads
    // and its net dominated the 402.8 MHz reset paths, so each block gets its
    // own copy. Same clock, same async input, same depth => identical value at
    // every cycle; this is fanout splitting only, not a behaviour change.
    // DONT_TOUCH stops synthesis from merging the equivalent registers back.
    (* DONT_TOUCH = "TRUE" *) taxi_sync_reset #(
        .N(4)
    ) net_reset_sync_inst (
        .clk (net_clk),
        .rst (mac_tx_rst[AS02_TRANSPORT_SFP_INDEX]),
        .out (net_rst)
    );

    (* DONT_TOUCH = "TRUE" *) taxi_sync_reset #(
        .N(4)
    ) net_reset_sync_fifo_inst (
        .clk (net_clk),
        .rst (mac_tx_rst[AS02_TRANSPORT_SFP_INDEX]),
        .out (net_rst_fifo)
    );

    (* DONT_TOUCH = "TRUE" *) taxi_sync_reset #(
        .N(4)
    ) net_reset_sync_com_inst (
        .clk (net_clk),
        .rst (mac_tx_rst[AS02_TRANSPORT_SFP_INDEX]),
        .out (net_rst_com)
    );

    (* DONT_TOUCH = "TRUE" *) taxi_sync_reset #(
        .N(4)
    ) net_reset_sync_rx_inst (
        .clk (net_clk),
        .rst (mac_tx_rst[AS02_TRANSPORT_SFP_INDEX]),
        .out (net_rst_rx)
    );

    // Mirror a network-domain reset into the PCIe soft path so every CDC FIFO
    // is flushed when SFP1 transport restarts.  net_rst is a network-domain
    // level, so it is sampled here instead of driving the preset pin: the
    // destination only consumes the synchronised value in clocked logic, and
    // an asynchronous pin driven by a foreign clock is a CDC-10 violation.
    taxi_sync_reset #(
        .N(4),
        .C_ASYNC_ASSERT(1'b0)
    ) net_reset_to_pcie_sync_inst (
        .clk (pcie_clk),
        .rst (net_rst),
        .out (net_rst_pcie)
    );

    // Register the merged PCIe-path reset request before it reaches the XCI
    // FIFO reset trees.  This removes a combinational LUT from the asynchronous
    // reset fanout while preserving the SFP1-triggered flush contract.
    always_ff @(posedge pcie_clk) begin
        reg_pcie_path_rst_pcie <= pcie_rst | net_rst_pcie;
    end

    // PCIe reset clears only PCIe-facing staging.  ARP, UDP, peer state, and
    // ordinary asmcehnk commands remain available for independent diagnosis.
    // One registered output drives the network-path reset consumers, avoiding
    // a combinational OR directly on data-path asynchronous reset pins.
    // pcie_rst_bridge crosses in from the PCIe domain, so it is sampled on its
    // own; mac_tx_rst is already in net_clk and is OR-ed in afterwards.  An OR
    // directly in front of the synchroniser is reported as CDC-10
    // (combinational logic before a synchroniser) even when only one input
    // crosses, which is why the merge happens after the chain, not before it.
    wire pcie_rst_bridge_net;

    taxi_sync_reset #(
        .N(4),
        .C_ASYNC_ASSERT(1'b0)
    ) pcie_rst_bridge_net_sync_inst (
        .clk (net_clk),
        .rst (pcie_rst_bridge),
        .out (pcie_rst_bridge_net)
    );

    (* DONT_TOUCH = "TRUE" *) taxi_sync_reset #(
        .N(4)
    ) pcie_path_reset_net_sync_inst (
        .clk (net_clk),
        .rst (mac_tx_rst[AS02_TRANSPORT_SFP_INDEX] | pcie_rst_bridge_net),
        .out (pcie_path_rst)
    );
    assign pcie_path_rst_pcie = reg_pcie_path_rst_pcie;

    taxi_axis_if #(
        .DATA_W(MAC_DATA_W),
        .KEEP_EN(1),
        .KEEP_W(MAC_DATA_W/8),
        .USER_EN(1),
        .USER_W(MAC_RX_USER_W)
    ) mac_rx_axis_core();

    // Physical SFP1 RX: recovered RX clock -> SFP1 TX/network clock.
    taxi_axis_async_fifo #(
        .DEPTH(32768),
        .RAM_PIPELINE(2),
        .FRAME_FIFO(1),
        .USER_BAD_FRAME_VALUE(1'b1),
        .USER_BAD_FRAME_MASK(1'b1),
        .DROP_OVERSIZE_FRAME(1),
        .DROP_BAD_FRAME(1),
        .DROP_WHEN_FULL(1)
    ) rx_cdc_fifo (
        .s_clk(mac_rx_clk[AS02_TRANSPORT_SFP_INDEX]),
        .s_rst(mac_rx_rst[AS02_TRANSPORT_SFP_INDEX]),
        .s_axis(mac_axis_rx[AS02_TRANSPORT_SFP_INDEX]),
        .m_clk(net_clk),
        .m_rst(net_rst_rx),
        .m_axis(mac_rx_axis_core),
        .s_pause_req(1'b0),
        .s_pause_ack(),
        .m_pause_req(1'b0),
        .m_pause_ack(),
        .s_status_depth(),
        .s_status_depth_commit(),
        .s_status_overflow(),
        .s_status_bad_frame(),
        .s_status_good_frame(),
        .m_status_depth(),
        .m_status_depth_commit(),
        .m_status_overflow(rx_cdc_status_overflow),
        .m_status_bad_frame(rx_cdc_status_bad_frame),
        .m_status_good_frame(rx_cdc_status_good_frame)
    );

    // Physical SFP2 carries no transport frames in the first bring-up image:
    // keep its AXIS TX invalid and drain/drop RX frames so it cannot back up
    // the shared Taxi MAC wrapper.  GT/optical idle behavior stays at Taxi's
    // board-shell defaults; this policy does not claim module power-down.
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tdata  = '0;
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tkeep  = '0;
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tstrb  = '0;
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tid    = '0;
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tdest  = '0;
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tuser  = '0;
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tlast  = 1'b0;
    assign mac_axis_tx[AS02_IDLE_SFP_INDEX].tvalid = 1'b0;

    logic [31:0] dbg_rx_words_w, dbg_rx_frames_w;

    assign mac_axis_rx[AS02_IDLE_SFP_INDEX].tready = 1'b1;
    assign mac_axis_tx_cpl[AS02_TRANSPORT_SFP_INDEX].tready = 1'b1;
    assign mac_axis_tx_cpl[AS02_IDLE_SFP_INDEX].tready = 1'b1;

    wire diag_arm,diag_capture,diag_ack,diag_reject,diag_snapshot,diag_peer_fault;
    wire [31:0] diag_nonce;
    wire [511:0] diag_local_registers,diag_peer_registers;
    // A diagnostic PCIe epoch also resets COM/FIFO. Ordinary images retain
    // their existing independent transport reset policy. No command is replayed.
    wire diag_com_rst=PARAM_RX25_BATCH_DIAG?pcie_path_rst:net_rst_com;
    wire diag_fifo_rst=PARAM_RX25_BATCH_DIAG?pcie_path_rst:net_rst_fifo;
    asmcehnk_com_axis_udp_25g #(
        .PARAM_LOCAL_MAC(PARAM_LOCAL_MAC),
        .PARAM_LOCAL_IP (PARAM_LOCAL_IP),
        .PARAM_UDP_PORT (PARAM_UDP_PORT),
        .PARAM_RX25_BATCH_DIAG(PARAM_RX25_BATCH_DIAG),
        .PARAM_RX25_REMOTE_CONTROL(PARAM_RX25_BATCH_DIAG),
        .PARAM_RX25_RESPONDER(PARAM_RX25_RESPONDER)
    ) com_inst (
        .clk              (net_clk),
        .rst              (diag_com_rst),
        .led_state_txdata (),
        .led_state_invert (1'b0),
        .dfifo            (dcom_fifo.mp_com),
        .s_axis_rx        (mac_rx_axis_core),
        .m_axis_tx        (mac_axis_tx[AS02_TRANSPORT_SFP_INDEX]),
        .diag_arm_valid(diag_arm),.diag_capture_valid(diag_capture),.diag_command_nonce(diag_nonce),
        .diag_arm_accepted(diag_ack),.diag_command_rejected(diag_reject),.diag_snapshot_valid(diag_snapshot),
        .diag_registers(diag_local_registers),.diag_peer_registers(diag_peer_registers),.diag_peer_fault(diag_peer_fault)
    );

    asmcehnk_fifo #(
        .PARAM_DEVICE_ID(PARAM_DEVICE_ID),
        .PARAM_VERSION_NUMBER_MAJOR(PARAM_VERSION_NUMBER_MAJOR),
        .PARAM_VERSION_NUMBER_MINOR(PARAM_VERSION_NUMBER_MINOR),
        .PARAM_CUSTOM_VALUE(PARAM_CUSTOM_VALUE),
        .PARAM_RX25_BYPASS(PARAM_RX25_MODE)
    ) fifo_inst (
        .clk            (net_clk),
        .rst            (diag_fifo_rst),
        .tick_100mhz_ce (tick_100mhz_ce),
        .rst_cfg_reload (1'b0),
        .pcie_present   (1'b1),
        .pcie_perst_n   (!pcie_rst_net),
        .dcom           (dcom_fifo.mp_fifo),
        .dcfg           (dcfg.mp_fifo),
        .dtlp           (dtlp.mp_fifo),
        .dpcie          (dpcie.mp_fifo),
        .dshadow2fifo   (dshadow2fifo.fifo),
        .dbg_rx_words   (dbg_rx_words_w),
        .dbg_rx_frames  (dbg_rx_frames_w)
    );

    asmcehnk_pcie_cfg_us #(
        // Driver-free far card: no function driver ever runs IRP_MN_START_DEVICE,
        // so Command.MEM/BME have to be set by the device itself or the root
        // complex discards every MRd it issues.  Pattern images keep this at 0
        // (PARAM_RX25_ADDR_MODE is 0 there), so their config-space traffic is
        // unchanged.
        .C_BME_BOOT(PARAM_RX25_ADDR_MODE),
        // Late re-assert stays off on purpose.  The arming problem turned out to
        // be C_ARM_ALWAYS, not Bus Master: measured Command was already 0x0106
        // (MEM+BME+SERR), so rewriting it every 67 ms buys nothing and the
        // 25-bit counter plus comparator costs 0.17 ns of setup on clk_pcie.
        .C_BME_HOLD_LOG2  (0),
        .C_BME_HOLD_REPEAT(0)
    ) cfg_inst (
        .clk_pcie                                (pcie_clk),
        .rst_pcie                                (pcie_path_rst_pcie),
        .clk_sys                                 (net_clk),
        .rst_sys                                 (pcie_path_rst),
        .dcfg                                     (dcfg.mp_pcie),
        .dpcie                                    (dpcie.mp_pcie),
        .user_lnk_up                              (pcie_user_lnk_up),
        .cfg_phy_link_down                        (cfg_phy_link_down),
        .cfg_phy_link_status                      (cfg_phy_link_status),
        .cfg_negotiated_width                     (cfg_negotiated_width),
        .cfg_current_speed                        (cfg_current_speed),
        .cfg_function_status                      (cfg_function_status),
        .cfg_function_power_state                 (cfg_function_power_state),
        .cfg_link_power_state                     (cfg_link_power_state),
        .cfg_ltssm_state                          (cfg_ltssm_state),
        .cfg_rx_pm_state                          (cfg_rx_pm_state),
        .cfg_tx_pm_state                          (cfg_tx_pm_state),
        .cfg_bus_number                           (cfg_bus_number),
        .cfg_max_payload                          (cfg_max_payload),
        .cfg_max_read_req                         (cfg_max_read_req),
        .cfg_rcb_status                           (cfg_rcb_status),
        .cfg_mgmt_addr                            (cfg_mgmt_addr),
        .cfg_mgmt_function_number                 (cfg_mgmt_function_number),
        .cfg_mgmt_write                           (cfg_mgmt_write),
        .cfg_mgmt_write_data                      (cfg_mgmt_write_data),
        .cfg_mgmt_byte_enable                     (cfg_mgmt_byte_enable),
        .cfg_mgmt_read                            (cfg_mgmt_read),
        .cfg_mgmt_read_data                       (cfg_mgmt_read_data),
        .cfg_mgmt_read_write_done                 (cfg_mgmt_read_write_done),
        .cfg_dsn                                  (cfg_dsn),
        .pcie_id                                  (pcie_id),
        .base_address_register                    (base_address_register),
        .cfg_fc_sel                               (cfg_fc_sel),
        .cfg_interrupt_msi_enable                 (cfg_interrupt_msi_enable),
        .cfg_interrupt_msi_mmenable               (cfg_interrupt_msi_mmenable),
        .cfg_interrupt_msi_mask_update            (cfg_interrupt_msi_mask_update),
        .cfg_interrupt_msi_data                   (cfg_interrupt_msi_data),
        .cfg_interrupt_msi_select                 (cfg_interrupt_msi_select),
        .cfg_interrupt_msi_int                    (cfg_interrupt_msi_int),
        .cfg_interrupt_msi_pending_status         (cfg_interrupt_msi_pending_status),
        .cfg_interrupt_msi_pending_status_data_enable(cfg_interrupt_msi_pending_status_data_enable),
        .cfg_interrupt_msi_pending_status_function_num(cfg_interrupt_msi_pending_status_function_num),
        .cfg_interrupt_msi_attr                   (cfg_interrupt_msi_attr),
        .cfg_interrupt_msi_tph_present            (cfg_interrupt_msi_tph_present),
        .cfg_interrupt_msi_tph_type               (cfg_interrupt_msi_tph_type),
        .cfg_interrupt_msi_tph_st_tag             (cfg_interrupt_msi_tph_st_tag),
        .cfg_interrupt_msi_function_number        (cfg_interrupt_msi_function_number),
        .cfg_interrupt_msi_sent                   (cfg_interrupt_msi_sent),
        .cfg_interrupt_msi_fail                   (cfg_interrupt_msi_fail)
    );

    // ---- RX25 host ABI -----------------------------------------------------
    // The descriptor side is wired; the request engine and the CQ writer are the
    // two pieces still missing, so a job is never consumed and no completion is
    // ever reported.  Keeping the ports connected (rather than dangling) means
    // those modules drop in here without touching the BAR path again.
    wire        rx25_enabled;
    wire        rx25_job_valid;
    wire [7:0]  rx25_job_slot;
    wire [31:0] rx25_job_request_id;
    wire [15:0] rx25_job_generation;
    wire [15:0] rx25_job_length;
    wire [63:0] rx25_job_remote_pa;
    wire [63:0] rx25_job_host_iova;
    wire        rx25_cqw_valid;
    wire [63:0] rx25_cqw_addr;
    wire [31:0] rx25_cqw_data;
    wire [2:0]  rx25_cqw_index;

    asmcehnk_pcie_tlp_us #(
        .RQ_SEQ_NUM_W(RQ_SEQ_NUM_W),
        .C_RX25_MODE      (PARAM_RX25_MODE),
        .C_RX25_RESPONDER (PARAM_RX25_RESPONDER),
        .C_RX25_REAL_MEM  (PARAM_RX25_REAL_MEM),
        .C_RX25_REAL_MEM_TEST_ADDR(PARAM_RX25_REAL_MEM_TEST_ADDR),
        .C_RX25_ADDR_MODE(PARAM_RX25_ADDR_MODE),
        .C_RX25_DIAGNOSTIC_V2(PARAM_RX25_DIAGNOSTIC_V2),
        .C_RX25_BATCH_DIAG(PARAM_RX25_BATCH_DIAG)
    ) tlp_inst (
        .clk                  (pcie_clk),
        .rst                  (pcie_path_rst_pcie),
        .clk_sys              (net_clk),
        .rst_sys              (pcie_path_rst),
        .dtlp                 (dtlp.mp_pcie),
        .s_axis_pcie_cq       (s_axis_pcie_cq),
        .m_axis_pcie_cc       (m_axis_pcie_cc),
        .m_axis_pcie_rq       (m_axis_pcie_rq),
        .s_axis_pcie_rc       (s_axis_pcie_rc),
        .dshadow2fifo         (dshadow2fifo.shadow),
        .pcie_id              (pcie_id),
        .pcie_link_up         (pcie_user_lnk_up),
        .base_address_register(base_address_register),
        .pcie_rq_seq_num0     (pcie_rq_seq_num0),
        .pcie_rq_seq_num_vld0 (pcie_rq_seq_num_vld0),
        .pcie_rq_seq_num1     (pcie_rq_seq_num1),
        .pcie_rq_seq_num_vld1 (pcie_rq_seq_num_vld1),
        .status_rq_flow        (pcie_tlp_rq_flow_status),
        // link_up and link_peer both come from SFP0 parallel detect: this is a
        // point-to-point link, so "the transceiver sees a partner" is exactly
        // what both bits mean.  fatal stays 0 until the request engine learns
        // to report one.
        .rx25_link            ({1'b0, sfp0_rx_status_sync, sfp0_rx_status_sync}),

        .rx25_obs_tx_pkt      (obs_tx_pkt_sync),
        .rx25_obs_rx_pkt      (obs_rx_pkt_sync),
        .rx25_obs_status      (obs_status_sync),
        .rx25_enabled         (rx25_enabled),
        .rx25_job_valid       (rx25_job_valid),
        .rx25_job_slot        (rx25_job_slot),
        .rx25_job_request_id  (rx25_job_request_id),
        .rx25_job_generation  (rx25_job_generation),
        .rx25_job_length      (rx25_job_length),
        .rx25_job_remote_pa   (rx25_job_remote_pa),
        .rx25_job_host_iova   (rx25_job_host_iova),
        .rx25_dbg_rx_words    (dbg_rx_words_w),
        .rx25_dbg_rx_frames   (dbg_rx_frames_w),
        .rx25_cqw_valid       (rx25_cqw_valid),
        .rx25_cqw_addr        (rx25_cqw_addr),
        .rx25_cqw_data        (rx25_cqw_data),
        .rx25_cqw_index       (rx25_cqw_index),
        .rx25_diag_arm_valid(diag_arm),.rx25_diag_capture_valid(diag_capture),.rx25_diag_command_nonce(diag_nonce),
        .rx25_diag_arm_accepted(diag_ack),.rx25_diag_command_rejected(diag_reject),.rx25_diag_snapshot_valid(diag_snapshot),
        .rx25_diag_registers({diag_peer_registers,diag_local_registers})
    );

`ifdef AS02_HW_DEBUG
    // Optional hardware-observation boundary.  The normal image does not
    // contain these nets or any debug core; vivado_build_debug_as02.tcl
    // enables them in an isolated project and inserts one ILA per clock
    // domain.  No VIO output is allowed to drive functional logic.
    (* keep = "true" *) wire dbg_net_clk;
    (* keep = "true" *) wire dbg_pcie_clk;

    (* mark_debug = "true", keep = "true" *) wire [63:0]  dbg_net_control;
    (* mark_debug = "true", keep = "true" *) wire [63:0]  dbg_net_rx_data;
    (* mark_debug = "true", keep = "true" *) wire [7:0]   dbg_net_rx_keep;
    (* mark_debug = "true", keep = "true" *) wire [63:0]  dbg_net_tx_data;
    (* mark_debug = "true", keep = "true" *) wire [7:0]   dbg_net_tx_keep;
    (* mark_debug = "true", keep = "true" *) wire [63:0]  dbg_net_com_rx_data;
    (* mark_debug = "true", keep = "true" *) wire [255:0] dbg_net_com_tx_data;

    (* mark_debug = "true", keep = "true" *) wire [63:0]  dbg_pcie_control;
    (* mark_debug = "true", keep = "true" *) wire [31:0]  dbg_pcie_keep;
    (* mark_debug = "true", keep = "true" *) wire [255:0] dbg_pcie_cq_data;
    (* mark_debug = "true", keep = "true" *) wire [87:0]  dbg_pcie_cq_user;
    (* mark_debug = "true", keep = "true" *) wire [255:0] dbg_pcie_cc_data;
    (* mark_debug = "true", keep = "true" *) wire [32:0]  dbg_pcie_cc_user;
    (* mark_debug = "true", keep = "true" *) wire [255:0] dbg_pcie_rq_data;
    (* mark_debug = "true", keep = "true" *) wire [61:0]  dbg_pcie_rq_user;
    (* mark_debug = "true", keep = "true" *) wire [255:0] dbg_pcie_rc_data;
    (* mark_debug = "true", keep = "true" *) wire [74:0]  dbg_pcie_rc_user;
    (* mark_debug = "true", keep = "true" *) wire [255:0] dbg_pcie_counters;
    (* mark_debug = "true", keep = "true" *) wire [127:0] dbg_pcie_status;

    logic [31:0] dbg_cnt_link_up = 32'd0;
    logic [31:0] dbg_cnt_link_down = 32'd0;
    logic [31:0] dbg_cnt_cq_packets = 32'd0;
    logic [31:0] dbg_cnt_cc_packets = 32'd0;
    logic [31:0] dbg_cnt_rq_packets = 32'd0;
    logic [31:0] dbg_cnt_rc_packets = 32'd0;
    logic [31:0] dbg_cnt_cfg_mgmt = 32'd0;
    logic [31:0] dbg_cnt_rq_seq = 32'd0;
    logic        dbg_link_up_prev = 1'b0;

    assign dbg_net_clk = net_clk;
    assign dbg_pcie_clk = pcie_clk;

    assign dbg_net_control[0] = net_rst;
    assign dbg_net_control[1] = pcie_rst_net;
    assign dbg_net_control[2] = mac_rx_axis_core.tvalid;
    assign dbg_net_control[3] = mac_rx_axis_core.tready;
    assign dbg_net_control[4] = mac_rx_axis_core.tlast;
    assign dbg_net_control[5] = mac_rx_axis_core.tuser[0];
    assign dbg_net_control[6] = mac_axis_tx[AS02_TRANSPORT_SFP_INDEX].tvalid;
    assign dbg_net_control[7] = mac_axis_tx[AS02_TRANSPORT_SFP_INDEX].tready;
    assign dbg_net_control[8] = mac_axis_tx[AS02_TRANSPORT_SFP_INDEX].tlast;
    assign dbg_net_control[9] = dcom_fifo.com_dout_valid;
    assign dbg_net_control[10] = dcom_fifo.com_din_wr_en;
    assign dbg_net_control[11] = dcom_fifo.com_din_ready;
    assign dbg_net_control[12] = dcfg.tx_valid;
    assign dbg_net_control[13] = dcfg.rx_valid;
    assign dbg_net_control[14] = dcfg.rx_rd_en;
    assign dbg_net_control[15] = dtlp.tx_valid;
    assign dbg_net_control[16] = dtlp.tx_last;
    assign dbg_net_control[17] = dtlp.rx_rd_en;
    assign dbg_net_control[21:18] = {
        dtlp.rx_valid[3], dtlp.rx_valid[2],
        dtlp.rx_valid[1], dtlp.rx_valid[0]
    };
    assign dbg_net_control[25:22] = {
        dtlp.rx_first[3], dtlp.rx_first[2],
        dtlp.rx_first[1], dtlp.rx_first[0]
    };
    assign dbg_net_control[29:26] = {
        dtlp.rx_last[3], dtlp.rx_last[2],
        dtlp.rx_last[1], dtlp.rx_last[0]
    };
    assign dbg_net_control[30] = dshadow2fifo.bar_en;
    assign dbg_net_control[31] = dshadow2fifo.cfgtlp_en;
    assign dbg_net_control[32] = rx_cdc_status_good_frame;
    assign dbg_net_control[33] = rx_cdc_status_bad_frame;
    assign dbg_net_control[34] = rx_cdc_status_overflow;
    assign dbg_net_control[35] = pcie_path_rst;
    assign dbg_net_control[36] = tick_100mhz_ce;
    assign dbg_net_control[63:37] = 27'd0;
    assign dbg_net_rx_data = mac_rx_axis_core.tdata;
    assign dbg_net_rx_keep = mac_rx_axis_core.tkeep;
    assign dbg_net_tx_data = mac_axis_tx[AS02_TRANSPORT_SFP_INDEX].tdata;
    assign dbg_net_tx_keep = mac_axis_tx[AS02_TRANSPORT_SFP_INDEX].tkeep;
    assign dbg_net_com_rx_data = dcom_fifo.com_dout;
    assign dbg_net_com_tx_data = dcom_fifo.com_din;

    assign dbg_pcie_control[0] = pcie_rst;
    assign dbg_pcie_control[1] = pcie_user_lnk_up;
    assign dbg_pcie_control[2] = cfg_phy_link_down;
    assign dbg_pcie_control[4:3] = cfg_phy_link_status;
    assign dbg_pcie_control[7:5] = cfg_negotiated_width;
    assign dbg_pcie_control[9:8] = cfg_current_speed;
    assign dbg_pcie_control[15:10] = cfg_ltssm_state;
    assign dbg_pcie_control[16] = s_axis_pcie_cq.tvalid;
    assign dbg_pcie_control[17] = s_axis_pcie_cq.tready;
    assign dbg_pcie_control[18] = s_axis_pcie_cq.tlast;
    assign dbg_pcie_control[19] = m_axis_pcie_cc.tvalid;
    assign dbg_pcie_control[20] = m_axis_pcie_cc.tready;
    assign dbg_pcie_control[21] = m_axis_pcie_cc.tlast;
    assign dbg_pcie_control[22] = m_axis_pcie_rq.tvalid;
    assign dbg_pcie_control[23] = m_axis_pcie_rq.tready;
    assign dbg_pcie_control[24] = m_axis_pcie_rq.tlast;
    assign dbg_pcie_control[25] = s_axis_pcie_rc.tvalid;
    assign dbg_pcie_control[26] = s_axis_pcie_rc.tready;
    assign dbg_pcie_control[27] = s_axis_pcie_rc.tlast;
    assign dbg_pcie_control[28] = pcie_rq_seq_num_vld0;
    assign dbg_pcie_control[29] = pcie_rq_seq_num_vld1;
    assign dbg_pcie_control[30] = cfg_mgmt_read;
    assign dbg_pcie_control[31] = cfg_mgmt_write;
    assign dbg_pcie_control[32] = cfg_mgmt_read_write_done;
    assign dbg_pcie_control[38:33] = pcie_rq_seq_num0;
    assign dbg_pcie_control[44:39] = pcie_rq_seq_num1;
    assign dbg_pcie_control[52:45] = cfg_bus_number;
    assign dbg_pcie_control[54:53] = cfg_max_payload;
    assign dbg_pcie_control[57:55] = cfg_max_read_req;
    assign dbg_pcie_control[61:58] = cfg_rcb_status;
    assign dbg_pcie_control[62] = cfg_interrupt_msi_sent;
    assign dbg_pcie_control[63] = cfg_interrupt_msi_fail;
    assign dbg_pcie_keep = {
        s_axis_pcie_rc.tkeep, m_axis_pcie_rq.tkeep,
        m_axis_pcie_cc.tkeep, s_axis_pcie_cq.tkeep
    };
    assign dbg_pcie_cq_data = s_axis_pcie_cq.tdata;
    assign dbg_pcie_cq_user = s_axis_pcie_cq.tuser;
    assign dbg_pcie_cc_data = m_axis_pcie_cc.tdata;
    assign dbg_pcie_cc_user = m_axis_pcie_cc.tuser;
    assign dbg_pcie_rq_data = m_axis_pcie_rq.tdata;
    assign dbg_pcie_rq_user = m_axis_pcie_rq.tuser;
    assign dbg_pcie_rc_data = s_axis_pcie_rc.tdata;
    assign dbg_pcie_rc_user = s_axis_pcie_rc.tuser;

    always_ff @(posedge pcie_clk) begin
        if (pcie_rst) begin
            dbg_cnt_link_up <= 32'd0;
            dbg_cnt_link_down <= 32'd0;
            dbg_cnt_cq_packets <= 32'd0;
            dbg_cnt_cc_packets <= 32'd0;
            dbg_cnt_rq_packets <= 32'd0;
            dbg_cnt_rc_packets <= 32'd0;
            dbg_cnt_cfg_mgmt <= 32'd0;
            dbg_cnt_rq_seq <= 32'd0;
            dbg_link_up_prev <= 1'b0;
        end else begin
            dbg_link_up_prev <= pcie_user_lnk_up;
            if (pcie_user_lnk_up && !dbg_link_up_prev) begin
                dbg_cnt_link_up <= dbg_cnt_link_up + 32'd1;
            end
            if (!pcie_user_lnk_up && dbg_link_up_prev) begin
                dbg_cnt_link_down <= dbg_cnt_link_down + 32'd1;
            end
            if (s_axis_pcie_cq.tvalid && s_axis_pcie_cq.tready &&
                s_axis_pcie_cq.tlast) begin
                dbg_cnt_cq_packets <= dbg_cnt_cq_packets + 32'd1;
            end
            if (m_axis_pcie_cc.tvalid && m_axis_pcie_cc.tready &&
                m_axis_pcie_cc.tlast) begin
                dbg_cnt_cc_packets <= dbg_cnt_cc_packets + 32'd1;
            end
            if (m_axis_pcie_rq.tvalid && m_axis_pcie_rq.tready &&
                m_axis_pcie_rq.tlast) begin
                dbg_cnt_rq_packets <= dbg_cnt_rq_packets + 32'd1;
            end
            if (s_axis_pcie_rc.tvalid && s_axis_pcie_rc.tready &&
                s_axis_pcie_rc.tlast) begin
                dbg_cnt_rc_packets <= dbg_cnt_rc_packets + 32'd1;
            end
            if (cfg_mgmt_read_write_done) begin
                dbg_cnt_cfg_mgmt <= dbg_cnt_cfg_mgmt + 32'd1;
            end
            if (pcie_rq_seq_num_vld0 || pcie_rq_seq_num_vld1) begin
                dbg_cnt_rq_seq <= dbg_cnt_rq_seq + 32'd1;
            end
        end
    end

    assign dbg_pcie_counters = {
        dbg_cnt_rq_seq,
        dbg_cnt_cfg_mgmt,
        dbg_cnt_rc_packets,
        dbg_cnt_rq_packets,
        dbg_cnt_cc_packets,
        dbg_cnt_cq_packets,
        dbg_cnt_link_down,
        dbg_cnt_link_up
    };
    assign dbg_pcie_status = {
        pcie_tlp_rq_flow_status,
        cfg_fc_nph,
        cfg_fc_pd,
        cfg_fc_ph,
        cfg_bus_number,
        cfg_phy_link_status,
        cfg_link_power_state,
        cfg_function_power_state,
        cfg_function_status,
        base_address_register,
        pcie_id
    };

    as02_pcie_vio as02_pcie_vio_inst (
        .clk      (pcie_clk),
        .probe_in0(dbg_pcie_control),
        .probe_in1(dbg_pcie_counters),
        .probe_in2(dbg_pcie_status)
    );
`endif

endmodule

`resetall

