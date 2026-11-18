// ---------------------------------------------------------------------------
// asmcehnk_frame_fifo128
//
// Beat-granular buffer between a PL11 frame extractor and a word-granular
// consumer.
//
// Why it exists: the from-wire TLP stream (asmcehnk_tlps128_src_fifo's output)
// must never be stalled.  Its FIFO issues the read one cycle before `valid`
// appears, so deasserting tready for even one cycle destroys the word that is
// already in flight -- the shim cannot pace itself by refusing beats.  This
// buffer therefore accepts one 128-bit beat (two frame words) per cycle,
// unconditionally, and drains one 64-bit word per cycle to the request engine.
//
// A frame word pair is stored as {word1, word0}: the low half is emitted first.
// `last` rides with the beat and is attached to its high word, which is always
// the final word of a PL11 frame (frames are a whole number of 4-dword beats).
//
// Overflow is sticky and reported: losing a word silently would write stale
// data into host memory at the right address, which is the worst possible
// failure mode for a memory reader.
// ---------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module asmcehnk_frame_fifo128 #(
    parameter int C_DEPTH = 16,
    parameter int C_AW    = 4
)(
    input  wire logic          rst,
    input  wire logic          clk,

    // ---- beat side, never stalls ------------------------------------------
    input  wire logic [127:0]  wr_data,
    input  wire logic          wr_last,
    input  wire logic          wr_en,
    output logic               full,
    output logic               overflow,

    // ---- word side ---------------------------------------------------------
    output logic [63:0]        rd_data,
    output logic               rd_last,
    output logic               rd_valid,
    input  wire logic          rd_en,
    output logic               empty
);

    logic [127:0] mem   [0:C_DEPTH-1];
    logic         mem_l [0:C_DEPTH-1];
    logic [C_AW-1:0] wr_ptr, rd_ptr;
    logic [C_AW:0]   count;
    logic            half;      // low word of the head entry already consumed

    assign full    = (count == (C_AW+1)'(C_DEPTH));
    assign empty   = (count == '0);
    assign rd_valid = !empty;
    assign rd_data  = half ? mem[rd_ptr][127:64] : mem[rd_ptr][63:0];
    assign rd_last  = half && mem_l[rd_ptr];

    wire wr_fire = wr_en && !full;
    wire rd_fire = rd_en && !empty;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            count    <= '0;
            half     <= 1'b0;
            overflow <= 1'b0;
        end else begin
            if (wr_en && full) begin
                overflow <= 1'b1;
            end

            if (wr_fire) begin
                mem[wr_ptr]   <= wr_data;
                mem_l[wr_ptr] <= wr_last;
                wr_ptr <= wr_ptr + 1'b1;
            end

            if (rd_fire) begin
                if (half) begin
                    half   <= 1'b0;
                    rd_ptr <= rd_ptr + 1'b1;
                end else begin
                    half <= 1'b1;
                end
            end

            case ({wr_fire, rd_fire && half})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule

`default_nettype wire
