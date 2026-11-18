`resetall
`timescale 1ns / 1ps
`default_nettype none
`include "asmcehnk_header.svh"

module asmcehnk_pcie_tlp_us #(
    parameter RQ_SEQ_NUM_W = 6,
    // 0 = PCILeech identity in BAR0 (target side), 1 = RX25 host ABI (control
    // side).  Compile-time: the two personalities share no register offsets.
    parameter bit C_RX25_MODE  = 1'b0,
    // Which end of the link this image is.  0 = initiator (the control-side
    // card: takes descriptors from the host, sends PL11 requests, writes the
    // returned records into host memory).  1 = responder (the far card: parses
    // PL11 requests, issues MRds, returns PL11 records).  Both ends run the
    // same PL11 shim; only what sits behind it differs.
    //
    // The two roles must never be built into the same binary: if both cards run
    // the initiator image they wait for each other and every request times out,
    // which looks exactly like a dead link.  As a guard the responder reports
    // itself in BAR0 CAPS bit 8, so the host can tell which card it is talking
    // to before issuing anything.
    parameter bit C_RX25_RESPONDER = 1'b0,
    // Opt in only for the responder; 0 preserves the diagnostic loop source.
    parameter bit C_RX25_REAL_MEM = 1'b0,
    parameter int C_RX25_SLOTS = 8,
    parameter bit C_RX25_DIAGNOSTIC_V2 = 1'b0,
    parameter bit C_RX25_BATCH_DIAG = 1'b0,
    // Address qualification mode for the guarded reader.
    //   0 = only C_RX25_REAL_MEM_TEST_ADDR may appear on the RQ stream
    //       (the original single-address build contract).
    //   1 = the address/len latched from the BAR at task start is the
    //       expected descriptor, i.e. the reader may issue an MRd to an
    //       arbitrary physical address chosen at run time.  The engine still
    //       enforces 16B alignment, <=256B, <=4KiB page crossing, requester
    //       ID and the single-tag rule; the guard still enforces one task at
    //       a time and faults on any non-matching RQ.
    parameter bit C_RX25_ADDR_MODE = 1'b0,
    parameter logic [63:0] C_RX25_REAL_MEM_TEST_ADDR = 64'd0
)(
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic clk_sys,
    input  wire logic rst_sys,

    IfPCIeFifoTlp.mp_pcie dtlp,

    taxi_axis_if.snk s_axis_pcie_cq,
    taxi_axis_if.src m_axis_pcie_cc,
    taxi_axis_if.src m_axis_pcie_rq,
    taxi_axis_if.snk s_axis_pcie_rc,

    IfShadow2Fifo.shadow dshadow2fifo,
    input wire logic [15:0] pcie_id,
    input wire logic pcie_link_up,
    input wire logic [31:0] base_address_register,

    input wire logic [RQ_SEQ_NUM_W-1:0] pcie_rq_seq_num0,
    input wire logic                    pcie_rq_seq_num_vld0,
    input wire logic [RQ_SEQ_NUM_W-1:0] pcie_rq_seq_num1,
    input wire logic                    pcie_rq_seq_num_vld1,

    output wire logic [11:0]            status_rq_flow,

    // ---- RX25 host ABI (C_RX25_MODE only) ---------------------------------
    // Descriptors arrive through BAR0 and leave as jobs; completions come back
    // as cq_* and are published as eight dword writes.  rx25_link is
    // {fatal, link_peer, link_up} from the 25G side.
    input  wire logic [2:0]  rx25_link,
    input  wire logic [31:0] rx25_obs_tx_pkt,
    input  wire logic [31:0] rx25_obs_rx_pkt,
    input  wire logic [31:0] rx25_obs_status,
    output bit               rx25_enabled,
    output bit               rx25_job_valid,
    output bit [7:0]         rx25_job_slot,
    output bit [31:0]        rx25_job_request_id,
    output bit [15:0]        rx25_job_generation,
    output bit [15:0]        rx25_job_length,
    output bit [63:0]        rx25_job_remote_pa,
    output bit [63:0]        rx25_job_host_iova,

    // Word/frame arrival counters from the TLP forwarding bridge.  Feeding them
    // in rather than counting locally keeps the observation point on the wire
    // side of the decode, which is where the second frame is suspected to die.
    input  wire logic [31:0] rx25_dbg_rx_words,
    input  wire logic [31:0] rx25_dbg_rx_frames,
    output bit               rx25_cqw_valid,
    output bit [63:0]        rx25_cqw_addr,
    output bit [31:0]        rx25_cqw_data,
    output bit [2:0]         rx25_cqw_index,
    // Address-free batch control; network results cross atomically via mailbox.
    output wire logic rx25_diag_arm_valid,rx25_diag_capture_valid,
    output wire logic [31:0] rx25_diag_command_nonce,
    input wire logic rx25_diag_arm_accepted,rx25_diag_command_rejected,rx25_diag_snapshot_valid,
    input wire logic [1023:0] rx25_diag_registers
);

    // UltraScale+ PCIe shim for the AMDUSB4/asmcehnk raw 128-bit TLP framework.
    // AMDUSB4 already implements BAR0/shadow/config/TLP FIFO logic against a
    // 7-series raw TLP stream; this file only adapts AS02 pcie4_uscale_plus
    // CQ/CC/RQ/RC formatting to that raw stream.  Keep the framework modules
    // reused instead of rewriting their chip-independent behavior.

    // Stages implemented here:
    //   * CQ memory BAR MRd/MWr descriptor -> AMDUSB4 IfAXIS128 raw TLP.
    //   * AMDUSB4 raw completion TLPs from cfgspace_shadow/BAR -> CC packets.
    //   * AMDUSB4 raw outbound MRd/MWr TLPs -> UltraScale+ RQ packets.
    //   * UltraScale+ RC completions -> AMDUSB4 IfAXIS128 raw Cpl/CplD TLPs.
    // The chip-independent asmcehnk FIFO, BAR and shadow-config modules stay
    // reused; only the pcie4_uscale_plus stream descriptors are translated here.

    IfAXIS128 tlps_rx_from_cq();
    IfAXIS128 tlps_rx_from_rc();
    IfAXIS128 tlps_cq_event();
    IfAXIS128 tlps_rx_to_filter();
    IfAXIS128 tlps_filtered();
    IfAXIS128 tlps_tx_from_fifo();
    IfAXIS128 tlps_tx_elastic();   // command-FIFO TLPs after the elastic buffer
    IfAXIS128 tlps_tx_dma();       // Memory Writes produced by the DMA engine
    IfAXIS128 tlps_tx_cqw();       // Memory Writes publishing an RX25 CQ dword
    IfAXIS128 tlps_tx_gen();       // dma | cqw, before the command path joins
    IfAXIS128 tlps_tx_gen2();      // + the role's data engine
    IfAXIS128 tlps_tx_gen2_sliced(); // shared data/CQ queue before final arbitration
    // mwr_stream (initiator) and the responder's read engine never run in the
    // same image, so they share one arbitration input.  Giving each its own mux
    // stage adds that stage's select and ready logic to the src_elastic
    // clock-enable cone, which is the longest combinatorial path in the PCIe
    // clock domain -- at 250 MHz the fourth stage is what pushed it negative.
    IfAXIS128 tlps_tx_data();
    IfAXIS128 tlps_tx_sliced();    // elastic output after the ready-path break
    IfAXIS128 tlps_tx_to_rq();
    IfAXIS128 tlps_cfg_rsp();
    IfAXIS128 tlps_bar_rsp();
    IfAXIS128 tlps_cc_mux();
    IfAXIS128 tlps_null1();
    IfAXIS128 tlps_null2();
    wire [383:0] first16_registers;
    // Exact single-DWORD BAR0 write starts an address-free, one-shot wire test.
    wire first16_start = !C_RX25_BATCH_DIAG && C_RX25_DIAGNOSTIC_V2 && C_RX25_MODE && !C_RX25_RESPONDER &&
        tlps_cq_event.tvalid && tlps_cq_event.tlast &&
        tlps_cq_event.tuser == 9'h007 && tlps_cq_event.tkeepdw == 4'hf &&
        tlps_cq_event.tdata[31:0] == 32'h40000001 &&
        tlps_cq_event.tdata[39:32] == 8'h0f &&
        tlps_cq_event.tdata[76:64] == 13'h1c0;
    wire [31:0] first16_rid = {tlps_cq_event.tdata[103:96],tlps_cq_event.tdata[111:104],
                             tlps_cq_event.tdata[119:112],tlps_cq_event.tdata[127:120]};

    wire [511:0] batch_registers,batch_owner_registers;
    wire [1023:0] batch_pressure_registers;
    wire [6:0] batch_payload_index;
    wire [31:0] batch_payload_data;
    wire batch_start,batch_start_accepted,batch_start_rejected;
    wire [31:0] batch_nonce;
    wire batch_bridge_fault;
    wire [12:0] batch_host_offset=tlps_cq_event.tdata[76:64];
    wire batch_host_valid=tlps_cq_event.tvalid && tlps_cq_event.tuser[0] &&
        tlps_cq_event.tuser[2] && tlps_cq_event.tdata[31:24]==8'h40 &&
        (batch_host_offset==13'hb00 || batch_host_offset==13'hb04 || batch_host_offset==13'hb08);
    wire batch_host_exact=tlps_cq_event.tlast && tlps_cq_event.tuser==9'h007 &&
        tlps_cq_event.tkeepdw==4'hf && tlps_cq_event.tdata[31:0]==32'h40000001 &&
        tlps_cq_event.tdata[39:32]==8'h0f;
    wire [1:0] batch_host_opcode=batch_host_offset==13'hb00 ? 2'd1 :
        (batch_host_offset==13'hb04 ? 2'd2 : 2'd3);
    if(C_RX25_BATCH_DIAG && (!C_RX25_MODE || !C_RX25_DIAGNOSTIC_V2 || C_RX25_REAL_MEM)) begin : g_batch_config_error
        RX25_BATCH_REQUIRES_DIAGNOSTIC_PATTERN_ONLY invalid_configuration();
    end
    if(C_RX25_BATCH_DIAG) begin : g_batch_owner
        wire command_valid,command_ready,response_valid,p_fault,n_fault;
        wire [1:0] command_opcode,response_kind,response_opcode;
        wire [31:0] command_nonce,response_nonce;
        wire [1023:0] response_registers;
        asmcehnk_rx25_batch_owner #(.C_RESPONDER(C_RX25_RESPONDER)) owner(
            .clk(clk),.rst(rst),.host_valid(batch_host_valid),.host_exact(batch_host_exact),
            .host_opcode(batch_host_opcode),.host_nonce(first16_rid),
            .command_valid(command_valid),.command_ready(command_ready),
            .command_opcode(command_opcode),.command_nonce(command_nonce),
            .response_valid(response_valid),.response_kind(response_kind),.response_opcode(response_opcode),
            .response_nonce(response_nonce),.response_registers(response_registers),.bridge_fault(p_fault),
            .start_valid(batch_start),.start_nonce(batch_nonce),.start_accepted(batch_start_accepted),
            .start_rejected(batch_start_rejected),.batch_registers(batch_registers),
            .pressure_registers(batch_pressure_registers),.registers(batch_owner_registers));
        if(!C_RX25_RESPONDER) begin : g_mailbox
            asmcehnk_rx25_diag_cdc #(.C_BANK_WIDTH(1024)) mailbox(
                .p_clk(clk),.p_rst(rst),.command_valid(command_valid),.command_ready(command_ready),
                .command_opcode(command_opcode),.command_nonce(command_nonce),
                .response_valid(response_valid),.response_ready(1'b1),.response_kind(response_kind),
                .response_opcode(response_opcode),.response_nonce(response_nonce),.response_registers(response_registers),
                .p_fault(p_fault),.n_clk(clk_sys),.n_rst(rst_sys),
                .net_arm_valid(rx25_diag_arm_valid),.net_capture_valid(rx25_diag_capture_valid),
                .net_command_nonce(rx25_diag_command_nonce),.net_arm_accepted(rx25_diag_arm_accepted),
                .net_command_rejected(rx25_diag_command_rejected),.net_snapshot_valid(rx25_diag_snapshot_valid),
                .net_registers(rx25_diag_registers),.n_fault(n_fault));
            assign batch_bridge_fault=p_fault;
        end else begin : g_no_b_host_commands
            assign command_ready=0;assign response_valid=0;assign response_kind=0;assign response_opcode=0;
            assign response_nonce=0;assign response_registers=0;assign p_fault=0;assign n_fault=0;
            assign rx25_diag_arm_valid=0;assign rx25_diag_capture_valid=0;assign rx25_diag_command_nonce=0;
            assign batch_bridge_fault=0;
        end
    end else begin : g_no_batch_owner
        assign batch_owner_registers=0;assign batch_pressure_registers=0;
        assign batch_start=0;assign batch_nonce=0;assign batch_bridge_fault=0;
        assign rx25_diag_arm_valid=0;assign rx25_diag_capture_valid=0;assign rx25_diag_command_nonce=0;
    end

    // RX25 channel binding.  PL11 frames ride the TLP channel: their first dword
    // is 'PL11', whose Fmt field (101) no real TLP can produce, so the two
    // streams can share the wire without a fifth type code.  In C_RX25_MODE the
    // PL11 stream owns this path outright -- the control card answers every host
    // BAR access locally and issues no host DMA, so there is no host-to-wire TLP
    // traffic to arbitrate against (see asmcehnk_rx25_tlp_shim).
    // Request-engine <-> BAR side.  In C_RX25_MODE these are driven by the
    // engine; otherwise they are tied off.
    logic                  rx25_job_ready_i;
    logic                  rx25_cq_valid_i;
    logic [7:0]            rx25_cq_slot_i;
    logic [15:0]           rx25_cq_status_i;
    logic [31:0]           rx25_cq_bytes_i;
    logic [31:0]           rx25_cq_detail_i;

    // Payload stream from the engine into host memory.
    logic [63:0]  rx25_mwr_addr;
    logic [31:0]  rx25_mwr_len;
    logic         rx25_mwr_start;
    logic [31:0]  rx25_mwr_done;
    logic [63:0]  rx25_mwr_addr_reg;
    logic [63:0]  rx25_mwr_cfg_addr;
    logic         rx25_mwr_busy, rx25_mwr_error;

    // Responder role: read engine <-> responder.  Idle in every other build.
    logic [63:0]  rx25_rd_addr;
    logic [31:0]  rx25_rd_len;
    logic         rx25_rd_start;
    logic         rx25_rd_busy, rx25_rd_done, rx25_rd_error;
    logic [63:0]  rx25_rd_data;
    logic         rx25_rd_valid, rx25_rd_ready;
    logic [127:0] rx25_mwr_tdata;
    logic [3:0]   rx25_mwr_tkeepdw;
    logic         rx25_mwr_tvalid, rx25_mwr_tready;
    IfAXIS128     tlps_tx_mwr();
    IfAXIS128     tlps_tx_rd();      // responder MRds (idle in other roles)

    // The from-wire dword stream cannot be stalled, so frame words need a place
    // to land while the write engine has no room for a payload beat.
    logic [63:0]  rx25_fifo_dout;
    logic         rx25_fifo_rd_valid;
    logic         rx25_frame_rd_last;

    // Responder-side header diagnostics, surfaced through the RX25 BAR so the
    // record loop can be debugged without an ILA.
    logic [31:0]  rx25_dbg_len;
    logic [31:0]  rx25_dbg_remain;
    logic         rx25_dbg_hdr_ok;
    logic [31:0]  rx25_dbg_requests;
    logic [63:0]  rx25_dbg_hdr0;
    logic [63:0]  rx25_dbg_hdr1;
    logic [63:0]  rx25_dbg_hdr2;
    // Shim framing counters: first/magic/start tell whether the first beat of a
    // frame was recognised, bad counts dropped beats.
    logic [31:0]  rx25_dbg_frames;
    logic [31:0]  rx25_dbg_bad;
    logic [31:0]  rx25_dbg_first;
    logic [31:0]  rx25_dbg_magic;
    logic [31:0]  rx25_dbg_start;
    logic [31:0]  rx25_beat_count;
    logic         rx25_dbg_in_frame;
    logic [7:0]   rx25_dbg_beats_in_frame;
    // initiator-side header diagnostics (see asmcehnk_rx25_req_engine).
    // Distinct names: the responder branch already drives rx25_dbg_bad from the
    // shim's rx_bad counter, and both live in exclusive generate arms, so a
    // shared name would be a duplicate declaration.
    logic [31:0]  rx25_init_bad;
    logic [31:0]  rx25_init_tmo;
    logic [31:0]  rx25_dbg_rx_magic;
    logic [31:0]  rx25_dbg_rx_type;
    logic [31:0]  rx25_dbg_rx_rid;
    logic [31:0]  rx25_dbg_rx_len;
    // responder record-loop position, and where the initiator timed out
    logic [2:0]   rx25_dbg_state;
    logic [5:0]   rx25_dbg_buf_n;
    logic [31:0]  rx25_dbg_rec_len;
    logic [2:0]   rx25_init_tmo_state;
    // Read-engine arming gate.  0xB8/0xBC expose why a request never reached
    // the engine: pcie_id (the requester ID arm_ok demands to be non-zero),
    // how many arms were accepted versus rejected, and the guard's first fault
    // cause.  Without these the only visible symptom is buf_n stuck at 0.
    logic [31:0]  rx25_dbg_gate0;
    logic [31:0]  rx25_dbg_gate1;
    // Single-driver shadows: the generate arms are mutually exclusive for the
    // parameters we build, but Vivado keeps a constant driver when the same
    // net is also assigned in a sibling arm, which silently zeroed these
    // registers.  Drive the shadows and mux once here.
    logic [31:0]  rx25_dbg_gate0_c;
    logic [31:0]  rx25_dbg_gate1_c;
    // Host-writable bus number (BAR+0xF0).  pcie4 in endpoint mode leaves
    // cfg_bus_number at 0, so pcie_id would be 0 and the read engine's arm
    // check (arm_requester != 0) could never pass.  When the host supplies the
    // bus number, it replaces the whole requester ID: {8'h00, bus}.
    wire [7:0]    rx25_bus_override;
    wire [15:0]   pcie_id_v = (rx25_bus_override != 8'd0) ? {8'h00, rx25_bus_override}
                                                          : pcie_id;
    // Wire-format Requester ID.  pcie_id carries {devfn,bus} (bus in the low
    // byte), which is the convention the legacy raw-TLP helpers expect, but a
    // TLP dword and the Xilinx RQ descriptor both want {bus,devfn}.  Feeding
    // the unswapped value made the RQ descriptor's Function field equal to 7
    // (0x0017 -> bus=0x00 dev=0x02 fn=7), so the MRd targeted a function that
    // does not exist and no completion ever came back.
    wire [15:0]   pcie_rid_wire = {pcie_id_v[7:0], pcie_id_v[15:8]};
    // Sole driver for the two gate words (see rx25_dbg_gate0_c above).
    assign rx25_dbg_gate0 = (C_RX25_MODE && C_RX25_RESPONDER && C_RX25_REAL_MEM)
                            ? rx25_dbg_gate0_c : 32'd0;
    assign rx25_dbg_gate1 = (C_RX25_MODE && C_RX25_RESPONDER && C_RX25_REAL_MEM)
                            ? rx25_dbg_gate1_c : 32'd0;
    logic [31:0]  rx25_dbg_buf_w0_lo, rx25_dbg_buf_w0_hi;
    logic [31:0]  rx25_dbg_buf_w1_lo, rx25_dbg_buf_w1_hi;
    logic         rx25_fifo_empty;
    logic         rx25_fifo_rd_en;
    logic         rx25_fifo_full;
    logic         rx25_frame_overflow;

    IfAXIS128   tlps_dst_in();
    IfAXIS128   tlps_tx_pre_elastic();   // src FIFO output, PL11 frames removed
    // What the receive mux sees on its RC input.  In the initiator role this is
    // the RC stream unchanged; in the responder the completions belong to the
    // read engine, so the mux input is held idle (two owners would corrupt the
    // packet boundary).
    IfAXIS128   tlps_rc_to_rx();

    logic [127:0] rx25_frame_wr_data;
    logic         rx25_frame_wr_last;
    logic         rx25_frame_wr_en;
    logic [63:0] rx25_frame_tx_data;
    logic        rx25_frame_tx_valid;
    logic        rx25_frame_tx_last;
    logic        rx25_frame_tx_ready;
    logic [127:0] rx25_tx_tdata;
    logic [3:0]   rx25_tx_tkeepdw;
    logic [8:0]   rx25_tx_tuser;
    logic         rx25_tx_tlast;
    logic         rx25_tx_tvalid;

    // DMA engine control, written by the host through BAR offset 0x600
    wire [63:0] dma_addr;
    wire [31:0] dma_len;
    wire        dma_start;
    wire [31:0] dma_done;
    wire        dma_busy;
    wire        dma_error;
    IfShadow2Fifo dshadow_pcie();

    taxi_axis_if #(
        .DATA_W  (256),
        .KEEP_EN (1),
        .KEEP_W  (8),
        .USER_EN (1),
        .USER_W  (33)
    ) axis_cc_normal();
    taxi_axis_if #(
        .DATA_W  (256),
        .KEEP_EN (1),
        .KEEP_W  (8),
        .USER_EN (1),
        .USER_W  (33)
    ) axis_cc_error();
    taxi_axis_if #(
        .DATA_W(256), .KEEP_EN(1), .KEEP_W(8), .USER_EN(1), .USER_W(33)
    ) axis_cc_muxed();
    taxi_axis_if #(
        .DATA_W(256), .KEEP_EN(1), .KEEP_W(8), .USER_EN(1), .USER_W(33)
    ) axis_cc_counted();
    taxi_axis_if #(
        .DATA_W(256), .KEEP_EN(1), .KEEP_W(8), .USER_EN(1), .USER_W(62)
    ) axis_rq_internal();

    localparam bit C_RX25_GUARDED_READER = C_RX25_MODE && C_RX25_RESPONDER && C_RX25_REAL_MEM;
    // Task address/len latched from the BAR at task start.  Declared at module
    // scope because the RQ descriptor qualifier below must see them too.
    logic [63:0] rx25_pending_addr_q;
    logic [31:0] rx25_pending_len_q;
    // Per-task tag.  Legacy single-address builds keep 0x1f; runtime-address
    // builds rotate 0x18..0x1f so a completion that survives one task can
    // never match the next task's identity, which removes the ABA window the
    // quiesce counter could only narrow.
    logic [2:0] rx25_tag_sel_q = 3'd0;   // initial value also covers builds where g_host_mem is not elaborated
    wire [7:0] rx25_task_tag = C_RX25_ADDR_MODE ? (8'h18 | {5'd0, rx25_tag_sel_q}) : 8'h1f;
    wire rx25_expected_len_match = C_RX25_ADDR_MODE
        ? (axis_rq_internal.tdata[74:64] == {1'b0, rx25_pending_len_q[11:2]})
        : (axis_rq_internal.tdata[74:64] == 11'd4);
    wire rx25_expected_addr_match = C_RX25_ADDR_MODE
        ? (axis_rq_internal.tdata[63:2] == rx25_pending_addr_q[63:2])
        : (axis_rq_internal.tdata[63:2] == C_RX25_REAL_MEM_TEST_ADDR[63:2]);
    wire rx25_expected_mrd_descriptor =
        axis_rq_internal.tdata[78:75] == 4'b0000 &&
        rx25_expected_len_match &&
        axis_rq_internal.tdata[103:96] == rx25_task_tag &&
        axis_rq_internal.tdata[95:80] == pcie_rid_wire &&
        rx25_expected_addr_match &&
        axis_rq_internal.tkeep == 8'h0f && axis_rq_internal.tlast;
    wire rx25_hardip_read_issued = C_RX25_GUARDED_READER &&
        m_axis_pcie_rq.tvalid && m_axis_pcie_rq.tready && rx25_expected_mrd_descriptor;
    wire rx25_unexpected_rq = C_RX25_GUARDED_READER &&
        axis_rq_internal.tvalid && !rx25_expected_mrd_descriptor;

    wire [5:0] shadow_control_async;
    wire [5:0] shadow_control_pcie;
    wire [RQ_SEQ_NUM_W:0] rq_seq_outstanding;
    wire                  rq_seq_blocked;
    wire                  rq_seq_error;
    wire                  rq_tag_blocked;
    wire                  rq_tag_error;
    wire [7:0]            rc_tag_release;
    wire                  rc_tag_release_valid;

    assign status_rq_flow[6:0] = {
        {(6-RQ_SEQ_NUM_W){1'b0}}, rq_seq_outstanding
    };
    assign status_rq_flow[7] = rq_seq_blocked;
    assign status_rq_flow[8] = rq_seq_error;
    assign status_rq_flow[9] = rq_tag_blocked;
    assign status_rq_flow[10] = rq_tag_error;
    assign status_rq_flow[11] = 1'b0;

    assign shadow_control_async = {
        dshadow2fifo.alltlp_filter,
        dshadow2fifo.cfgtlp_filter,
        dshadow2fifo.cfgtlp_wren,
        dshadow2fifo.cfgtlp_zero,
        dshadow2fifo.cfgtlp_en,
        dshadow2fifo.bar_en
    };

    taxi_sync_signal #(
        .WIDTH(6),
        .N(2)
    ) shadow_control_sync_inst (
        .clk (clk),
        .in  (shadow_control_async),
        .out (shadow_control_pcie)
    );

    // The shadow command/response FIFOs already cross clk_sys/clk.  Only the
    // slowly changing mode controls need a synchronizer before PCIe-side use.
    assign dshadow_pcie.rx_rden = dshadow2fifo.rx_rden;
    assign dshadow_pcie.rx_wren = dshadow2fifo.rx_wren;
    assign dshadow_pcie.rx_be = dshadow2fifo.rx_be;
    assign dshadow_pcie.rx_data = dshadow2fifo.rx_data;
    assign dshadow_pcie.rx_addr = dshadow2fifo.rx_addr;
    assign dshadow_pcie.rx_addr_lo = dshadow2fifo.rx_addr_lo;
    assign dshadow_pcie.alltlp_filter = shadow_control_pcie[5];
    assign dshadow_pcie.cfgtlp_filter = shadow_control_pcie[4];
    assign dshadow_pcie.cfgtlp_wren = shadow_control_pcie[3];
    assign dshadow_pcie.cfgtlp_zero = shadow_control_pcie[2];
    assign dshadow_pcie.cfgtlp_en = shadow_control_pcie[1];
    assign dshadow_pcie.bar_en = shadow_control_pcie[0];
    assign dshadow2fifo.tx_valid = dshadow_pcie.tx_valid;
    assign dshadow2fifo.tx_data = dshadow_pcie.tx_data;
    assign dshadow2fifo.tx_addr = dshadow_pcie.tx_addr;
    assign dshadow2fifo.tx_addr_lo = dshadow_pcie.tx_addr_lo;

    assign tlps_null1.tdata = 128'd0;
    assign tlps_null1.tkeepdw = 4'd0;
    assign tlps_null1.tvalid = 1'b0;
    assign tlps_null1.tlast = 1'b0;
    assign tlps_null1.tuser = 9'd0;
    assign tlps_null1.has_data = 1'b0;

    assign tlps_null2.tdata = 128'd0;
    assign tlps_null2.tkeepdw = 4'd0;
    assign tlps_null2.tvalid = 1'b0;
    assign tlps_null2.tlast = 1'b0;
    assign tlps_null2.tuser = 9'd0;
    assign tlps_null2.has_data = 1'b0;

    asmcehnk_pcie_us_cq_to_tlps128 #(
        .C_DIAGNOSTIC_V2(C_RX25_DIAGNOSTIC_V2)
    ) cq_to_tlps128_inst (
        .clk             (clk),
        .rst             (rst),
        .pcie_id         (pcie_id_v),
        .s_axis_cq       (s_axis_pcie_cq),
        .tlps_out        (tlps_rx_from_cq.source),
        .m_axis_cc_error (axis_cc_error)
    );

    // CQ and RC are independent PCIe channels.  Merge them with packet-locked
    // ready/valid arbitration so simultaneous traffic cannot overwrite a
    // one-word holding register.
    asmcehnk_tlps128_mux2 rx_tlps_mux_inst (
        .clk        (clk),
        .rst        (rst),
        .tlps_in1   (tlps_rx_from_cq.sink),
        .tlps_in2   (tlps_rc_to_rx.sink),
        .tlps_out   (tlps_rx_to_filter.source)
    );

    assign tlps_rx_to_filter.tready = 1'b1;

    // BAR and shadow helpers have the original AMDUSB4 pulse-only input.
    // Present a CQ beat exactly once, when the lossless merger accepts it.
    assign tlps_cq_event.tdata = tlps_rx_from_cq.tdata;
    assign tlps_cq_event.tkeepdw = tlps_rx_from_cq.tkeepdw;
    assign tlps_cq_event.tvalid = tlps_rx_from_cq.tvalid && tlps_rx_from_cq.tready;
    assign tlps_cq_event.tlast = tlps_rx_from_cq.tlast;
    assign tlps_cq_event.tuser = tlps_rx_from_cq.tuser;
    assign tlps_cq_event.has_data = tlps_rx_from_cq.has_data;

    asmcehnk_tlps128_filter tlp_filter_inst (
        .rst            (rst),
        .clk_pcie       (clk),
        .alltlp_filter  (shadow_control_pcie[5]),
        .cfgtlp_filter  (shadow_control_pcie[4]),
        .tlps_in        (tlps_rx_to_filter.sink_lite),
        .tlps_out       (tlps_filtered.source_lite)
    );

    generate
        if (C_RX25_MODE) begin : g_rx25_chan
            logic shim_pass_valid;
            // The real-memory responder is the sole MRd/RC owner. Drain raw
            // command traffic instead of allowing it to share its reserved tag.
            assign tlps_tx_pre_elastic.tvalid = shim_pass_valid &&
                                              !(C_RX25_RESPONDER && C_RX25_REAL_MEM);
            // PL11 owns the wire slot in this image: the shim is the only driver
            // of the to-wire stream, so two packets can never interleave and
            // nothing can be silently dropped for lack of backpressure.
            // tlps_filtered is intentionally left unconnected: in an RX25 image
            // a TLP received from the host is NOT tunnelled to the peer, because
            // the peer is busy answering PL11 records, not acting as a BAR
            // proxy.  Dropping it is the honest outcome -- the alternative is
            // interleaving it into a PL11 frame.  The command-FIFO path
            // (tlps_tx_elastic -> RQ) still works, so the local DMA self-test
            // keeps running in this image.
            asmcehnk_rx25_tlp_shim rx25_shim_inst (
                .rst            (rst),
                .clk            (clk),
                .rx_tdata       (tlps_tx_from_fifo.tdata),
                .rx_tkeepdw     (tlps_tx_from_fifo.tkeepdw),
                .rx_tfirst      (tlps_tx_from_fifo.tuser[0]),
                .rx_tlast       (tlps_tx_from_fifo.tlast),
                .rx_tvalid      (tlps_tx_from_fifo.tvalid),
                .rx_tready      (tlps_tx_from_fifo.tready),
                .pass_tdata     (tlps_tx_pre_elastic.tdata),
                .pass_tkeepdw   (tlps_tx_pre_elastic.tkeepdw),
                .pass_tfirst    (tlps_tx_pre_elastic.tuser[0]),
                .pass_tlast     (tlps_tx_pre_elastic.tlast),
                .pass_tvalid    (shim_pass_valid),
                .pass_tready    ((C_RX25_RESPONDER && C_RX25_REAL_MEM) ? 1'b1 : tlps_tx_pre_elastic.tready),
                .frame_wr_data  (rx25_frame_wr_data),
                .frame_wr_last  (rx25_frame_wr_last),
                .frame_wr_en    (rx25_frame_wr_en),
                .frame_wr_full  (rx25_fifo_full),
                .frame_tx_data  (rx25_frame_tx_data),
                .frame_tx_valid (rx25_frame_tx_valid),
                .frame_tx_last  (rx25_frame_tx_last),
                .frame_tx_ready (rx25_frame_tx_ready),
                .tx_tdata       (rx25_tx_tdata),
                .tx_tkeepdw     (rx25_tx_tkeepdw),
                .tx_tuser       (rx25_tx_tuser),
                .tx_tlast       (rx25_tx_tlast),
                .tx_tvalid      (rx25_tx_tvalid),
                .tx_tready      (1'b1),   // dst_fifo writes every valid beat
                .cnt_rx_frames  (rx25_dbg_frames),
                .cnt_rx_bad     (rx25_dbg_bad),
                .cnt_rx_first   (rx25_dbg_first),
                .cnt_rx_magic   (rx25_dbg_magic),
                .cnt_rx_start   (rx25_dbg_start),
                .dbg_in_frame      (rx25_dbg_in_frame),
                .dbg_beats_in_frame(rx25_dbg_beats_in_frame),
                .cnt_tx_frames  (),
                .dbg_rx_beats   (rx25_beat_count)
            );

            assign tlps_dst_in.tdata   = rx25_tx_tdata;
            assign tlps_dst_in.tkeepdw = rx25_tx_tkeepdw;
            assign tlps_dst_in.tuser   = rx25_tx_tuser;
            assign tlps_dst_in.tlast   = rx25_tx_tlast;
            assign tlps_dst_in.tvalid  = rx25_tx_tvalid;

            // Beat-to-word buffer.  The from-wire stream cannot be stalled, so
            // the shim always accepts and this FIFO absorbs the difference.
            // Hold a complete 512-byte response (two 256-byte records) plus
            // margin while the non-backpressurable PCIe source drains after RQ
            // stalls. Each record occupies 19 beats at this FIFO boundary.
            asmcehnk_frame_fifo128 #(
                .C_DEPTH(64),
                .C_AW   (6)
            ) rx25_frame_fifo_inst (
                .rst      (rst),
                .clk      (clk),
                .wr_data  (rx25_frame_wr_data),
                .wr_last  (rx25_frame_wr_last),
                .wr_en    (rx25_frame_wr_en),
                .full     (rx25_fifo_full),
                .overflow (rx25_frame_overflow),
                .rd_data  (rx25_fifo_dout),
                .rd_last  (rx25_frame_rd_last),
                .rd_valid (rx25_fifo_rd_valid),
                .rd_en    (rx25_fifo_rd_en),
                .empty    (rx25_fifo_empty)
            );

            // What sits behind the shim depends on which end of the link this
            // image is.  Everything above this point (shim, word buffer, PL11
            // framing) is identical for both roles, which is the whole point of
            // keeping the frame format in one place.
            if (!C_RX25_RESPONDER) begin : g_init
              if (C_RX25_DIAGNOSTIC_V2) begin : g_first16
               if(C_RX25_BATCH_DIAG) begin : g_batch
                asmcehnk_rx25_batch32 batch_inst(
                    .clk(clk),.rst(rst),.start_valid(batch_start),.start_nonce(batch_nonce),
                    .start_accepted(batch_start_accepted),.start_rejected(batch_start_rejected),
                    .link_ok(rx25_link[1:0]==2'b11 && rx25_obs_status[0] && !rx25_obs_status[1]),
                    .external_fault(rx25_link[2] || rx25_frame_overflow || batch_bridge_fault),
                    .tx_valid(rx25_frame_tx_valid),.tx_ready(rx25_frame_tx_ready),
                    .tx_data(rx25_frame_tx_data),.tx_last(rx25_frame_tx_last),
                    .rx_valid(rx25_fifo_rd_valid),.rx_data(rx25_fifo_dout),
                    .rx_last(rx25_frame_rd_last),.rx_ready(rx25_fifo_rd_en),
                    .payload_read_index(batch_payload_index),.payload_read_data(batch_payload_data),
                    .registers(batch_registers));
                assign first16_registers=0;
               end else begin : g_legacy_first16
                asmcehnk_rx25_first16 first16_inst (
                    .clk(clk), .rst(rst), .start_valid(first16_start), .start_rid(first16_rid),
                    .link_ok(rx25_link[1:0] == 2'b11 && rx25_obs_status[0] && !rx25_obs_status[1]),
                    .external_fault(rx25_link[2] || rx25_frame_overflow),
                    .tx_valid(rx25_frame_tx_valid), .tx_ready(rx25_frame_tx_ready),
                    .tx_data(rx25_frame_tx_data), .tx_last(rx25_frame_tx_last),
                    .rx_valid(rx25_fifo_rd_valid), .rx_data(rx25_fifo_dout),
                    .rx_last(rx25_frame_rd_last), .rx_ready(rx25_fifo_rd_en),
                    .registers(first16_registers)
                );
               end
                assign rx25_job_ready_i = 0;
                assign rx25_cq_valid_i = 0;
                assign rx25_cq_slot_i = 0;
                assign rx25_cq_status_i = 0;
                assign rx25_cq_bytes_i = 0;
                assign rx25_cq_detail_i = 0;
                assign rx25_init_bad = 0;
                assign rx25_init_tmo = 0;
                assign rx25_dbg_rx_magic = 0;
                assign rx25_dbg_rx_type = 0;
                assign rx25_dbg_rx_rid = 0;
                assign rx25_dbg_rx_len = 0;
                assign rx25_init_tmo_state = 0;
                assign rx25_mwr_addr = 0;
                assign rx25_mwr_len = 0;
                assign rx25_mwr_start = 0;
                assign rx25_mwr_done = 0;
                assign rx25_mwr_addr_reg = 0;
                assign rx25_mwr_cfg_addr = 0;
                assign rx25_mwr_busy = 0;
                assign rx25_mwr_error = 0;
                assign rx25_mwr_tdata = 0;
                assign rx25_mwr_tkeepdw = 0;
                assign rx25_mwr_tvalid = 0;
                assign rx25_mwr_tready = 0;
                assign tlps_tx_mwr.tdata = 0;
                assign tlps_tx_mwr.tkeepdw = 0;
                assign tlps_tx_mwr.tuser = 0;
                assign tlps_tx_mwr.tlast = 0;
                assign tlps_tx_mwr.tvalid = 0;
                assign tlps_tx_mwr.has_data = 0;
              end else begin : g_host_dma
                // Request engine: descriptor -> PL11 request -> DATA records ->
                // host memory.  One job in flight; the rest stay queued in the
                // BAR.
                asmcehnk_rx25_req_engine #(
                    .C_TIMEOUT_CYCLES(200_000)
                ) rx25_engine_inst (
                    .rst            (rst),
                    .clk            (clk),
                    .job_valid      (rx25_job_valid),
                    .job_ready      (rx25_job_ready_i),
                    .job_slot       (rx25_job_slot),
                    .job_request_id (rx25_job_request_id),
                    .job_generation (rx25_job_generation),
                    .job_length     (rx25_job_length),
                    .job_remote_pa  (rx25_job_remote_pa),
                    .job_host_iova  (rx25_job_host_iova),
                    .cq_valid       (rx25_cq_valid_i),
                    .cq_ready       (!rx25_cqw_valid),
                    .cq_slot        (rx25_cq_slot_i),
                    .cq_status      (rx25_cq_status_i),
                    .cq_bytes       (rx25_cq_bytes_i),
                    .cq_detail      (rx25_cq_detail_i),
                    .mwr_addr       (rx25_mwr_addr),
                    .mwr_len        (rx25_mwr_len),
                    .mwr_start      (rx25_mwr_start),
                    .mwr_done       (rx25_mwr_done),
                    .mwr_busy       (rx25_mwr_busy),
                    .mwr_error      (rx25_mwr_error),
                    .mwr_tdata      (rx25_mwr_tdata),
                    .mwr_tkeepdw    (rx25_mwr_tkeepdw),
                    .mwr_tvalid     (rx25_mwr_tvalid),
                    .mwr_tready     (rx25_mwr_tready),
                    .tx_valid       (rx25_frame_tx_valid),
                    .tx_ready       (rx25_frame_tx_ready),
                    .tx_data        (rx25_frame_tx_data),
                    .tx_last        (rx25_frame_tx_last),
                    .rx_valid       (rx25_fifo_rd_valid),
                    .rx_data        (rx25_fifo_dout),
                    .rx_ready       (rx25_fifo_rd_en),
                    .cnt_frames_bad (rx25_init_bad),
                    .cnt_timeout    (rx25_init_tmo),
                    .dbg_rx_magic   (rx25_dbg_rx_magic),
                    .dbg_rx_type    (rx25_dbg_rx_type),
                    .dbg_rx_rid     (rx25_dbg_rx_rid),
                    .dbg_rx_len     (rx25_dbg_rx_len),
                    .dbg_tmo_state  (rx25_init_tmo_state)
                );

                asmcehnk_mwr_stream #(
                    .C_PAYLOAD_BYTES(128),
                    .C_REQID(16'h0100)
                ) rx25_mwr_inst (
                    .rst       (rst),
                    .clk       (clk),
                    .cfg_addr  (rx25_mwr_addr),
                    .cfg_len   (rx25_mwr_len),
                    .cfg_start (rx25_mwr_start),
                    .done_bytes(rx25_mwr_done),
                    .dbg_addr_reg (rx25_mwr_addr_reg),
                    .dbg_cfg_addr (rx25_mwr_cfg_addr),
                    .busy      (rx25_mwr_busy),
                    .error     (rx25_mwr_error),
                    .s_tdata   (rx25_mwr_tdata),
                    .s_tkeepdw (rx25_mwr_tkeepdw),
                    .s_tvalid  (rx25_mwr_tvalid),
                    .s_tready  (rx25_mwr_tready),
                    .s_tlast   (1'b0),
                    .tlps_out  (tlps_tx_mwr.source)
                );
                assign first16_registers = 0;
              end

                // The RD stream belongs to the other role; keep it idle so the
                // TX merge tree has a well-defined input in every build.
                assign tlps_tx_rd.tdata   = 128'd0;
                assign tlps_tx_rd.tkeepdw = 4'd0;
                assign tlps_tx_rd.tuser   = 9'd0;
                assign tlps_tx_rd.tlast   = 1'b0;
                assign tlps_tx_rd.tvalid  = 1'b0;
            end else begin : g_resp
                assign first16_registers = 0;
                // Responder: PL11 request -> MRd -> completion -> PL11 records.
                // The read engine owns the RC channel outright in this role, so
                // the receive mux input is held idle instead of forwarding
                // completions to the filter (which would either drop them or
                // mistake them for requests).
                // Real-memory bring-up is restricted to one whitelisted 16B span.
                // Length profile.  Two independent knobs, and both matter:
                //   C_MAX_RECORD        sizes the record buffer (BUF_WORDS*8 bytes)
                //   C_MAX_REQUEST_BYTES rejects anything longer at the frame
                //                       header, silently, with no reply at all
                // Leaving the second at 16 makes 64 B and 192 B requests look
                // like a link hang on the A side (status 4, no frame back).
                // Stage 1 of the post-D1 plan raises both to the full 256 B.
                // Declared before the instance: Vivado synthesis rejects a
                // forward reference even though xvlog accepts it.
                wire rx25_fail_ack;
                asmcehnk_rx25_responder #(
                    .C_MAX_RECORD(256),
                    .C_MAX_REQUEST_BYTES(C_RX25_REAL_MEM ? 256 : 0),
                    .C_REQUIRE_ALIGNED(C_RX25_REAL_MEM),
                    .C_TEST_ADDR(C_RX25_REAL_MEM_TEST_ADDR),
                    // Runtime address mode: the job frame carries the address,
                    // so the compile-time single-address check must stand down
                    // (alignment/size/page checks in the responder stay on).
                    .C_CHECK_TEST_ADDR(C_RX25_REAL_MEM && !C_RX25_ADDR_MODE)
                ) rx25_responder_inst (
                    .rst            (rst),
                    .clk            (clk),
                    .rx_data        (rx25_fifo_dout),
                    .rx_valid       (rx25_fifo_rd_valid),
                    .rx_last        (rx25_frame_rd_last),
                    .rx_ready       (rx25_fifo_rd_en),
                    .tx_data        (rx25_frame_tx_data),
                    .tx_valid       (rx25_frame_tx_valid),
                    .tx_last        (rx25_frame_tx_last),
                    .tx_ready       (rx25_frame_tx_ready),
                    .rd_addr        (rx25_rd_addr),
                    .rd_len         (rx25_rd_len),
                    .rd_start       (rx25_rd_start),
                    .rd_busy        (rx25_rd_busy),
                    .rd_done        (rx25_rd_done),
                    .rd_error       (rx25_rd_error),
                    .rd_data        (rx25_rd_data),
                    .rd_valid       (rx25_rd_valid),
                    .rd_ready       (rx25_rd_ready),
                    .fail_ack       (rx25_fail_ack),
                    .cnt_requests   (rx25_dbg_requests),
                    .cnt_errors     (),
                    .dbg_len        (rx25_dbg_len),
                    .dbg_remain     (rx25_dbg_remain),
                    .dbg_hdr_ok     (rx25_dbg_hdr_ok),
                    .dbg_hdr0       (rx25_dbg_hdr0),
                    .dbg_hdr1       (rx25_dbg_hdr1),
                    .dbg_hdr2       (rx25_dbg_hdr2),
                    .dbg_state      (rx25_dbg_state),
                    .dbg_buf_n      (rx25_dbg_buf_n),
                    .dbg_rec_len    (rx25_dbg_rec_len),
                    .dbg_buf_w0_lo  (rx25_dbg_buf_w0_lo),
                    .dbg_buf_w0_hi  (rx25_dbg_buf_w0_hi),
                    .dbg_buf_w1_lo  (rx25_dbg_buf_w1_lo),
                    .dbg_buf_w1_hi  (rx25_dbg_buf_w1_hi)
                );

                // Compile-time diagnostic source or native PCIe host-memory reader.
                if (!C_RX25_REAL_MEM) begin : g_loop
                    asmcehnk_rx25_loop_mem #(.C_ADDRESS_PATTERN(C_RX25_BATCH_DIAG)) rx25_loop_mem_inst (
                        .rst       (rst),
                        .clk       (clk),
                        .cfg_addr  (rx25_rd_addr),
                        .cfg_len   (rx25_rd_len),
                        .cfg_start (rx25_rd_start),
                        .busy      (rx25_rd_busy),
                        .done      (rx25_rd_done),
                        .error     (rx25_rd_error),
                        .out_data  (rx25_rd_data),
                        .out_valid (rx25_rd_valid),
                        .out_ready (rx25_rd_ready)
                    );

                    // The loopback source issues no MRd, so this merge input must be
                    // held idle explicitly.  Leaving it undriven would let the TX
                    // merge tree latch an undefined tvalid and stall the RQ path.
                    assign tlps_tx_rd.tdata   = 128'd0;
                    assign tlps_tx_rd.tkeepdw = 4'd0;
                    assign tlps_tx_rd.tuser   = 9'd0;
                    assign tlps_tx_rd.tlast   = 1'b0;
                    assign tlps_tx_rd.tvalid  = 1'b0;
                    assign tlps_tx_rd.has_data = 1'b0;
                    assign tlps_rx_from_rc.tready = 1'b1;
                end else begin : g_host_mem
                    IfAXIS128 rd_cpl();
                    logic engine_busy, engine_done, engine_error;
                    logic [63:0] engine_data;
                    logic engine_valid;
                    logic fault_reg, reject_done;
                    logic arm_pending, arm_sent, reader_start;
                    logic [63:0] owner_task_q, task_counter_q;
                    logic [63:0] task_epoch_q;
                    wire arm_valid, arm_ready, arm_accepted, arm_rejected;
                    wire request_allowed, stop_new_requests, spent;
                    wire [7:0] guard_release_tag;
                    wire guard_release_valid, guard_fault, guard_task_fail, release_allowed;
                    wire pipeline_idle = !engine_busy && !arm_pending && !reader_start &&
                                         !reject_done;
                    wire [15:0] guard_causes;
                    wire guard_desc_valid;
                    wire [95:0] guard_desc;
                    wire [74:0] guard_user;
                    wire [7:0] guard_keep;
                    wire guard_last;
                    wire [63:0] result_epoch, result_task;
                    wire unexpected_fault = rx25_unexpected_rq || rq_seq_error || rq_tag_error;
                    assign arm_valid = arm_pending && !arm_sent;

                    always_ff @(posedge clk) begin
                        if (rst) begin
                            fault_reg <= 1'b0; reject_done <= 1'b0;
                            arm_pending <= 1'b0; arm_sent <= 1'b0; reader_start <= 1'b0;
                            owner_task_q <= 64'd0; task_counter_q <= 64'd0;
                            task_epoch_q <= 64'd1;
                            rx25_tag_sel_q <= 3'd0;
                            rx25_pending_addr_q <= 64'd0; rx25_pending_len_q <= 32'd0;
                        end
                        else begin
                            reader_start <= 1'b0;
                            reject_done <= 1'b0;
                            if (rx25_rd_start && !fault_reg && !arm_pending && !engine_busy) begin
                                arm_pending <= 1'b1;
                                arm_sent <= 1'b0;
                                rx25_pending_addr_q <= rx25_rd_addr;
                                rx25_pending_len_q <= rx25_rd_len;
                                task_counter_q <= task_counter_q + 64'd1;
                                owner_task_q <= task_counter_q + 64'd1;
                            end
                            if (arm_valid) arm_sent <= 1'b1;
                            if (arm_accepted) begin
                                arm_pending <= 1'b0;
                                arm_sent <= 1'b0;
                                reader_start <= 1'b1;
                                // Monotonic per-boot epoch: the guard latches
                                // this at arm time, so incrementing on accept
                                // keeps result_epoch unique per task without
                                // disturbing the in-flight value.
                                task_epoch_q <= task_epoch_q + 64'd1;
                            end else if (arm_rejected) begin
                                arm_pending <= 1'b0;
                                arm_sent <= 1'b0;
                                reject_done <= 1'b1;
                            end
                            // Self-heal: guard arm_ok requires arm_epoch != 0.
                            // A driverless endpoint that is only rescanned --
                            // never reset through a full enumeration -- leaves
                            // this register at its power-on value of zero, so
                            // every arm is rejected for the rest of the boot
                            // and the read engine never issues an MRd.  Seen on
                            // the B card as arm_acc=0 / arm_rej=1 with
                            // guard_causes=0: nothing wrong with the data, the
                            // handshake never happened.  Placed after the
                            // accept branch on purpose (last assignment wins)
                            // and harmless on a healthy boot because epoch is
                            // already non-zero there.
                            if (task_epoch_q == 64'd0) task_epoch_q <= 64'd1;
                            if (guard_fault) begin
                                fault_reg <= 1'b1;
                                if (!engine_busy && (arm_pending || rx25_rd_start)) reject_done <= 1'b1;
                            end
                            // Rotate the task tag only after a validated release,
                            // so the in-flight task's identity never changes.
                            if (guard_release_valid) rx25_tag_sel_q <= rx25_tag_sel_q + 3'd1;
                            if (rx25_rd_start && fault_reg) reject_done <= 1'b1;
                        end
                    end

                    assign rd_cpl.tdata = tlps_rx_from_rc.tdata;
                    assign rd_cpl.tkeepdw = tlps_rx_from_rc.tkeepdw;
                    assign rd_cpl.tuser = tlps_rx_from_rc.tuser;
                    assign rd_cpl.tlast = tlps_rx_from_rc.tlast;
                    assign rd_cpl.tvalid = tlps_rx_from_rc.tvalid && engine_busy && !fault_reg;
                    assign tlps_rx_from_rc.tready = (!engine_busy || fault_reg) ? 1'b1 : rd_cpl.tready;

                    // Arming-gate observability.  arm_ok requires
                    // arm_requester (= pcie_id) to be non-zero, and arm_ready
                    // requires link_ok, no external fault and no pending RC
                    // beat.  When either fails the engine is never started and
                    // the only outward symptom is buf_n stuck at 0, so publish
                    // the gate itself: 0xB8 = {pcie_id, accepts, rejects},
                    // 0xBC = {engine_busy, arm_ready, fault_reg, guard_fault,
                    // guard first-cause bitmap}.
                    logic [7:0] arm_acc_q, arm_rej_q;
                    always_ff @(posedge clk) begin
                        if (rst) begin
                            arm_acc_q <= 8'd0;
                            arm_rej_q <= 8'd0;
                        end else begin
                            if (arm_accepted && arm_acc_q != 8'hff) arm_acc_q <= arm_acc_q + 8'd1;
                            if (arm_rejected && arm_rej_q != 8'hff) arm_rej_q <= arm_rej_q + 8'd1;
                        end
                    end
                    assign rx25_dbg_gate0_c = {pcie_id_v, arm_acc_q, arm_rej_q};
                    assign rx25_dbg_gate1_c = {8'd0, (unexpected_fault || rx25_link[2]),
                                             request_allowed, stop_new_requests,
                                             engine_busy, arm_ready,
                                             fault_reg, guard_fault, guard_task_fail, guard_causes};

                    asmcehnk_rx25_read_fault_guard #(
                        // Runtime-address mode implies a sequence of reads, so
                        // the owner must reopen after each validated release.
                        .C_MULTI_TASK(C_RX25_ADDR_MODE)
                    ) rx25_read_fault_guard_inst (
                        .clk(clk), .rst(rst),
                        .arm_valid(arm_valid), .arm_ready(arm_ready),
                        .arm_accepted(arm_accepted), .arm_rejected(arm_rejected),
                        .arm_epoch(task_epoch_q), .arm_task(owner_task_q),
                        .arm_requester(pcie_rid_wire), .arm_tag(rx25_task_tag),
                        // rx25_link is {fatal, link_peer, link_up}: a healthy
                        // link requires both low bits set and fatal clear.
                        // The previous pcie_link_up && rx25_link[2] inverts
                        // that: arming was only accepted while the 25G side
                        // reported fatal, so no guarded request could ever be
                        // issued.  Match the two sibling instances above.
                        .link_ok(pcie_link_up && (rx25_link[1:0]==2'b11) &&
                                 rx25_obs_status[0] && !rx25_obs_status[1]),
                        .external_fault(unexpected_fault || rx25_link[2]),
                        .request_issued(rx25_hardip_read_issued),
                        .read_complete(engine_done && !engine_error),
                        .read_error(engine_done && engine_error),
                        .request_allowed(request_allowed), .stop_new_requests(stop_new_requests),
                        .spent(spent), .s_axis_rc(s_axis_pcie_rc), .tlps_out(tlps_rx_from_rc.source),
                        .tag_release(guard_release_tag), .tag_release_valid(guard_release_valid),
                        .faulted(guard_fault), .task_fail(guard_task_fail),
                        .task_fail_ack(rx25_fail_ack),
                        .pipeline_idle(pipeline_idle),
                        .first_causes(guard_causes),
                        .first_descriptor_valid(guard_desc_valid), .first_descriptor(guard_desc),
                        .first_user(guard_user), .first_keep(guard_keep), .first_last(guard_last),
                        .result_epoch(result_epoch), .result_task(result_task),
                        .release_allowed(release_allowed)
                    );

                    assign rc_tag_release = guard_release_tag;
                    assign rc_tag_release_valid = guard_release_valid;
                    asmcehnk_rx25_rd_engine #(.C_TAG(8'h1f), .C_CHECK_REQID(1'b1)) rx25_rd_engine_inst (
                        .rst(rst), .clk(clk), .cfg_addr(rx25_pending_addr_q),
                        .cfg_len(rx25_pending_len_q), .cfg_requester_id(pcie_rid_wire),
                        .cfg_tag(rx25_task_tag),
                        .cfg_start(reader_start && request_allowed),
                        .abort(guard_fault || guard_task_fail),
                        .busy(engine_busy), .done(engine_done), .error(engine_error),
                        .out_data(engine_data), .out_valid(engine_valid),
                        .out_ready(rx25_rd_ready), .cpl_in(rd_cpl.sink),
                        .tlps_out(tlps_tx_rd.source)
                    );
                    assign rx25_rd_busy = engine_busy || arm_pending || reader_start;
                    assign rx25_rd_done = engine_done || reject_done || guard_task_fail;
                    assign rx25_rd_error = engine_error || fault_reg || guard_fault ||
                                           reject_done || guard_task_fail;
                    assign rx25_rd_valid = engine_valid;
                    // Native RC -> raw swaps bytes in each DWORD. PL11 payload
                    // is a host-memory byte stream; undo that at this boundary.
                    assign rx25_rd_data = {engine_data[39:32],engine_data[47:40],
                        engine_data[55:48],engine_data[63:56],engine_data[7:0],
                        engine_data[15:8],engine_data[23:16],engine_data[31:24]};
                end

                // No descriptors are accepted on this end: a job written here
                // would have nobody to answer it.  Rejecting the doorbell (the
                // BAR counts it) is better than silently queueing it.
                assign rx25_job_ready_i = 1'b0;
                assign rx25_cq_valid_i  = 1'b0;
                assign rx25_cq_slot_i   = 8'd0;
                assign rx25_cq_status_i = 16'd0;
                assign rx25_cq_bytes_i  = 32'd0;

                // This role has no request engine, so the initiator-side header
                // diagnostics have no source; tie them off rather than leave the
                // BAR registers floating.
                assign rx25_init_bad     = 32'd0;
                assign rx25_init_tmo     = 32'd0;
                assign rx25_dbg_rx_magic = 32'd0;
                assign rx25_dbg_rx_type  = 32'd0;
                assign rx25_dbg_rx_rid   = 32'd0;
                assign rx25_dbg_rx_len   = 32'd0;
                assign rx25_init_tmo_state = 3'd0;
                assign rx25_cq_detail_i = 32'd0;

                assign rx25_mwr_addr    = 64'd0;
                assign rx25_mwr_addr_reg = 64'd0;
                assign rx25_mwr_cfg_addr = 64'd0;
                assign rx25_mwr_len     = 32'd0;
                assign rx25_mwr_start   = 1'b0;
                assign tlps_tx_mwr.tdata   = 128'd0;
                assign tlps_tx_mwr.tkeepdw = 4'd0;
                assign tlps_tx_mwr.tuser   = 9'd0;
                assign tlps_tx_mwr.tlast   = 1'b0;
                assign tlps_tx_mwr.tvalid  = 1'b0;
                assign rx25_mwr_tready     = 1'b0;
            end

            // RC stream routing is role-independent from the mux's point of
            // view: the initiator passes it through, the responder already
            // consumed it in the read engine above.
            if (C_RX25_RESPONDER) begin : g_rc_consumed
                assign tlps_rc_to_rx.tdata   = 128'd0;
                assign tlps_rc_to_rx.tkeepdw = 4'd0;
                assign tlps_rc_to_rx.tuser   = 9'd0;
                assign tlps_rc_to_rx.tlast   = 1'b0;
                assign tlps_rc_to_rx.tvalid  = 1'b0;
            end else begin : g_rc_passthru
                assign tlps_rc_to_rx.tdata    = tlps_rx_from_rc.tdata;
                assign tlps_rc_to_rx.tkeepdw  = tlps_rx_from_rc.tkeepdw;
                assign tlps_rc_to_rx.tuser    = tlps_rx_from_rc.tuser;
                assign tlps_rc_to_rx.tlast    = tlps_rx_from_rc.tlast;
                assign tlps_rc_to_rx.tvalid   = tlps_rx_from_rc.tvalid;
                assign tlps_rx_from_rc.tready = tlps_rc_to_rx.tready;
            end
        end else begin : g_host_tlp
            assign first16_registers = 0;
            // Target-side / PCILeech image: unchanged, host TLPs go straight out.
            assign tlps_tx_pre_elastic.tdata   = tlps_tx_from_fifo.tdata;
            assign tlps_tx_pre_elastic.tkeepdw = tlps_tx_from_fifo.tkeepdw;
            assign tlps_tx_pre_elastic.tuser   = tlps_tx_from_fifo.tuser;
            assign tlps_tx_pre_elastic.tlast   = tlps_tx_from_fifo.tlast;
            assign tlps_tx_pre_elastic.tvalid  = tlps_tx_from_fifo.tvalid;
            assign tlps_tx_pre_elastic.has_data = tlps_tx_from_fifo.has_data;
            assign tlps_tx_from_fifo.tready    = tlps_tx_pre_elastic.tready;

            assign tlps_dst_in.tdata   = tlps_filtered.tdata;
            assign tlps_dst_in.tkeepdw = tlps_filtered.tkeepdw;
            assign tlps_dst_in.tuser   = tlps_filtered.tuser;
            assign tlps_dst_in.tlast   = tlps_filtered.tlast;
            assign tlps_dst_in.tvalid  = tlps_filtered.tvalid;

            assign rx25_frame_wr_data  = 128'd0;
            assign rx25_frame_wr_last  = 1'b0;
            assign rx25_frame_wr_en    = 1'b0;
            assign rx25_frame_tx_ready = 1'b0;

            assign rx25_job_ready_i  = 1'b0;
            assign rx25_cq_valid_i   = 1'b0;
            assign rx25_cq_slot_i    = 8'd0;
            assign rx25_cq_status_i  = 16'd0;
            assign rx25_cq_bytes_i   = 32'd0;
            assign rx25_cq_detail_i  = 32'd0;

            assign tlps_tx_mwr.tdata   = 128'd0;
            assign tlps_tx_mwr.tkeepdw = 4'd0;
            assign tlps_tx_mwr.tuser   = 9'd0;
            assign tlps_tx_mwr.tlast   = 1'b0;
            assign tlps_tx_mwr.tvalid  = 1'b0;
            assign rx25_mwr_tready     = 1'b0;

            assign tlps_tx_rd.tdata   = 128'd0;
            assign tlps_tx_rd.tkeepdw = 4'd0;
            assign tlps_tx_rd.tuser   = 9'd0;
            assign tlps_tx_rd.tlast   = 1'b0;
            assign tlps_tx_rd.tvalid  = 1'b0;

            assign rx25_rd_addr    = 64'd0;
            assign rx25_rd_len     = 32'd0;
            assign rx25_rd_start   = 1'b0;
            assign rx25_rd_data    = 64'd0;
            assign rx25_rd_valid   = 1'b0;
            assign rx25_rd_ready   = 1'b0;
            assign rx25_rd_busy    = 1'b0;
            assign rx25_rd_done    = 1'b0;
            assign rx25_rd_error   = 1'b0;

            // PCILeech image: the RC stream is host traffic, pass it straight
            // through to the filter as before.
            assign tlps_rc_to_rx.tdata    = tlps_rx_from_rc.tdata;
            assign tlps_rc_to_rx.tkeepdw  = tlps_rx_from_rc.tkeepdw;
            assign tlps_rc_to_rx.tuser    = tlps_rx_from_rc.tuser;
            assign tlps_rc_to_rx.tlast    = tlps_rx_from_rc.tlast;
            assign tlps_rc_to_rx.tvalid   = tlps_rx_from_rc.tvalid;
            assign tlps_rx_from_rc.tready = tlps_rc_to_rx.tready;

            assign rx25_fifo_dout      = 64'd0;
            assign rx25_fifo_rd_valid  = 1'b0;
            assign rx25_frame_rd_last  = 1'b0;

            // No responder in this image; keep the diagnostic slots defined.
            assign rx25_dbg_len       = 32'd0;
            assign rx25_dbg_remain    = 32'd0;
            assign rx25_dbg_hdr_ok    = 1'b0;
            assign rx25_dbg_requests  = 32'd0;
            assign rx25_dbg_hdr0      = 64'd0;
            assign rx25_dbg_hdr1      = 64'd0;
            assign rx25_dbg_hdr2      = 64'd0;
            assign rx25_dbg_frames    = 32'd0;
            assign rx25_dbg_bad       = 32'd0;
            assign rx25_dbg_first     = 32'd0;
            assign rx25_dbg_magic     = 32'd0;
            assign rx25_dbg_start     = 32'd0;
            assign rx25_dbg_state     = 3'd0;
            assign rx25_dbg_buf_n     = 6'd0;
            assign rx25_dbg_rec_len   = 32'd0;
            assign rx25_dbg_buf_w0_lo = 32'd0;
            assign rx25_dbg_buf_w0_hi = 32'd0;
            assign rx25_dbg_buf_w1_lo = 32'd0;
            assign rx25_dbg_buf_w1_hi = 32'd0;
            assign rx25_fifo_empty     = 1'b1;
            assign rx25_fifo_rd_en     = 1'b0;
            assign rx25_fifo_full      = 1'b0;
            assign rx25_frame_overflow = 1'b0;
        end
    endgenerate

    asmcehnk_tlps128_dst_fifo_us tlp_dst_fifo_inst (
        .rst_pcie (rst),
        .rst_sys  (rst_sys),
        .clk_pcie (clk),
        .clk_sys  (clk_sys),
        .tlps_in  (tlps_dst_in.sink_lite),
        .dfifo    (dtlp)
    );

    // asmcehnk -> PCIe TLP TX source FIFO: preserve the AMDUSB4 implementation.
    // Its read-valid pulse is normalized by an AS02-only elastic stage before
    // the UltraScale+ RQ packetizer applies native descriptor/tuser formatting.
    asmcehnk_tlps128_src_fifo tlp_src_fifo_inst (
        .rst_pcie       (rst),
        .rst_sys        (rst_sys),
        .clk_pcie       (clk),
        .clk_sys        (clk_sys),
        .dfifo_tx_data  (dtlp.tx_data),
        .dfifo_tx_last  (dtlp.tx_last),
        .dfifo_tx_valid (dtlp.tx_valid),
        .tlps_out       (tlps_tx_from_fifo.source)
    );

    asmcehnk_tlps128_src_elastic_us tlp_src_elastic_inst (
        .rst            (rst),
        .clk            (clk),
        .tlps_legacy_in (tlps_tx_pre_elastic.sink),
        .tlps_out       (tlps_tx_elastic.source)
    );

    // The card has two sources of outbound TLPs: the host command FIFO (reads
    // issued by pcileech/fastdump) and the DMA engine (writes of data received
    // from the peer card).  mux2 is packet-locked: it latches a source on the
    // first beat and holds it until tlast, so a TLP is never interleaved.
    // in1 wins, which keeps the existing command path's latency unchanged.
    // Both card-generated write sources (the DMA self-test engine and the RX25
    // completion publisher) are Memory Writes that never come back, so they
    // share one packet-locked mux before the command path joins.
    asmcehnk_tlps128_mux2 tx_gen_mux_inst (
        .clk        (clk),
        .rst        (rst),
        .tlps_in1   (tlps_tx_dma.sink),
        .tlps_in2   (tlps_tx_cqw.sink),
        .tlps_out   (tlps_tx_gen.source)
    );

    // The single role-exclusive data source.
    generate
        if (C_RX25_RESPONDER) begin : g_data_from_rd
            assign tlps_tx_data.tdata   = tlps_tx_rd.tdata;
            assign tlps_tx_data.tkeepdw = tlps_tx_rd.tkeepdw;
            assign tlps_tx_data.tuser   = tlps_tx_rd.tuser;
            assign tlps_tx_data.tlast   = tlps_tx_rd.tlast;
            assign tlps_tx_data.tvalid  = tlps_tx_rd.tvalid;
            assign tlps_tx_data.has_data = tlps_tx_rd.has_data;
            assign tlps_tx_rd.tready    = tlps_tx_data.tready;
        end else begin : g_data_from_mwr
            assign tlps_tx_data.tdata   = tlps_tx_mwr.tdata;
            assign tlps_tx_data.tkeepdw = tlps_tx_mwr.tkeepdw;
            assign tlps_tx_data.tuser   = tlps_tx_mwr.tuser;
            assign tlps_tx_data.tlast   = tlps_tx_mwr.tlast;
            assign tlps_tx_data.tvalid  = tlps_tx_mwr.tvalid;
            assign tlps_tx_data.has_data = tlps_tx_mwr.has_data;
            assign tlps_tx_mwr.tready   = tlps_tx_data.tready;
        end
    endgenerate

    // RX25 read data joins the two other card-generated write sources before the
    // command path is merged in.  In the legacy build both are tied idle.
    asmcehnk_tlps128_mux2 tx_mwr_mux_inst (
        .clk        (clk),
        .rst        (rst),
        .tlps_in1   (tlps_tx_gen.sink),
        .tlps_in2   (tlps_tx_data.sink),
        .tlps_out   (tlps_tx_gen2.source)
    );

    // Break the ready chain before it reaches the elastic buffer.  See the
    // header of asmcehnk_tlps128_slice for why this is load-bearing.
    asmcehnk_tlps128_slice tx_slice_inst (
        .clk      (clk),
        .rst      (rst),
        .tlps_in  (tlps_tx_elastic.sink),
        .tlps_out (tlps_tx_sliced.source)
    );

    // Queue data and CQ only after they have merged.  A slice on the data
    // branch alone could let CQ overtake data still waiting in that queue.
    // Local occupancy now terminates the RQ ready/credit path to both sources.
    asmcehnk_tlps128_slice tx_gen_slice_inst (
        .clk      (clk),
        .rst      (rst),
        .tlps_in  (tlps_tx_gen2.sink),
        .tlps_out (tlps_tx_gen2_sliced.source)
    );

    asmcehnk_tlps128_mux2 tx_tlp_mux_inst (
        .clk        (clk),
        .rst        (rst),
        .tlps_in1   (tlps_tx_sliced.sink),
        .tlps_in2   (tlps_tx_gen2_sliced.sink),
        .tlps_out   (tlps_tx_to_rq.source)
    );

    asmcehnk_mwr_engine mwr_engine_inst (
        .rst        (rst),
        .clk        (clk),
        .cfg_addr   (dma_addr),
        .cfg_len    (dma_len),
        .cfg_start  (dma_start),
        .done_bytes (dma_done),
        .busy       (dma_busy),
        .tlps_out   (tlps_tx_dma.source)
    );

    assign dma_error = 1'b0;   // engine reports failure by refusing to start

    // RX25 completion publisher: one 4-byte Memory Write per CQ dword, in the
    // order asmcehnk_rx25_bar emits them (dword 1 last).
    wire rx25_cqw_done;
    asmcehnk_cq_writer #(
        .C_REQID(16'h0100)
    ) cq_writer_inst (
        .rst       (rst),
        .clk       (clk),
        .cqw_valid (rx25_cqw_valid),
        .cqw_addr  (rx25_cqw_addr),
        .cqw_data  (rx25_cqw_data),
        .cqw_index (rx25_cqw_index),
        .cqw_done  (rx25_cqw_done),
        .tlps_out  (tlps_tx_cqw.source)
    );

    // Address-free images have no requester. Keep unsupported raw wire traffic
    // backpressured before conversion, rather than retaining a live converter
    // behind a closed hard-IP valid gate.
    localparam bit C_RQ_DISABLED = C_RX25_DIAGNOSTIC_V2 ||
        (C_RX25_MODE && C_RX25_RESPONDER && !C_RX25_REAL_MEM);
    generate
    if (!C_RQ_DISABLED) begin : g_rq_enabled
    asmcehnk_tlps128_to_axis_rq_us #(
        .RQ_SEQ_NUM_W(RQ_SEQ_NUM_W)
    ) tlps128_to_rq_inst (
        .clk                  (clk),
        .rst                  (rst),
        .tlps_in              (tlps_tx_to_rq.sink),
        .m_axis_rq            (axis_rq_internal),
        .pcie_rq_seq_num0     (pcie_rq_seq_num0),
        .pcie_rq_seq_num_vld0 (pcie_rq_seq_num_vld0),
        .pcie_rq_seq_num1     (pcie_rq_seq_num1),
        .pcie_rq_seq_num_vld1 (pcie_rq_seq_num_vld1),
        .rc_tag_release       (rc_tag_release),
        .rc_tag_release_valid (rc_tag_release_valid),
        .status_outstanding   (rq_seq_outstanding),
        .status_blocked       (rq_seq_blocked),
        .status_error         (rq_seq_error),
        .status_tag_blocked   (rq_tag_blocked),
        .status_tag_error     (rq_tag_error)
    );
    end else begin : g_rq_disabled
        assign tlps_tx_to_rq.tready = 1'b0;
        assign axis_rq_internal.tdata = '0;
        assign axis_rq_internal.tkeep = '0;
        assign axis_rq_internal.tstrb = '0;
        assign axis_rq_internal.tuser = '0;
        assign axis_rq_internal.tlast = 1'b0;
        assign axis_rq_internal.tvalid = 1'b0;
        assign axis_rq_internal.tid = '0;
        assign axis_rq_internal.tdest = '0;
        assign rq_seq_outstanding = '0;
        assign rq_seq_blocked = 1'b0;
        assign rq_seq_error = 1'b0;
        assign rq_tag_blocked = 1'b0;
        assign rq_tag_error = 1'b0;
    end
    endgenerate

    // Both address-free personalities must block every PCIe request source,
    // including non-PL11 traffic arriving through the legacy wire path.
    // Keep the diagnostic image from issuing any PCIe Memory Read or Write.
    // This is after all request sources, directly at the hard-IP interface.
    assign m_axis_pcie_rq.tdata  = axis_rq_internal.tdata;
    assign m_axis_pcie_rq.tkeep  = axis_rq_internal.tkeep;
    assign m_axis_pcie_rq.tstrb  = axis_rq_internal.tstrb;
    assign m_axis_pcie_rq.tuser  = axis_rq_internal.tuser;
    assign m_axis_pcie_rq.tlast  = axis_rq_internal.tlast;
    assign m_axis_pcie_rq.tvalid = axis_rq_internal.tvalid && !C_RQ_DISABLED &&
                                   (!C_RX25_GUARDED_READER || rx25_expected_mrd_descriptor);
    assign m_axis_pcie_rq.tid    = axis_rq_internal.tid;
    assign m_axis_pcie_rq.tdest  = axis_rq_internal.tdest;
    assign axis_rq_internal.tready = m_axis_pcie_rq.tready && !C_RQ_DISABLED &&
                                     (!C_RX25_GUARDED_READER || rx25_expected_mrd_descriptor);

    asmcehnk_tlps128_cfgspace_shadow cfgspace_shadow_inst (
        .rst          (rst),
        .clk_pcie     (clk),
        .clk_sys      (clk_sys),
        .tlps_in      (tlps_cq_event.sink_lite),
        .pcie_id      (pcie_id_v),
        .tlps_cfg_rsp (tlps_cfg_rsp.source),
        .dshadow2fifo (dshadow_pcie)
    );

    wire        bar_int_enable_unused;
    wire [31:0] bar_o_addr_unused;
    wire [31:0] bar_o_data_unused;
    wire        bar_dbg_rd_valid_unused;
    wire [63:0] bar_dbg_rd_info_unused;
    wire        bar_dbg_wr_valid_unused;
    wire [63:0] bar_dbg_wr_info_unused;

    // The responder role only exists inside the RX25 personality: without the
    // PL11 shim there is nothing to respond to, and a build with RESPONDER set
    // but MODE clear would silently produce a PCILeech image that looks fine and
    // can never answer a request.
    if (C_RX25_RESPONDER && !C_RX25_MODE) begin : g_role_error
        AS02_RX25_RESPONDER_REQUIRES_MODE u_role_error ();
    end

    if(!(C_RX25_BATCH_DIAG && C_RX25_DIAGNOSTIC_V2 && C_RX25_MODE && !C_RX25_RESPONDER)) begin : g_no_batch_engine
        assign batch_registers=0;assign batch_payload_data=0;
        assign batch_start_accepted=0;assign batch_start_rejected=0;
    end

    asmcehnk_tlps128_bar_controller #(
        .C_FIRST16(!C_RX25_BATCH_DIAG && C_RX25_DIAGNOSTIC_V2 && C_RX25_MODE && !C_RX25_RESPONDER),
        .C_BATCH_DIAG(C_RX25_BATCH_DIAG),
        .C_RX25_MODE     (C_RX25_MODE),
        .C_RX25_RESPONDER(C_RX25_RESPONDER),
        .C_RX25_REAL_MEM (C_RX25_REAL_MEM),
        .C_RX25_SLOTS    (C_RX25_SLOTS),
        // Descriptor personality only: the far end has no driver to arm it and
        // this board cannot take a non-zero CONTROL write (see rx25_bar).
        // The responder needs this even more than the initiator: it is the board
        // sitting in the target machine with no driver and no host-side arm
        // path at all, so without this the read engine stays idle, the guard
        // rejects every task and the reply frame carries buf_n = 0.
        .C_RX25_ARM_ALWAYS(C_RX25_MODE && !C_RX25_DIAGNOSTIC_V2)
    ) bar_controller_inst (
        .first16_registers(first16_registers),
        .batch_registers(batch_registers),.batch_pressure_registers(batch_pressure_registers),
        .batch_owner_registers(batch_owner_registers),.batch_payload_index(batch_payload_index),
        .batch_payload_data(batch_payload_data),
        .rst                   (rst),
        .clk                   (clk),
        .bar_en                (shadow_control_pcie[0]),
        .int_enable            (bar_int_enable_unused),
        .o_addr                (bar_o_addr_unused),
        .o_data                (bar_o_data_unused),
        .base_address_register (base_address_register),
        .pcie_id               (pcie_id_v),
        .dbg_rd_valid          (bar_dbg_rd_valid_unused),
        .dbg_rd_info           (bar_dbg_rd_info_unused),
        .dbg_wr_valid          (bar_dbg_wr_valid_unused),
        .dbg_wr_info           (bar_dbg_wr_info_unused),
        .tlps_in               (tlps_cq_event.sink_lite),
        .tlps_out              (tlps_bar_rsp.source),
        .dma_addr              (dma_addr),
        .dma_len               (dma_len),
        .dma_start             (dma_start),
        .dma_done              (dma_done),
        .dma_busy              (dma_busy),
        .dma_error             (dma_error),
        .rx25_enabled          (rx25_enabled),
        .rx25_link             (rx25_link),
        .rx25_obs_tx_pkt       (rx25_obs_tx_pkt),
        .rx25_obs_rx_pkt       (rx25_obs_rx_pkt),
        .rx25_obs_status       (rx25_obs_status),
        .rx25_dbg_len          (rx25_dbg_len),
        .rx25_dbg_remain       (rx25_dbg_remain),
        .rx25_dbg_hdr_ok       (rx25_dbg_hdr_ok),
        .rx25_dbg_requests     (rx25_dbg_requests),
        .rx25_dbg_hdr0         (rx25_dbg_hdr0),
        .rx25_dbg_hdr1         (rx25_dbg_hdr1),
        .rx25_dbg_hdr2         (rx25_dbg_hdr2),
        .rx25_dbg_frames       (rx25_dbg_frames),
        .rx25_dbg_bad          (rx25_dbg_bad),
        .rx25_dbg_first        (rx25_dbg_first),
        .rx25_dbg_magic        (rx25_dbg_magic),
        .rx25_dbg_start        (rx25_dbg_start),
        .rx25_dbg_gate0        (rx25_dbg_gate0),
        .rx25_dbg_gate1        (rx25_dbg_gate1),
        .rx25_bus_override     (rx25_bus_override),
        .rx25_dbg_in_frame     (rx25_dbg_in_frame),
        .rx25_dbg_beats_in_frame(rx25_dbg_beats_in_frame),
        .rx25_dbg_rx_words     (rx25_beat_count),
        .rx25_dbg_rx_frames    (rx25_dbg_rx_frames),
        .rx25_init_bad         (rx25_init_bad),
        .rx25_init_tmo         (rx25_init_tmo),
        .rx25_dbg_rx_magic     (rx25_dbg_rx_magic),
        .rx25_dbg_rx_type      (rx25_dbg_rx_type),
        .rx25_dbg_rx_rid       (rx25_dbg_rx_rid),
        .rx25_dbg_rx_len       (rx25_dbg_rx_len),
        // Record-loop position.  These were declared on both sides but never
        // wired at this instantiation, so the BAR read them as floating zeros
        // while 0x58 (a separate port that *was* connected) reported 0x100.
        .rx25_dbg_state        (rx25_dbg_state),
        .rx25_dbg_buf_n        (rx25_dbg_buf_n),
        .rx25_dbg_rec_len      (rx25_dbg_rec_len),
        .rx25_init_tmo_state   (rx25_init_tmo_state),
        .rx25_dbg_buf_w0_lo    (rx25_dbg_buf_w0_lo),
        .rx25_dbg_buf_w0_hi    (rx25_dbg_buf_w0_hi),
        .rx25_dbg_buf_w1_lo    (rx25_dbg_buf_w1_lo),
        .rx25_dbg_buf_w1_hi    (rx25_dbg_buf_w1_hi),
        .rx25_mwr_addr_reg     (rx25_mwr_addr_reg),
        .rx25_mwr_cfg_addr     (rx25_mwr_cfg_addr),
        .rx25_job_valid        (rx25_job_valid),
        .rx25_job_ready        (rx25_job_ready_i),
        .rx25_job_slot         (rx25_job_slot),
        .rx25_job_request_id   (rx25_job_request_id),
        .rx25_job_generation   (rx25_job_generation),
        .rx25_job_length       (rx25_job_length),
        .rx25_job_remote_pa    (rx25_job_remote_pa),
        .rx25_job_host_iova    (rx25_job_host_iova),
        .rx25_cq_valid         (rx25_cq_valid_i && !rx25_cqw_valid),
        .rx25_cq_slot          (rx25_cq_slot_i),
        .rx25_cq_status        (rx25_cq_status_i),
        .rx25_cq_bytes         (rx25_cq_bytes_i),
        .rx25_cq_detail        (rx25_cq_detail_i),
        .rx25_cqw_valid        (rx25_cqw_valid),
        .rx25_cqw_addr         (rx25_cqw_addr),
        .rx25_cqw_data         (rx25_cqw_data),
        .rx25_cqw_index        (rx25_cqw_index),
        .rx25_cqw_done         (rx25_cqw_done)
    );

    // CC only carries completions generated by AMDUSB4 cfgspace/BAR helpers.
    // Raw outbound TLPs from the host command FIFO use the independent RQ path.
    asmcehnk_tlps128_sink_mux1 cc_mux_inst (
        .rst            (rst),
        .clk_pcie       (clk),
        .tlps_out       (tlps_cc_mux.source),
        .tlps_in1       (tlps_cfg_rsp.sink),
        .tlps_in2       (tlps_bar_rsp.sink),
        .tlps_in3       (tlps_null1.sink),
        .tlps_in4       (tlps_null2.sink)
    );

    asmcehnk_tlps128_to_axis_cc_us tlps128_to_cc_inst (
        .clk        (clk),
        .rst        (rst),
        .tlps_in    (tlps_cc_mux.sink),
        .m_axis_cc  (axis_cc_normal)
    );

    asmcehnk_rx25_cc_mux_v2 #(.C_ENABLE(C_RX25_DIAGNOSTIC_V2)) cc_axis_mux_inst (
        .clk             (clk),
        .rst             (rst),
        .external_fault (1'b0),
        .error_in       (axis_cc_error),
        .normal_in      (axis_cc_normal),
        .cc_out         (axis_cc_muxed),
        .fault_now      (),
        .faulted        (),
        .reasons        ()
    );

    asmcehnk_rx25_cc_count_v2 #(.C_ENABLE(C_RX25_DIAGNOSTIC_V2)) cc_count_adapter_inst (
        .clk(clk), .rst(rst), .cc_in(axis_cc_muxed), .cc_out(axis_cc_counted)
    );

    assign m_axis_pcie_cc.tdata  = axis_cc_counted.tdata;
    assign m_axis_pcie_cc.tkeep  = axis_cc_counted.tkeep;
    assign m_axis_pcie_cc.tstrb  = axis_cc_counted.tstrb;
    assign m_axis_pcie_cc.tvalid = axis_cc_counted.tvalid;
    assign m_axis_pcie_cc.tlast  = axis_cc_counted.tlast;
    assign m_axis_pcie_cc.tuser  = axis_cc_counted.tuser;
    assign m_axis_pcie_cc.tid    = axis_cc_counted.tid;
    assign m_axis_pcie_cc.tdest  = axis_cc_counted.tdest;
    assign axis_cc_counted.tready = m_axis_pcie_cc.tready;

    generate
        if (!C_RX25_GUARDED_READER) begin : g_legacy_rc_converter
            asmcehnk_pcie_us_rc_to_tlps128 rc_to_tlps128_inst (
                .clk        (clk),
                .rst        (rst),
                .s_axis_rc  (s_axis_pcie_rc),
                .tlps_out   (tlps_rx_from_rc.source),
                .tag_release       (rc_tag_release),
                .tag_release_valid (rc_tag_release_valid)
            );
        end
    endgenerate

endmodule

module asmcehnk_tlps128_mux2 (
    input  wire logic clk,
    input  wire logic rst,

    IfAXIS128.sink   tlps_in1,
    IfAXIS128.sink   tlps_in2,
    IfAXIS128.source tlps_out
);

    logic [1:0] select_reg = 2'd0;

    wire [1:0] select_next;
    wire       output_fire;

    assign select_next = (select_reg != 2'd0) ? select_reg :
                         tlps_in1.tvalid       ? 2'd1 :
                         tlps_in2.tvalid       ? 2'd2 : 2'd0;
    assign output_fire = tlps_out.tvalid && tlps_out.tready;

    assign tlps_out.tdata = (select_next == 2'd1) ? tlps_in1.tdata :
                            (select_next == 2'd2) ? tlps_in2.tdata : 128'd0;
    assign tlps_out.tkeepdw = (select_next == 2'd1) ? tlps_in1.tkeepdw :
                              (select_next == 2'd2) ? tlps_in2.tkeepdw : 4'd0;
    assign tlps_out.tlast = (select_next == 2'd1) ? tlps_in1.tlast :
                            (select_next == 2'd2) ? tlps_in2.tlast : 1'b0;
    assign tlps_out.tuser = (select_next == 2'd1) ? tlps_in1.tuser :
                            (select_next == 2'd2) ? tlps_in2.tuser : 9'd0;
    assign tlps_out.tvalid = (select_next == 2'd1) ? tlps_in1.tvalid :
                             (select_next == 2'd2) ? tlps_in2.tvalid : 1'b0;
    assign tlps_out.has_data = tlps_in1.has_data || tlps_in2.has_data;

    assign tlps_in1.tready = tlps_out.tready && (select_next == 2'd1);
    assign tlps_in2.tready = tlps_out.tready && (select_next == 2'd2);

    always_ff @(posedge clk) begin
        if (rst) begin
            select_reg <= 2'd0;
        end else if (output_fire && tlps_out.tlast) begin
            select_reg <= 2'd0;
        end else if (select_reg == 2'd0 && select_next != 2'd0) begin
            select_reg <= select_next;
        end
    end

endmodule

module asmcehnk_pcie_us_axis_cc_mux2 (
    input  wire logic clk,
    input  wire logic rst,

    taxi_axis_if.snk s_axis_cc_error,
    taxi_axis_if.snk s_axis_cc_normal,
    taxi_axis_if.src m_axis_cc
);

    logic [1:0] cc_axis_select_reg = 2'd0;

    wire [1:0] cc_axis_select_next;
    wire       cc_axis_output_fire;

    assign cc_axis_select_next = (cc_axis_select_reg != 2'd0) ?
                                 cc_axis_select_reg :
                                 s_axis_cc_error.tvalid ? 2'd1 :
                                 s_axis_cc_normal.tvalid ? 2'd2 : 2'd0;
    assign cc_axis_output_fire = m_axis_cc.tvalid && m_axis_cc.tready;

    assign m_axis_cc.tdata = (cc_axis_select_next == 2'd1) ?
                             s_axis_cc_error.tdata :
                             (cc_axis_select_next == 2'd2) ?
                             s_axis_cc_normal.tdata : 256'd0;
    assign m_axis_cc.tkeep = (cc_axis_select_next == 2'd1) ?
                             s_axis_cc_error.tkeep :
                             (cc_axis_select_next == 2'd2) ?
                             s_axis_cc_normal.tkeep : 8'd0;
    assign m_axis_cc.tstrb = (cc_axis_select_next == 2'd1) ?
                             s_axis_cc_error.tstrb :
                             (cc_axis_select_next == 2'd2) ?
                             s_axis_cc_normal.tstrb : 8'd0;
    assign m_axis_cc.tlast = (cc_axis_select_next == 2'd1) ?
                             s_axis_cc_error.tlast :
                             (cc_axis_select_next == 2'd2) ?
                             s_axis_cc_normal.tlast : 1'b0;
    assign m_axis_cc.tuser = (cc_axis_select_next == 2'd1) ?
                             s_axis_cc_error.tuser :
                             (cc_axis_select_next == 2'd2) ?
                             s_axis_cc_normal.tuser : 33'd0;
    assign m_axis_cc.tid = (cc_axis_select_next == 2'd1) ?
                           s_axis_cc_error.tid :
                           (cc_axis_select_next == 2'd2) ?
                           s_axis_cc_normal.tid : '0;
    assign m_axis_cc.tdest = (cc_axis_select_next == 2'd1) ?
                             s_axis_cc_error.tdest :
                             (cc_axis_select_next == 2'd2) ?
                             s_axis_cc_normal.tdest : '0;
    assign m_axis_cc.tvalid = (cc_axis_select_next == 2'd1) ?
                              s_axis_cc_error.tvalid :
                              (cc_axis_select_next == 2'd2) ?
                              s_axis_cc_normal.tvalid : 1'b0;

    assign s_axis_cc_error.tready = m_axis_cc.tready &&
                                    (cc_axis_select_next == 2'd1);
    assign s_axis_cc_normal.tready = m_axis_cc.tready &&
                                     (cc_axis_select_next == 2'd2);

    always_ff @(posedge clk) begin
        if (rst) begin
            cc_axis_select_reg <= 2'd0;
        end else if (cc_axis_select_reg == 2'd0) begin
            if ((cc_axis_select_next != 2'd0) &&
                !(cc_axis_output_fire && m_axis_cc.tlast)) begin
                cc_axis_select_reg <= cc_axis_select_next;
            end
        end else if (cc_axis_output_fire && m_axis_cc.tlast) begin
            cc_axis_select_reg <= 2'd0;
        end
    end

endmodule

// Two-entry native-CQ queue. Upstream ready uses occupancy only, so neither
// downstream ready nor CQ descriptor data has a combinational path back to IP.
module asmcehnk_pcie_us_cq_ingress (
    input wire logic clk,
    input wire logic rst,
    taxi_axis_if.snk s_axis,
    taxi_axis_if.src m_axis
);
    localparam integer WORD_W = 256+8+8+1+88+s_axis.ID_W+s_axis.DEST_W;
    logic [WORD_W-1:0] q0 = '0, q1 = '0;
    logic [1:0] count = 2'd0;
    wire [WORD_W-1:0] in_word = {s_axis.tdata, s_axis.tkeep, s_axis.tstrb,
        s_axis.tlast, s_axis.tuser, s_axis.tid, s_axis.tdest};
    wire push = s_axis.tvalid && s_axis.tready;
    wire pop = m_axis.tvalid && m_axis.tready;

    assign s_axis.tready = !rst && (count != 2'd2);
    assign m_axis.tvalid = !rst && (count != 2'd0);
    assign {m_axis.tdata, m_axis.tkeep, m_axis.tstrb, m_axis.tlast,
        m_axis.tuser, m_axis.tid, m_axis.tdest} = q0;

    always_ff @(posedge clk) begin
        if (rst) begin
            q0 <= '0;
            q1 <= '0;
            count <= 2'd0;
        end else begin
            case ({push, pop})
                2'b10: begin
                    if (count == 2'd0) q0 <= in_word;
                    else q1 <= in_word;
                    count <= count + 2'd1;
                end
                2'b01: begin
                    q0 <= q1;
                    count <= count - 2'd1;
                end
                2'b11: begin
                    // Simultaneous transfer at occupancy one must replace q0.
                    if (count == 2'd1) q0 <= in_word;
                    else begin q0 <= q1; q1 <= in_word; end
                end
                default: begin end
            endcase
        end
    end
endmodule

module asmcehnk_pcie_us_cq_to_tlps128 #(
    parameter bit C_DIAGNOSTIC_V2 = 1'b0
)(
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic [15:0] pcie_id,

    taxi_axis_if.snk s_axis_cq,
    IfAXIS128.source tlps_out,
    taxi_axis_if.src m_axis_cc_error
);

    // Isolate hard-IP CQ timing from descriptor validation and replay control.
    // Both ready and every beat field cross a local two-entry register queue.
    // Reset discards queued beats; it is not an OS/DMA release guarantee.
    taxi_axis_if #(
        .DATA_W(256), .KEEP_W(8), .KEEP_EN(1), .STRB_EN(1),
        .USER_W(88), .USER_EN(1),
        .ID_W(s_axis_cq.ID_W), .DEST_W(s_axis_cq.DEST_W)
    ) cq_registered();

    asmcehnk_pcie_us_cq_ingress ingress_inst (
        .clk(clk), .rst(rst), .s_axis(s_axis_cq), .m_axis(cq_registered)
    );


    localparam [3:0] REQ_MEM_READ  = 4'b0000;
    localparam [3:0] REQ_MEM_WRITE = 4'b0001;
    localparam integer CQ_CAPTURE_BEATS = 32'd17;

    typedef enum logic [2:0] {
        CQ_WRAP_IDLE,
        CQ_WRAP_CAPTURE,
        CQ_WRAP_REPLAY,
        CQ_WRAP_DRAIN,
        CQ_WRAP_DRAIN_UR
    } cq_wrap_state_t;

    cq_wrap_state_t state_reg = CQ_WRAP_IDLE;

    taxi_axis_if #(
        .DATA_W  (256),
        .KEEP_EN (1),
        .KEEP_W  (8),
        .USER_EN (1),
        .USER_W  (88)
    ) cq_replay();
    IfAXIS128 tlps_stream();

    logic [255:0] capture_data_mem [0:CQ_CAPTURE_BEATS-1];
    logic [7:0]   capture_keep_mem [0:CQ_CAPTURE_BEATS-1];
    logic [87:0]  capture_first_user_reg = 88'd0;
    logic [4:0]   capture_write_index_reg = 5'd0;
    logic [4:0]   capture_last_index_reg = 5'd0;
    logic [4:0]   replay_index_reg = 5'd0;
    logic [10:0]  capture_remaining_reg = 11'd0;

    logic [255:0] error_cc_tdata_reg = 256'd0;
    logic         error_cc_tvalid_reg = 1'b0;

    wire [63:0] wrap_cq_addr;
    wire [10:0] wrap_cq_len_dw;
    wire [3:0]  wrap_cq_type;
    wire [15:0] wrap_cq_requester_id;
    wire [7:0]  wrap_cq_tag;
    wire [2:0]  wrap_cq_tc;
    wire [2:0]  wrap_cq_attr;
    wire [2:0]  cq_first_payload_count;
    wire [3:0]  capture_beat_dw_count;
    wire        cq_first_expected_last;
    wire        capture_expected_last;
    wire        cq_mrd_supported;
    wire        cq_mrd_shape_valid;
    wire        cq_mwr_supported;
    wire        cq_request_is_posted;
    wire        cq_descriptor_valid;
    wire        wrap_cq_fire;
    wire        replay_fire;
    wire        error_cc_fire;

    logic [7:0] cq_first_expected_keep;
    logic [7:0] capture_expected_keep;
    logic [95:0] error_cc_desc_next;
    logic [31:0] error_cc_info_next;
    logic [255:0] error_cc_tdata_next;

    assign wrap_cq_addr = {cq_registered.tdata[63:2], 2'b00};
    assign wrap_cq_len_dw = cq_registered.tdata[74:64];
    assign wrap_cq_type = cq_registered.tdata[78:75];
    assign wrap_cq_requester_id = cq_registered.tdata[95:80];
    assign wrap_cq_tag = cq_registered.tdata[103:96];
    assign wrap_cq_tc = cq_registered.tdata[123:121];
    assign wrap_cq_attr = cq_registered.tdata[126:124];
    assign cq_first_payload_count = (wrap_cq_len_dw >= 11'd4) ? 3'd4 :
                                     wrap_cq_len_dw[2:0];
    assign capture_beat_dw_count = (capture_remaining_reg >= 11'd8) ? 4'd8 :
                                   {1'b0, capture_remaining_reg[2:0]};
    assign cq_first_expected_last = wrap_cq_len_dw <= 11'd4;
    assign capture_expected_last = capture_remaining_reg <= 11'd8;
    assign cq_mrd_supported = (wrap_cq_type == REQ_MEM_READ) &&
                              (wrap_cq_addr[63:32] == 32'd0) &&
                              (wrap_cq_len_dw != 11'd0);
    assign cq_mrd_shape_valid = (cq_registered.tkeep == 8'h0f) &&
                                cq_registered.tlast;
    // The active PCIe4 profile advertises a 512-byte maximum payload, so all
    // legal CQ MWr packets fit in one 17-beat native capture buffer.
    assign cq_mwr_supported = (wrap_cq_type == REQ_MEM_WRITE) &&
                              (wrap_cq_addr[63:32] == 32'd0) &&
                              (wrap_cq_len_dw != 11'd0) &&
                              (wrap_cq_len_dw <= 11'd128);
    assign cq_request_is_posted = (wrap_cq_type == REQ_MEM_WRITE) ||
                                   ((wrap_cq_type & 4'b1100) == 4'b1100);
    assign cq_descriptor_valid = (cq_registered.tkeep[3:0] == 4'hf);
    assign wrap_cq_fire = cq_registered.tvalid && cq_registered.tready;
    assign replay_fire = cq_replay.tvalid && cq_replay.tready;
    assign error_cc_fire = error_cc_tvalid_reg && m_axis_cc_error.tready;

    always_comb begin
        case (cq_first_payload_count)
            3'd1: cq_first_expected_keep = 8'b0001_1111;
            3'd2: cq_first_expected_keep = 8'b0011_1111;
            3'd3: cq_first_expected_keep = 8'b0111_1111;
            3'd4: cq_first_expected_keep = 8'b1111_1111;
            default: cq_first_expected_keep = 8'b0000_1111;
        endcase
    end

    always_comb begin
        case (capture_beat_dw_count)
            4'd1: capture_expected_keep = 8'b0000_0001;
            4'd2: capture_expected_keep = 8'b0000_0011;
            4'd3: capture_expected_keep = 8'b0000_0111;
            4'd4: capture_expected_keep = 8'b0000_1111;
            4'd5: capture_expected_keep = 8'b0001_1111;
            4'd6: capture_expected_keep = 8'b0011_1111;
            4'd7: capture_expected_keep = 8'b0111_1111;
            4'd8: capture_expected_keep = 8'b1111_1111;
            default: capture_expected_keep = 8'b0000_0000;
        endcase
    end

    always_comb begin
        error_cc_desc_next = 96'd0;
        error_cc_desc_next[28:16] = 13'd20;
        error_cc_desc_next[42:32] = 11'd5;
        error_cc_desc_next[45:43] = 3'b001;
        error_cc_desc_next[63:48] = wrap_cq_requester_id;
        error_cc_desc_next[71:64] = wrap_cq_tag;
        error_cc_desc_next[87:72] = C_DIAGNOSTIC_V2 ? {pcie_id[7:0], pcie_id[15:8]} : pcie_id;
        error_cc_desc_next[88] = 1'b1;
        error_cc_desc_next[91:89] = wrap_cq_tc;
        error_cc_desc_next[94:92] = wrap_cq_attr;

        error_cc_info_next = {8'b0, cq_registered.tuser[52:45], 5'b0,
                              cq_registered.tuser[44:43], cq_registered.tuser[42],
                              cq_registered.tuser[7:0]};
        error_cc_tdata_next = {cq_registered.tdata[127:0], error_cc_info_next,
                               error_cc_desc_next};
    end

    always_comb begin
        cq_replay.tdata = 256'd0;
        cq_replay.tkeep = 8'd0;
        cq_replay.tstrb = 8'd0;
        cq_replay.tvalid = 1'b0;
        cq_replay.tlast = 1'b0;
        cq_replay.tuser = 88'd0;
        cq_replay.tid = '0;
        cq_replay.tdest = '0;
        cq_registered.tready = 1'b0;

        case (state_reg)
            CQ_WRAP_IDLE: begin
                if (!tlps_stream.has_data && !error_cc_tvalid_reg) begin
                    if (cq_mrd_supported && cq_mrd_shape_valid) begin
                        cq_replay.tdata = cq_registered.tdata;
                        cq_replay.tkeep = cq_registered.tkeep;
                        cq_replay.tstrb = cq_registered.tstrb;
                        cq_replay.tvalid = cq_registered.tvalid;
                        cq_replay.tlast = cq_registered.tlast;
                        cq_replay.tuser = cq_registered.tuser;
                        cq_replay.tid = cq_registered.tid;
                        cq_replay.tdest = cq_registered.tdest;
                        cq_registered.tready = cq_replay.tready;
                    end else begin
                        cq_registered.tready = 1'b1;
                    end
                end
            end
            CQ_WRAP_CAPTURE,
            CQ_WRAP_DRAIN,
            CQ_WRAP_DRAIN_UR: cq_registered.tready = 1'b1;
            CQ_WRAP_REPLAY: begin
                cq_replay.tdata = capture_data_mem[replay_index_reg];
                cq_replay.tkeep = capture_keep_mem[replay_index_reg];
                cq_replay.tstrb = capture_keep_mem[replay_index_reg];
                cq_replay.tvalid = 1'b1;
                cq_replay.tlast = replay_index_reg == capture_last_index_reg;
                cq_replay.tuser = (replay_index_reg == 5'd0) ?
                                  capture_first_user_reg : 88'd0;
            end
            default: cq_registered.tready = 1'b0;
        endcase
    end

    assign tlps_out.tdata = tlps_stream.tdata;
    assign tlps_out.tkeepdw = tlps_stream.tkeepdw;
    assign tlps_out.tvalid = tlps_stream.tvalid;
    assign tlps_out.tlast = tlps_stream.tlast;
    assign tlps_out.tuser = tlps_stream.tuser;
    assign tlps_out.has_data = tlps_stream.has_data;
    assign tlps_stream.tready = tlps_out.tready;

    assign m_axis_cc_error.tdata = error_cc_tdata_reg;
    assign m_axis_cc_error.tkeep = 8'hff;
    assign m_axis_cc_error.tstrb = 8'hff;
    assign m_axis_cc_error.tvalid = error_cc_tvalid_reg;
    assign m_axis_cc_error.tlast = 1'b1;
    assign m_axis_cc_error.tuser = 33'd0;
    assign m_axis_cc_error.tid = '0;
    assign m_axis_cc_error.tdest = '0;

    asmcehnk_pcie_us_cq_to_tlps128_stream stream_inst (
        .clk       (clk),
        .rst       (rst),
        .s_axis_cq (cq_replay),
        .tlps_out  (tlps_stream.source)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg <= CQ_WRAP_IDLE;
            capture_first_user_reg <= 88'd0;
            capture_write_index_reg <= 5'd0;
            capture_last_index_reg <= 5'd0;
            replay_index_reg <= 5'd0;
            capture_remaining_reg <= 11'd0;
            error_cc_tdata_reg <= 256'd0;
            error_cc_tvalid_reg <= 1'b0;
        end else begin
            if (error_cc_fire) begin
                error_cc_tvalid_reg <= 1'b0;
            end

            case (state_reg)
                CQ_WRAP_IDLE: begin
                    if (wrap_cq_fire) begin
                        if (cq_mwr_supported) begin
                            capture_data_mem[0] <= cq_registered.tdata;
                            capture_keep_mem[0] <= cq_registered.tkeep;
                            capture_first_user_reg <= cq_registered.tuser;
                            if ((cq_registered.tkeep == cq_first_expected_keep) &&
                                (cq_registered.tlast == cq_first_expected_last)) begin
                                if (cq_registered.tlast) begin
                                    capture_last_index_reg <= 5'd0;
                                    replay_index_reg <= 5'd0;
                                    state_reg <= CQ_WRAP_REPLAY;
                                end else begin
                                    capture_write_index_reg <= 5'd1;
                                    capture_remaining_reg <= wrap_cq_len_dw -
                                                             cq_first_payload_count;
                                    state_reg <= CQ_WRAP_CAPTURE;
                                end
                            end else begin
                                state_reg <= cq_registered.tlast ? CQ_WRAP_IDLE :
                                                               CQ_WRAP_DRAIN;
                            end
                        end else if (cq_mrd_supported) begin
                            state_reg <= cq_registered.tlast ? CQ_WRAP_IDLE :
                                                           CQ_WRAP_DRAIN;
                        end else if (cq_request_is_posted) begin
                            state_reg <= cq_registered.tlast ? CQ_WRAP_IDLE :
                                                           CQ_WRAP_DRAIN;
                        end else if (cq_descriptor_valid && cq_registered.tlast) begin
                            error_cc_tdata_reg <= error_cc_tdata_next;
                            error_cc_tvalid_reg <= 1'b1;
                        end else if (cq_descriptor_valid) begin
                            error_cc_tdata_reg <= error_cc_tdata_next;
                            state_reg <= CQ_WRAP_DRAIN_UR;
                        end else begin
                            state_reg <= cq_registered.tlast ? CQ_WRAP_IDLE :
                                                           CQ_WRAP_DRAIN;
                        end
                    end
                end
                CQ_WRAP_CAPTURE: begin
                    if (wrap_cq_fire) begin
                        if ((cq_registered.tkeep == capture_expected_keep) &&
                            (cq_registered.tlast == capture_expected_last)) begin
                            capture_data_mem[capture_write_index_reg] <=
                                cq_registered.tdata;
                            capture_keep_mem[capture_write_index_reg] <=
                                cq_registered.tkeep;
                            if (cq_registered.tlast) begin
                                capture_last_index_reg <= capture_write_index_reg;
                                replay_index_reg <= 5'd0;
                                state_reg <= CQ_WRAP_REPLAY;
                            end else begin
                                capture_write_index_reg <=
                                    capture_write_index_reg + 1'b1;
                                capture_remaining_reg <= capture_remaining_reg -
                                                         capture_beat_dw_count;
                            end
                        end else begin
                            state_reg <= cq_registered.tlast ? CQ_WRAP_IDLE :
                                                           CQ_WRAP_DRAIN;
                        end
                    end
                end
                CQ_WRAP_REPLAY: begin
                    if (replay_fire) begin
                        if (replay_index_reg == capture_last_index_reg) begin
                            state_reg <= CQ_WRAP_IDLE;
                        end else begin
                            replay_index_reg <= replay_index_reg + 1'b1;
                        end
                    end
                end
                CQ_WRAP_DRAIN: begin
                    if (wrap_cq_fire && cq_registered.tlast) begin
                        state_reg <= CQ_WRAP_IDLE;
                    end
                end
                CQ_WRAP_DRAIN_UR: begin
                    if (wrap_cq_fire && cq_registered.tlast) begin
                        error_cc_tvalid_reg <= 1'b1;
                        state_reg <= CQ_WRAP_IDLE;
                    end
                end
                default: state_reg <= CQ_WRAP_IDLE;
            endcase
        end
    end

endmodule
module asmcehnk_pcie_us_cq_to_tlps128_stream (
    input  wire logic clk,
    input  wire logic rst,

    taxi_axis_if.snk s_axis_cq,
    IfAXIS128.source tlps_out
);

    localparam [3:0] REQ_MEM_READ  = 4'b0000;
    localparam [3:0] REQ_MEM_WRITE = 4'b0001;

    typedef enum logic [1:0] {
        CQ_STATE_IDLE,
        CQ_STATE_FLUSH,
        CQ_STATE_PAYLOAD,
        CQ_STATE_DRAIN
    } cq_state_t;

    cq_state_t state_reg = CQ_STATE_IDLE;

    logic [127:0] out_tdata_reg = '0;
    logic [3:0]   out_tkeepdw_reg = '0;
    logic         out_tvalid_reg = 1'b0;
    logic         out_tlast_reg = 1'b0;
    logic [8:0]   out_tuser_reg = '0;

    logic [127:0] pending_data_reg = '0;
    logic [2:0]   pending_count_reg = '0;
    logic         pending_last_reg = 1'b0;
    logic [10:0]  remaining_dw_reg = '0;

    assign tlps_out.tdata   = out_tdata_reg;
    assign tlps_out.tkeepdw = out_tkeepdw_reg;
    assign tlps_out.tvalid  = out_tvalid_reg;
    assign tlps_out.tlast   = out_tlast_reg;
    assign tlps_out.tuser   = out_tuser_reg;
    assign tlps_out.has_data = out_tvalid_reg || (state_reg != CQ_STATE_IDLE);

    wire cq_output_ready;

    assign cq_output_ready = !out_tvalid_reg || tlps_out.tready;
    assign s_axis_cq.tready = cq_output_ready &&
                              ((state_reg == CQ_STATE_IDLE) ||
                               (state_reg == CQ_STATE_PAYLOAD) ||
                               (state_reg == CQ_STATE_DRAIN));

    wire        cq_fire;
    wire [63:0] cq_addr;
    wire [10:0] cq_len_dw;
    wire [9:0]  cq_len10;
    wire [3:0]  cq_type;
    wire [15:0] cq_requester_id;
    wire [7:0]  cq_tag;
    wire [2:0]  cq_bar_id;
    wire [2:0]  cq_tc;
    wire [2:0]  cq_attr;
    wire [3:0]  cq_first_be;
    wire [3:0]  cq_last_be;
    wire [31:0] cq_payload_dw0_swap;
    wire [31:0] cq_payload_dw1_swap;
    wire [31:0] cq_payload_dw2_swap;
    wire [31:0] cq_payload_dw3_swap;
    wire [31:0] cq_payload_dw4_swap;
    wire [31:0] cq_payload_dw5_swap;
    wire [31:0] cq_payload_dw6_swap;
    wire [31:0] cq_payload_dw7_swap;

    logic [6:0]  cq_bar_onehot;
    logic [31:0] cq_raw_mem_read_dw0;
    logic [31:0] cq_raw_mem_write_dw0;

    assign cq_fire = s_axis_cq.tvalid && s_axis_cq.tready;
    assign cq_addr = {s_axis_cq.tdata[63:2], 2'b00};
    assign cq_len_dw = s_axis_cq.tdata[74:64];
    assign cq_len10 = cq_len_dw[10] ? 10'd0 : cq_len_dw[9:0];
    assign cq_type = s_axis_cq.tdata[78:75];
    assign cq_requester_id = s_axis_cq.tdata[95:80];
    assign cq_tag = s_axis_cq.tdata[103:96];
    assign cq_bar_id = s_axis_cq.tdata[114:112];
    assign cq_tc = s_axis_cq.tdata[123:121];
    assign cq_attr = s_axis_cq.tdata[126:124];
    assign cq_first_be = s_axis_cq.tuser[3:0];
    assign cq_last_be = s_axis_cq.tuser[7:4];
    assign cq_payload_dw0_swap = {s_axis_cq.tdata[135:128], s_axis_cq.tdata[143:136], s_axis_cq.tdata[151:144], s_axis_cq.tdata[159:152]};
    assign cq_payload_dw1_swap = {s_axis_cq.tdata[167:160], s_axis_cq.tdata[175:168], s_axis_cq.tdata[183:176], s_axis_cq.tdata[191:184]};
    assign cq_payload_dw2_swap = {s_axis_cq.tdata[199:192], s_axis_cq.tdata[207:200], s_axis_cq.tdata[215:208], s_axis_cq.tdata[223:216]};
    assign cq_payload_dw3_swap = {s_axis_cq.tdata[231:224], s_axis_cq.tdata[239:232], s_axis_cq.tdata[247:240], s_axis_cq.tdata[255:248]};
    assign cq_payload_dw4_swap = {s_axis_cq.tdata[7:0], s_axis_cq.tdata[15:8], s_axis_cq.tdata[23:16], s_axis_cq.tdata[31:24]};
    assign cq_payload_dw5_swap = {s_axis_cq.tdata[39:32], s_axis_cq.tdata[47:40], s_axis_cq.tdata[55:48], s_axis_cq.tdata[63:56]};
    assign cq_payload_dw6_swap = {s_axis_cq.tdata[71:64], s_axis_cq.tdata[79:72], s_axis_cq.tdata[87:80], s_axis_cq.tdata[95:88]};
    assign cq_payload_dw7_swap = {s_axis_cq.tdata[103:96], s_axis_cq.tdata[111:104], s_axis_cq.tdata[119:112], s_axis_cq.tdata[127:120]};

    always_comb begin
        case (cq_bar_id)
            3'd0: cq_bar_onehot = 7'b0000001;
            3'd1: cq_bar_onehot = 7'b0000010;
            3'd2: cq_bar_onehot = 7'b0000100;
            3'd3: cq_bar_onehot = 7'b0001000;
            3'd4: cq_bar_onehot = 7'b0010000;
            3'd5: cq_bar_onehot = 7'b0100000;
            default: cq_bar_onehot = 7'b1000000;
        endcase
    end

    always_comb begin
        cq_raw_mem_read_dw0 = {3'b000, 5'b00000, 1'b0, cq_tc, 1'b0, cq_attr[2],
                               1'b0, 1'b0, 1'b0, 1'b0, cq_attr[1:0], 2'b00, cq_len10};
        cq_raw_mem_write_dw0 = {3'b010, 5'b00000, 1'b0, cq_tc, 1'b0, cq_attr[2],
                                1'b0, 1'b0, 1'b0, 1'b0, cq_attr[1:0], 2'b00, cq_len10};
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg <= CQ_STATE_IDLE;
            out_tdata_reg <= '0;
            out_tkeepdw_reg <= '0;
            out_tvalid_reg <= 1'b0;
            out_tlast_reg <= 1'b0;
            out_tuser_reg <= '0;
            pending_data_reg <= '0;
            pending_count_reg <= '0;
            pending_last_reg <= 1'b0;
            remaining_dw_reg <= '0;
        end else if (cq_output_ready) begin
            out_tvalid_reg <= 1'b0;
            out_tdata_reg <= '0;
            out_tkeepdw_reg <= '0;
            out_tlast_reg <= 1'b0;
            out_tuser_reg <= '0;

            case (state_reg)
                CQ_STATE_IDLE: begin
                    if (cq_fire) begin
                        if ((cq_type == REQ_MEM_READ) && (cq_addr[63:32] == 32'd0) && (cq_len_dw != 11'd0)) begin
                            out_tdata_reg[31:0]  <= cq_raw_mem_read_dw0;
                            out_tdata_reg[63:32] <= {cq_requester_id, cq_tag, cq_last_be, cq_first_be};
                            out_tdata_reg[95:64] <= {cq_addr[31:2], 2'b00};
                            out_tdata_reg[127:96] <= 32'd0;
                            out_tkeepdw_reg <= 4'b0111;
                            out_tlast_reg <= 1'b1;
                            out_tvalid_reg <= 1'b1;
                            out_tuser_reg <= {cq_bar_onehot, 1'b1, 1'b1};
                            state_reg <= s_axis_cq.tlast ? CQ_STATE_IDLE : CQ_STATE_DRAIN;
                        end else if ((cq_type == REQ_MEM_WRITE) && (cq_addr[63:32] == 32'd0) && (cq_len_dw != 11'd0)) begin
                            logic [2:0] first_count;
                            logic [10:0] rem_after_first;
                            if (cq_len_dw > 11'd4) begin
                                first_count = 3'd4;
                            end else begin
                                first_count = cq_len_dw[2:0];
                            end
                            rem_after_first = cq_len_dw - first_count;

                            out_tdata_reg[31:0]  <= cq_raw_mem_write_dw0;
                            out_tdata_reg[63:32] <= {cq_requester_id, cq_tag, cq_last_be, cq_first_be};
                            out_tdata_reg[95:64] <= {cq_addr[31:2], 2'b00};
                            out_tdata_reg[127:96] <= cq_payload_dw0_swap;
                            out_tkeepdw_reg <= 4'b1111;
                            out_tlast_reg <= (cq_len_dw == 11'd1) && s_axis_cq.tlast;
                            out_tvalid_reg <= 1'b1;
                            out_tuser_reg <= {cq_bar_onehot, ((cq_len_dw == 11'd1) && s_axis_cq.tlast), 1'b1};

                            pending_data_reg[31:0]   <= cq_payload_dw1_swap;
                            pending_data_reg[63:32]  <= cq_payload_dw2_swap;
                            pending_data_reg[95:64]  <= cq_payload_dw3_swap;
                            pending_data_reg[127:96] <= 32'd0;
                            pending_count_reg <= (first_count == 3'd0) ? 3'd0 : (first_count - 3'd1);
                            pending_last_reg <= (rem_after_first == 11'd0) && s_axis_cq.tlast;
                            remaining_dw_reg <= rem_after_first;

                            if (first_count > 3'd1) begin
                                state_reg <= CQ_STATE_FLUSH;
                            end else if (rem_after_first != 11'd0) begin
                                state_reg <= CQ_STATE_PAYLOAD;
                            end else begin
                                state_reg <= s_axis_cq.tlast ? CQ_STATE_IDLE : CQ_STATE_DRAIN;
                            end
                        end else begin
                            // Unsupported CQ request for this first BAR gate.
                            state_reg <= s_axis_cq.tlast ? CQ_STATE_IDLE : CQ_STATE_DRAIN;
                        end
                    end
                end
                CQ_STATE_FLUSH: begin
                    out_tdata_reg <= pending_data_reg;
                    case (pending_count_reg)
                        3'd0: out_tkeepdw_reg <= 4'b0000;
                        3'd1: out_tkeepdw_reg <= 4'b0001;
                        3'd2: out_tkeepdw_reg <= 4'b0011;
                        3'd3: out_tkeepdw_reg <= 4'b0111;
                        default: out_tkeepdw_reg <= 4'b1111;
                    endcase
                    out_tlast_reg <= pending_last_reg;
                    out_tvalid_reg <= (pending_count_reg != 3'd0);
                    out_tuser_reg <= {7'd0, pending_last_reg, 1'b0};
                    pending_count_reg <= 3'd0;
                    pending_last_reg <= 1'b0;

                    if (remaining_dw_reg != 11'd0) begin
                        state_reg <= CQ_STATE_PAYLOAD;
                    end else begin
                        state_reg <= pending_last_reg ? CQ_STATE_IDLE : CQ_STATE_DRAIN;
                    end
                end
                CQ_STATE_PAYLOAD: begin
                    if (cq_fire) begin
                        logic [2:0] lower_count;
                        logic [2:0] upper_count;
                        logic [10:0] rem_after_lower;
                        logic [10:0] rem_after_beat;
                        if (remaining_dw_reg > 11'd4) begin
                            lower_count = 3'd4;
                        end else begin
                            lower_count = remaining_dw_reg[2:0];
                        end
                        rem_after_lower = remaining_dw_reg - lower_count;
                        if (rem_after_lower > 11'd4) begin
                            upper_count = 3'd4;
                        end else begin
                            upper_count = rem_after_lower[2:0];
                        end
                        rem_after_beat = rem_after_lower - upper_count;

                        out_tdata_reg[31:0]   <= cq_payload_dw4_swap;
                        out_tdata_reg[63:32]  <= cq_payload_dw5_swap;
                        out_tdata_reg[95:64]  <= cq_payload_dw6_swap;
                        out_tdata_reg[127:96] <= cq_payload_dw7_swap;
                        case (lower_count)
                            3'd0: out_tkeepdw_reg <= 4'b0000;
                            3'd1: out_tkeepdw_reg <= 4'b0001;
                            3'd2: out_tkeepdw_reg <= 4'b0011;
                            3'd3: out_tkeepdw_reg <= 4'b0111;
                            default: out_tkeepdw_reg <= 4'b1111;
                        endcase
                        out_tlast_reg <= (upper_count == 3'd0) && (rem_after_beat == 11'd0) && s_axis_cq.tlast;
                        out_tvalid_reg <= (lower_count != 3'd0);
                        out_tuser_reg <= {7'd0, ((upper_count == 3'd0) && (rem_after_beat == 11'd0) && s_axis_cq.tlast), 1'b0};

                        pending_data_reg[31:0]   <= cq_payload_dw0_swap;
                        pending_data_reg[63:32]  <= cq_payload_dw1_swap;
                        pending_data_reg[95:64]  <= cq_payload_dw2_swap;
                        pending_data_reg[127:96] <= cq_payload_dw3_swap;
                        pending_count_reg <= upper_count;
                        pending_last_reg <= (upper_count != 3'd0) && (rem_after_beat == 11'd0) && s_axis_cq.tlast;
                        remaining_dw_reg <= rem_after_beat;

                        if (upper_count != 3'd0) begin
                            state_reg <= CQ_STATE_FLUSH;
                        end else if (rem_after_beat != 11'd0) begin
                            state_reg <= CQ_STATE_PAYLOAD;
                        end else begin
                            state_reg <= s_axis_cq.tlast ? CQ_STATE_IDLE : CQ_STATE_DRAIN;
                        end
                    end
                end
                CQ_STATE_DRAIN: begin
                    if (cq_fire && s_axis_cq.tlast) begin
                        state_reg <= CQ_STATE_IDLE;
                    end
                end
                default: state_reg <= CQ_STATE_IDLE;
            endcase
        end
    end

endmodule


module asmcehnk_tlps128_to_axis_rq_us #(
    parameter RQ_SEQ_NUM_W = 6
)(
    input  wire logic clk,
    input  wire logic rst,

    IfAXIS128.sink   tlps_in,
    taxi_axis_if.src m_axis_rq,

    input wire logic [RQ_SEQ_NUM_W-1:0] pcie_rq_seq_num0,
    input wire logic                    pcie_rq_seq_num_vld0,
    input wire logic [RQ_SEQ_NUM_W-1:0] pcie_rq_seq_num1,
    input wire logic                    pcie_rq_seq_num_vld1,

    input wire logic [7:0]              rc_tag_release,
    input wire logic                    rc_tag_release_valid,

    output wire logic [RQ_SEQ_NUM_W:0]  status_outstanding,
    output wire logic                   status_blocked,
    output wire logic                   status_error,
    output wire logic                   status_tag_blocked,
    output wire logic                   status_tag_error
);

    localparam int RQ_USER_W = m_axis_rq.USER_W;
    localparam int RQ_SEQ_COUNT = 1 << RQ_SEQ_NUM_W;
    localparam int RQ_OUTSTANDING_LIMIT = 1 << (RQ_SEQ_NUM_W-1);

    localparam [3:0] REQ_MEM_READ  = 4'b0000;
    localparam [3:0] REQ_MEM_WRITE = 4'b0001;

    typedef enum logic [1:0] {
        RQ_STATE_IDLE,
        RQ_STATE_PAYLOAD,
        RQ_STATE_DRAIN
    } rq_state_t;

    rq_state_t state_reg = RQ_STATE_IDLE;

    // m_axis_rq is 256 bit but tlps_in is 128 bit, so the write payload has to
    // be packed two beats at a time.  Feeding the core a half-empty beat in the
    // middle of a TLP makes it assemble a short TLP that the root complex drops
    // without a trace: a posted write has no completion, so the card never
    // learns.  That is exactly what happened on 2026-11-02 -- correct
    // descriptor, correct address, zero bytes in host memory.
    logic [127:0] pay_hold = '0;
    logic [127:0] desc_hold = '0;
    // rq_tuser_next carries the First/Last DW BE taken from the header's dw1.
    // Once the descriptor is emitted together with a payload beat, raw_dw1 is
    // payload data, so the BE must be latched at header time or it comes out
    // as garbage and the core masks the first and last dword of every TLP
    // (that is exactly what p21 measured: only offset 0x0 and 0xFC missing).
    logic [RQ_USER_W-1:0] tuser_hold = '0;
    // 0 = waiting for the low half of a pair
    // 1 = low half parked, next beat completes the pair
    // 2 = descriptor parked, the next payload beat is emitted with it
    logic [1:0]   pay_phase = 2'd0;

    logic [255:0] out_tdata_reg = '0;
    logic [7:0]   out_tkeep_reg = '0;

    // tkeep for a beat that carries the descriptor plus some payload dwords.
    // The descriptor always fills lanes 0..3; payload fills lanes 4..(3+N).
    // Reporting 0xFF for a 1-dword write tells the core that 32 bytes are
    // present, and it writes all 32 -- which lands on top of the neighbouring
    // CQ dwords and shows up as "CQ dword 2 is zero".
    function automatic [7:0] folded_keep(input logic [2:0] payload_dw);
        case (payload_dw)
            3'd0:    folded_keep = 8'b0000_1111;
            3'd1:    folded_keep = 8'b0001_1111;
            3'd2:    folded_keep = 8'b0011_1111;
            3'd3:    folded_keep = 8'b0111_1111;
            default: folded_keep = 8'b1111_1111;
        endcase
    endfunction

    logic [RQ_USER_W-1:0] out_tuser_reg = '0;
    logic         out_tlast_reg = 1'b0;
    logic         out_tvalid_reg = 1'b0;

    logic [RQ_SEQ_NUM_W-1:0] seq_alloc_reg = '0;
    logic [RQ_SEQ_COUNT-1:0] seq_pending_reg = '0;
    logic [RQ_SEQ_COUNT-1:0] seq_pending_next;
    logic [RQ_SEQ_NUM_W:0]   seq_outstanding_reg = '0;
    logic [RQ_SEQ_NUM_W:0]   seq_outstanding_next;
    logic                    seq_error_reg = 1'b0;
    logic [255:0]            tag_pending_reg = '0;
    logic [255:0]            tag_pending_next;
    logic                    tag_error_reg = 1'b0;

    assign m_axis_rq.tdata = out_tdata_reg;
    assign m_axis_rq.tkeep = out_tkeep_reg;
    assign m_axis_rq.tstrb = out_tkeep_reg;
    assign m_axis_rq.tuser = out_tuser_reg;
    assign m_axis_rq.tlast = out_tlast_reg;
    assign m_axis_rq.tvalid = out_tvalid_reg;
    assign m_axis_rq.tid = '0;
    assign m_axis_rq.tdest = '0;

    wire output_ready;
    wire rq_input_fire;
    wire rq_start_needs_credit;
    wire rq_credit_available;
    wire rq_seq_launch;
    wire rq_seq_ack0;
    wire rq_seq_ack1;
    wire rq_tag_launch;
    wire rq_tag_blocked;
    wire rc_tag_release_known;
    wire [31:0] raw_dw0;
    wire [31:0] raw_dw1;
    wire [31:0] raw_dw2;
    wire [31:0] raw_dw3;
    wire [2:0]  raw_fmt;
    wire [4:0]  raw_type;
    wire [9:0]  raw_len10;
    wire [10:0] raw_len10_ext;
    wire [10:0] raw_len11;
    wire        raw_is_4dw;
    wire        raw_is_mrd;
    wire        raw_is_mwr;
    wire        raw_hdr_present;
    wire [31:0] raw_dw0_swap;
    wire [31:0] raw_dw1_swap;
    wire [31:0] raw_dw2_swap;
    wire [31:0] raw_dw3_swap;
    wire [63:0] raw_addr64;
    wire [7:0]  raw_tag;

    logic [127:0] rq_desc_read;
    logic [127:0] rq_desc_write;
    logic [RQ_USER_W-1:0] rq_tuser_next;

    assign output_ready = !out_tvalid_reg || m_axis_rq.tready;
    assign rq_start_needs_credit = (state_reg == RQ_STATE_IDLE) &&
                                   tlps_in.tvalid && raw_hdr_present &&
                                   (raw_is_mrd || raw_is_mwr);
    assign rq_credit_available = (seq_outstanding_reg < RQ_OUTSTANDING_LIMIT) &&
                                 !seq_pending_reg[seq_alloc_reg];
    assign rq_tag_blocked = (state_reg == RQ_STATE_IDLE) &&
                            tlps_in.tvalid && raw_hdr_present && raw_is_mrd &&
                            tag_pending_reg[raw_tag];
    assign tlps_in.tready = output_ready &&
                            (!rq_start_needs_credit || rq_credit_available) &&
                            !rq_tag_blocked;

    assign rq_input_fire = tlps_in.tvalid && tlps_in.tready;
    assign raw_dw0 = tlps_in.tdata[31:0];
    assign raw_dw1 = tlps_in.tdata[63:32];
    assign raw_dw2 = tlps_in.tdata[95:64];
    assign raw_dw3 = tlps_in.tdata[127:96];
    assign raw_fmt = raw_dw0[31:29];
    assign raw_type = raw_dw0[28:24];
    assign raw_len10 = raw_dw0[9:0];
    assign raw_len10_ext = {1'b0, raw_len10};
    assign raw_len11 = (raw_len10_ext == 11'd0) ? 11'd1024 : raw_len10_ext;
    assign raw_is_4dw = raw_fmt[0];
    assign raw_is_mrd = (raw_type == 5'b00000) && ((raw_fmt == 3'b000) || (raw_fmt == 3'b001));
    assign raw_is_mwr = (raw_type == 5'b00000) && ((raw_fmt == 3'b010) || (raw_fmt == 3'b011));
    assign raw_hdr_present = tlps_in.tuser[0] && tlps_in.tkeepdw[0] && tlps_in.tkeepdw[1] &&
                             tlps_in.tkeepdw[2] && (!raw_is_4dw || tlps_in.tkeepdw[3]);
    assign raw_dw0_swap = {tlps_in.tdata[7:0], tlps_in.tdata[15:8], tlps_in.tdata[23:16], tlps_in.tdata[31:24]};
    assign raw_dw1_swap = {tlps_in.tdata[39:32], tlps_in.tdata[47:40], tlps_in.tdata[55:48], tlps_in.tdata[63:56]};
    assign raw_dw2_swap = {tlps_in.tdata[71:64], tlps_in.tdata[79:72], tlps_in.tdata[87:80], tlps_in.tdata[95:88]};
    assign raw_dw3_swap = {tlps_in.tdata[103:96], tlps_in.tdata[111:104], tlps_in.tdata[119:112], tlps_in.tdata[127:120]};
    assign raw_addr64 = raw_is_4dw ? {raw_dw2, raw_dw3[31:2], 2'b00} :
                                    {32'd0, raw_dw2[31:2], 2'b00};
    assign raw_tag = raw_dw1[15:8];

    assign rq_seq_launch = rq_input_fire && (state_reg == RQ_STATE_IDLE) &&
                           raw_hdr_present && (raw_is_mrd || raw_is_mwr);
    assign rq_tag_launch = rq_seq_launch && raw_is_mrd;
    assign rq_seq_ack0 = pcie_rq_seq_num_vld0 &&
                         seq_pending_reg[pcie_rq_seq_num0];
    assign rq_seq_ack1 = pcie_rq_seq_num_vld1 &&
                         seq_pending_reg[pcie_rq_seq_num1] &&
                         !(pcie_rq_seq_num_vld0 &&
                           (pcie_rq_seq_num0 == pcie_rq_seq_num1));
    assign status_outstanding = seq_outstanding_reg;
    assign status_blocked = rq_start_needs_credit && !rq_credit_available;
    assign status_error = seq_error_reg;
    assign status_tag_blocked = rq_tag_blocked;
    assign status_tag_error = tag_error_reg;
    assign rc_tag_release_known = rc_tag_release_valid &&
                                  tag_pending_reg[rc_tag_release];

    always_comb begin
        seq_pending_next = seq_pending_reg;
        seq_outstanding_next = seq_outstanding_reg;

        if (rq_seq_ack0) begin
            seq_pending_next[pcie_rq_seq_num0] = 1'b0;
            seq_outstanding_next = seq_outstanding_next - 1'b1;
        end
        if (rq_seq_ack1) begin
            seq_pending_next[pcie_rq_seq_num1] = 1'b0;
            seq_outstanding_next = seq_outstanding_next - 1'b1;
        end
        if (rq_seq_launch) begin
            seq_pending_next[seq_alloc_reg] = 1'b1;
            seq_outstanding_next = seq_outstanding_next + 1'b1;
        end
    end

    always_comb begin
        tag_pending_next = tag_pending_reg;

        if (rc_tag_release_known) begin
            tag_pending_next[rc_tag_release] = 1'b0;
        end
        if (rq_tag_launch) begin
            tag_pending_next[raw_tag] = 1'b1;
        end
    end

    always_comb begin
        rq_desc_read = '0;
        rq_desc_read[1:0] = raw_dw0[11:10];
        rq_desc_read[63:2] = raw_addr64[63:2];
        rq_desc_read[74:64] = raw_len11;
        rq_desc_read[78:75] = REQ_MEM_READ;
        rq_desc_read[79] = raw_dw0[14];
        rq_desc_read[95:80] = raw_dw1[31:16];
        rq_desc_read[103:96] = raw_dw1[15:8];
        rq_desc_read[119:104] = 16'd0;
        rq_desc_read[120] = 1'b0;
        rq_desc_read[123:121] = raw_dw0[22:20];
        rq_desc_read[126:124] = {raw_dw0[18], raw_dw0[13:12]};
        rq_desc_read[127] = 1'b0;

        rq_desc_write = rq_desc_read;
        rq_desc_write[78:75] = REQ_MEM_WRITE;
    end

    always_comb begin
        rq_tuser_next = '0;
        rq_tuser_next[3:0] = raw_dw1[3:0];
        rq_tuser_next[7:4] = raw_dw1[7:4];
        rq_tuser_next[10:8] = 3'd0;
        rq_tuser_next[11] = 1'b0;
        rq_tuser_next[12] = 1'b0;
        rq_tuser_next[14:13] = 2'b00;
        rq_tuser_next[15] = 1'b0;
        rq_tuser_next[23:16] = 8'd0;
        rq_tuser_next[27:24] = seq_alloc_reg[3:0];
        rq_tuser_next[59:28] = 32'd0;
        rq_tuser_next[61:60] = seq_alloc_reg[RQ_SEQ_NUM_W-1:4];
    end

    always_ff @(posedge clk) begin
        seq_pending_reg <= seq_pending_next;
        seq_outstanding_reg <= seq_outstanding_next;
        tag_pending_reg <= tag_pending_next;

        if ((pcie_rq_seq_num_vld0 && !rq_seq_ack0) ||
            (pcie_rq_seq_num_vld1 && !rq_seq_ack1)) begin
            seq_error_reg <= 1'b1;
        end
        if (rc_tag_release_valid && !rc_tag_release_known) begin
            tag_error_reg <= 1'b1;
        end

        if (output_ready) begin
            out_tdata_reg <= '0;
            out_tkeep_reg <= '0;
            out_tuser_reg <= '0;
            out_tlast_reg <= 1'b0;
            out_tvalid_reg <= 1'b0;

            if (rq_input_fire) begin
                case (state_reg)
                    RQ_STATE_IDLE: begin
                        if (raw_hdr_present && raw_is_mrd) begin
                            out_tdata_reg[127:0] <= rq_desc_read;
                            out_tkeep_reg <= 8'b0000_1111;
                            out_tuser_reg <= rq_tuser_next;
                            out_tlast_reg <= 1'b1;
                            out_tvalid_reg <= 1'b1;
                            seq_alloc_reg <= seq_alloc_reg + {{(RQ_SEQ_NUM_W-1){1'b0}}, 1'b1};
                            state_reg <= tlps_in.tlast ? RQ_STATE_IDLE : RQ_STATE_DRAIN;
                        end else if (raw_hdr_present && raw_is_mwr) begin
                            logic payload0_present;
                            payload0_present = !raw_is_4dw && tlps_in.tkeepdw[3];
                            // A 4DW write must carry its first 16 payload bytes in
                            // the descriptor beat with tkeep 0xFF.  Emitting the
                            // descriptor alone (tkeep 0x0F) makes the core treat
                            // the TLP as data-less: the write lands with the right
                            // address and length but every byte is zero, which is
                            // what p20 showed.  Park the descriptor and fold it
                            // into the first payload beat instead.
                            desc_hold <= rq_desc_write;
                            tuser_hold <= rq_tuser_next;
                            if (payload0_present) begin
                                out_tdata_reg[127:0] <= rq_desc_write;
                                out_tdata_reg[255:128] <= {96'd0, raw_dw3_swap};
                                out_tkeep_reg <= 8'h1f;
                                out_tuser_reg <= rq_tuser_next;
                                out_tlast_reg <= tlps_in.tlast;
                                out_tvalid_reg <= 1'b1;
                                pay_phase <= 2'd0;
                            end else begin
                                out_tdata_reg <= '0;
                                out_tkeep_reg <= 8'b0000_0000;
                                out_tuser_reg <= '0;
                                out_tlast_reg <= 1'b0;
                                out_tvalid_reg <= 1'b0;
                                pay_phase <= 2'd2;
                            end
                            seq_alloc_reg <= seq_alloc_reg + {{(RQ_SEQ_NUM_W-1){1'b0}}, 1'b1};
                            state_reg <= tlps_in.tlast ? RQ_STATE_IDLE : RQ_STATE_PAYLOAD;
                        end else begin
                            state_reg <= tlps_in.tlast ? RQ_STATE_IDLE : RQ_STATE_DRAIN;
                        end
                    end
                    RQ_STATE_PAYLOAD: begin
                        logic [2:0] payload_count;
                        logic [127:0] beat_data;
                        payload_count = {2'd0, tlps_in.tkeepdw[0]} + {2'd0, tlps_in.tkeepdw[1]} +
                                        {2'd0, tlps_in.tkeepdw[2]} + {2'd0, tlps_in.tkeepdw[3]};
                        beat_data = {raw_dw3_swap, raw_dw2_swap, raw_dw1_swap, raw_dw0_swap};

                        // Phase 2: fold the parked descriptor and this beat into
                        // one full 32-byte beat.  Phase 0/1: pair payload beats.
                        if (pay_phase == 2'd2) begin
                            out_tdata_reg[127:0]   <= desc_hold;
                            out_tdata_reg[255:128] <= beat_data;
                            out_tkeep_reg  <= folded_keep(payload_count);
                            out_tuser_reg  <= tuser_hold;
                            out_tvalid_reg <= 1'b1;
                            out_tlast_reg  <= tlps_in.tlast;
                            pay_phase      <= 2'd0;
                            state_reg      <= tlps_in.tlast ? RQ_STATE_IDLE : RQ_STATE_PAYLOAD;
                        end else if (pay_phase == 2'd0) begin
                            pay_hold       <= beat_data;
                            out_tuser_reg  <= '0;
                            if (tlps_in.tlast) begin
                                // Odd tail: descriptor was already emitted, so this
                                // is a lone half beat at the end of the TLP.
                                out_tdata_reg[127:0]   <= beat_data;
                                out_tdata_reg[255:128] <= 128'd0;
                                case (payload_count)
                                    3'd1: out_tkeep_reg <= 8'h01;
                                    3'd2: out_tkeep_reg <= 8'h03;
                                    3'd3: out_tkeep_reg <= 8'h07;
                                    default: out_tkeep_reg <= 8'h0f;
                                endcase
                                out_tvalid_reg <= (payload_count != 3'd0);
                                out_tlast_reg  <= 1'b1;
                                pay_phase      <= 2'd0;
                                state_reg      <= RQ_STATE_IDLE;
                            end else begin
                                out_tkeep_reg  <= 8'b0000_0000;
                                out_tvalid_reg <= 1'b0;
                                out_tlast_reg  <= 1'b0;
                                pay_phase      <= 2'd1;
                                state_reg      <= RQ_STATE_PAYLOAD;
                            end
                        end else begin
                            out_tdata_reg[127:0]   <= pay_hold;
                            out_tdata_reg[255:128] <= beat_data;
                            out_tkeep_reg  <= (payload_count == 3'd4) ? 8'hFF : 8'b0000_1111;
                            out_tuser_reg  <= '0;
                            out_tvalid_reg <= 1'b1;
                            out_tlast_reg  <= tlps_in.tlast;
                            pay_phase      <= 2'd0;
                            state_reg      <= tlps_in.tlast ? RQ_STATE_IDLE : RQ_STATE_PAYLOAD;
                        end
                    end
                    RQ_STATE_DRAIN: begin
                        state_reg <= tlps_in.tlast ? RQ_STATE_IDLE : RQ_STATE_DRAIN;
                    end
                    default: state_reg <= RQ_STATE_IDLE;
                endcase
            end
        end

        if (rst) begin
            state_reg <= RQ_STATE_IDLE;
            out_tdata_reg <= '0;
            out_tkeep_reg <= '0;
            out_tuser_reg <= '0;
            out_tlast_reg <= 1'b0;
            out_tvalid_reg <= 1'b0;
            seq_alloc_reg <= '0;
            seq_pending_reg <= '0;
            seq_outstanding_reg <= '0;
            seq_error_reg <= 1'b0;
            tag_pending_reg <= '0;
            tag_error_reg <= 1'b0;
        end
    end

endmodule

module asmcehnk_pcie_us_rc_to_tlps128 (
    input  wire logic clk,
    input  wire logic rst,

    taxi_axis_if.snk s_axis_rc,
    IfAXIS128.source tlps_out,

    output wire logic [7:0] tag_release,
    output wire logic       tag_release_valid
);

    typedef enum logic [0:0] {
        RC_STATE_IDLE,
        RC_STATE_FLUSH
    } rc_state_t;

    rc_state_t state_reg = RC_STATE_IDLE;

    logic [127:0] out_tdata_reg = '0;
    logic [3:0]   out_tkeepdw_reg = '0;
    logic         out_tvalid_reg = 1'b0;
    logic         out_tlast_reg = 1'b0;
    logic [8:0]   out_tuser_reg = '0;

    logic [127:0] pending_data_reg = '0;
    logic [2:0]   pending_count_reg = '0;
    logic         pending_last_reg = 1'b0;
    logic         frame_reg = 1'b0;
    logic [7:0]   release_tag_reg = 8'd0;
    logic         release_pending_reg = 1'b0;
    logic [7:0]   completion_tag_reg = 8'd0;
    logic         completion_tag_valid_reg = 1'b0;

    assign tlps_out.tdata = out_tdata_reg;
    assign tlps_out.tkeepdw = out_tkeepdw_reg;
    assign tlps_out.tvalid = out_tvalid_reg;
    assign tlps_out.tlast = out_tlast_reg;
    assign tlps_out.tuser = out_tuser_reg;
    assign tlps_out.has_data = out_tvalid_reg ||
                               (state_reg != RC_STATE_IDLE) || frame_reg;

    wire rc_output_ready;

    assign rc_output_ready = !out_tvalid_reg || tlps_out.tready;
    assign s_axis_rc.tready = rc_output_ready && (state_reg == RC_STATE_IDLE);
    wire rc_input_fire;
    wire [95:0] rc_desc;
    wire [10:0] rc_len_dw;
    wire [9:0]  rc_len10;
    wire        rc_has_data;
    wire [12:0] rc_byte_count;
    wire [12:0] rc_payload_bytes;
    wire [2:0]  rc_completion_status;
    wire        rc_completion_final;
    wire [31:0] rc_data_dw0_swap;
    wire [31:0] rc_data_dw1_swap;
    wire [31:0] rc_data_dw2_swap;
    wire [31:0] rc_data_dw3_swap;
    wire [31:0] rc_data_dw4_swap;
    wire [31:0] rc_data_dw5_swap;
    wire [31:0] rc_data_dw6_swap;
    wire [31:0] rc_data_dw7_swap;

    logic [3:0]  rc_valid_dw_count;
    logic [31:0] rc_raw_dw0_next;
    logic [31:0] rc_raw_dw1_next;
    logic [31:0] rc_raw_dw2_next;

    assign rc_input_fire = s_axis_rc.tvalid && s_axis_rc.tready;
    assign rc_desc = s_axis_rc.tdata[95:0];
    assign rc_len_dw = rc_desc[42:32];
    assign rc_len10 = rc_len_dw[10] ? 10'd0 : rc_len_dw[9:0];
    assign rc_has_data = (rc_len_dw != 11'd0);
    assign rc_byte_count = rc_desc[28:16];
    assign rc_payload_bytes = {rc_len_dw, 2'b00} -
                              {11'd0, rc_desc[1:0]};
    // Native RC errors (including timeout) must survive the raw conversion.
    // Preserve explicit PCIe status; otherwise report Completer Abort.
    assign rc_completion_status = (rc_desc[45:43] != 0) ? rc_desc[45:43] :
                                  ((rc_desc[15:12] != 0) ? 3'b100 : 3'd0);
    assign rc_completion_final = rc_desc[30] ||
                                 (rc_completion_status != 3'd0) ||
                                 !rc_has_data ||
                                 (rc_byte_count <= rc_payload_bytes);
    assign tag_release = completion_tag_reg;
    assign tag_release_valid = completion_tag_valid_reg;

    // Separate native RC descriptor decoding (including the ByteCount compare)
    // from the RQ tag bitmap's lookup, decode and update.  The extra cycle keeps
    // the tag occupied conservatively; it never makes a tag reusable early.
    // This event pipeline runs every clock, independently of rc_output_ready:
    // a stalled payload must not hold a release valid and free the tag twice.
    // It can carry one accepted terminal completion per clock without a queue.
    always_ff @(posedge clk) begin
        if (rst) begin
            completion_tag_reg <= 8'd0;
            completion_tag_valid_reg <= 1'b0;
        end else begin
            completion_tag_valid_reg <= rc_input_fire && s_axis_rc.tlast &&
                ((!frame_reg && rc_completion_final) ||
                 (frame_reg && release_pending_reg));
            if (rc_input_fire && s_axis_rc.tlast) begin
                completion_tag_reg <= frame_reg ? release_tag_reg : rc_desc[71:64];
            end
        end
    end
    assign rc_data_dw0_swap = {s_axis_rc.tdata[103:96], s_axis_rc.tdata[111:104], s_axis_rc.tdata[119:112], s_axis_rc.tdata[127:120]};
    assign rc_data_dw1_swap = {s_axis_rc.tdata[135:128], s_axis_rc.tdata[143:136], s_axis_rc.tdata[151:144], s_axis_rc.tdata[159:152]};
    assign rc_data_dw2_swap = {s_axis_rc.tdata[167:160], s_axis_rc.tdata[175:168], s_axis_rc.tdata[183:176], s_axis_rc.tdata[191:184]};
    assign rc_data_dw3_swap = {s_axis_rc.tdata[199:192], s_axis_rc.tdata[207:200], s_axis_rc.tdata[215:208], s_axis_rc.tdata[223:216]};
    assign rc_data_dw4_swap = {s_axis_rc.tdata[231:224], s_axis_rc.tdata[239:232], s_axis_rc.tdata[247:240], s_axis_rc.tdata[255:248]};
    assign rc_data_dw5_swap = {s_axis_rc.tdata[7:0], s_axis_rc.tdata[15:8], s_axis_rc.tdata[23:16], s_axis_rc.tdata[31:24]};
    assign rc_data_dw6_swap = {s_axis_rc.tdata[39:32], s_axis_rc.tdata[47:40], s_axis_rc.tdata[55:48], s_axis_rc.tdata[63:56]};
    assign rc_data_dw7_swap = {s_axis_rc.tdata[71:64], s_axis_rc.tdata[79:72], s_axis_rc.tdata[87:80], s_axis_rc.tdata[95:88]};

    always_comb begin
        rc_valid_dw_count = {3'd0, s_axis_rc.tkeep[0]} + {3'd0, s_axis_rc.tkeep[1]} +
                            {3'd0, s_axis_rc.tkeep[2]} + {3'd0, s_axis_rc.tkeep[3]} +
                            {3'd0, s_axis_rc.tkeep[4]} + {3'd0, s_axis_rc.tkeep[5]} +
                            {3'd0, s_axis_rc.tkeep[6]} + {3'd0, s_axis_rc.tkeep[7]};
    end

    always_comb begin
        rc_raw_dw0_next = {rc_has_data ? 3'b010 : 3'b000, 5'b01010,
                           1'b0, rc_desc[91:89], 1'b0, rc_desc[94],
                           1'b0, 1'b0, 1'b0, rc_desc[46], rc_desc[93:92],
                           rc_desc[9:8], rc_len10};
        // PCIe completion header order (and the order LeechCore's TLP_HDR_CplD
        // parses in leechcore/device_fpga.c):
        //   DW1 = {CompleterID, CplStatus[2:0], BCM, ByteCount[11:0]}
        //   DW2 = {RequesterID, Tag, R, LowerAddress[6:0]}
        // A 4 KB read's first completion carries ByteCount=4096, which wraps to
        // 0 in the 12-bit field; hosts read 0 as "4096 remaining", not as done.
        rc_raw_dw1_next = {rc_desc[87:72], rc_completion_status, 1'b0, rc_desc[27:16]};
        rc_raw_dw2_next = {rc_desc[63:48], rc_desc[71:64], 1'b0, rc_desc[6:0]};
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg <= RC_STATE_IDLE;
            out_tdata_reg <= '0;
            out_tkeepdw_reg <= '0;
            out_tvalid_reg <= 1'b0;
            out_tlast_reg <= 1'b0;
            out_tuser_reg <= '0;
            pending_data_reg <= '0;
            pending_count_reg <= '0;
            pending_last_reg <= 1'b0;
            frame_reg <= 1'b0;
            release_tag_reg <= 8'd0;
            release_pending_reg <= 1'b0;
        end else if (rc_output_ready) begin
            out_tvalid_reg <= 1'b0;
            out_tdata_reg <= '0;
            out_tkeepdw_reg <= '0;
            out_tlast_reg <= 1'b0;
            out_tuser_reg <= '0;

            case (state_reg)
                RC_STATE_IDLE: begin
                    if (rc_input_fire) begin
                        if (!frame_reg) begin
                            if (rc_valid_dw_count >= 4'd3) begin
                                logic [2:0] payload_count;
                                logic payload0_present;
                                payload_count = rc_valid_dw_count - 4'd3;
                                payload0_present = (payload_count != 3'd0);

                                out_tdata_reg[31:0] <= rc_raw_dw0_next;
                                out_tdata_reg[63:32] <= rc_raw_dw1_next;
                                out_tdata_reg[95:64] <= rc_raw_dw2_next;
                                out_tdata_reg[127:96] <= payload0_present ? rc_data_dw0_swap : 32'd0;
                                out_tkeepdw_reg <= payload0_present ? 4'b1111 : 4'b0111;
                                out_tlast_reg <= s_axis_rc.tlast && (payload_count <= 3'd1);
                                out_tvalid_reg <= 1'b1;
                                out_tuser_reg <= {7'd0, (s_axis_rc.tlast && (payload_count <= 3'd1)), 1'b1};

                                pending_data_reg[31:0] <= rc_data_dw1_swap;
                                pending_data_reg[63:32] <= rc_data_dw2_swap;
                                pending_data_reg[95:64] <= rc_data_dw3_swap;
                                pending_data_reg[127:96] <= rc_data_dw4_swap;
                                pending_count_reg <= (payload_count > 3'd1) ? (payload_count - 3'd1) : 3'd0;
                                pending_last_reg <= s_axis_rc.tlast && (payload_count > 3'd1);
                                state_reg <= (payload_count > 3'd1) ? RC_STATE_FLUSH : RC_STATE_IDLE;
                            end
                            release_tag_reg <= rc_desc[71:64];
                            release_pending_reg <= rc_completion_final &&
                                                   !s_axis_rc.tlast;
                            frame_reg <= !s_axis_rc.tlast;
                        end else begin
                            logic [2:0] lower_count;
                            logic [2:0] upper_count;
                            lower_count = (rc_valid_dw_count > 4'd4) ? 3'd4 : rc_valid_dw_count[2:0];
                            upper_count = (rc_valid_dw_count > 4'd4) ? (rc_valid_dw_count[2:0] - 3'd4) : 3'd0;

                            out_tdata_reg[31:0] <= rc_data_dw5_swap;
                            out_tdata_reg[63:32] <= rc_data_dw6_swap;
                            out_tdata_reg[95:64] <= rc_data_dw7_swap;
                            out_tdata_reg[127:96] <= rc_data_dw0_swap;
                            case (lower_count)
                                3'd0: out_tkeepdw_reg <= 4'b0000;
                                3'd1: out_tkeepdw_reg <= 4'b0001;
                                3'd2: out_tkeepdw_reg <= 4'b0011;
                                3'd3: out_tkeepdw_reg <= 4'b0111;
                                default: out_tkeepdw_reg <= 4'b1111;
                            endcase
                            out_tlast_reg <= s_axis_rc.tlast && (upper_count == 3'd0);
                            out_tvalid_reg <= (lower_count != 3'd0);
                            out_tuser_reg <= {7'd0, (s_axis_rc.tlast && (upper_count == 3'd0)), 1'b0};

                            pending_data_reg[31:0] <= rc_data_dw1_swap;
                            pending_data_reg[63:32] <= rc_data_dw2_swap;
                            pending_data_reg[95:64] <= rc_data_dw3_swap;
                            pending_data_reg[127:96] <= rc_data_dw4_swap;
                            pending_count_reg <= upper_count;
                            pending_last_reg <= s_axis_rc.tlast && (upper_count != 3'd0);
                            state_reg <= (upper_count != 3'd0) ? RC_STATE_FLUSH : RC_STATE_IDLE;
                            if (s_axis_rc.tlast) begin
                                release_pending_reg <= 1'b0;
                            end
                            frame_reg <= !s_axis_rc.tlast;
                        end
                    end
                end
                RC_STATE_FLUSH: begin
                    out_tdata_reg <= pending_data_reg;
                    case (pending_count_reg)
                        3'd0: out_tkeepdw_reg <= 4'b0000;
                        3'd1: out_tkeepdw_reg <= 4'b0001;
                        3'd2: out_tkeepdw_reg <= 4'b0011;
                        3'd3: out_tkeepdw_reg <= 4'b0111;
                        default: out_tkeepdw_reg <= 4'b1111;
                    endcase
                    out_tlast_reg <= pending_last_reg;
                    out_tvalid_reg <= (pending_count_reg != 3'd0);
                    out_tuser_reg <= {7'd0, pending_last_reg, 1'b0};
                    pending_count_reg <= 3'd0;
                    pending_last_reg <= 1'b0;
                    state_reg <= RC_STATE_IDLE;
                end
                default: state_reg <= RC_STATE_IDLE;
            endcase
        end
    end

endmodule

module asmcehnk_tlps128_to_axis_cc_us (
    input  wire logic clk,
    input  wire logic rst,

    IfAXIS128.sink    tlps_in,
    taxi_axis_if.src  m_axis_cc
);

    logic [255:0] out_tdata_reg = '0;
    logic [7:0]   out_tkeep_reg = '0;
    logic         out_tvalid_reg = 1'b0;
    logic         out_tlast_reg = 1'b0;

    logic [383:0] pack_data_reg = '0;
    logic [3:0]   pack_count_reg = '0;
    logic         pack_last_reg = 1'b0;

    assign m_axis_cc.tdata = out_tdata_reg;
    assign m_axis_cc.tkeep = out_tkeep_reg;
    assign m_axis_cc.tstrb = out_tkeep_reg;
    assign m_axis_cc.tvalid = out_tvalid_reg;
    assign m_axis_cc.tlast = out_tlast_reg;
    assign m_axis_cc.tuser = 33'd0;
    assign m_axis_cc.tid = '0;
    assign m_axis_cc.tdest = '0;

    wire cc_output_ready;

    assign cc_output_ready = !out_tvalid_reg || m_axis_cc.tready;
    assign tlps_in.tready = cc_output_ready && !pack_last_reg &&
                            (pack_count_reg <= 4'd8);

    wire cc_input_fire;
    wire [31:0] cc_raw_dw0;
    wire [31:0] cc_raw_dw1;
    wire [31:0] cc_raw_dw2;
    wire [31:0] cc_raw_dw3_swap;
    wire [31:0] cc_raw_payload0_swap;
    wire [31:0] cc_raw_payload1_swap;
    wire [31:0] cc_raw_payload2_swap;
    wire [31:0] cc_raw_payload3_swap;

    logic [95:0] cc_desc_next;

    assign cc_input_fire = tlps_in.tvalid && tlps_in.tready;
    assign cc_raw_dw0 = tlps_in.tdata[31:0];
    assign cc_raw_dw1 = tlps_in.tdata[63:32];
    assign cc_raw_dw2 = tlps_in.tdata[95:64];
    assign cc_raw_dw3_swap = {tlps_in.tdata[103:96], tlps_in.tdata[111:104], tlps_in.tdata[119:112], tlps_in.tdata[127:120]};
    assign cc_raw_payload0_swap = {tlps_in.tdata[7:0], tlps_in.tdata[15:8], tlps_in.tdata[23:16], tlps_in.tdata[31:24]};
    assign cc_raw_payload1_swap = {tlps_in.tdata[39:32], tlps_in.tdata[47:40], tlps_in.tdata[55:48], tlps_in.tdata[63:56]};
    assign cc_raw_payload2_swap = {tlps_in.tdata[71:64], tlps_in.tdata[79:72], tlps_in.tdata[87:80], tlps_in.tdata[95:88]};
    assign cc_raw_payload3_swap = {tlps_in.tdata[103:96], tlps_in.tdata[111:104], tlps_in.tdata[119:112], tlps_in.tdata[127:120]};

    always_comb begin
        cc_desc_next = '0;
        cc_desc_next[6:0]   = cc_raw_dw2[6:0];
        cc_desc_next[9:8]   = cc_raw_dw0[11:10];
        cc_desc_next[28:16] = {1'b0, cc_raw_dw1[11:0]};
        cc_desc_next[42:32] = {1'b0, cc_raw_dw0[9:0]};
        cc_desc_next[45:43] = cc_raw_dw1[15:13];
        cc_desc_next[63:48] = cc_raw_dw2[31:16];
        cc_desc_next[71:64] = cc_raw_dw2[15:8];
        cc_desc_next[87:72] = cc_raw_dw1[31:16];
        cc_desc_next[88]    = 1'b1;
        cc_desc_next[91:89] = cc_raw_dw0[22:20];
        cc_desc_next[94:92] = {cc_raw_dw0[18], cc_raw_dw0[13:12]};
        cc_desc_next[95]    = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            out_tdata_reg <= '0;
            out_tkeep_reg <= '0;
            out_tvalid_reg <= 1'b0;
            out_tlast_reg <= 1'b0;
            pack_data_reg <= '0;
            pack_count_reg <= '0;
            pack_last_reg <= 1'b0;
        end else if (cc_output_ready) begin
            out_tdata_reg <= '0;
            out_tkeep_reg <= '0;
            out_tvalid_reg <= 1'b0;
            out_tlast_reg <= 1'b0;

            // A final raw beat can leave up to four DWORDs after a full
            // 256-bit CC beat.  Emit that tail before accepting a new packet.
            if (pack_last_reg && (pack_count_reg != 4'd0)) begin
                out_tdata_reg <= pack_data_reg[255:0];
                case (pack_count_reg)
                    4'd1: out_tkeep_reg <= 8'b0000_0001;
                    4'd2: out_tkeep_reg <= 8'b0000_0011;
                    4'd3: out_tkeep_reg <= 8'b0000_0111;
                    4'd4: out_tkeep_reg <= 8'b0000_1111;
                    4'd5: out_tkeep_reg <= 8'b0001_1111;
                    4'd6: out_tkeep_reg <= 8'b0011_1111;
                    4'd7: out_tkeep_reg <= 8'b0111_1111;
                    default: out_tkeep_reg <= 8'b1111_1111;
                endcase
                out_tvalid_reg <= 1'b1;
                out_tlast_reg <= 1'b1;
                pack_data_reg <= '0;
                pack_count_reg <= '0;
                pack_last_reg <= 1'b0;
            end else if (cc_input_fire) begin
                logic [383:0] pack_tmp;
                logic [3:0] count_tmp;

                pack_tmp = pack_data_reg;
                count_tmp = pack_count_reg;

                if (tlps_in.tuser[0]) begin
                    pack_tmp[95:0] = cc_desc_next;
                    count_tmp = 4'd3;
                    if (tlps_in.tkeepdw[3]) begin
                        pack_tmp[127:96] = cc_raw_dw3_swap;
                        count_tmp = 4'd4;
                    end
                end else begin
                    if (tlps_in.tkeepdw[0]) begin
                        pack_tmp[count_tmp*32 +: 32] = cc_raw_payload0_swap;
                        count_tmp = count_tmp + 4'd1;
                    end
                    if (tlps_in.tkeepdw[1]) begin
                        pack_tmp[count_tmp*32 +: 32] = cc_raw_payload1_swap;
                        count_tmp = count_tmp + 4'd1;
                    end
                    if (tlps_in.tkeepdw[2]) begin
                        pack_tmp[count_tmp*32 +: 32] = cc_raw_payload2_swap;
                        count_tmp = count_tmp + 4'd1;
                    end
                    if (tlps_in.tkeepdw[3]) begin
                        pack_tmp[count_tmp*32 +: 32] = cc_raw_payload3_swap;
                        count_tmp = count_tmp + 4'd1;
                    end
                end

                if (count_tmp >= 4'd8) begin
                    out_tdata_reg <= pack_tmp[255:0];
                    out_tkeep_reg <= 8'b1111_1111;
                    out_tvalid_reg <= 1'b1;
                    out_tlast_reg <= tlps_in.tlast && (count_tmp == 4'd8);

                    if (count_tmp > 4'd8) begin
                        pack_data_reg <= {256'd0, pack_tmp[383:256]};
                        pack_count_reg <= count_tmp - 4'd8;
                        pack_last_reg <= tlps_in.tlast;
                    end else begin
                        pack_data_reg <= '0;
                        pack_count_reg <= '0;
                        pack_last_reg <= 1'b0;
                    end
                end else if (tlps_in.tlast) begin
                    out_tdata_reg <= pack_tmp[255:0];
                    case (count_tmp)
                        4'd1: out_tkeep_reg <= 8'b0000_0001;
                        4'd2: out_tkeep_reg <= 8'b0000_0011;
                        4'd3: out_tkeep_reg <= 8'b0000_0111;
                        4'd4: out_tkeep_reg <= 8'b0000_1111;
                        4'd5: out_tkeep_reg <= 8'b0001_1111;
                        4'd6: out_tkeep_reg <= 8'b0011_1111;
                        4'd7: out_tkeep_reg <= 8'b0111_1111;
                        default: out_tkeep_reg <= 8'b0000_0000;
                    endcase
                    out_tvalid_reg <= (count_tmp != 4'd0);
                    out_tlast_reg <= (count_tmp != 4'd0);
                    pack_data_reg <= '0;
                    pack_count_reg <= '0;
                    pack_last_reg <= 1'b0;
                end else begin
                    pack_data_reg <= pack_tmp;
                    pack_count_reg <= count_tmp;
                    pack_last_reg <= 1'b0;
                end
            end
        end
    end

endmodule

`resetall
