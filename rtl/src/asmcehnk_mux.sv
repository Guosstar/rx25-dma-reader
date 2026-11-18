//
// asmcehnk FPGA.
//
// Merge multiple 32-bit words into a 256-bit word consisting of one (1) 32-bit
// status word and seven (7) data words. This is done to enable relatively
// efficient transmission over the FT601 together with some additional info.
//
// (c) Ulf Frisk, 2017-2024
// Author: Ulf Frisk, asmcehnk@frizk.net
//

`timescale 1ns / 1ps

module asmcehnk_mux(
    input                clk,
    input                rst,
    // output
    output [255:0]       dout,
    output               valid,
    input                rd_en,
    // port0: input highest priority
    input  [31:0]        p0_din,
    input  [1:0]         p0_tag,
    input  [1:0]         p0_ctx,
    input                p0_wr_en,
    output               p0_req_data,
    // port1:
    input  [31:0]        p1_din,
    input  [1:0]         p1_tag,
    input  [1:0]         p1_ctx,
    input                p1_wr_en,
    output               p1_req_data,
    // port2:
    input  [31:0]        p2_din,
    input  [1:0]         p2_tag,
    input  [1:0]         p2_ctx,
    input                p2_wr_en,
    output               p2_req_data,
    // port3:
    input  [31:0]        p3_din,
    input  [1:0]         p3_tag,
    input  [1:0]         p3_ctx,
    input                p3_wr_en,
    output               p3_req_data,
    // port4:
    input  [31:0]        p4_din,
    input  [1:0]         p4_tag,
    input  [1:0]         p4_ctx,
    input                p4_wr_en,
    output               p4_req_data,
    // port5:
    input  [31:0]        p5_din,
    input  [1:0]         p5_tag,
    input  [1:0]         p5_ctx,
    input                p5_wr_en,
    output               p5_req_data,
    // port6:
    input  [31:0]        p6_din,
    input  [1:0]         p6_tag,
    input  [1:0]         p6_ctx,
    input                p6_wr_en,
    output               p6_req_data,
    // port7:
    input  [31:0]        p7_din,
    input  [1:0]         p7_tag,
    input  [1:0]         p7_ctx,
    input                p7_wr_en,
    output               p7_req_data
    );

    // 'en' is delayed 1CLK so it's in synch with inputs.
    //      output integrity is handled by extra register.
    // max_fanout: 'en' drives the CE of 15x32 data/ctx flops, so the single net
    // is both long and heavily loaded. Replicating it is behaviour-identical.
    (* max_fanout = 32 *) reg en;
    always @ ( posedge clk )
        en <= rd_en && !rst;

    assign p0_req_data = rd_en;
    assign p1_req_data = rd_en;
    assign p2_req_data = rd_en;
    assign p3_req_data = rd_en;
    assign p4_req_data = rd_en;
    assign p5_req_data = rd_en;
    assign p6_req_data = rd_en;
    assign p7_req_data = rd_en;

    reg [31:0]  data_reg[14];
    reg [3:0]   ctx_reg[14];

    wire        p8_wr_en;
    (* max_fanout = 32 *) reg [3:0] idx_base;
    // Prefix-sum index computation.
    // The original form chained eight 4-bit increments:
    //   p1_idx = p0_idx + p0_wr_en; p2_idx = p1_idx + p1_wr_en; ...
    // which put eight dependent adders in front of the 15-entry write decode
    // and dominated the 402.8 MHz path. Summing the enables in a tree and
    // adding idx_base once is arithmetically identical (4-bit wraparound
    // included) with ~3 levels instead of 8.
    wire [3:0] n0 = {3'b000, p0_wr_en};
    wire [3:0] n1 = {3'b000, p1_wr_en};
    wire [3:0] n2 = {3'b000, p2_wr_en};
    wire [3:0] n3 = {3'b000, p3_wr_en};
    wire [3:0] n4 = {3'b000, p4_wr_en};
    wire [3:0] n5 = {3'b000, p5_wr_en};
    wire [3:0] n6 = {3'b000, p6_wr_en};
    wire [3:0] n7 = {3'b000, p7_wr_en};

    wire [3:0] s01 = n0 + n1;
    wire [3:0] s23 = n2 + n3;
    wire [3:0] s45 = n4 + n5;
    wire [3:0] s67 = n6 + n7;
    wire [3:0] s0123 = s01 + s23;
    wire [3:0] s4567 = s45 + s67;
    wire [3:0] s01234567 = s0123 + s4567;   // p0..p7 enables
    wire [3:0] s0123456 = s0123 + s45 + n6; // p0..p6 enables

    wire [3:0]  p0_idx = idx_base;
    wire [3:0]  p1_idx = idx_base + n0;
    wire [3:0]  p2_idx = idx_base + s01;
    wire [3:0]  p3_idx = idx_base + s01 + n2;
    wire [3:0]  p4_idx = idx_base + s0123;
    wire [3:0]  p5_idx = idx_base + s0123 + n4;
    wire [3:0]  p6_idx = idx_base + s0123 + s45;
    wire [3:0]  p7_idx = idx_base + s0123456;
    wire [3:0]  p8_idx = idx_base + s01234567;
    wire [3:0] idx_max = idx_base + s01234567 + {3'b000, p8_wr_en};

    // P8: INTERNAL "IDLE PORT"
    // 8-bit and saturating: a 4-bit counter wrapped at 15, which made the
    // "> 7" pad condition re-arm periodically. Widening the window also gives
    // in-flight answers far more time to land before the short frame is padded,
    // which is where burst traffic was losing tail words.
    reg [7:0]   idle_count;
    wire [31:0] p8_din = 32'hffffffff;
    wire [1:0]  p8_tag = 2'b11;
    wire [1:0]  p8_ctx = 2'b11;
    assign      p8_wr_en = en && (idx_base > 0) && (idle_count > 8'd63) && (idx_base == p8_idx);
    
    
    
    // output buffer logic, when rd_en is deasserted the output data must be
    // buffered not to cause data loss.
    reg             dout_valid;
    wire [255:0]    dout_data = { ctx_reg[1], ctx_reg[0], ctx_reg[3], ctx_reg[2], ctx_reg[5], ctx_reg[4], 4'hE, ctx_reg[6], data_reg[0], data_reg[1], data_reg[2], data_reg[3], data_reg[4], data_reg[5], data_reg[6] };
    reg [1:0]       dout_buf_count;
    reg [255:0]     dout_buf_data;
    reg [255:0]     dout_buf_tail;
    wire            dout_buf_valid = (dout_buf_count != 0);
    assign valid = rd_en && (dout_buf_valid || dout_valid);
    assign dout = dout_buf_valid ? dout_buf_data : dout_data;

    // rd_en stops new requests, but en still admits one in-flight return.
    // Preserve both the currently presented result and that final result.
    always @(posedge clk) begin
        if (rst) begin
            dout_buf_count <= 0;
        end else if (rd_en) begin
            if (dout_buf_count != 0) begin
                if (dout_buf_count == 2) begin
                    dout_buf_data <= dout_buf_tail;
                    if (dout_valid) dout_buf_tail <= dout_data;
                end else if (dout_valid) begin
                    dout_buf_data <= dout_data;
                end
                if (!dout_valid) dout_buf_count <= dout_buf_count - 1'b1;
            end
        end else if (dout_valid) begin
            if (dout_buf_count == 0) dout_buf_data <= dout_data;
            else dout_buf_tail <= dout_data;
            dout_buf_count <= dout_buf_count + 1'b1;
        end
    end
    
    
    
    always @ ( posedge clk ) begin
        if( rst )
            begin
                idx_base <= 0;
                idle_count <= 0;
                dout_valid <= 0;
            end
        else
            begin
                // Output queue is maintained separately above.
            
                // OUTPUT VALID:
                dout_valid <= en && (idx_max >= 7);
                
                if( en ) begin
                    // NEXT INDEX BASE:
                    idx_base <= idx_max - ((idx_max >= 7) ? 7 : 0);
                    // IDLE COUNT:
                    idle_count <= ((idx_base > 0) && (idx_base == p8_idx)) ?
                                  ((idle_count == 8'hFF) ? 8'hFF : (idle_count + 8'd1)) : 8'd0;
                    // DATA/CTX writes into index [0-8]:
                    if( p0_wr_en ) begin  data_reg[p0_idx] <= p0_din;  ctx_reg[p0_idx] <= {p0_ctx, p0_tag};  end
                    if( p1_wr_en ) begin  data_reg[p1_idx] <= p1_din;  ctx_reg[p1_idx] <= {p1_ctx, p1_tag};  end
                    if( p2_wr_en ) begin  data_reg[p2_idx] <= p2_din;  ctx_reg[p2_idx] <= {p2_ctx, p2_tag};  end
                    if( p3_wr_en ) begin  data_reg[p3_idx] <= p3_din;  ctx_reg[p3_idx] <= {p3_ctx, p3_tag};  end
                    if( p4_wr_en ) begin  data_reg[p4_idx] <= p4_din;  ctx_reg[p4_idx] <= {p4_ctx, p4_tag};  end
                    if( p5_wr_en ) begin  data_reg[p5_idx] <= p5_din;  ctx_reg[p5_idx] <= {p5_ctx, p5_tag};  end
                    if( p6_wr_en ) begin  data_reg[p6_idx] <= p6_din;  ctx_reg[p6_idx] <= {p6_ctx, p6_tag};  end
                    if( p7_wr_en ) begin  data_reg[p7_idx] <= p7_din;  ctx_reg[p7_idx] <= {p7_ctx, p7_tag};  end
                    if( p8_wr_en ) begin  data_reg[p8_idx] <= p8_din;  ctx_reg[p8_idx] <= {p8_ctx, p8_tag};  end
                end
                
                if( dout_valid ) begin
                    // DATA/CTX previous move:
                    if( idx_base > 0) begin  data_reg[0] <= data_reg[7+0];  ctx_reg[0] <= ctx_reg[7+0];  end
                    if( idx_base > 1) begin  data_reg[1] <= data_reg[7+1];  ctx_reg[1] <= ctx_reg[7+1];  end
                    if( idx_base > 2) begin  data_reg[2] <= data_reg[7+2];  ctx_reg[2] <= ctx_reg[7+2];  end
                    if( idx_base > 3) begin  data_reg[3] <= data_reg[7+3];  ctx_reg[3] <= ctx_reg[7+3];  end
                    if( idx_base > 4) begin  data_reg[4] <= data_reg[7+4];  ctx_reg[4] <= ctx_reg[7+4];  end
                    if( idx_base > 5) begin  data_reg[5] <= data_reg[7+5];  ctx_reg[5] <= ctx_reg[7+5];  end
                    if( idx_base > 6) begin  data_reg[6] <= data_reg[7+6];  ctx_reg[6] <= ctx_reg[7+6];  end
                end
                

            end
    end
endmodule
