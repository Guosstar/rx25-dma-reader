// RXD2 diagnostic control frames, separate from the paused COM/UDP path.
// Fixed 96-byte payload; no address, length or DMA operation is accepted.
`resetall
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_diag_link #(
    parameter bit C_RESPONDER=0,
    parameter logic [47:0] C_MAC=48'h0200000000de
)(
    input wire logic clk,rst,
    input wire logic s_hdr_valid,
    output wire logic s_hdr_ready,
    input wire logic [47:0] s_dest_mac,s_src_mac,
    input wire logic [15:0] s_type,
    input wire logic [63:0] s_data,
    input wire logic [7:0] s_keep,
    input wire logic s_valid,
    output wire logic s_ready,
    input wire logic s_last,s_user,
    output logic rx_valid,
    input wire logic rx_ready,
    output logic [7:0] rx_opcode,
    output logic [31:0] rx_nonce,rx_status,
    output logic [511:0] rx_bank,
    input wire logic tx_valid,
    output wire logic tx_ready,
    input wire logic [7:0] tx_opcode,
    input wire logic [31:0] tx_nonce,tx_status,
    input wire logic [511:0] tx_bank,
    output wire logic m_hdr_valid,
    input wire logic m_hdr_ready,
    output wire logic [47:0] m_dest_mac,m_src_mac,
    output wire logic [15:0] m_type,
    output wire logic [63:0] m_data,
    output wire logic [7:0] m_keep,
    output wire logic m_valid,
    input wire logic m_ready,
    output wire logic m_last,m_user,
    output logic [31:0] cnt_rx_good,cnt_rx_bad,cnt_tx
);
    function automatic [63:0] reverse_bytes(input [63:0] w);
        for(integer j=0;j<8;j++) reverse_bytes[j*8+:8]=w[56-j*8+:8];
    endfunction
    function automatic [31:0] crc_word(input [31:0] seed,input [63:0] w);
        reg [31:0] c;
        begin
            c=seed;
            for(integer b=0;b<8;b++) for(integer k=0;k<8;k++)
                c=(c>>1)^((c[0]^w[56-b*8+k])?32'hedb88320:32'd0);
            crc_word=c;
        end
    endfunction
    logic rx_active,rx_bad;
    logic [3:0] rx_index;
    logic [31:0] rx_crc;
    logic [63:0] header0,header1,header2;
    logic [511:0] bank_buffer;
    logic bank_nonzero;
    wire [63:0] rx_word=reverse_bytes(s_data);
    wire [7:0] incoming_op=header0[15:8];
    wire incoming_request=incoming_op==1 || incoming_op==2;
    wire incoming_response=incoming_op==8'h81 || incoming_op==8'h82;
    wire fields_ok=header0[63:32]==32'h52584432 && header0[31:16]==1 &&
        header0[7:0]==(C_RESPONDER?8'd1:8'd2) &&
        (C_RESPONDER?incoming_request:incoming_response) &&
        header1[63:37]!=0 && header1[36:32]==0 && header1[31:0]==32'h00600000 &&
        header2[31:0]==0 && header2[63:32]<=2 &&
        (!C_RESPONDER || (header2==0 && !bank_nonzero));
    assign s_hdr_ready=!rx_active && (!rx_valid || rx_ready) && !rst;
    assign s_ready=rx_active && !rst;
    always_ff @(posedge clk) begin
        if(rst) begin
            rx_active<=0;rx_bad<=0;rx_index<=0;rx_crc<=32'hffffffff;
            header0<=0;header1<=0;header2<=0;bank_buffer<=0;bank_nonzero<=0;
            rx_valid<=0;rx_opcode<=0;rx_nonce<=0;rx_status<=0;rx_bank<=0;
            cnt_rx_good<=0;cnt_rx_bad<=0;
        end else begin
            if(rx_valid && rx_ready) rx_valid<=0;
            if(s_hdr_valid && s_hdr_ready) begin
                rx_active<=1;rx_index<=0;rx_crc<=32'hffffffff;bank_buffer<=0;bank_nonzero<=0;
                rx_bad<=s_dest_mac!=C_MAC || s_src_mac!=C_MAC || s_type!=16'h88b5;
            end
            if(s_valid && s_ready) begin
                if(rx_index<11) rx_crc<=crc_word(rx_crc,rx_word);
                if(rx_index==0) header0<=rx_word;
                if(rx_index==1) header1<=rx_word;
                if(rx_index==2) header2<=rx_word;
                if(rx_index>=3 && rx_index<=10) begin
                    bank_buffer[(rx_index-3)*64+:64]<=rx_word;
                    // Accepted bank words precede the trailer, including index 10.
                    // Keep the 512-bit responder zero check off the publish CE.
                    bank_nonzero<=bank_nonzero || (|rx_word);
                end
                if(rx_index!=15) rx_index<=rx_index+1;
                if(s_keep!=8'hff || s_user || rx_index>11) rx_bad<=1;
                if(s_last) begin
                    rx_active<=0;
                    if(!rx_bad && s_keep==8'hff && !s_user && rx_index==11 && fields_ok &&
                        rx_word=={~rx_crc,32'h43454e44}) begin
                        rx_opcode<=incoming_op;rx_nonce<=header1[63:32];rx_status<=header2[63:32];
                        rx_bank<=bank_buffer;rx_valid<=1;cnt_rx_good<=cnt_rx_good+1;
                    end else cnt_rx_bad<=cnt_rx_bad+1;
                end
            end
        end
    end

    localparam [1:0] TX_IDLE=0,TX_HEADER=1,TX_BODY=2;
    logic [1:0] tx_state;
    logic [3:0] tx_index;
    logic [7:0] held_opcode;
    logic [31:0] held_nonce,held_status,tx_crc;
    logic [511:0] held_bank;
    logic [63:0] tx_word;
    always_comb begin
        case(tx_index)
            0:tx_word={32'h52584432,16'd1,held_opcode,(C_RESPONDER?8'd2:8'd1)};
            1:tx_word={held_nonce,16'd96,16'd0};
            2:tx_word={held_status,32'd0};
            11:tx_word={~tx_crc,32'h43454e44};
            default:tx_word=held_bank[(tx_index-3)*64+:64];
        endcase
    end
    assign tx_ready=tx_state==TX_IDLE && !rst;
    assign m_hdr_valid=tx_state==TX_HEADER && !rst;
    assign m_src_mac=C_MAC;
    assign m_dest_mac=C_MAC;
    assign m_type=16'h88b5;
    assign m_valid=tx_state==TX_BODY && !rst;
    assign m_data=reverse_bytes(tx_word);
    assign m_keep=8'hff;
    assign m_last=tx_index==11;
    assign m_user=0;
    always_ff @(posedge clk) begin
        if(rst) begin
            tx_state<=TX_IDLE;tx_index<=0;tx_crc<=32'hffffffff;
            held_opcode<=0;held_nonce<=0;held_status<=0;held_bank<=0;cnt_tx<=0;
        end else case(tx_state)
            TX_IDLE:if(tx_valid && tx_ready) begin
                held_opcode<=tx_opcode;held_nonce<=tx_nonce;held_status<=tx_status;held_bank<=tx_bank;
                tx_state<=TX_HEADER;tx_index<=0;tx_crc<=32'hffffffff;
            end
            TX_HEADER:if(m_hdr_valid && m_hdr_ready) tx_state<=TX_BODY;
            TX_BODY:if(m_valid && m_ready) begin
                if(tx_index<11) tx_crc<=crc_word(tx_crc,tx_word);
                if(tx_index==11) begin tx_state<=TX_IDLE;cnt_tx<=cnt_tx+1;end
                else tx_index<=tx_index+1;
            end
            default:tx_state<=TX_IDLE;
        endcase
    end
endmodule
`default_nettype wire
