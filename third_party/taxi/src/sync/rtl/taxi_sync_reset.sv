// SPDX-License-Identifier: CERN-OHL-S-2.0
/*

Copyright (c) 2014-2025 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Synchronizes an active-high reset signal to a given clock by using a
 * pipeline of N registers.
 *
 * C_ASYNC_ASSERT selects how the request is sampled:
 *
 *   1 (default, original behaviour) the request drives the asynchronous
 *     preset of the whole pipeline, so assertion is immediate and release is
 *     delayed by N edges.  This is the right choice when the request is
 *     already in `clk`'s domain (a local power-on reset, a GT reset-done
 *     flag, anything quasi-static within the domain).
 *
 *   0 the request is sampled as a level by an N-deep ASYNC_REG chain with no
 *     asynchronous pin at all.  Use this whenever the request comes from a
 *     different clock domain.  With C_ASYNC_ASSERT=1 the first flop's
 *     preset/clear pin is driven by a foreign clock, which the CDC engine
 *     reports as CDC-10 / CDC-11 (Critical) on every build: it cannot prove
 *     the de-assertion edge is captured, and the fanout lands on an
 *     asynchronous control pin of a cell that may be physically far away.
 *     A level chain has neither problem, and every consumer in this design
 *     uses the synchronised output inside a clocked block anyway, so losing
 *     the asynchronous assertion edge changes no state: the pointer or FSM
 *     still clears on the next `clk` edge, which is the earliest edge at
 *     which the destination domain can act on it.
 *
 * The AS02 images use 0 for every reset that crosses a clock domain and keep
 * 1 for same-domain resets.
 */
module taxi_sync_reset #
(
    // depth of synchronizer
    parameter N = 2,
    // 1: asynchronous assertion (original), 0: level sampling with no async pin
    parameter bit C_ASYNC_ASSERT = 1'b1
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    output wire logic  out
);

generate
if (C_ASYNC_ASSERT) begin : g_async_assert

    (* async_reg="true", srl_style="register", shreg_extract="no" *)
    logic [N-1:0] sync_reg = '1;

    assign out = sync_reg[N-1];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sync_reg <= '1;
        end else begin
            sync_reg <= {sync_reg[N-2:0], 1'b0};
        end
    end

end else begin : g_level

    (* async_reg="true", srl_style="register", shreg_extract="no" *)
    logic [N-1:0] sync_level_reg = '1;

    assign out = sync_level_reg[N-1];

    always_ff @(posedge clk) begin
        sync_level_reg <= {sync_level_reg[N-2:0], rst};
    end

end
endgenerate

endmodule

`resetall
