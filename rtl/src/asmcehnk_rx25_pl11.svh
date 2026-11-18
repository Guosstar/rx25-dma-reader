// ---------------------------------------------------------------------------
// asmcehnk_rx25_pl11.svh -- card-to-card frame format for RX25.
//
// PL11 is the wire format between the RX25 receiver (control machine) and the
// responder (target machine).  Nothing outside the two FPGAs parses it: the
// host side only sees the CQ, and leechcore surfaces PL11 problems through
// error_detail, so the layout below is ours to define.
//
// Framing
//   * one frame = 6 x 64-bit header words + 0..N payload words
//   * 64-bit words, little endian, payload starts at byte 0x30
//   * payload length is always a multiple of 16 (one 128-bit data beat), so a
//     receiver can hand beats straight to asmcehnk_mwr_stream
//   * every word carries valid/ready; `last` marks the final word of a frame
//   * a receiver re-synchronises on MAGIC in word 0; anything else is dropped
//     and counted (LC_FPGA_RX_CQ_DETAIL_PL11_MAGIC / _FRAME / _HEADER)
//
// Header words
//   w0  [31:0]  magic    PL11_MAGIC
//       [47:32]  version  PL11_VERSION
//       [63:48]  type     PL11_TYPE_*
//   w1  [31:0]  request_id
//       [47:32]  sequence record index inside the request, 0-based
//       [63:48]  flags    PL11_FLAG_LAST_RECORD marks the final record
//   w2  [31:0]  length   payload bytes in THIS frame (0 for a request), or the
//                        total transfer length for a request frame
//       [63:32]  status   PL11_STATUS_* (responses only)
//   w3  [63:0]  remote_pa   target physical address (request only)
//   w4  [63:0]  host_iova   control-host physical address (response only, echo)
//   w5  [63:0]  reserved, must be zero
//
// Request (type 1): sequence 0, flags 0, length = whole transfer, no payload.
// Data     (type 2): one per record, payload = the record's bytes.
// A request is answered by DATA records with sequence 0..N; the record with
// PL11_FLAG_LAST_RECORD set ends the transfer.
//
// Why the header is duplicated across records: the RX card matches by
// request_id and checks sequence strictly increasing, so a lost or reordered
// frame is detected instead of silently corrupting host memory at the wrong
// offset (LC_FPGA_RX_CQ_DETAIL_PL11_SEQUENCE).
// ---------------------------------------------------------------------------

`ifndef _asmcehnk_rx25_pl11_svh_
`define _asmcehnk_rx25_pl11_svh_

// 'PL11' little endian.
`define PL11_MAGIC          32'h3131_4C50

`define PL11_VERSION        16'd1

`define PL11_TYPE_REQ       16'd1
`define PL11_TYPE_DATA      16'd2

`define PL11_FLAG_LAST_RECORD 16'h0001

`define PL11_STATUS_OK      32'd0
`define PL11_STATUS_SHORT   32'd1    // responder could not read the whole span
`define PL11_STATUS_ABORT   32'd2

`define PL11_HDR_WORDS      6
`define PL11_HDR_BYTES      48
`define PL11_MAX_RECORD     256      // payload bytes per data frame

`endif
