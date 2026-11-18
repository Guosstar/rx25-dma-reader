#include <Windows.h>
#include <stdio.h>
#include <string.h>
#include "../rx25_capture_v2.h"

static unsigned checks,cases,providerFailures,bitFlips,histories;
#define CHECK(x) do {checks++;if(!(x)){printf("FAIL capture line %u: %s\n",__LINE__,#x);return 0;}} while(0)
typedef struct _MODEL {
    UCHAR Memory[8192];
    RX25_SNAPSHOT_V2_BINDING Binding;
    ULONG References,Frozen,Online,Calls,FailAt,Reads,Copies,MutateAt,RevokeAt;
    ULONG PublishOffset,MutationKind,TraceUsed,DelayAt,Delay;
    char Trace[256];
} MODEL;
static RX25_CAPTURE_V2 adapter,savedAdapter;
static MODEL model,savedModel;
static RX25_SNAPSHOT_V2_BINDING binding={0xa526111200000001ULL,0xb526111200000001ULL,1,2,3,0x12345678000ULL,8192,0x10f};
static RX25_SNAPSHOT_V2_JOB job={1,0x12345678,1,0,0,16,1};
static RX25_CAPTURE_V2_LIMITS limits={100,100,100,100};
static ULONGLONG tick;
static void put32(UCHAR *p,ULONG v)
{
    unsigned n;for(n=0;n<4;n++) p[n]=(UCHAR)(v>>(8*n));
}
static ULONG get32(const UCHAR *p)
{
    return (ULONG)p[0]+((ULONG)p[1]<<8)+((ULONG)p[2]<<16)+((ULONG)p[3]<<24);
}
static int call(MODEL *m,char tag)
{
    m->Calls++;
    if(m->TraceUsed<255) {m->Trace[m->TraceUsed++]=tag;m->Trace[m->TraceUsed]=0;}
    if(m->Calls==m->MutateAt) {
        if(m->MutationKind==1) put32(m->Memory+m->PublishOffset,0);
        else if(m->MutationKind==2) m->Memory[8191]^=1;
        else if(m->MutationKind==3) put32(m->Memory+m->PublishOffset,0x10001);
    }
    if(m->Calls==m->RevokeAt) m->Online=0;
    if(m->Calls==m->DelayAt) tick+=m->Delay;
    return m->Calls!=m->FailAt;
}
static int retain(void *context,const RX25_SNAPSHOT_V2_BINDING *b)
{
    MODEL *m=context;
    if(!call(m,'R') || m->References || !Rx25SnapshotV2BindingMatches(&m->Binding,b)) return 0;
    m->References++;m->Frozen=1;return 1;
}
static int current(void *context,const RX25_SNAPSHOT_V2_BINDING *b)
{
    MODEL *m=context;
    return call(m,'C') && m->Online && m->References==1 && m->Frozen && Rx25SnapshotV2BindingMatches(&m->Binding,b);
}
static int visibility(void *context,enum RX25_CAPTURE_V2_VISIBILITY phase)
{
    MODEL *m=context;
    return call(m,(char)('0'+phase));
}
static int readPublish(void *context,ULONG offset,ULONG *value)
{
    MODEL *m=context;m->Reads++;
    if(!call(m,'P') || offset!=m->PublishOffset || offset>8188) return 0;
    *value=get32(m->Memory+offset);return 1;
}
static int copyMapping(void *context,UCHAR *destination,ULONG bytes)
{
    MODEL *m=context;m->Copies++;
    if(!call(m,'M') || bytes!=8192) {memcpy(destination,m->Memory,16);return 0;}
    memcpy(destination,m->Memory,8192);return 1;
}
static int readClock(void *context,ULONGLONG *value)
{
    MODEL *m=context;if(!call(m,'T')) return 0;
    *value=tick;return 1;
}
static RX25_CAPTURE_V2_OPS ops={&model,retain,current,visibility,readPublish,copyMapping,readClock};
static RX25_CAPTURE_V2_INPUT input(void)
{
    RX25_CAPTURE_V2_INPUT in={0};
    in.Task=adapter.Task;in.StopBinding=binding;in.StopSequence=777;
    return in;
}
static int advance(RX25_CAPTURE_V2_INPUT in)
{
    return Rx25CaptureV2Advance(&adapter,&in,++tick);
}
static int fresh(void)
{
    RX25_CAPTURE_V2_INPUT in={0};
    unsigned n;
    memset(&adapter,0,sizeof(adapter));memset(&model,0,sizeof(model));
    for(n=0;n<8192;n++) model.Memory[n]=(UCHAR)((n*17)^(n>>3)^0xcc);
    model.Binding=binding;model.Online=1;model.PublishOffset=4100;tick=10;cases++;
    CHECK(Rx25CaptureV2Open(&adapter,&binding,&ops,&limits,tick));
    CHECK(adapter.Phase==Rx25CaptureV2AwaitReady && adapter.ReferenceHeld && model.Frozen);
    CHECK(!Rx25CaptureV2Prepare(&adapter,&job,tick));
    in.JobReady=1;CHECK(advance(in));CHECK(adapter.Phase==Rx25CaptureV2Ready);
    return 1;
}
static int prepare(const RX25_SNAPSHOT_V2_JOB *j)
{
    CHECK(Rx25CaptureV2Prepare(&adapter,j,++tick));
    model.PublishOffset=4096+j->TargetOffset+4;
    CHECK(adapter.Owned && adapter.SubmitOffered && model.References==1);
    return 1;
}
static int acceptJob(void)
{
    RX25_CAPTURE_V2_INPUT in=input();
    in.JobReady=1;CHECK(advance(in));
    CHECK(adapter.Phase==Rx25CaptureV2SubmitReply && !adapter.SubmitOffered);
    in=input();in.JobAccepted=1;CHECK(advance(in));
    CHECK(adapter.Phase==Rx25CaptureV2WaitRetire);
    return 1;
}
static void dmaImage(const RX25_SNAPSHOT_V2_JOB *j)
{
    unsigned n,k;
    ULONG words[8]={j->RequestId,0x10000+j->Generation,j->Length,(ULONG)j->Sequence,0,
        (ULONG)(j->Sequence>>32),0x32514352,0};
    for(n=0;n<j->Length/8;n++) {
        ULONGLONG word=0xa5a5000000000000ULL+(ULONGLONG)(j->SourceOffset/8+n);
        for(k=0;k<8;k++) model.Memory[j->TargetOffset+n*8+k]=(UCHAR)(word>>(8*k));
    }
    for(n=0;n<8;n++) put32(model.Memory+4096+j->TargetOffset+n*4,words[n]);
}
static int retire(void)
{
    RX25_CAPTURE_V2_INPUT in=input();in.RetireValid=1;in.RetireSuccess=1;in.RetireBytes=adapter.Task.Job.Length;
    return advance(in);
}
static int queueEvent(void)
{
    CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);CHECK(retire());
    CHECK(adapter.Phase==Rx25CaptureV2VerifiedPending && adapter.VerifiedOffered && adapter.Owned);
    return 1;
}
static int deliver(void)
{
    RX25_CAPTURE_V2_INPUT in=input();in.VerifiedReady=1;CHECK(advance(in));
    CHECK(adapter.Phase==Rx25CaptureV2VerifiedReply && !adapter.VerifiedOffered && adapter.Owned);
    in=input();in.VerifiedAccepted=1;CHECK(advance(in));
    CHECK(adapter.Phase==Rx25CaptureV2WaitComplete && adapter.Owned);
    return 1;
}
static int finish(void)
{
    RX25_CAPTURE_V2_INPUT in=input();in.Completed=1;in.JobReady=1;CHECK(advance(in));
    CHECK(adapter.Phase==Rx25CaptureV2AwaitReady && !adapter.Owned && adapter.Completions);
    CHECK(!Rx25CaptureV2Prepare(&adapter,&job,++tick));
    in=input();in.JobReady=1;CHECK(advance(in));CHECK(adapter.Phase==Rx25CaptureV2Ready);
    return 1;
}
static int isolated(ULONG owned)
{
    RX25_CAPTURE_V2_OUTPUT out;
    RX25_CAPTURE_V2_INPUT in=input();ULONG calls=model.Calls,count=adapter.Completions;
    CHECK(Rx25CaptureV2ReadOutput(&adapter,&out));
    CHECK(out.FaultValid && out.Owned==owned && !out.CanPrepare && !out.ReleaseAllowed && !out.CpuWriteAllowed);
    CHECK(out.ReferenceHeld==model.References);
    CHECK(!Rx25CaptureV2Prepare(&adapter,&job,++tick));
    CHECK(!Rx25CaptureV2Open(&adapter,&binding,&ops,&limits,tick));
    in.JobReady=1;in.VerifiedReady=1;in.JobAccepted=1;in.RetireValid=1;
    in.RetireSuccess=1;in.RetireBytes=16;in.VerifiedAccepted=1;in.Completed=1;
    CHECK(!advance(in));
    CHECK(adapter.Phase==Rx25CaptureV2Fault && adapter.Owned==owned && adapter.Completions==count && model.Calls==calls);
    return 1;
}
static int successTests(void)
{
    RX25_CAPTURE_V2_INPUT in;
    RX25_CAPTURE_V2_OUTPUT first,out;
    RX25_SNAPSHOT_V2_JOB j=job;
    unsigned n;
    CHECK(fresh());model.TraceUsed=0;model.Trace[0]=0;CHECK(prepare(&j));
    CHECK(!strcmp(model.Trace,"C1M2CT"));
    CHECK(Rx25CaptureV2ReadOutput(&adapter,&first));
    for(n=0;n<25;n++) {
        in=input();in.VerifiedReady=1;CHECK(advance(in));
        CHECK(Rx25CaptureV2ReadOutput(&adapter,&out));
        CHECK(out.SubmitValid && !out.VerifiedValid && !memcmp(&first.Task,&out.Task,sizeof(out.Task)));
        CHECK(!model.Reads && !adapter.Captures);
        CHECK(!Rx25CaptureV2Prepare(&adapter,&j,tick));
    }
    CHECK(acceptJob());dmaImage(&j);model.TraceUsed=0;model.Trace[0]=0;
    in=input();in.RetireValid=1;in.RetireSuccess=1;in.RetireBytes=16;in.VerifiedReady=1;
    CHECK(advance(in));CHECK(!strcmp(model.Trace,"CTP3M4PCT"));
    /* Ready from before event creation cannot consume the new event. */
    CHECK(adapter.VerifiedOffered && adapter.Phase==Rx25CaptureV2VerifiedPending);
    CHECK(Rx25CaptureV2ReadOutput(&adapter,&first));
    for(n=0;n<25;n++) {
        in=input();CHECK(advance(in));CHECK(Rx25CaptureV2ReadOutput(&adapter,&out));
        CHECK(out.VerifiedValid && out.VerifiedSuccess && out.Owned && !out.CanPrepare);
        CHECK(!memcmp(&first.Task,&out.Task,sizeof(out.Task)) && !out.ReleaseAllowed && !out.CpuWriteAllowed);
    }
    CHECK(deliver());CHECK(finish());
    /* Same-address then overlapping CQ reuse, with a new immutable baseline. */
    for(n=0;n<3;n++) {
        j.Sequence++;j.Generation++;j.Length=n==0?128:16;j.TargetOffset=n==2?4064:n*16;j.SourceOffset=n==2?4080:128;
        CHECK(prepare(&j));CHECK(acceptJob());dmaImage(&j);CHECK(retire());CHECK(deliver());CHECK(finish());
    }
    CHECK(adapter.Completions==4 && model.References==1 && model.Frozen);
    /* Duplicate completion is stale; job_ready drop closes host preparation. */
    in=input();in.Completed=1;CHECK(advance(in));CHECK(adapter.StaleEvents);
    j.Sequence++;j.Generation++;CHECK(!Rx25CaptureV2Prepare(&adapter,&j,++tick));
    return 1;
}
static int identityTests(void)
{
    RX25_CAPTURE_V2_INPUT in;
    RX25_SNAPSHOT_V2_JOB bad;
    unsigned n,calls;
    for(n=0;n<16;n++) {
        CHECK(fresh());bad=job;calls=model.Calls;
        switch(n) {
        case 0:bad.Sequence=2;break;case 1:bad.RequestId=0;break;case 2:bad.Generation=0;break;
        case 3:bad.Generation=65536;break;case 4:bad.SourceKind=2;break;case 5:bad.Length=32;break;
        case 6:bad.SourceOffset=1;break;case 7:bad.SourceOffset=4096;break;case 8:bad.SourceOffset=~0u;break;
        case 9:bad.SourceOffset=4080;bad.Length=128;break;case 10:bad.TargetOffset=1;break;
        case 11:bad.TargetOffset=4080;break;case 12:bad.TargetOffset=~0u;break;
        case 13:bad.TargetOffset=4000;bad.Length=128;break;case 14:bad.Length=0;break;default:bad.Sequence=0;break;
        }
        CHECK(!Rx25CaptureV2Prepare(&adapter,&bad,++tick) && !adapter.Owned && model.Calls==calls);
    }
    for(n=0;n<15;n++) {
        CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());in=input();
        switch(n) {
        case 0:in.Task.Binding.LocalEpoch++;break;case 1:in.Task.Binding.PeerEpoch++;break;
        case 2:in.Task.Binding.SessionId++;break;case 3:in.Task.Binding.WindowId++;break;
        case 4:in.Task.Binding.BufferId++;break;case 5:in.Task.Binding.DmaAddress+=8192;break;
        case 6:in.Task.Binding.BufferBytes++;break;case 7:in.Task.Binding.PeerCaps++;break;
        case 8:in.Task.Job.Sequence+=0x100000000ULL;break;case 9:in.Task.Job.RequestId++;break;
        case 10:in.Task.Job.Generation++;break;case 11:in.Task.Job.SourceOffset+=16;break;
        case 12:in.Task.Job.TargetOffset+=16;break;case 13:in.Task.Job.Length=128;break;
        default:in.Task.Job.SourceKind++;break;
        }
        savedAdapter=adapter;calls=model.Reads;
        in.JobAccepted=1;in.RetireValid=1;in.RetireSuccess=0;in.VerifiedRejected=1;in.Completed=1;
        CHECK(advance(in));CHECK(adapter.StaleEvents && adapter.Phase==Rx25CaptureV2WaitRetire && model.Reads==calls);
        CHECK(!memcmp(&adapter.Task,&savedAdapter.Task,sizeof(adapter.Task)) && adapter.Owned);
        dmaImage(&job);CHECK(retire());CHECK(deliver());CHECK(finish());
    }
    CHECK(queueEvent());in=input();in.VerifiedAccepted=1;
    CHECK(!advance(in));CHECK(adapter.FaultReasons & Rx25CaptureV2Bridge);CHECK(isolated(1));
    CHECK(queueEvent());in=input();in.Completed=1;
    CHECK(!advance(in));CHECK(isolated(1));
    CHECK(fresh());CHECK(prepare(&job));in=input();in.RetireValid=1;in.RetireSuccess=1;in.RetireBytes=16;
    CHECK(!advance(in));CHECK(isolated(1));
    return 1;
}
static int providerTests(void)
{
    RX25_CAPTURE_V2_INPUT in;
    unsigned n,base;
    for(n=1;n<=3;n++) {
        unsigned k;
        memset(&adapter,0,sizeof(adapter));memset(&model,0,sizeof(model));
        model.Binding=binding;model.Online=1;model.FailAt=n;tick=10;
        for(k=0;k<8192;k++) model.Memory[k]=(UCHAR)k;
        CHECK(!Rx25CaptureV2Open(&adapter,&binding,&ops,&limits,tick));
        CHECK(adapter.Phase==Rx25CaptureV2Fault && adapter.ReferenceHeld==(n==1?0u:1u));
        CHECK(isolated(0));providerFailures++;
    }
    /* Every baseline and snapshot callback can fail, including partial copy. */
    for(n=1;n<=6;n++) {
        CHECK(fresh());model.FailAt=model.Calls+n;
        CHECK(!Rx25CaptureV2Prepare(&adapter,&job,++tick));CHECK(adapter.FaultReasons & Rx25CaptureV2Provider);
        CHECK(!adapter.SubmitOffered);CHECK(isolated(1));providerFailures++;
    }
    for(n=1;n<=9;n++) {
        CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);model.FailAt=model.Calls+n;
        CHECK(!retire());CHECK(adapter.FaultReasons & Rx25CaptureV2Provider);CHECK(!adapter.VerifiedOffered);
        CHECK(isolated(1));providerFailures++;
    }
    for(n=1;n<=9;n++) {
        CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);model.RevokeAt=model.Calls+n;
        (void)retire();
        /* Loss after the final Current check is caught at the next coherent
         * bridge sample, before any queued success can be acknowledged. */
        if(adapter.Phase!=Rx25CaptureV2Fault) {in=input();in.VerifiedReady=1;CHECK(!advance(in));}
        CHECK(isolated(1));
    }
    CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);
    base=model.Calls;model.MutateAt=base+6;model.MutationKind=1;
    CHECK(retire());CHECK(adapter.Phase==Rx25CaptureV2Polling && !adapter.VerifiedOffered && adapter.Retries==1);
    model.MutateAt=0;dmaImage(&job);in=input();CHECK(advance(in));
    CHECK(adapter.VerifiedOffered && adapter.Captures==2);CHECK(deliver());CHECK(finish());
    CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);
    put32(model.Memory+4100,0);model.MutateAt=model.Calls+4;model.MutationKind=3;
    CHECK(retire());CHECK(adapter.Phase==Rx25CaptureV2Polling && !adapter.VerifiedOffered && adapter.Retries==1);
    model.MutateAt=0;in=input();CHECK(advance(in));CHECK(deliver());CHECK(finish());
    CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);
    put32(model.Memory+4100,0x10002);CHECK(retire());CHECK(adapter.Phase==Rx25CaptureV2Polling && adapter.Retries==1);
    dmaImage(&job);in=input();CHECK(advance(in));CHECK(deliver());CHECK(finish());
    CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);
    model.MutateAt=model.Calls+4;model.MutationKind=2;
    CHECK(!retire());CHECK(adapter.FaultReasons & Rx25CaptureV2Image);CHECK(isolated(1));
    CHECK(fresh());model.DelayAt=model.Calls+3;model.Delay=100;
    CHECK(!Rx25CaptureV2Prepare(&adapter,&job,++tick));
    CHECK(adapter.FaultReasons & Rx25CaptureV2Deadline);CHECK(!adapter.SubmitOffered);CHECK(isolated(1));
    CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);
    model.DelayAt=model.Calls+5;model.Delay=100;
    CHECK(!retire());CHECK(adapter.FaultReasons & Rx25CaptureV2Deadline);
    CHECK(!adapter.VerifiedOffered);CHECK(isolated(1));
    CHECK(queueEvent());CHECK(deliver());model.DelayAt=model.Calls+1;model.Delay=100;
    in=input();in.Completed=1;CHECK(!advance(in));
    CHECK(adapter.FaultReasons & Rx25CaptureV2Deadline);CHECK(!adapter.Completions);CHECK(isolated(1));
    return 1;
}
static int faultAndDeadlineTests(void)
{
    RX25_CAPTURE_V2_INPUT in;
    RX25_CAPTURE_V2_OUTPUT out;
    unsigned phase,n;
    ULONGLONG deadline;
    for(phase=0;phase<7;phase++) for(n=0;n<5;n++) {
        CHECK(fresh());
        if(phase) CHECK(prepare(&job));
        if(phase>=2) CHECK(acceptJob());
        if(phase>=3) {dmaImage(&job);CHECK(retire());}
        if(phase>=4) {in=input();in.VerifiedReady=1;CHECK(advance(in));}
        if(phase>=5) {in=input();in.VerifiedAccepted=1;CHECK(advance(in));}
        if(phase>=6) CHECK(finish());
        in=input();in.FaultReasons=1u<<n;in.VerifiedAccepted=1;in.Completed=1;in.VerifiedReady=1;in.JobReady=1;
        CHECK(!advance(in));CHECK(adapter.Completions==(phase==6?1u:0u));CHECK(isolated(phase && phase<6));
        CHECK(adapter.FaultReasons & (1u<<n));
    }
    /* A fault under backpressure preserves the offered identity and valid. */
    CHECK(queueEvent());in=input();in.FaultReasons=Rx25CaptureV2External;CHECK(!advance(in));
    CHECK(Rx25CaptureV2ReadOutput(&adapter,&out));CHECK(out.VerifiedValid && out.FaultValid && out.Owned);
    CHECK(Rx25CaptureV2TaskMatches(&adapter,&out.Task));CHECK(isolated(1));
    CHECK(fresh());CHECK(prepare(&job));in=input();in.FaultReasons=Rx25CaptureV2External;CHECK(!advance(in));
    CHECK(Rx25CaptureV2ReadOutput(&adapter,&out));CHECK(out.SubmitValid && out.FaultValid && out.Owned);CHECK(isolated(1));
    /* Timeout wins over ready, retire, verified ACK, or completion at deadline. */
    for(phase=0;phase<4;phase++) {
        CHECK(fresh());CHECK(prepare(&job));
        if(phase) CHECK(acceptJob());
        if(phase>=2) {dmaImage(&job);CHECK(retire());}
        if(phase==3) CHECK(deliver());
        deadline=phase<2?adapter.TaskStart+limits.Job:phase==2?adapter.RetireStart+limits.Verify:adapter.DeliveryStart+limits.Complete;
        in=input();in.JobReady=1;in.RetireValid=1;in.RetireSuccess=1;in.RetireBytes=16;
        in.VerifiedReady=1;in.VerifiedAccepted=1;in.Completed=1;
        tick=deadline;CHECK(!Rx25CaptureV2Advance(&adapter,&in,tick));
        CHECK(adapter.FaultReasons & Rx25CaptureV2Deadline);CHECK(isolated(1));
    }
    CHECK(queueEvent());in=input();CHECK(!Rx25CaptureV2Advance(&adapter,&in,tick-1));
    CHECK(adapter.FaultReasons & Rx25CaptureV2ClockFault);CHECK(isolated(1));
    return 1;
}
static int stopTests(void)
{
    RX25_CAPTURE_V2_INPUT in;
    RX25_CAPTURE_V2_OUTPUT out;
    RX25_SNAPSHOT_V2_JOB next=job;
    unsigned phase,n;
    ULONGLONG start;
    for(phase=0;phase<5;phase++) {
        CHECK(fresh());
        if(phase) CHECK(prepare(&job));
        if(phase>=2) CHECK(acceptJob());
        if(phase>=3) {dmaImage(&job);CHECK(retire());}
        if(phase>=4) CHECK(deliver());
        in=input();in.StopRequest=1;CHECK(advance(in));start=adapter.StopStart;
        CHECK(Rx25CaptureV2ReadOutput(&adapter,&out));CHECK(!out.CanPrepare && !out.ReleaseAllowed);
        CHECK(!Rx25CaptureV2Prepare(&adapter,&job,++tick));
        if(phase==1) {CHECK(!out.StopValid && out.SubmitValid);CHECK(acceptJob());}
        in=input();in.StopRequest=1;CHECK(advance(in));CHECK(adapter.StopStart==start);
        in=input();in.StopRequest=1;in.StopSequence=778;CHECK(advance(in));
        CHECK(adapter.StopSequence==777 && adapter.StaleEvents && adapter.StopStart==start);
        in=input();in.StopAccepted=1;CHECK(advance(in));CHECK(adapter.StopAcknowledged && !adapter.StopOffered);
        if(phase && phase<3) {dmaImage(&job);CHECK(retire());}
        if(phase && phase<4) CHECK(deliver());
        if(phase) {in=input();in.Completed=1;CHECK(advance(in));}
        in=input();in.PeerConfirmed=1;CHECK(advance(in));
        CHECK(Rx25CaptureV2ReadOutput(&adapter,&out));
        CHECK(out.PeerConfirmed && !out.Owned && out.ReferenceHeld && !out.ReleaseAllowed && !out.CpuWriteAllowed && !out.CanPrepare);
        next.Sequence=2;next.Generation=2;CHECK(!Rx25CaptureV2Prepare(&adapter,&next,++tick));
        in=input();in.FaultReasons=Rx25CaptureV2FileClose;CHECK(!advance(in));CHECK(isolated(0));
    }
    for(n=0;n<9;n++) {
        CHECK(fresh());in=input();in.StopRequest=1;
        switch(n) {
        case 0:in.StopSequence=0;break;case 1:in.StopBinding.LocalEpoch++;break;case 2:in.StopBinding.PeerEpoch++;break;
        case 3:in.StopBinding.SessionId++;break;case 4:in.StopBinding.WindowId++;break;case 5:in.StopBinding.BufferId++;break;
        case 6:in.StopBinding.DmaAddress+=8192;break;case 7:in.StopBinding.PeerCaps++;break;
        default:in.StopBinding.BufferBytes++;break;
        }
        CHECK(advance(in));CHECK(!adapter.Stopping && adapter.StaleEvents);
    }
    CHECK(queueEvent());in=input();in.StopRequest=1;CHECK(advance(in));
    in=input();in.StopAccepted=1;in.PeerConfirmed=1;CHECK(!advance(in));CHECK(isolated(1));
    CHECK(fresh());in=input();in.StopRequest=1;CHECK(advance(in));
    in=input();in.StopAccepted=1;CHECK(advance(in));in=input();in.PeerConfirmed=1;
    CHECK(!Rx25CaptureV2Advance(&adapter,&in,adapter.StopStart+limits.Stop));CHECK(isolated(0));
    /* STOP fault/early peer must beat a simultaneous legitimate completion. */
    for(n=0;n<2;n++) {
        CHECK(queueEvent());CHECK(deliver());
        in=input();in.StopRequest=1;CHECK(advance(in));
        in=input();in.Completed=1;
        if(n==0) in.StopRejected=1;
        else {in.StopAccepted=1;in.PeerConfirmed=1;}
        CHECK(!advance(in));CHECK(adapter.Owned && !adapter.Completions);
        CHECK(isolated(1));
    }
    return 1;
}
static int corruptionTests(void)
{
    unsigned offset,bit;
    CHECK(fresh());CHECK(prepare(&job));CHECK(acceptJob());dmaImage(&job);
    savedAdapter=adapter;savedModel=model;
    /* Full end-to-end callback path for every bit in the immutable image. */
    for(offset=0;offset<8192;offset++) for(bit=0;bit<8;bit++) {
        RX25_CAPTURE_V2_INPUT in;
        adapter=savedAdapter;model=savedModel;model.Memory[offset]^=(UCHAR)(1u<<bit);tick=adapter.Now;
        in=input();in.RetireValid=1;in.RetireSuccess=1;in.RetireBytes=16;
        (void)advance(in);bitFlips++;
        CHECK(!adapter.VerifiedOffered && adapter.Owned && adapter.ReferenceHeld && !adapter.Completions);
        CHECK(adapter.Phase==Rx25CaptureV2Fault || adapter.Phase==Rx25CaptureV2Polling);
    }
    return 1;
}
static int invalidApiTests(void)
{
    RX25_CAPTURE_V2_INPUT in={0};
    RX25_CAPTURE_V2_OUTPUT out;
    RX25_CAPTURE_V2_OPS bad;
    RX25_CAPTURE_V2_LIMITS shortLimits=limits;
    unsigned n;
    memset(&adapter,0,sizeof(adapter));
    CHECK(!Rx25CaptureV2Open(NULL,&binding,&ops,&limits,0));
    CHECK(!Rx25CaptureV2Open(&adapter,NULL,&ops,&limits,0));
    CHECK(!Rx25CaptureV2Open(&adapter,&adapter.Task.Binding,&ops,&limits,0));
    CHECK(!Rx25CaptureV2Advance(&adapter,&in,0));
    CHECK(!Rx25CaptureV2Prepare(NULL,&job,0));CHECK(!Rx25CaptureV2Prepare(&adapter,NULL,0));
    CHECK(!Rx25CaptureV2ReadOutput(NULL,&out));CHECK(!Rx25CaptureV2ReadOutput(&adapter,NULL));
    CHECK(!Rx25CaptureV2ReadOutput(&adapter,(RX25_CAPTURE_V2_OUTPUT *)(void *)adapter.Image));
    CHECK(!Rx25CaptureV2Advance(&adapter,(RX25_CAPTURE_V2_INPUT *)(void *)adapter.Image,0));
    for(n=0;n<6;n++) {
        bad=ops;memset(&adapter,0,sizeof(adapter));
        switch(n) {case 0:bad.Retain=NULL;break;case 1:bad.Current=NULL;break;case 2:bad.Visibility=NULL;break;
        case 3:bad.ReadPublish=NULL;break;case 4:bad.CopyMapping=NULL;break;default:bad.ReadClock=NULL;break;}
        CHECK(!Rx25CaptureV2Open(&adapter,&binding,&bad,&limits,0));
    }
    for(n=0;n<4;n++) {
        shortLimits=limits;memset(&adapter,0,sizeof(adapter));
        switch(n) {case 0:shortLimits.Job=0;break;case 1:shortLimits.Verify=0;break;
        case 2:shortLimits.Complete=0;break;default:shortLimits.Stop=0;break;}
        CHECK(!Rx25CaptureV2Open(&adapter,&binding,&ops,&shortLimits,0));
    }
    CHECK(fresh());CHECK(!Rx25CaptureV2Prepare(&adapter,&adapter.Task.Job,tick));
    return 1;
}
/* Bounded histories start at a valid held event. No action sequence may
 * clear ownership without BOTH delivery/ACK and a matching completion. */
static int historyTests(void)
{
    unsigned code,n;
    CHECK(queueEvent());savedAdapter=adapter;savedModel=model;
    for(code=0;code<4096;code++) {
        unsigned digits=code,delivered=0,acked=0,done=0,faulted=0;
        adapter=savedAdapter;model=savedModel;tick=adapter.Now;
        for(n=0;n<4;n++) {
            unsigned action=digits%8;RX25_CAPTURE_V2_INPUT in=input();digits/=8;
            switch(action) {
            case 0:break;
            case 1:in.VerifiedReady=1;if(!faulted && adapter.VerifiedOffered) delivered=1;break;
            case 2:in.VerifiedAccepted=1;if(!faulted && delivered && adapter.Phase==Rx25CaptureV2VerifiedReply) acked=1;break;
            case 3:in.Completed=1;if(!faulted && acked && adapter.Phase==Rx25CaptureV2WaitComplete) done=1;break;
            case 4:in.FaultReasons=Rx25CaptureV2External;faulted=1;break;
            case 5:in.VerifiedReady=1;in.Completed=1;
                if(!faulted && acked && adapter.Phase==Rx25CaptureV2WaitComplete) done=1;break;
            case 6:in.Task.Binding.BufferId++;in.VerifiedRejected=1;in.Completed=1;break;
            default:in.StopRequest=1;break;
            }
            (void)advance(in);if(adapter.Phase==Rx25CaptureV2Fault) faulted=1;
            CHECK(adapter.ReferenceHeld && model.References==1 && model.Frozen);
            CHECK(adapter.Owned==!done && adapter.Completions==done);
            if(faulted) CHECK(adapter.Phase==Rx25CaptureV2Fault && !adapter.AdmissionReady);
        }
        histories++;
    }
    return 1;
}
int main(void)
{
    if(!invalidApiTests() || !successTests() || !identityTests() || !providerTests() ||
        !faultAndDeadlineTests() || !stopTests() || !corruptionTests() || !historyTests()) return 1;
    printf("RX25_CAPTURE_V2_TEST_PASS checks=%u cases=%u provider_failures=%u flipped_bits=%u histories=%u\n",
        checks,cases,providerFailures,bitFlips,histories);
    return 0;
}
