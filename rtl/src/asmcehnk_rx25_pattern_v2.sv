// PL11 v2 ONBOARD_PATTERN wire endpoint. No host address or PCIe interface.
// Standalone: not yet selected by the board mux or connected to A's writer.
// STOP_ACK proves only this endpoint stopped admitting/producing DATA and the
// earlier DATA frame passed its final ready/valid handshake. It is not an A
// posted-write fence, link-delivery acknowledgement, or OS release permission.
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_pattern_v2 #(
    parameter int RX_IDLE_LIMIT = 4096
)(
    input wire clk, rst,
    // Trusted outer allocator must change this on every reset/reconfiguration.
    input wire [63:0] boot_epoch,
    input wire [63:0] rx_data,
    input wire rx_valid, rx_last,
    output wire rx_ready,
    output logic [63:0] tx_data,
    output wire tx_valid, tx_last,
    input wire tx_ready,
    output logic [1:0] session_state, // 0 closed, 1 ready, 2 stopped, 3 fault
    output logic [31:0] accepted_requests, rejected_frames, stop_acks
);
    localparam logic [31:0] MAGIC=32'h31314c50;
    localparam logic [15:0] HELLO=16'h10, HELLO_ACK=16'h11,
        OPEN=16'h12, OPEN_ACK=16'h13, REQ=16'h14, DATA=16'h15,
        STOP=16'h16, STOP_ACK=16'h17, CLOSE=16'h18, CLOSE_ACK=16'h19;
    logic [63:0] header[0:11], outgoing[0:11], stop_header[0:11];
    logic [3:0] rx_index;
    logic dropping, frame_pending;
    integer idle_cycles;
    logic [63:0] epoch_q, controller_q, session_q, window_q;
    logic [63:0] last_sequence, stop_sequence;
    logic ack_pending, ack_sent, tx_busy, tx_payload;
    logic [5:0] tx_index;
    logic [31:0] payload_offset, payload_length;

    wire common_ok = header[0][31:0]==MAGIC && header[0][47:32]==16'd2 &&
        header[1]!=0 && header[8]==64'd1 && header[9]==64'd4096 &&
        header[10]==0 && header[11]==0;
    wire empty_fields = header[6]==0 && header[7]==0;
    wire token_ok = header[1]==controller_q && header[2]==epoch_q &&
        header[3]==session_q && header[4]==window_q;
    wire [15:0] kind = header[0][63:48];
    wire req_ok = session_state==1 && token_ok &&
        last_sequence!=64'hffffffffffffffff && header[5]==last_sequence+1 &&
        header[6][31:0]!=0 && header[6][63:32]!=0 && header[6][63:48]==0 &&
        (header[7][63:32]==16 || header[7][63:32]==128) &&
        header[7][3:0]==0 && header[7][31:0]<=4096-header[7][63:32];

    assign rx_ready = !frame_pending;
    assign tx_valid = tx_busy;
    wire [5:0] final_index = tx_payload ? 6'd11+6'(payload_length>>3) : 6'd11;
    assign tx_last = tx_busy && tx_index==final_index;
    always_comb begin
        tx_data=0;
        if(tx_index<12) tx_data=outgoing[tx_index];
        else if(tx_payload)
            tx_data=64'ha5a5000000000000 |
                ((64'(payload_offset)>>3)+64'(tx_index-6'd12));
    end

    // All response headers are copied before starting TX. Neither RX nor STOP
    // can modify an outgoing frame while downstream ready is low.
    task automatic start_reply(input logic [15:0] reply_kind, input logic with_payload);
        for(integer k=0;k<12;k=k+1) outgoing[k]<=header[k];
        outgoing[0]<={reply_kind,16'd2,MAGIC};
        outgoing[2]<=epoch_q;
        outgoing[10]<=64'h10f;
        outgoing[11]<=0;
        tx_payload<=with_payload;
        payload_offset<=header[7][31:0];
        payload_length<=header[7][63:32];
        tx_index<=0;
        tx_busy<=1;
    endtask

    always_ff @(posedge clk) begin
        if(rst) begin
            epoch_q<=boot_epoch; controller_q<=0; session_q<=0; window_q<=0;
            session_state<=0; last_sequence<=0; stop_sequence<=0;
            rx_index<=0; dropping<=0; frame_pending<=0; idle_cycles<=0;
            ack_pending<=0; ack_sent<=0; tx_busy<=0; tx_payload<=0;
            tx_index<=0; payload_offset<=0; payload_length<=0;
            accepted_requests<=0; rejected_frames<=0; stop_acks<=0;
            for(integer k=0;k<12;k=k+1) begin
                header[k]<=0; outgoing[k]<=0; stop_header[k]<=0;
            end
        end else begin
            if(tx_busy && tx_ready) begin
                if(tx_last) begin
                    tx_busy<=0;
                    if(outgoing[0][63:48]==STOP_ACK) begin
                        ack_sent<=1; stop_acks<=stop_acks+1;
                    end
                end else tx_index<=tx_index+1;
            end

            // Accept only exactly 12 words and a real last boundary. On an
            // overlength/timeout, drain through last; never resync on payload.
            if(rx_valid && rx_ready) begin
                idle_cycles<=0;
                if(dropping) begin
                    if(rx_last) begin dropping<=0; rx_index<=0; end
                end else if(rx_last) begin
                    if(rx_index==11) begin header[11]<=rx_data; frame_pending<=1; end
                    else rejected_frames<=rejected_frames+1;
                    rx_index<=0;
                end else if(rx_index==11) begin
                    dropping<=1; rx_index<=0; rejected_frames<=rejected_frames+1;
                end else begin header[rx_index]<=rx_data; rx_index<=rx_index+1; end
            end else if(rx_index!=0 && !dropping && !frame_pending) begin
                if(idle_cycles==RX_IDLE_LIMIT-1) begin
                    dropping<=1; rx_index<=0; idle_cycles<=0;
                    rejected_frames<=rejected_frames+1;
                end else idle_cycles<=idle_cycles+1;
            end

            if(session_state==3) begin
                if(frame_pending) begin
                    frame_pending<=0; rejected_frames<=rejected_frames+1;
                end
            end else if(boot_epoch==0 || boot_epoch!=epoch_q) begin
                session_state<=3; ack_pending<=0;
            end else if(!tx_busy && ack_pending) begin
                // DATA's last beat has already been accepted. The ACK is next
                // on the SAME ordered output stream, never a separate bypass.
                for(integer k=0;k<12;k=k+1) outgoing[k]<=stop_header[k];
                outgoing[0]<={STOP_ACK,16'd2,MAGIC};
                outgoing[10]<=64'h10f; outgoing[11]<=0;
                tx_payload<=0; tx_index<=0; tx_busy<=1; ack_pending<=0;
            end else if(frame_pending) begin
                frame_pending<=0;
                if(!common_ok) rejected_frames<=rejected_frames+1;
                else if(kind==STOP && session_state!=0 && token_ok &&
                        empty_fields && header[5]!=0 &&
                        (session_state==1 || header[5]==stop_sequence)) begin
                    session_state<=2; stop_sequence<=header[5];
                    // Coalesce duplicates while ACK is queued or in flight.
                    if(session_state==1 || (!ack_pending &&
                        !(tx_busy && outgoing[0][63:48]==STOP_ACK))) begin
                        for(integer k=0;k<12;k=k+1) stop_header[k]<=header[k];
                        ack_pending<=1;
                    end
                end else if(tx_busy || ack_pending) rejected_frames<=rejected_frames+1;
                else case(kind)
                    HELLO: begin
                        if(session_state==0 && header[2]==0 && header[3]==0 &&
                           header[4]==0 && header[5]==0 && empty_fields)
                            start_reply(HELLO_ACK,0);
                        else rejected_frames<=rejected_frames+1;
                    end
                    OPEN: begin
                        if(session_state==0 && header[2]==epoch_q && header[3]!=0 &&
                           header[4]!=0 && header[5]==0 && empty_fields &&
                           (controller_q==0 || header[1]==controller_q) && header[3]>session_q) begin
                            controller_q<=header[1]; session_q<=header[3]; window_q<=header[4];
                            last_sequence<=0; stop_sequence<=0; ack_sent<=0;
                            session_state<=1; start_reply(OPEN_ACK,0);
                        end else if(session_state==1 && token_ok && last_sequence==0 &&
                                    header[5]==0 && empty_fields) begin
                            // A lost OPEN_ACK may be retried before any REQ.
                            start_reply(OPEN_ACK,0);
                        end else rejected_frames<=rejected_frames+1;
                    end
                    REQ: begin
                        if(req_ok) begin
                            last_sequence<=header[5]; accepted_requests<=accepted_requests+1;
                            start_reply(DATA,1);
                        end else rejected_frames<=rejected_frames+1;
                    end
                    CLOSE: begin
                        if((session_state==2 || session_state==0) && token_ok && ack_sent &&
                           header[5]==stop_sequence && empty_fields) begin
                            session_state<=0; start_reply(CLOSE_ACK,0);
                        end else rejected_frames<=rejected_frames+1;
                    end
                    default: rejected_frames<=rejected_frames+1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
