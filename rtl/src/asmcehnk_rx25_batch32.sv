// Bounded, host-address-free PL11 diagnostic. Not the legacy FIRST16 ABI.
`resetall
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_rx25_pl11.svh"
module asmcehnk_rx25_batch32 #(
    parameter int C_WAIT_LIMIT = 25_000_000
)(
    input wire logic clk, rst,
    input wire logic start_valid,
    input wire logic [31:0] start_nonce,
    input wire logic link_ok, external_fault,
    output logic start_accepted, start_rejected,
    output wire logic tx_valid,
    input wire logic tx_ready,
    output logic [63:0] tx_data,
    output wire logic tx_last,
    input wire logic rx_valid,
    input wire logic [63:0] rx_data,
    input wire logic rx_last,
    output wire logic rx_ready,
    // Actual received data, 128 little-endian DWORDs; no host-memory writer.
    input wire logic [6:0] payload_read_index,
    output wire logic [31:0] payload_read_data,
    output logic [511:0] registers
);
    logic spent, running, done, fault, tx_active;
    logic [31:0] nonce, elapsed, reasons, rejected_starts;
    logic [31:0] tx_words, rx_words, completed_mask;
    logic [5:0] sent, completed, peak_owned;
    logic [2:0] tx_index, rx_index;
    logic [4:0] response_index;
    logic [63:0] payload [0:63];
    logic [63:0] expected_rx;
    logic [31:0] rx_error, context_error;
    wire busy = running || tx_active;
    wire [5:0] outstanding = sent - completed;
    wire [5:0] owned = outstanding + {5'd0, tx_active};
    wire expired = running && elapsed >= 32'(C_WAIT_LIMIT-1);
    wire tx_fire = tx_active && tx_ready;
    wire tx_end = tx_fire && tx_index == 5;
    wire [4:0] candidate = rx_data[4:0];
    wire candidate_ok = rx_data[63:32] == 32'h0001_0000 &&
        rx_data[31:5] == nonce[31:5] &&
        {1'b0, candidate} < sent && !completed_mask[candidate];
    assign tx_valid = tx_active;
    assign tx_last = tx_index == 5;
    assign rx_ready = 1'b1; // faults drain; never reuse the attempt
    assign payload_read_data = payload_read_index[0] ?
        payload[payload_read_index[6:1]][63:32] :
        payload[payload_read_index[6:1]][31:0];

    always_comb begin
        case (tx_index)
            0: tx_data = {`PL11_TYPE_REQ, `PL11_VERSION, `PL11_MAGIC};
            1: tx_data = {32'd0, nonce[31:5], sent[4:0]};
            2: tx_data = 64'd16;
            3: tx_data = {55'd0, sent[4:0], 4'd0};
            default: tx_data = 64'd0;
        endcase
        case (rx_index)
            0: expected_rx = {`PL11_TYPE_DATA, `PL11_VERSION, `PL11_MAGIC};
            1: expected_rx = rx_data; // full identity checked by candidate_ok
            2: expected_rx = 64'd16; // status OK, exactly 16 bytes
            3: expected_rx = {55'd0, response_index, 4'd0};
            4,5: expected_rx = 64'd0; // host echo and reserved
            6: expected_rx = 64'hA5A5_0000_0000_0000 | {58'd0,response_index,1'b0};
            default: expected_rx = 64'hA5A5_0000_0000_0000 | {58'd0,response_index,1'b1};
        endcase
        rx_error = 0;
        if (rx_valid && spent && !fault) begin
            if (!running || (rx_index == 0 && outstanding == 0)) rx_error = 32'h40;
            else begin
                if (rx_last != (rx_index == 7)) rx_error = rx_error | 32'h08;
                if (rx_index == 1 && !candidate_ok) rx_error = rx_error | 32'h10;
                if (rx_data != expected_rx)
                    rx_error = rx_error | (rx_index >= 6 ? 32'h20 : 32'h04);
            end
        end
        context_error = 0;
        if (spent && (!link_ok || external_fault || C_WAIT_LIMIT < 8)) context_error = 1;
        if (expired) context_error = context_error | 2;
    end

    always_comb begin
        registers = '0;
        registers[31:0] = 32'h41323342; // B32A, distinct from F16A
        registers[63:32] = {24'd0, (done && completed_mask == 32'hffff_ffff),
            1'b1, link_ok, fault, done, busy, running, spent};
        registers[95:64] = nonce;
        registers[127:96] = {26'd0, sent};
        registers[159:128] = {26'd0, completed};
        registers[191:160] = {22'd0, completed, 4'd0};
        registers[223:192] = completed_mask;
        registers[255:224] = tx_words;
        registers[287:256] = rx_words;
        registers[319:288] = elapsed;
        registers[351:320] = reasons;
        registers[383:352] = {26'd0, peak_owned};
        registers[415:384] = rejected_starts;
        registers[447:416] = {26'd0, owned};
        registers[479:448] = 32'd32;
        registers[511:480] = 32'd16;
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            spent <= 0; running <= 0; done <= 0; fault <= 0; tx_active <= 0;
            nonce <= 0; elapsed <= 0; reasons <= 0; rejected_starts <= 0;
            tx_words <= 0; rx_words <= 0; completed_mask <= 0;
            sent <= 0; completed <= 0; peak_owned <= 0;
            tx_index <= 0; rx_index <= 0; response_index <= 0;
            start_accepted <= 0; start_rejected <= 0;
            for (i = 0; i < 64; i = i+1) payload[i] <= 0;
        end else begin
            start_accepted <= 0; start_rejected <= 0;
            if (start_valid) begin
                if (!spent && start_nonce[31:5] != 0 && start_nonce[4:0] == 0 &&
                    link_ok && !external_fault && !rx_valid && C_WAIT_LIMIT >= 8) begin
                    spent <= 1; running <= 1; nonce <= start_nonce;
                    tx_active <= 1; tx_index <= 0; peak_owned <= 1;
                    start_accepted <= 1;
                end else begin
                    start_rejected <= 1;
                    if (rejected_starts != 32'hffff_ffff) rejected_starts <= rejected_starts + 1;
                end
            end
            if (running && !expired) elapsed <= elapsed + 1;
            // A valid already offered on the wire is never withdrawn by a fault.
            if (tx_fire) begin
                tx_words <= tx_words + 1;
                if (tx_index == 5) begin
                    sent <= sent + 1; tx_active <= 0; tx_index <= 0;
                end else tx_index <= tx_index + 1;
            end
            if (running && !fault && context_error == 0 && rx_error == 0 &&
                !tx_active && sent < 32 && outstanding < 16) begin
                tx_active <= 1; tx_index <= 0;
                if (outstanding + 1 > peak_owned) peak_owned <= outstanding + 1;
            end
            if (rx_valid && spent && !fault && running) begin
                rx_words <= rx_words + 1;
                // Keep actual received payload, including a mismatching word.
                if (rx_index >= 6) payload[{response_index,rx_index[0]}] <= rx_data;
                if (rx_error == 0 && context_error == 0) begin
                    if (rx_index == 1) response_index <= candidate;
                    if (rx_index == 7) begin
                        completed <= completed + 1;
                        completed_mask[response_index] <= 1;
                        rx_index <= 0;
                        if (completed == 31) begin running <= 0; done <= 1; end
                    end else rx_index <= rx_index + 1;
                end
            end
            if (context_error != 0 || rx_error != 0) begin
                reasons <= reasons | context_error | rx_error;
                fault <= 1; running <= 0; done <= 0;
            end
        end
    end
endmodule
`default_nettype wire
