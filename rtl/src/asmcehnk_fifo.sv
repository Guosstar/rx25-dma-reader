//
// asmcehnk FPGA.
//
// FIFO network / control.
//
// (c) Ulf Frisk, 2017-2024
// Author: Ulf Frisk, asmcehnk@frizk.net
// Special thanks to: Dmytro Oleksiuk @d_olex
//

`timescale 1ns / 1ps
`include "asmcehnk_header.svh"

// AS02/XCKU3P: top-level QSPI glue owns STARTUPE3; disable the
// old 7-series STARTUPE2 path when AS02_DISABLE_STARTUPE2 is defined.
`ifndef AS02_DISABLE_STARTUPE2
`define ENABLE_STARTUPE2
`endif

module asmcehnk_fifo #(
    parameter               PARAM_DEVICE_ID = 0,
    parameter               PARAM_VERSION_NUMBER_MAJOR = 0,
    parameter               PARAM_VERSION_NUMBER_MINOR = 0,
    parameter               PARAM_CUSTOM_VALUE = 0,
    // 1 = RX25 image: take the TLP channel straight onto the wire instead of
    // through asmcehnk_mux's 7-channel 256-bit packing.
    //
    // Why: the mux packs seven 32-bit channels into one 256-bit word and the
    // receiver side (asmcehnk_fifo's CHECK_MAGIC decode) reads 64-bit words one
    // at a time -- there is no inverse of that packing anywhere in the design.
    // PL11 frames therefore never survived the round trip.  In RX25 mode only
    // the TLP channel carries traffic (the host talks over BAR0, so CFG/CMD/LOOP
    // are idle), and a 128-bit TLP beat maps exactly onto four 64-bit words, so
    // one beat fills one 256-bit packet with no packing needed.
    parameter               PARAM_RX25_BYPASS = 0
) (
    input                   clk,
    input                   rst,
    input                   tick_100mhz_ce,
    input                   rst_cfg_reload,
    
    input                   pcie_present,
    input                   pcie_perst_n,
    
    IfComToFifo.mp_fifo     dcom,
    
    IfPCIeFifoCfg.mp_fifo   dcfg,
    IfPCIeFifoTlp.mp_fifo   dtlp,
    IfPCIeFifoCore.mp_fifo  dpcie,
    IfShadow2Fifo.fifo      dshadow2fifo,

    // Word/frame arrival counters.  The responder recognises exactly one PL11
    // frame however many times the initiator submits, and every stage after the
    // wire has been cleared: the shim is proven correct in simulation and the
    // src fifo is a shift register.  That leaves this module -- specifically
    // whether the second frame's words ever satisfy CHECK_MAGIC.  Counting the
    // words that do, versus the frames the shim then builds, separates a wire
    // problem from a decode one.
    output logic [31:0]     dbg_rx_words,
    output logic [31:0]     dbg_rx_frames
    );
      
    // ----------------------------------------------------
    // TickCount64
    // ----------------------------------------------------
    
    time tickcount64 = 0;
    always @ ( posedge clk )
        if ( tick_100mhz_ce )
            tickcount64 <= tickcount64 + 1;
   
    // ----------------------------------------------------------------------------
    // RX FROM USB/FT601/FT245 BELOW:
    // ----------------------------------------------------------------------------
    // Incoming data received from FT601 is converted from 32-bit to 64-bit.
    // This always happen regardless whether receiving FIFOs are full or not.
    // The actual data contains a MAGIC which tells which receiving FIFO should
    // accept the data. Receiving TYPEs are: PCIe TLP, PCIe CFG, Loopback, Command.
    //
    //         /--> PCIe TLP (32-bit)
    //         |
    // FT601 --+--> PCIe CFG (64-bit)
    //         |
    //         +--> LOOPBACK (32-bit)
    //         |
    //         \--> COMMAND  (64-bit)
    //
            
    // ----------------------------------------------------------
    // Route 64-bit incoming FT601 data to correct receiver below:
    // ----------------------------------------------------------
    // ----------------------------------------------------------
    // Route 64-bit incoming FT601 data to correct receiver below:
    // ----------------------------------------------------------
    `define CHECK_MAGIC     (dcom.com_dout[7:0] == 8'h77)
    `define CHECK_TYPE_TLP  (dcom.com_dout[9:8] == 2'b00)
    `define CHECK_TYPE_CFG  (dcom.com_dout[9:8] == 2'b01)
    `define CHECK_TYPE_LOOP (dcom.com_dout[9:8] == 2'b10)
    `define CHECK_TYPE_CMD  (dcom.com_dout[9:8] == 2'b11)
    assign   dtlp.tx_valid = dcom.com_dout_valid & `CHECK_MAGIC & `CHECK_TYPE_TLP;
    assign   dcfg.tx_valid = dcom.com_dout_valid & `CHECK_MAGIC & `CHECK_TYPE_CFG;
    wire     _loop_rx_wren = dcom.com_dout_valid & `CHECK_MAGIC & `CHECK_TYPE_LOOP;
    wire     _cmd_rx_wren  = dcom.com_dout_valid & `CHECK_MAGIC & `CHECK_TYPE_CMD;
    // Incoming TLPs are forwarded to PCIe core logic.
    assign dtlp.tx_data = dcom.com_dout[63:32];
    assign dtlp.tx_last = dcom.com_dout[10];
    // Incoming CFGs are forwarded to PCIe core logic.
    assign dcfg.tx_data = dcom.com_dout;

    // ----------------------------------------------------------------------------
    // TX TO USB/FT601/FT245 BELOW:
    // ----------------------------------------------------------------------------
    //
    //                                         MULTIPLEXER
    //                                         ===========
    //                                         1st priority
    // PCIe TLP ->(32-bit) --------------------->--\
    //                                         2nd |    /-----------------------------------------\
    // PCIe CFG ->(32-bit)---------------------->--+--> | 256-> BUFFER FIFO (NATIVE OR DRAM) ->32 | -> FT601
    //                                             |    \-----------------------------------------/
    //            /--------------------------\ 3rd |
    // FT601   -> | 34->  Loopback FIFO ->34 | ->--/
    //            \--------------------------/     | 
    //                                             |
    //            /--------------------------\ 4th |
    // COMMAND -> | 34->  Command FIFO  ->34 | ->--/
    //            \--------------------------/
    //
   
    // ----------------------------------------------------------
    // LOOPBACK FIFO:
    // ----------------------------------------------------------
    wire [33:0]       _loop_dout;
    wire              _loop_valid;
    wire              _loop_rd_en;
    fifo_34_34 i_fifo_loop_tx(
        .clk            ( clk                       ),
        .srst           ( rst                       ),
        .rd_en          ( _loop_rd_en               ),
        .dout           ( _loop_dout                ),
        .din            ( {dcom.com_dout[11:10], dcom.com_dout[63:32]} ),
        .wr_en          ( _loop_rx_wren             ),
        .full           (                           ),
        .almost_full    (                           ),
        .empty          (                           ),
        .valid          ( _loop_valid               )
    );
   
    // ----------------------------------------------------------
    // COMMAND FIFO:
    // ----------------------------------------------------------
    wire [33:0]       _cmd_tx_dout;
    wire              _cmd_tx_valid;
    wire              _cmd_tx_rd_en;
    wire              _cmd_tx_almost_full;
    reg               _cmd_tx_wr_en;
    reg [33:0]        _cmd_tx_din;
    fifo_34_34 i_fifo_cmd_tx(
        .clk            ( clk                       ),
        .srst           ( rst                       ),
        .rd_en          ( _cmd_tx_rd_en             ),
        .dout           ( _cmd_tx_dout              ),
        .din            ( _cmd_tx_din               ),
        .wr_en          ( _cmd_tx_wr_en             ),
        .full           (                           ),
        .almost_full    ( _cmd_tx_almost_full       ),
        .empty          (                           ),
        .valid          ( _cmd_tx_valid             )
    );

    // ----------------------------------------------------------
    // MULTIPLEXER
    // ----------------------------------------------------------
    wire [255:0]    mux_dout;
    wire            mux_valid;

    asmcehnk_mux i_asmcehnk_mux(
        .clk            ( clk                           ),
        .rst            ( rst                           ),
        // output
        .dout           ( mux_dout                      ),
        .valid          ( mux_valid                     ),
        .rd_en          ( dcom.com_din_ready            ),
        // LOOPBACK:
        .p0_din         ( _loop_dout[31:0]              ),
        .p0_tag         ( 2'b10                         ),
        .p0_ctx         ( _loop_dout[33:32]             ),
        .p0_wr_en       ( _loop_valid                   ),
        .p0_req_data    ( _loop_rd_en                   ),
        // COMMAND:
        .p1_din         ( _cmd_tx_dout[31:0]            ),
        .p1_tag         ( 2'b11                         ),
        .p1_ctx         ( _cmd_tx_dout[33:32]           ),
        .p1_wr_en       ( _cmd_tx_valid                 ),
        .p1_req_data    ( _cmd_tx_rd_en                 ),
        // PCIe CFG
        .p2_din         ( dcfg.rx_data                  ),
        .p2_tag         ( 2'b01                         ),
        .p2_ctx         ( 2'b00                         ),
        .p2_wr_en       ( dcfg.rx_valid                 ),
        .p2_req_data    ( dcfg.rx_rd_en                 ),
        // PCIe TLP #1
        .p3_din         ( dtlp.rx_data[0]               ),
        .p3_tag         ( 2'b00                         ),
        .p3_ctx         ( {dtlp.rx_first[0], dtlp.rx_last[0]} ),
        .p3_wr_en       ( dtlp.rx_valid[0]              ),
        .p3_req_data    ( dtlp.rx_rd_en                 ),
        // PCIe TLP #2
        .p4_din         ( dtlp.rx_data[1]               ),
        .p4_tag         ( 2'b00                         ),
        .p4_ctx         ( {dtlp.rx_first[1], dtlp.rx_last[1]} ),
        .p4_wr_en       ( dtlp.rx_valid[1]              ),
        .p4_req_data    (                               ),
        // PCIe TLP #3
        .p5_din         ( dtlp.rx_data[2]               ),
        .p5_tag         ( 2'b00                         ),
        .p5_ctx         ( {dtlp.rx_first[2], dtlp.rx_last[2]} ),
        .p5_wr_en       ( dtlp.rx_valid[2]              ),
        .p5_req_data    ( dtlp.rx_rd_en                 ),
        // PCIe TLP #4
        .p6_din         ( dtlp.rx_data[3]               ),
        .p6_tag         ( 2'b00                         ),
        .p6_ctx         ( {dtlp.rx_first[3], dtlp.rx_last[3]} ),
        .p6_wr_en       ( dtlp.rx_valid[3]              ),
        .p6_req_data    (                               ),
        // P7
        .p7_din         ( 32'h00000000                  ),
        .p7_tag         ( 2'b11                         ),
        .p7_ctx         ( 2'b00                         ),
        .p7_wr_en       ( 1'b0                          ),
        .p7_req_data    (                               )
    );

    // ------------------------------------------------------------------------
    // RX25 BYPASS: TLP channel straight to the wire
    // ------------------------------------------------------------------------
    // Four 32-bit TLP lanes become four 64-bit words, each carrying the header
    // the receive side already expects:
    //     bit[7:0]   = 8'h77  magic        (CHECK_MAGIC)
    //     bit[9:8]   = 2'b00  TLP          (CHECK_TYPE_TLP)
    //     bit[10]    = last
    //     bit[63:32] = payload dword       (dfifo_tx_data)
    // This is exactly what asmcehnk_fifo's decode and
    // asmcehnk_tlps128_src_fifo's four-beat reassembly assume, so the return
    // path needs no change at all.
    // Magic is gated by lane valid.  dst_fifo deasserts rx_valid on lanes beyond
    // tkeepdw, and rx_data on those lanes is stale.  Sending them with a real
    // magic made the receiver accept phantom words: tkeepdw grew from 0011 to
    // 1111 and every following frame started two words late.  A zero magic
    // fails CHECK_MAGIC at the far end and the word is dropped there instead.
    wire [63:0] rx25_w0 = {dtlp.rx_data[0], 21'd0, dtlp.rx_last[0], 2'b00, dtlp.rx_valid[0] ? 8'h77 : 8'h00};
    wire [63:0] rx25_w1 = {dtlp.rx_data[1], 21'd0, dtlp.rx_last[1], 2'b00, dtlp.rx_valid[1] ? 8'h77 : 8'h00};
    wire [63:0] rx25_w2 = {dtlp.rx_data[2], 21'd0, dtlp.rx_last[2], 2'b00, dtlp.rx_valid[2] ? 8'h77 : 8'h00};
    wire [63:0] rx25_w3 = {dtlp.rx_data[3], 21'd0, dtlp.rx_last[3], 2'b00, dtlp.rx_valid[3] ? 8'h77 : 8'h00};

    // Only lane 0 drives valid: dst_fifo raises all four lanes together for a
    // full 128-bit beat, and PL11 frames are always a whole number of 4-dword
    // beats, so a partial beat never occurs.
    //
    // Handshake note: dst_fifo's rx_valid trails rx_rd_en by one cycle
    // (request_delay_reg), so a beat can become visible on the same cycle the
    // UDP packetizer drops ready.  A one-deep skid buffer holds it instead of
    // dropping a frame.  rx_rd_en itself stays driven by asmcehnk_mux (it is
    // simply com_din_ready), which keeps dst_fifo from advancing while we stall.
    // Word order matters and is not the obvious one.  The downstream path is
    //    com_tx_data --(full 256-bit byte reverse)--> leechcore_tx_data
    //                --(axis_fifo_adapter, LSB first)--> 4x64-bit payloads
    // so com_din[255:192] is the word that reaches the wire first.  The receive
    // side undoes the byte swap and feeds asmcehnk_tlps128_src_fifo, which fills
    // tdata[31:0] first -- i.e. lane 0.  Putting w0 in the high slot therefore
    // lands lane 0 first, which is what the reassembly expects.  Writing
    // {w3,w2,w1,w0} here silently reverses every 128-bit beat.
    wire [255:0] tlp_beat = {rx25_w0, rx25_w1, rx25_w2, rx25_w3};

    logic [255:0] bp_data  = 256'd0;
    logic         bp_valid = 1'b0;

    always_ff @(posedge clk) begin
        if (rst) begin
            bp_valid <= 1'b0;
        end else if (bp_valid) begin
            if (dcom.com_din_ready) begin
                // Drained.  A beat arriving on this same cycle takes the slot
                // directly rather than costing a second cycle.
                bp_valid <= dtlp.rx_valid[0];
                if (dtlp.rx_valid[0]) bp_data <= tlp_beat;
            end
        end else if (dtlp.rx_valid[0] && !dcom.com_din_ready) begin
            // Stalled while empty: the only case that needs buffering.
            //
            // The previous version also stored the beat in the cycle where the
            // downstream accepted it through the fall-through mux, so it left
            // twice.  A duplicated first beat of a PL11 frame makes the far end
            // count two magics while opening only one frame -- which is exactly
            // the responder stall this build is chasing.
            bp_data  <= tlp_beat;
            bp_valid <= 1'b1;
        end
    end

    assign dcom.com_din       = PARAM_RX25_BYPASS ? (bp_valid ? bp_data : tlp_beat)
                                                  : mux_dout;
    assign dcom.com_din_wr_en = PARAM_RX25_BYPASS ? (bp_valid || dtlp.rx_valid[0])
                                                  : mux_valid;

    // ------------------------------------------------------------------------
    // COMMAND / CONTROL FIFO: REGISTER FILE: COMMON
    // ------------------------------------------------------------------------
    
    localparam          RWPOS_WAIT_COMPLETE         = 18;   // WAIT FOR DRP COMPLETION
    localparam          RWPOS_DRP_RD_EN             = 20;
    localparam          RWPOS_DRP_WR_EN             = 21;
    localparam          RWPOS_GLOBAL_SYSTEM_RESET   = 31;
    
    wire    [319:0]     ro;
    reg     [239:0]     rw;
    
    // special non-user accessible registers 
    reg     [79:0]      _pcie_core_config = { 4'hf, 1'b1, 1'b1, 1'b0, 1'b0, 8'h02, 16'h0666, 16'h10EE, 16'h0007, 16'h10EE };
    time                _cmd_timer_inactivity_base;
    reg                 rwi_drp_rd_en;
    reg                 rwi_drp_wr_en;
    reg     [15:0]      rwi_drp_data;
    
    // ------------------------------------------------------------------------
    // COMMAND / CONTROL FIFO: REGISTER FILE: READ-ONLY LAYOUT/SPECIFICATION
    // ------------------------------------------------------------------------
    
    // MAGIC
    assign ro[15:0]     = 16'hab89;                     // +000: MAGIC
    // SPECIAL
    assign ro[19:16]    = 0;                            // +002: SPECIAL
    assign ro[20]       = rwi_drp_rd_en;                //
    assign ro[21]       = rwi_drp_wr_en;                //
    assign ro[31:22]    = 0;                            //
    // SIZEOF / BYTECOUNT [little-endian]
    assign ro[63:32]    = $bits(ro) >> 3;               // +004: SIZEOF / BYTECOUNT [little-endian]
    // ID: VERSION & DEVICE
    assign ro[71:64]    = PARAM_VERSION_NUMBER_MAJOR;   // +008: VERSION MAJOR
    assign ro[79:72]    = PARAM_VERSION_NUMBER_MINOR;   // +009: VERSION MINOR
    assign ro[87:80]    = PARAM_DEVICE_ID;              // +00A: DEVICE ID
    assign ro[127:88]   = 0;                            // +00B: SLACK
    // UPTIME (tickcount64*100MHz)
    assign ro[191:128]   = tickcount64;                 // +010: UPTIME (tickcount64*100MHz)
    // INACTIVITY TIMER
    assign ro[255:192]  = _cmd_timer_inactivity_base;   // +018: INACTIVITY TIMER
    // PCIe DRP 
    assign ro[271:256]  = rwi_drp_data;                 // +020: DRP: pcie_drp_do
    // PCIe
    assign ro[272]      = pcie_present;                 // +022: PCIe PRSNT#
    assign ro[273]      = pcie_perst_n;                 //       PCIe PERST#
    assign ro[287:274]  = 0;                            //       SLACK
    // CUSTOM_VALUE
    assign ro[319:288]  = PARAM_CUSTOM_VALUE;           // +024: CUSTOM VALUE
    // +028
    
    // ------------------------------------------------------------------------
    // INITIALIZATION/RESET BLOCK _AND_
    // COMMAND / CONTROL FIFO: REGISTER FILE: READ-WRITE LAYOUT/SPECIFICATION
    // ------------------------------------------------------------------------
    
    task asmcehnk_fifo_ctl_initialvalues;               // task is non automatic
        begin
            _cmd_tx_wr_en  <= 1'b0;
               
            // MAGIC
            rw[15:0]    <= 16'hefcd;                    // +000: MAGIC
            // SPECIAL
            rw[16]      <= 0;                           // +002: enable inactivity timer
            rw[17]      <= 0;                           //       enable send count
            rw[18]      <= 1;                           //       WAIT FOR PCIe DRP RD/WR COMPLETION BEFORE ACCEPT NEW FIFO READ/WRITES
            rw[19]      <= 0;                           //       SLACK
            rw[20]      <= 0;                           //       DRP RD EN
            rw[21]      <= 0;                           //       DRP WR EN
            rw[30:22]   <= 0;                           //       RESERVED FUTURE
            rw[31]      <= 0;                           //       global system reset (GSR) via STARTUPE2 primitive
            // SIZEOF / BYTECOUNT [little-endian]
            rw[63:32]   <= $bits(rw) >> 3;              // +004: bytecount [little endian]
            // CMD INACTIVITY TIMER TRIGGER VALUE
            rw[95:64]   <= 0;                           // +008: cmd_inactivity_timer (ticks) [little-endian]
            // CMD SEND COUNT
            rw[127:96]  <= 0;                           // +00C: cmd_send_count [little-endian]
            // PCIE INITIAL CONFIG (SPECIAL BITSTREAM)
            // NB! "initial" CLK0 values may also be changed in: '_pcie_core_config = {...};' [important on PCIeScreamer].
            rw[143:128] <= 16'h10EE;                    // +010: CFG_SUBSYS_VEND_ID (NOT IMPLEMENTED)
            rw[159:144] <= 16'h0007;                    // +012: CFG_SUBSYS_ID      (NOT IMPLEMENTED)
            rw[175:160] <= 16'h10EE;                    // +014: CFG_VEND_ID        (NOT IMPLEMENTED)
            rw[191:176] <= 16'h0666;                    // +016: CFG_DEV_ID         (NOT IMPLEMENTED)
            rw[199:192] <= 8'h02;                       // +018: CFG_REV_ID         (NOT IMPLEMENTED)
            rw[200]     <= 1'b1;                        // +019: PCIE CORE RESET
            rw[201]     <= 1'b0;                        //       PCIE SUBSYSTEM RESET
            rw[202]     <= 1'b1;                        //       CFGTLP PROCESSING ENABLE
            rw[203]     <= 1'b0;                        //       CFGTLP ZERO DATA
            rw[204]     <= 1'b1;                        //       CFGTLP FILTER TLP FROM USER
            rw[205]     <= 1'b1;                        //       PCIE BAR PIO ON-BOARD PROCESSING ENABLE
            rw[206]     <= 1'b1;                        //       CFGTLP PCIE WRITE ENABLE
            rw[207]     <= 1'b1;                        //       TLP FILTER FROM USER: EXCEPT: Cpl,CplD and CfgRd/CfgWr (handled by rw[204])
            // PCIe DRP, PRSNT#, PERST#
           // rw[208+:16] <= 0;                           // +01A: DRP: pcie_drp_di
            //rw[224+:9]  <= 0;                           // +01C: DRP: pcie_drp_addr
            //rw[233+:7]  <= 0;                           //       SLACK
            // 01E -  
             
        end
    endtask
    
    wire                _cmd_timer_inactivity_enable    = rw[16];
    wire    [31:0]      _cmd_timer_inactivity_ticks     = rw[95:64];
    wire    [15:0]      _cmd_send_count_dword           = rw[63:32];
    wire                _cmd_send_count_enable          = rw[17] & (_cmd_send_count_dword != 16'h0000);
    
    always @ ( posedge clk )
         _pcie_core_config <= rw[207:128];
    assign dpcie.pcie_rst_core                          = _pcie_core_config[72];
    assign dpcie.pcie_rst_subsys                        = _pcie_core_config[73];
    assign dshadow2fifo.cfgtlp_en                       = _pcie_core_config[74];
    assign dshadow2fifo.cfgtlp_zero                     = _pcie_core_config[75];
    assign dshadow2fifo.cfgtlp_filter                   = _pcie_core_config[76];
    assign dshadow2fifo.bar_en                          = _pcie_core_config[77];
    assign dshadow2fifo.cfgtlp_wren                     = _pcie_core_config[78];
    assign dshadow2fifo.alltlp_filter                   = _pcie_core_config[79];
    assign dpcie.drp_en                                 = rw[RWPOS_DRP_WR_EN] | rw[RWPOS_DRP_RD_EN];
    assign dpcie.drp_we                                 = rw[RWPOS_DRP_WR_EN];
    assign dpcie.drp_addr                               = rw[224+:9];
    assign dpcie.drp_di                                 = rw[208+:16];
    
    // ------------------------------------------------------------------------
    // COMMAND / CONTROL FIFO: STATE MACHINE / LOGIC FOR READ/WRITE AND OTHER HOUSEKEEPING TASKS
    // ------------------------------------------------------------------------
 
    wire [63:0] cmd_rx_dout;
    wire        cmd_rx_valid;
    wire        cmd_rx_rd_en_drp = rwi_drp_rd_en | rwi_drp_wr_en | rw[RWPOS_DRP_RD_EN] | rw[RWPOS_DRP_WR_EN];
    wire        cmd_rx_rd_en = tick_100mhz_ce & tickcount64[1] & ( ~rw[RWPOS_WAIT_COMPLETE] | ~cmd_rx_rd_en_drp);
    
    fifo_64_64_clk1_fifocmd i_fifo_cmd_rx(
        .clk            ( clk                       ),
        .srst           ( rst                       ),
        .rd_en          ( cmd_rx_rd_en              ),
        .dout           ( cmd_rx_dout               ),
        .din            ( dcom.com_dout             ),
        .wr_en          ( _cmd_rx_wren              ),
        .full           (                           ),
        .empty          (                           ),
        .valid          ( cmd_rx_valid              )
    );
    
    // Pipeline the command FIFO output.
    //
    // The command word comes out of a block RAM and is then decoded by five LUT
    // levels (address/mask extraction, the rw/ro read mux and the write enable)
    // before it lands in the rw register file.  That does not fit in the 2.482 ns
    // of the 402.8 MHz SFP1 clock: the routed design misses it by 59 ps and
    // neither phys_opt_design nor retiming can move a flop into the cone because
    // the source is a hard RAMB36 output.
    //
    // Registering dout and valid together keeps their pairing and shifts the
    // whole command pipeline by one SFP clock.  The host protocol cannot observe
    // that: a register write is posted and a read is polled, and cmd_rx_rd_en
    // only advances the FIFO on the 100 MHz tick, so the word is stable for
    // several cycles either way.  `keep` stops the optimiser from folding the
    // new flops straight back into the decode.
    (* keep = "true" *) reg [63:0] cmd_rx_dout_q;
    (* keep = "true" *) reg        cmd_rx_valid_q;

    always @ ( posedge clk ) begin
        cmd_rx_dout_q  <= cmd_rx_dout;
        cmd_rx_valid_q <= cmd_rx_valid;
    end

    integer i_write;
    wire [15:0] in_cmd_address_byte = cmd_rx_dout_q[31:16];
    wire [17:0] in_cmd_address_bit  = {in_cmd_address_byte[14:0], 3'b000};
    wire [15:0] in_cmd_value        = {cmd_rx_dout_q[48+:8], cmd_rx_dout_q[56+:8]};
    wire [15:0] in_cmd_mask         = {cmd_rx_dout_q[32+:8], cmd_rx_dout_q[40+:8]};
    wire        f_rw                = in_cmd_address_byte[15];
    wire        f_shadowcfgspace    = in_cmd_address_byte[14];
    wire [15:0] in_cmd_data_in      = (in_cmd_address_bit < (f_rw ? $bits(rw) : $bits(ro))) ? (f_rw ? rw[in_cmd_address_bit+:16] : ro[in_cmd_address_bit+:16]) : 16'h0000;
    wire        in_cmd_read         = cmd_rx_valid_q & cmd_rx_dout_q[12] & ~f_shadowcfgspace;
    wire        in_cmd_write        = cmd_rx_valid_q & cmd_rx_dout_q[13] & ~f_shadowcfgspace & f_rw;
    assign dshadow2fifo.rx_rden     = cmd_rx_valid_q & cmd_rx_dout_q[12] &  f_shadowcfgspace;
    assign dshadow2fifo.rx_wren     = cmd_rx_valid_q & cmd_rx_dout_q[13] &  f_shadowcfgspace & f_rw;
    assign dshadow2fifo.rx_be       = {(in_cmd_mask[7:0] > 0 ? ~in_cmd_address_byte[1] : 1'b0), (in_cmd_mask[15:8] > 0 ? ~in_cmd_address_byte[1] : 1'b0), (in_cmd_mask[7:0] > 0 ? in_cmd_address_byte[1] : 1'b0), (in_cmd_mask[15:8] > 0 ? in_cmd_address_byte[1] : 1'b0)};
    assign dshadow2fifo.rx_addr     = in_cmd_address_byte[11:2];
    assign dshadow2fifo.rx_addr_lo  = in_cmd_address_byte[1];
    assign dshadow2fifo.rx_data     = {in_cmd_value[7:0], in_cmd_value[15:8], in_cmd_value[7:0], in_cmd_value[15:8]};
    
    initial asmcehnk_fifo_ctl_initialvalues();
    logic[3:0] init_state = 4'd0;
    localparam IDLE = 4'd0;
    localparam IDLE_PADDING = 4'd1;
    localparam INIT_PCIE_DCAP_LOW = 4'd2;
    localparam INIT_PCIE_DCAP_LOW_PADDING = 4'd3;
    localparam INIT_LINK_CAP = 4'd4;
    localparam INIT_LINK_CAP_PADDING = 4'd5;
    always @ ( posedge clk )
        if ( rst ) begin
            asmcehnk_fifo_ctl_initialvalues();

            case (init_state)
            IDLE:begin
//                rw[233:224]<=10'h01a;
//                rw[208+16] <= { 2'b0, 1'b1, 1'b0, 1'b0, 2'b00, 1'b0, 1'b0, 2'b00, 1'b1, 1'b0, 1'b0 , 1'b0,1'b0};
//                rw[RWPOS_DRP_WR_EN] <= 1'b1;
                init_state <= INIT_PCIE_DCAP_LOW;

            end
            IDLE_PADDING: begin
                rw[RWPOS_DRP_WR_EN] <= 1'b0;
                init_state <= INIT_PCIE_DCAP_LOW;
            end
            INIT_PCIE_DCAP_LOW: begin
//                rw[224+:9] <= 10'h1b;
//                rw[208+:16] <= {2'b0, 1'b1, 2'b00, 3'b000, 1'b0, 1'b0, 3'b110 , 3'b110};
//                rw[RWPOS_DRP_WR_EN] <= 1'b1;
                init_state <= INIT_PCIE_DCAP_LOW_PADDING;
            end
            INIT_PCIE_DCAP_LOW_PADDING:begin
                rw[RWPOS_DRP_WR_EN] <= 1'b0;
                init_state <= INIT_LINK_CAP;
            end
            INIT_LINK_CAP:begin
                rw[224+:9] <= 10'h25;
                rw[208+:16] <= { 1'b0, 1'b1, 4'b0001, 1'b0, 3'b011, 3'b011, 3'b011};
                rw[RWPOS_DRP_WR_EN] <= 1'b1;
                init_state <= INIT_LINK_CAP_PADDING;
            end
            INIT_LINK_CAP_PADDING:begin
                init_state <= INIT_LINK_CAP_PADDING;
                rw[RWPOS_DRP_WR_EN] <= 1'b0;
            end
            default:
                    init_state <= IDLE;
            endcase
        end else
            begin
                init_state <= IDLE;
                // SHADOW CONFIG SPACE RESPONSE
                if ( dshadow2fifo.tx_valid )
                    begin
                        _cmd_tx_wr_en       <= 1'b1;
                        _cmd_tx_din[31:16]  <= {4'b1100, dshadow2fifo.tx_addr, dshadow2fifo.tx_addr_lo, 1'b0};
                        _cmd_tx_din[15:0]   <= dshadow2fifo.tx_addr_lo ? dshadow2fifo.tx_data[15:0] : dshadow2fifo.tx_data[31:16];                        
                    end
                // READ config
                else if ( in_cmd_read )
                    begin
                        _cmd_tx_wr_en       <= 1'b1;
                        _cmd_tx_din[31:16]  <= in_cmd_address_byte;
                        _cmd_tx_din[15:0]   <= {in_cmd_data_in[7:0], in_cmd_data_in[15:8]};
                    end
                // SEND COUNT ACTION
                else if ( ~_cmd_tx_almost_full & ~in_cmd_write & _cmd_send_count_enable )
                    begin
                        _cmd_tx_wr_en       <= 1'b1;
                        _cmd_tx_din[31:16]  <= 16'hfffe;
                        _cmd_tx_din[15:0]   <= _cmd_send_count_dword;
                        rw[63:32]           <= _cmd_send_count_dword - 1;
                    end
                // INACTIVITY TIMER ACTION
                else if ( ~_cmd_tx_almost_full & ~in_cmd_write & _cmd_timer_inactivity_enable & (_cmd_timer_inactivity_ticks + _cmd_timer_inactivity_base < tickcount64) )
                    begin
                        _cmd_tx_wr_en       <= 1'b1;
                        _cmd_tx_din[31:16]  <= 16'hffff;
                        _cmd_tx_din[15:0]   <= 16'hcede;
                        rw[16]              <= 1'b0;
                    end
                else
                    _cmd_tx_wr_en <= 1'b0;

                // WRITE config
                if ( tickcount64 < 8 )
                    asmcehnk_fifo_ctl_initialvalues();
                else if ( in_cmd_write )
                    for ( i_write = 0; i_write < 16; i_write = i_write + 1 )
                        begin
                            if ( in_cmd_mask[i_write] )
                                rw[in_cmd_address_bit+i_write] <= in_cmd_value[i_write];
                        end

                // UPDATE INACTIVITY TIMER BASE
                if ( dcom.com_din_wr_en | ~dcom.com_din_ready )
                    _cmd_timer_inactivity_base <= tickcount64;  
                    
                // DRP READ/WRITE                        
                if ( dpcie.drp_rdy )
                    begin
                        rwi_drp_rd_en   <= 1'b0;
                        rwi_drp_wr_en   <= 1'b0;
                        rwi_drp_data    <= dpcie.drp_do;
                    end
                else if ( rw[RWPOS_DRP_RD_EN] | rw[RWPOS_DRP_WR_EN] )
                    begin
                        rw[RWPOS_DRP_RD_EN] <= 1'b0;
                        rw[RWPOS_DRP_WR_EN] <= 1'b0;
                        rwi_drp_rd_en <= rwi_drp_rd_en | rw[RWPOS_DRP_RD_EN];
                        rwi_drp_wr_en <= rwi_drp_wr_en | rw[RWPOS_DRP_WR_EN];
                    end      
            
            end

    // ----------------------------------------------------
    // GLOBAL SYSTEM RESET:  ( provided via STARTUPE2 primitive )
    // ----------------------------------------------------
`ifdef ENABLE_STARTUPE2

    STARTUPE2 #(
      .PROG_USR         ( "FALSE"           ),
      .SIM_CCLK_FREQ    ( 0.0               )
    ) i_STARTUPE2 (
      .CFGCLK           (                   ), // ->
      .CFGMCLK          (                   ), // ->
      .EOS              (                   ), // ->
      .PREQ             (                   ), // ->
      .CLK              ( clk               ), // <-
      .GSR              ( rw[RWPOS_GLOBAL_SYSTEM_RESET] | rst_cfg_reload ), // <- GLOBAL SYSTEM RESET
      .GTS              ( 1'b0              ), // <-
      .KEYCLEARB        ( 1'b0              ), // <-
      .PACK             ( 1'b0              ), // <-
      .USRCCLKO         ( 1'b0              ), // <-
      .USRCCLKTS        ( 1'b0              ), // <-
      .USRDONEO         ( 1'b1              ), // <-
      .USRDONETS        ( 1'b1              )  // <-
    );
`endif /* ENABLE_STARTUPE2 */

endmodule
