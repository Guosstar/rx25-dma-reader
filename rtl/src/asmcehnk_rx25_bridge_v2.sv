// SAME-CLOCK DIAGNOSTIC register bridge; not connected to legacy BAR/board.
// Trusted kernel transport only. VERIFIED is not a public userspace command.
// Reset destroys this instance, not its old DMA obligations. Supply a new,
// externally managed, nonzero incarnation after every destructive reset.
`timescale 1ns/1ps
`default_nettype none
`include "asmcehnk_header.svh"
module asmcehnk_rx25_bridge_v2 #(
    parameter int A_WAIT_LIMIT=1000000,
    parameter int SINK_WAIT_LIMIT=1000000,
    parameter int VERIFY_WAIT_LIMIT=1000000
)(
    input wire clk,rst,external_fault,
    input wire [63:0] incarnation,
    input wire wr_en,rd_en,
    input wire [11:0] wr_addr,rd_addr,
    input wire [31:0] wr_data,
    input wire [3:0] wr_be,
    output logic [31:0] rd_data,
    output wire irq,faulted,bridge_owned,release_allowed,
    output wire [63:0] tx_data,
    output wire tx_valid,tx_last,
    input wire tx_ready,
    input wire [63:0] rx_data,
    input wire rx_valid,rx_last,
    output wire rx_ready,
    IfAXIS128.source tlps_out
);
    localparam logic [31:0] E_CFG_OK=1,E_CFG_BAD=2,E_JOB_OK=4,E_JOB_BAD=8,
        E_RETIRE=16,E_VERIFY_OK=32,E_VERIFY_BAD=64,E_COMPLETE=128,
        E_STOP_OK=256,E_STOP_BAD=512,E_PEER=1024,E_FAULT=2048;
    localparam logic [31:0] F_EXTERNAL=1,F_INCAR=2,F_BUS=4,F_FRAME=8,
        F_COMMAND=16,F_ACK=32,F_OVERFLOW=64,F_PIPELINE=128,F_HOST=256,F_COUNTER=512;
    logic [63:0] incarnation_q;
    logic [831:0] stage;
    logic [103:0] dirty;
    logic [25:0] word_complete,word_matches,word_nonzero;
    logic [447:0] binding;
    logic [223:0] task_q;
    logic verify_success_q;
    logic configured_q,active_q,stop_q,stop_sent,stop_done;
    logic [63:0] stop_sequence_q;
    logic [2:0] pending;
    logic offered;
    logic sticky_fault,fault_reported,peer_seen;
    logic [31:0] reasons;
    logic [1279:0] events[0:7];
    logic [2:0] head,tail;
    logic [3:0] count;
    logic [63:0] next_id,head_id;
    logic [127:0] ack_stage;
    logic [15:0] ack_dirty;
    logic [15:0] ack_matches;
    logic [3:0] ack_word_ok;
    logic [31:0] dropped;
    wire p_cfg_ready,p_cfg_ok,p_cfg_bad,p_job_ready,p_job_ok,p_job_bad;
    wire p_verify_ready,p_verify_ok,p_verify_bad,p_completed,p_stop_ok,p_stop_bad;
    wire p_retire,p_retire_success,p_configured,p_quarantined,p_owned,p_peer,p_release;
    wire [63:0] p_retire_sequence;
    wire [31:0] p_retire_bytes;
    wire [2:0] guard_state,a_state;
    wire [3:0] sink_state;
    wire commit=wr_en && wr_addr==12'h010;
    wire ack_write=wr_en && wr_addr==12'h040;
    // Precompute only the staging predicates. Each commit clears freshness;
    // binding/task/STOP identity changes can never validate old staging bytes.
    wire frame_complete=&word_complete;
    wire frame_inc=&word_matches[1:0];
    wire binding_match=&word_matches[15:2];
    wire task_match=&word_matches[22:16];
    wire [2:0] opcode=wr_data[2:0];
    wire command_ok=frame_complete && frame_inc && wr_be==15 && wr_data[30:3]==0 &&
        ((opcode==1 && !configured_q && pending==0 && !stop_q) ||
         (opcode==2 && configured_q && !active_q && pending==0 && !stop_q && binding_match) ||
         (opcode==3 && configured_q && active_q && pending==0 && binding_match && task_match && word_matches[23]) ||
         (opcode==4 && configured_q && binding_match && (|word_nonzero[25:24]) &&
          (!stop_q || (&word_matches[25:24]))));
    // Head identity can change ONLY on ACK; that edge clears all dirty bytes.
    // Prechecking each byte when staged is therefore equivalent to comparing
    // the complete ACK on commit, without a RAM read in the fault-priority path.
    wire [127:0] ack_expected={head_id,incarnation_q};
    wire ack_ok=ack_write && wr_be==15 && wr_data==1 && count!=0 && (&ack_word_ok);
    wire staging_write=wr_addr>=12'h100 && wr_addr<12'h168 && wr_addr[1:0]==0;
    wire ack_staging_write=wr_addr>=12'h030 && wr_addr<=12'h03c && wr_addr[1:0]==0;
    wire bad_bus=wr_en && (wr_addr[1:0]!=0 || wr_be==0 ||
        !(staging_write || ack_staging_write || commit || ack_write));
    wire bad_command=commit && !command_ok;
    wire host_fault=commit && wr_data[31];
    wire [31:0] native_flags=(p_cfg_ok?E_CFG_OK:0)|(p_cfg_bad?E_CFG_BAD:0)|
        (p_job_ok?E_JOB_OK:0)|(p_job_bad?E_JOB_BAD:0)|(p_retire?E_RETIRE:0)|
        (p_verify_ok?E_VERIFY_OK:0)|(p_verify_bad?E_VERIFY_BAD:0)|
        (p_completed?E_COMPLETE:0)|(p_stop_ok?E_STOP_OK:0)|(p_stop_bad?E_STOP_BAD:0)|
        ((p_peer && !peer_seen)?E_PEER:0);
    // Overflow is detected combinationally so it also defeats success on this
    // pipeline edge. Full+valid ACK is a legal simultaneous pop/push.
    wire overflow=(native_flags!=0 || (sticky_fault && !fault_reported)) && count==8 && !ack_ok;
    wire [31:0] fault_causes=(external_fault?F_EXTERNAL:0)|
        ((incarnation==0 || incarnation!=incarnation_q)?F_INCAR:0)|
        (bad_bus?F_BUS:0)|(bad_command?(frame_complete?F_COMMAND:F_FRAME):0)|
        ((ack_write && !ack_ok)?F_ACK:0)|(overflow?F_OVERFLOW:0)|
        ((p_quarantined || p_cfg_bad || p_job_bad || p_verify_bad || p_stop_bad ||
          (p_retire && (!p_retire_success || p_retire_sequence!=task_q[63:0] || p_retire_bytes!=task_q[223:192])))?F_PIPELINE:0)|
        (host_fault?F_HOST:0)|((next_id==64'hffffffffffffffff)?F_COUNTER:0);
    wire fault_now=sticky_fault || fault_causes!=0;
    wire [31:0] event_flags=native_flags|((fault_now && !fault_reported)?E_FAULT:0);
    wire push=event_flags!=0 && (count<8 || ack_ok) && next_id!=64'hffffffffffffffff;
    wire p_cfg_valid=pending==1 && offered;
    wire p_job_valid=pending==2 && offered;
    wire p_verify_valid=pending==3 && offered;
    // STOP never closes pipeline admission before an offered JOB has received
    // its accepted reply. The bridge itself closes admission at STOP commit.
    wire p_stop_valid=stop_q && !stop_sent && !fault_now && pending!=1 && pending!=2;
    wire [31:0] status={16'd0,offered,stop_done,p_cfg_ready,p_verify_ready,p_job_ready,
        p_quarantined,p_owned,p_peer,p_configured,
        count==8,count!=0,active_q,configured_q,stop_q,pending!=0,sticky_fault};
    logic [1279:0] event_image;
    always_comb begin
        event_image=0;
        event_image[63:0]=incarnation_q;
        event_image[127:64]=next_id;
        event_image[159:128]=event_flags;
        event_image[191:160]=reasons|fault_causes;
        event_image[223:192]=status;
        event_image[255:224]=p_retire_bytes;
        event_image[319:256]=p_retire_sequence;
        event_image[767:320]=binding;
        event_image[991:768]=task_q;
        event_image[1023:992]={31'd0,verify_success_q};
        event_image[1087:1024]=stop_sequence_q;
        event_image[1119:1088]={31'd0,p_retire_success};
    end
    assign faulted=sticky_fault;
    assign bridge_owned=active_q;
    assign release_allowed=1'b0;
    assign irq=count!=0 || sticky_fault;
    always_comb begin
        rd_data=0;
        if(rd_en && rd_addr[1:0]==0) begin
            case(rd_addr)
                12'h000:rd_data=32'h32424852; // RHB2, little endian bytes
                12'h004:rd_data=32'h00020000;
                12'h008:rd_data=32'h0000000f; // frame/event/fault/same-clock only
                12'h00c:rd_data=status;
                12'h014:rd_data=reasons;
                12'h018:rd_data=incarnation_q[31:0];
                12'h01c:rd_data=incarnation_q[63:32];
                12'h020:rd_data=count!=0?head_id[31:0]:0;
                12'h024:rd_data=count!=0?head_id[63:32]:0;
                12'h028:rd_data=count!=0?events[head][159:128]:0;
                12'h02c:rd_data={28'd0,count};
                12'h044:rd_data=dropped;
                default:if(rd_addr>=12'h200 && rd_addr<12'h2a0 && count!=0)
                    rd_data=events[head][int'((rd_addr-12'h200)>>2)*32+:32];
            endcase
        end
    end
    // A word-local byte merge feeds a registered comparison on the SAME edge
    // that accepts those bytes. The next edge may be COMMIT, no extra wait.
    // No fault signal or pipeline acceptance is delayed by these registers.
    wire [831:0] staging_expected={stop_sequence_q,32'd0,task_q,binding,incarnation_q};
    for(genvar w=0;w<26;w=w+1) begin : g_staging
        wire select_word=wr_en && wr_addr==12'('h100+w*4);
        wire [31:0] byte_mask={{8{wr_be[3]}},{8{wr_be[2]}},{8{wr_be[1]}},{8{wr_be[0]}}};
        wire [31:0] merged=(stage[w*32+:32]&~byte_mask)|(wr_data&byte_mask);
        always_ff @(posedge clk) begin
            if(rst) begin
                stage[w*32+:32]<=0;dirty[w*4+:4]<=0;
                word_complete[w]<=0;word_matches[w]<=0;word_nonzero[w]<=0;
            end else begin
                if(select_word) begin
                    stage[w*32+:32]<=merged;
                    dirty[w*4+:4]<=dirty[w*4+:4]|wr_be;
                    word_complete[w]<=&(dirty[w*4+:4]|wr_be);
                    if(w==23) word_matches[w]<=merged[31:1]==0;
                    else word_matches[w]<=merged==staging_expected[w*32+:32];
                    word_nonzero[w]<=merged!=0;
                end
                if(commit) begin dirty[w*4+:4]<=0;word_complete[w]<=0;end
            end
        end
    end
    for(genvar a=0;a<4;a=a+1) begin : g_ack
        wire select_word=wr_en && wr_addr==12'('h030+a*4);
        wire [31:0] byte_mask={{8{wr_be[3]}},{8{wr_be[2]}},{8{wr_be[1]}},{8{wr_be[0]}}};
        wire [31:0] merged=(ack_stage[a*32+:32]&~byte_mask)|(wr_data&byte_mask);
        always_ff @(posedge clk) begin
            if(rst) begin
                ack_stage[a*32+:32]<=0;ack_dirty[a*4+:4]<=0;ack_matches[a*4+:4]<=0;ack_word_ok[a]<=0;
            end else begin
                if(select_word) begin
                    ack_stage[a*32+:32]<=merged;
                    ack_dirty[a*4+:4]<=ack_dirty[a*4+:4]|wr_be;
                    ack_word_ok[a]<=(&(ack_dirty[a*4+:4]|wr_be)) && merged==ack_expected[a*32+:32];
                    for(integer b=0;b<4;b=b+1) if(wr_be[b])
                        ack_matches[a*4+b]<=wr_data[b*8+:8]==ack_expected[a*32+b*8+:8];
                end
                if(ack_write) begin ack_dirty[a*4+:4]<=0;ack_matches[a*4+:4]<=0;ack_word_ok[a]<=0;end
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            incarnation_q<=incarnation;binding<=0;task_q<=0;
            verify_success_q<=0;configured_q<=0;active_q<=0;stop_q<=0;stop_sent<=0;stop_done<=0;
            stop_sequence_q<=0;pending<=0;offered<=0;sticky_fault<=0;fault_reported<=0;
            peer_seen<=0;reasons<=0;head<=0;tail<=0;count<=0;next_id<=1;head_id<=1;
            dropped<=0;
        end else begin
            if(fault_now) begin sticky_fault<=1;reasons<=reasons|fault_causes;end
            if(p_peer) peer_seen<=1;
            if(commit) begin
                if(command_ok && !fault_now) begin
                    case(opcode)
                        1:begin binding<=stage[511:64];pending<=1;offered<=1;end
                        2:begin task_q<=stage[735:512];verify_success_q<=0;active_q<=1;pending<=2;offered<=1;end
                        3:begin verify_success_q<=stage[736];pending<=3;offered<=1;end
                        4:begin stop_q<=1;stop_sequence_q<=stage[831:768];end
                        default:;
                    endcase
                end
            end
            // Transport valids/identity stay stable under fault and backpressure.
            if((p_cfg_valid && p_cfg_ready)||(p_job_valid && p_job_ready)||(p_verify_valid && p_verify_ready)) offered<=0;
            if(!offered && (p_cfg_ok || p_cfg_bad || p_job_ok || p_job_bad || p_verify_ok || p_verify_bad)) pending<=0;
            if(p_cfg_ok && !fault_now) configured_q<=1;
            if(p_completed && !fault_now) active_q<=0;
            if(p_stop_valid) stop_sent<=1;
            if(p_stop_ok) stop_done<=1;
            if(ack_ok) begin head<=head+1'b1;head_id<=head_id+1'b1;end
            if(push) begin
                events[tail]<=event_image;tail<=tail+1'b1;next_id<=next_id+1'b1;
                if(event_flags[11]) fault_reported<=1;
            end else if(native_flags!=0 && dropped!=32'hffffffff) dropped<=dropped+1'b1;
            case({push,ack_ok})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:;
            endcase
        end
    end
    asmcehnk_rx25_pipeline_v2 #(.A_WAIT_LIMIT(A_WAIT_LIMIT),.SINK_WAIT_LIMIT(SINK_WAIT_LIMIT),
        .VERIFY_WAIT_LIMIT(VERIFY_WAIT_LIMIT)) pipeline(
        .clk(clk),.rst(rst),.external_fault(fault_now),
        .cfg_valid(p_cfg_valid),.cfg_ready(p_cfg_ready),.cfg_accepted(p_cfg_ok),.cfg_rejected(p_cfg_bad),
        .cfg_local_epoch(binding[63:0]),.cfg_peer_epoch(binding[127:64]),.cfg_session(binding[191:128]),
        .cfg_window(binding[255:192]),.cfg_base(binding[319:256]),.cfg_buffer_id(binding[383:320]),
        .cfg_bytes(binding[415:384]),.cfg_caps(binding[447:416]),
        .job_valid(p_job_valid),.job_ready(p_job_ready),.job_accepted(p_job_ok),.job_rejected(p_job_bad),
        .job_sequence(task_q[63:0]),.job_rid(task_q[95:64]),.job_generation(task_q[127:96]),
        .job_source_offset(task_q[159:128]),.job_target_offset(task_q[191:160]),.job_length(task_q[223:192]),
        .verified_valid(p_verify_valid),.verified_ready(p_verify_ready),.verified_success(verify_success_q),
        .verified_local_epoch(binding[63:0]),.verified_peer_epoch(binding[127:64]),
        .verified_session(binding[191:128]),.verified_window(binding[255:192]),.verified_buffer_id(binding[383:320]),
        .verified_sequence(task_q[63:0]),.verified_rid(task_q[95:64]),.verified_generation(task_q[127:96]),
        .verified_length(task_q[223:192]),.verified_accepted(p_verify_ok),.verified_rejected(p_verify_bad),.completed(p_completed),
        .stop_valid(p_stop_valid),.stop_sequence(stop_sequence_q),.stop_accepted(p_stop_ok),.stop_rejected(p_stop_bad),
        .local_retire_valid(p_retire),.local_retire_success(p_retire_success),
        .local_retire_sequence(p_retire_sequence),.local_retire_bytes(p_retire_bytes),
        .configured(p_configured),.quarantined(p_quarantined),.owned(p_owned),.peer_confirmed(p_peer),
        .release_allowed(p_release),.guard_state(guard_state),.a_state(a_state),.sink_state(sink_state),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_last(tx_last),.tx_ready(tx_ready),
        .rx_data(rx_data),.rx_valid(rx_valid),.rx_last(rx_last),.rx_ready(rx_ready),.tlps_out(tlps_out));
endmodule
`default_nettype wire
