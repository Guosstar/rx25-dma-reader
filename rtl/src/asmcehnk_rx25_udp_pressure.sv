// One net-clock attempt. Arm only before any valid has been offered; never
// pause again after release. Export a stable bank only after accepted capture.
`resetall
`timescale 1ns/1ps
`default_nettype none
module asmcehnk_rx25_udp_pressure #(
    parameter int C_PAUSE_LIMIT = 250000,
    parameter int C_CAPTURE_LIMIT = 250000
)(
    input wire logic clk, rst,
    input wire logic arm_valid, capture_valid,
    input wire logic [31:0] command_nonce,
    input wire logic path_idle,
    input wire logic [9:0] events,
    output logic pause_output,
    output logic arm_accepted, command_rejected, snapshot_valid,
    output logic [511:0] registers
);
    logic spent, released, failed, captured, capture_pending, covered, recovered, saw_full;
    logic [31:0] nonce, age, capture_age, rejected;
    logic [31:0] headers_in, headers_out, payload_in, payload_out;
    logic [31:0] writes, reads, full_cycles, pending_cycles, run_cycles, peak_run, recoveries;
    logic [31:0] payload_last_out;
    wire nonce_ok = command_nonce[31:5] != 0 && command_nonce[4:0] == 0;
    wire tracking = spent && !captured;
    wire holding = events[0] && events[1] && pause_output;
    always_comb begin
        registers = '0;
        registers[31:0] = 32'h31535250; // PRS1
        registers[63:32] = {23'd0,saw_full,recovered,covered,capture_pending,
            captured,failed,released,pause_output,spent};
        registers[95:64] = nonce;
        registers[127:96] = headers_in;
        registers[159:128] = headers_out;
        registers[191:160] = payload_in;
        registers[223:192] = payload_out;
        registers[255:224] = writes;
        registers[287:256] = reads;
        registers[319:288] = full_cycles;
        registers[351:320] = pending_cycles;
        registers[383:352] = peak_run;
        registers[415:384] = recoveries;
        registers[447:416] = age;
        registers[479:448] = rejected;
        registers[511:480] = payload_last_out;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            spent<=0;released<=0;failed<=0;captured<=0;capture_pending<=0;
            covered<=0;recovered<=0;saw_full<=0;pause_output<=0;
            arm_accepted<=0;command_rejected<=0;snapshot_valid<=0;
            nonce<=0;age<=0;capture_age<=0;rejected<=0;
            headers_in<=0;headers_out<=0;payload_in<=0;payload_out<=0;
            writes<=0;reads<=0;full_cycles<=0;pending_cycles<=0;
            run_cycles<=0;peak_run<=0;recoveries<=0;payload_last_out<=0;
        end else begin
            arm_accepted<=0;command_rejected<=0;snapshot_valid<=0;
            if(arm_valid || capture_valid) begin
                if(arm_valid && !capture_valid && !spent && nonce_ok && path_idle &&
                    C_PAUSE_LIMIT>=40 && C_CAPTURE_LIMIT>=1) begin
                    spent<=1;pause_output<=1;nonce<=command_nonce;arm_accepted<=1;
                end else if(capture_valid && !arm_valid && spent && released &&
                    !captured && !capture_pending && command_nonce==nonce) begin
                    capture_pending<=1;capture_age<=0;
                end else begin
                    command_rejected<=1;
                    if(!captured && rejected!=32'hffff_ffff) rejected<=rejected+1;
                end
            end
            if(tracking) begin
                if(events[4]) headers_in<=headers_in+1;
                if(events[5]) headers_out<=headers_out+1;
                if(events[6]) payload_in<=payload_in+1;
                if(events[7]) payload_out<=payload_out+1;
                if(events[2]) writes<=writes+1;
                if(events[3]) reads<=reads+1;
                if(events[0]) begin full_cycles<=full_cycles+1;saw_full<=1;end
                if(events[1]) pending_cycles<=pending_cycles+1;
                if(events[9]) payload_last_out<=payload_last_out+1;
                if(holding) begin
                    run_cycles<=run_cycles+1;
                    if(run_cycles+1>peak_run) peak_run<=run_cycles+1;
                end else run_cycles<=0;
                if(released && covered && !recovered && events[2]) begin
                    recovered<=1;recoveries<=recoveries+1;
                end
            end
            if(pause_output) begin
                age<=age+1;
                if(holding && run_cycles==39) begin
                    pause_output<=0;released<=1;covered<=1;
                end else if(age>=32'(C_PAUSE_LIMIT-1)) begin
                    pause_output<=0;released<=1;failed<=1;
                end
            end
            if(capture_pending) begin
                if(path_idle) begin
                    capture_pending<=0;captured<=1;snapshot_valid<=1;
                    if(!covered || !recovered) failed<=1;
                end else if(capture_age>=32'(C_CAPTURE_LIMIT-1)) begin
                    // Timeout is explicitly incomplete, never a successful snapshot.
                    capture_pending<=0;captured<=1;failed<=1;snapshot_valid<=1;
                end else capture_age<=capture_age+1;
            end
        end
    end
endmodule
`default_nettype wire
