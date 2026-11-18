// ---------------------------------------------------------------------------
// asmcehnk_pcie_bme_boot
//
// Driver-free requester arming.  Windows assigns BARs during enumeration even
// when no function driver exists, so a driverless target still answers config
// cycles and its BARs are mapped.  What is *not* guaranteed is Command.BME
// (Bus Master Enable, bit 2) plus Memory Space Enable (bit 1): pci.sys sets
// those in IRP_MN_START_DEVICE, and a device with no driver never gets that
// IRP.  A requester that is not armed has its MRd discarded upstream, which
// looks identical to "the address does not exist".
//
// Timing history -- read before changing the defaults:
//   The first version wrote Command = 0x0006 exactly three times at
//   2^20 / 2^22 / 2^24 cycles (~8.4 / 33.5 / 134 ms at 125 MHz) and then went
//   quiet forever.  UEFI and Windows start config-cycling the endpoint seconds
//   after that, and their CfgWr of offset 0x04 overwrites whatever this module
//   wrote.  So the three boot writes cannot survive enumeration: they are
//   clobbered long before the OS decides the device has no driver.  Any test
//   of "can the endpoint arm itself" has to re-assert *after* enumeration.
//
// C_HOLD_REPEAT / C_HOLD_LOG2 add that late phase.  With C_HOLD_REPEAT = 0 the
// module behaves exactly like the sealed images (three writes, then done), so
// enabling the late phase is a per-build decision, not a global behaviour
// change.  With C_HOLD_REPEAT = N it keeps rewriting Command every
// 2^C_HOLD_LOG2 cycles N more times, which covers the whole boot and the first
// minutes of the desktop.  A host that clears BME is corrected within one
// period; a host that keeps it set sees an idempotent write of the same value.
//
// `busy` is asserted only while a management write is actually in flight, not
// for the whole boot window: asmcehnk_pcie_cfg_us muxes its normal register
// file out whenever busy is high, and the old version locked that file out for
// the full 134 ms.
//
// Gated by C_BME_BOOT, which the RX25 pa build maps to PARAM_RX25_ADDR_MODE.
// The sealed pattern images keep the gate at 0, so their config-space
// behaviour is byte-for-byte what was signed off.
//
// Each phase is bounded: if cfg_mgmt_read_write_done never arrives (the IP can
// ignore a management write while it is busy with a host config cycle), the
// FSM gives up after C_DONE_TIMEOUT cycles and moves on.  A missing done must
// not wedge the boot counter.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module asmcehnk_pcie_bme_boot #(
    parameter logic [31:0] C_COMMAND_VALUE = 32'h0000_0006,  // MEM_SPACE | BUS_MASTER
    parameter logic [9:0]  C_COMMAND_DW    = 10'd1,
    parameter int unsigned C_STAGE0_LOG2   = 20,
    parameter int unsigned C_STAGE1_LOG2   = 22,
    parameter int unsigned C_STAGE2_LOG2   = 24,
    parameter int unsigned C_DONE_TIMEOUT  = 1024,
    // Late re-assert phase.  0 disables it (legacy three-write behaviour).
    // 23 ~= 67 ms at 125 MHz; 400 repeats covers ~27 s of boot.
    parameter int unsigned C_HOLD_LOG2     = 0,
    parameter int unsigned C_HOLD_REPEAT   = 0
)(
    input  wire logic        clk,
    input  wire logic        rst,
    output logic             busy,
    output logic [9:0]       mgmt_addr,
    output logic [7:0]       mgmt_function_number,
    output logic             mgmt_write,
    output logic [31:0]      mgmt_write_data,
    output logic [3:0]       mgmt_byte_enable,
    output logic             mgmt_read,
    input  wire logic        mgmt_read_write_done
);
    typedef enum logic [3:0] {
        S_WAIT0, S_DO0, S_WAIT1, S_DO1, S_WAIT2, S_DO2, S_HOLD, S_DOR, S_DONE
    } state_t;

    state_t      state_reg;
    logic [24:0] cnt_reg;
    logic [11:0] hold_reg;
    logic [15:0] rep_reg;

    localparam logic [15:0] REPEAT = 16'(C_HOLD_REPEAT);

    wire do_phase = (state_reg == S_DO0) || (state_reg == S_DO1) ||
                    (state_reg == S_DO2) || (state_reg == S_DOR);
    wire [24:0] limit = (state_reg == S_WAIT0) ? (25'd1 << C_STAGE0_LOG2) :
                        (state_reg == S_WAIT1) ? (25'd1 << C_STAGE1_LOG2) :
                        (state_reg == S_WAIT2) ? (25'd1 << C_STAGE2_LOG2) :
                        (state_reg == S_HOLD)  ? (25'd1 << C_HOLD_LOG2)  : 25'd0;
    wire hold_expired = (hold_reg >= C_DONE_TIMEOUT[11:0]);

    // Legacy mode (C_HOLD_REPEAT = 0) owns the port for the whole boot window,
    // exactly like the sealed images.  The late-re-assert mode releases it
    // between writes so the normal config register file keeps working.
    assign busy                 = do_phase || ((REPEAT == 16'd0) && (state_reg != S_DONE));
    assign mgmt_addr            = C_COMMAND_DW;
    assign mgmt_function_number = 8'd0;
    assign mgmt_write           = do_phase;
    assign mgmt_write_data      = C_COMMAND_VALUE;
    assign mgmt_byte_enable     = 4'b0011;   // bytes 0..1 of the Command register
    assign mgmt_read            = 1'b0;

    always_ff @(posedge clk) begin
        if (rst) begin
            state_reg <= S_WAIT0;
            cnt_reg   <= 25'd0;
            hold_reg  <= 12'd0;
            rep_reg   <= 16'd0;
        end else begin
            if (do_phase) begin
                if (hold_reg != 12'hfff) hold_reg <= hold_reg + 12'd1;
            end else begin
                hold_reg <= 12'd0;
                if (cnt_reg != limit) cnt_reg <= cnt_reg + 25'd1;
            end

            case (state_reg)
                S_WAIT0: if (cnt_reg == limit) begin cnt_reg <= 25'd0; state_reg <= S_DO0; end
                S_DO0:   if (mgmt_read_write_done || hold_expired) begin
                             cnt_reg <= 25'd0; state_reg <= S_WAIT1;
                         end
                S_WAIT1: if (cnt_reg == limit) begin cnt_reg <= 25'd0; state_reg <= S_DO1; end
                S_DO1:   if (mgmt_read_write_done || hold_expired) begin
                             cnt_reg <= 25'd0; state_reg <= S_WAIT2;
                         end
                S_WAIT2: if (cnt_reg == limit) begin cnt_reg <= 25'd0; state_reg <= S_DO2; end
                S_DO2:   if (mgmt_read_write_done || hold_expired) begin
                             cnt_reg <= 25'd0;
                             state_reg <= (REPEAT == 16'd0) ? S_DONE : S_HOLD;
                         end
                S_HOLD:  if (cnt_reg == limit) begin cnt_reg <= 25'd0; state_reg <= S_DOR; end
                S_DOR:   if (mgmt_read_write_done || hold_expired) begin
                             cnt_reg <= 25'd0;
                             if ((rep_reg + 16'd1) >= REPEAT) begin
                                 rep_reg   <= REPEAT;
                                 state_reg <= S_DONE;
                             end else begin
                                 rep_reg   <= rep_reg + 16'd1;
                                 state_reg <= S_HOLD;
                             end
                         end
                default: state_reg <= S_DONE;
            endcase
        end
    end
endmodule

`default_nettype wire
