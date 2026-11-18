// One-shot PL11 v1 board-to-board diagnostic. No PCIe requester or host address.
`resetall
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_rx25_pl11.svh"
module asmcehnk_rx25_first16 #(
    parameter int C_WAIT_LIMIT = 25_000_000
)(
    input wire logic clk, rst,
    input wire logic start_valid,
    input wire logic [31:0] start_rid,
    input wire logic link_ok, external_fault,
    output wire logic tx_valid,
    input wire logic tx_ready,
    output logic [63:0] tx_data,
    output wire logic tx_last,
    input wire logic rx_valid,
    input wire logic [63:0] rx_data,
    input wire logic rx_last,
    output wire logic rx_ready,
    output logic [383:0] registers
);
    localparam logic [127:0] PATTERN = 128'hA5A5000000000001_A5A5000000000000;
    logic spent, done, fault;
    logic [31:0] rid, elapsed, reasons;
    logic [127:0] payload;
    logic [3:0] rx_index;
    logic [2:0] tx_index;
    logic tx_active, rx_active;
    logic [31:0] tx_words, rx_words;
    wire busy = tx_active || rx_active;
    wire expired = busy && elapsed >= 32'(C_WAIT_LIMIT-1);
    wire context_fault = (spent && (!link_ok || external_fault)) || C_WAIT_LIMIT < 8;
    logic [63:0] expected_rx;
    always_comb begin
        case (tx_index)
            0: tx_data = {`PL11_TYPE_REQ, `PL11_VERSION, `PL11_MAGIC};
            1: tx_data = {32'd0, rid};
            2: tx_data = 64'd16;
            default: tx_data = 64'd0;
        endcase
        case (rx_index)
            0: expected_rx = {`PL11_TYPE_DATA, `PL11_VERSION, `PL11_MAGIC};
            1: expected_rx = {16'h0001, 16'd0, rid};
            2: expected_rx = 64'd16;
            3,4,5: expected_rx = 64'd0;
            6: expected_rx = PATTERN[63:0];
            default: expected_rx = PATTERN[127:64];
        endcase
    end
    assign tx_valid = tx_active;
    assign tx_last = tx_index == 5;
    // Always drain the diagnostic FIFO; unexpected, early and duplicate words
    // during an owned attempt fault it instead of becoming a second request.
    assign rx_ready = 1'b1;
    always_comb begin
        registers = '0;
        registers[31:0] = 32'h41363146; // little-endian F16A
        registers[63:32] = {25'd0, (done && payload == PATTERN), 1'b1,
                                    link_ok, fault, done, busy, spent};
        registers[95:64] = rid;
        registers[127:96] = done ? 32'd16 : 32'd0;
        registers[255:128] = payload;
        registers[287:256] = tx_words;
        registers[319:288] = rx_words;
        registers[351:320] = elapsed;
        registers[383:352] = reasons;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            spent <= 0; done <= 0; fault <= 0; rid <= 0;
            elapsed <= 0; reasons <= 0; payload <= 0;
            rx_index <= 0; tx_index <= 0; tx_active <= 0; rx_active <= 0;
            tx_words <= 0; rx_words <= 0;
        end else begin
            if (start_valid && !spent && start_rid != 0 && link_ok && !external_fault) begin
                spent <= 1; rid <= start_rid; tx_active <= 1;
            end
            if (busy && !expired) elapsed <= elapsed + 1;
            // Even after a fault, finish an already offered request frame.
            if (tx_active && tx_ready) begin
                tx_words <= tx_words + 1;
                if (tx_index == 5) begin
                    tx_active <= 0;
                    if (!fault && !expired && !context_fault) rx_active <= 1;
                end else tx_index <= tx_index + 1;
            end
            if (rx_valid && spent) begin
                rx_words <= rx_words + 1;
                if (!rx_active || rx_data != expected_rx || rx_last != (rx_index == 7)) begin
                    fault <= 1; done <= 0; rx_active <= 0;
                    reasons <= reasons | 32'h4;
                end else if (!fault && !expired && !context_fault) begin
                    if (rx_index == 6) payload[63:0] <= rx_data;
                    if (rx_index == 7) begin
                        payload[127:64] <= rx_data; rx_active <= 0; done <= 1;
                    end else rx_index <= rx_index + 1;
                end
            end
            if (expired || context_fault) begin
                fault <= 1; done <= 0; rx_active <= 0;
                reasons <= reasons | (expired ? 32'h2 : 0) | (context_fault ? 32'h1 : 0) |
                           ((rx_valid && spent && (!rx_active || rx_data != expected_rx ||
                             rx_last != (rx_index == 7))) ? 32'h4 : 0);
            end
        end
    end
endmodule
`default_nettype wire
