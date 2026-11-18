#include <Windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../rx25_transport_v2.h"

#define CHECK(x) do {checks++;if(!(x)){printf("FAIL transport line %u: %s\n",__LINE__,#x);return 0;}} while(0)
#define INC 0x1122334455667788ULL
#define STOP 0x1122334400000309ULL
static unsigned checks,cases,callbackFailures,flips,replayEvents,replayCommands;
static ULONGLONG tick;
static RX25_SNAPSHOT_V2_BINDING binding={0xa526111200000001ULL,0xb526111200000001ULL,
    0x1020304000000001ULL,0x2233445500000002ULL,0x6677889900000003ULL,0x12345678000ULL,8192,0x10f};
static RX25_SNAPSHOT_V2_JOB jobs[2]={{1,0x12345678,1,0,0,16,1},{2,0x87654321,65535,3968,3968,128,1}};
static RX25_CAPTURE_V2_LIMITS limits={1000000,1000000,1000000,1000000};
typedef struct _BUS {
    ULONG Magic,Version,Caps,Status,Reasons,Count,Words[40],Ack[4],Stage[26];
    ULONGLONG Incarnation,Head;
    UCHAR Memory[8192];
    ULONG Calls,FailAt,FailPartial,FaultAt,ResetAt,Reads,Writes,Flushes,Commits,AckCount;
    ULONG References,Online,PublishOffset,CallbackFault,ClockDelay;
    ULONG Log[4096][3],LogUsed;
} BUS;
static BUS bus,savedBus;
static RX25_TRANSPORT_V2 transport,savedTransport;
static RX25_CAPTURE_V2 capture,work,savedCapture;
static int call(void)
{
    bus.Calls++;
    if(bus.Calls==bus.FaultAt) {bus.Status|=1;bus.Reasons|=1;}
    if(bus.Calls==bus.ResetAt) {bus.Incarnation++;bus.Status=1u<<13;bus.Count=0;}
    return bus.Calls!=bus.FailAt;
}
static int read32(void *context,ULONG offset,ULONG *v)
{
    BUS *b=context;b->Reads++;
    if(!call()) return 0;
    switch(offset) {
    case 0:*v=b->Magic;break;case 4:*v=b->Version;break;case 8:*v=b->Caps;break;
    case 0x0c:*v=b->Status;break;case 0x14:*v=b->Reasons;break;
    case 0x18:*v=(ULONG)b->Incarnation;break;case 0x1c:*v=(ULONG)(b->Incarnation>>32);break;
    case 0x20:*v=b->Count?(ULONG)b->Head:0;break;case 0x24:*v=b->Count?(ULONG)(b->Head>>32):0;break;
    case 0x2c:*v=b->Count;break;
    default:if(offset<0x200 || offset>=0x2a0 || (offset & 3)) return 0;
        *v=b->Count?b->Words[(offset-0x200)/4]:0;break;
    }
    return 1;
}
static int write32(void *context,ULONG offset,ULONG value,ULONG be)
{
    BUS *b=context;int ok=call();b->Writes++;
    if(!ok && !b->FailPartial) return 0;
    if(b->LogUsed>=4096 || be!=15 || (offset & 3)) return 0;
    b->Log[b->LogUsed][0]=offset;b->Log[b->LogUsed][1]=value;b->Log[b->LogUsed++][2]=be;
    if(offset>=0x100 && offset<0x168) b->Stage[(offset-0x100)/4]=value;
    else if(offset>=0x30 && offset<=0x3c) b->Ack[(offset-0x30)/4]=value;
    else if(offset==0x10) {
        if(value & 0x80000000u) {b->Status|=1;b->Reasons|=256;}
        else {b->Commits++;if(value==1) b->Status=(1u<<3)|(1u<<7)|(1u<<11);}
    } else if(offset==0x40) {
        if(value!=1 || !b->Count || Rx25TransportV2Get64(b->Ack)!=b->Incarnation ||
           Rx25TransportV2Get64(b->Ack+2)!=b->Head) return 0;
        b->Count=0;b->Status&=~(1u<<5);b->AckCount++;
    } else return 0;
    return ok;
}
static int flush(void *context) {BUS *b=context;b->Flushes++;return call();}
static int retain(void *context,const RX25_SNAPSHOT_V2_BINDING *b)
{
    BUS *m=context;if(!call() || m->References || !Rx25SnapshotV2BindingMatches(&binding,b)) return 0;
    m->References=1;return 1;
}
static int current(void *context,const RX25_SNAPSHOT_V2_BINDING *b)
{
    BUS *m=context;
    if(m->CallbackFault) {m->Status|=1;m->Reasons|=1;m->CallbackFault=0;}
    return call() && m->Online && m->References==1 && Rx25SnapshotV2BindingMatches(&binding,b);
}
static int visibility(void *context,enum RX25_CAPTURE_V2_VISIBILITY phase)
{ (void)context;(void)phase;return call(); }
static ULONG get32(const UCHAR *p) {return (ULONG)p[0]|((ULONG)p[1]<<8)|((ULONG)p[2]<<16)|((ULONG)p[3]<<24);}
static void put32(UCHAR *p,ULONG v) {unsigned n;for(n=0;n<4;n++) p[n]=(UCHAR)(v>>(n*8));}
static int readPublish(void *context,ULONG offset,ULONG *v)
{
    BUS *b=context;if(!call() || offset>8188 || offset!=b->PublishOffset) return 0;
    *v=get32(b->Memory+offset);return 1;
}
static int copyMapping(void *context,UCHAR *p,ULONG bytes)
{
    BUS *b=context;if(!call() || bytes!=8192) {memcpy(p,b->Memory,16);return 0;}
    memcpy(p,b->Memory,8192);return 1;
}
static int readClock(void *context,ULONGLONG *v)
{ BUS *b=context;if(!call()) return 0;tick+=b->ClockDelay;*v=tick;return 1; }
static RX25_TRANSPORT_V2_OPS ops={&bus,read32,write32,flush};
static RX25_CAPTURE_V2_OPS captureOps={&bus,retain,current,visibility,readPublish,copyMapping,readClock};
static int fresh(void)
{
    memset(&bus,0,sizeof(bus));memset(&transport,0,sizeof(transport));
    memset(&capture,0,sizeof(capture));memset(&work,0,sizeof(work));
    bus.Magic=RX25_TRANSPORT_V2_MAGIC;bus.Version=RX25_TRANSPORT_V2_VERSION;bus.Caps=RX25_TRANSPORT_V2_CAPS;
    bus.Status=1u<<13;bus.Incarnation=INC;bus.Online=1;memset(bus.Memory,0xcc,8192);tick=10;cases++;
    CHECK(Rx25TransportV2Init(&transport,INC,&binding,&ops,&capture,&work,&captureOps,&limits));return 1;
}
static void event(ULONG flags)
{
    ULONG *w=bus.Words;memset(w,0,40*sizeof(*w));bus.Count=1;bus.Head=transport.AckedId+1;bus.Status|=1u<<5;
    Rx25TransportV2Put64(w,INC);Rx25TransportV2Put64(w+2,bus.Head);w[4]=flags;
    w[6]=bus.Status;Rx25TransportV2EncodeBinding(w+10,&binding);
    if(capture.Task.Job.Sequence) Rx25TransportV2EncodeJob(w+24,&capture.Task.Job);
    w[31]=(flags & (32u|128u|256u|1024u))!=0;Rx25TransportV2Put64(w+32,capture.StopSequence);
    if(flags & 16) {w[7]=capture.Task.Job.Length;Rx25TransportV2Put64(w+8,capture.Task.Job.Sequence);w[34]=1;}
}
static int deliver(ULONG flags)
{
    event(flags);CHECK(Rx25TransportV2ReadHead(&transport));CHECK(transport.Held && !transport.Delivered);
    {ULONG writes=bus.Writes;CHECK(!Rx25TransportV2Ack(&transport));CHECK(bus.Writes==writes);}
    CHECK(Rx25TransportV2Deliver(&transport,++tick));CHECK(transport.Delivered);
    CHECK(!Rx25TransportV2Deliver(&transport,tick));CHECK(Rx25TransportV2Ack(&transport));
    CHECK(!transport.Held && transport.Acks==transport.Events);return 1;
}
static int configured(void)
{
    CHECK(fresh());CHECK(Rx25TransportV2Configure(&transport));CHECK(!Rx25TransportV2Configure(&transport));
    CHECK(capture.Phase==Rx25CaptureV2Empty && !bus.References);CHECK(deliver(1));
    CHECK(capture.Phase==Rx25CaptureV2AwaitReady && bus.References==1);
    CHECK(Rx25TransportV2Observe(&transport,++tick));CHECK(capture.Phase==Rx25CaptureV2Ready);return 1;
}
static int prepare(unsigned n)
{
    bus.PublishOffset=4096+jobs[n].TargetOffset+4;
    CHECK(Rx25TransportV2Prepare(&transport,jobs+n,++tick));return 1;
}
static int submit(unsigned n)
{
    ULONG old;CHECK(prepare(n));old=bus.Commits;
    CHECK(Rx25TransportV2Observe(&transport,++tick));CHECK(capture.SubmitOffered);
    CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(bus.Commits==old+1);
    CHECK(capture.Phase==Rx25CaptureV2SubmitReply && !capture.SubmitOffered && capture.Owned);
    CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(bus.Commits==old+1);
    CHECK(deliver(4));CHECK(capture.Phase==Rx25CaptureV2WaitRetire);return 1;
}
static void image(const RX25_SNAPSHOT_V2_JOB *j)
{
    ULONG n,k,words[8]={j->RequestId,0x10000|j->Generation,j->Length,(ULONG)j->Sequence,0,
        (ULONG)(j->Sequence>>32),0x32514352,0};
    for(n=0;n<j->Length/8;n++) {
        ULONGLONG v=0xa5a5000000000000ULL | (j->SourceOffset/8+n);
        for(k=0;k<8;k++) bus.Memory[j->TargetOffset+n*8+k]=(UCHAR)(v>>(8*k));
    }
    for(n=0;n<8;n++) put32(bus.Memory+4096+j->TargetOffset+n*4,words[n]);
}
static int verified(void)
{
    CHECK(configured());CHECK(submit(0));image(jobs);CHECK(deliver(16));
    CHECK(capture.Phase==Rx25CaptureV2VerifiedPending && capture.VerifiedOffered);
    CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(capture.Phase==Rx25CaptureV2VerifiedReply);
    CHECK(deliver(32));CHECK(capture.Phase==Rx25CaptureV2WaitComplete);return 1;
}
static int normal(void)
{
    unsigned n;CHECK(configured());
    for(n=0;n<2;n++) {
        ULONG old;
        CHECK(submit(n));image(jobs+n);CHECK(deliver(16));
        CHECK(capture.VerifiedOffered && capture.Owned);old=bus.Commits;
        CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(!capture.VerifiedOffered && capture.Owned);
        CHECK(deliver(32));CHECK(capture.Owned);CHECK(deliver(128));
        CHECK(capture.Phase==Rx25CaptureV2AwaitReady && !capture.Owned);
        CHECK(!Rx25CaptureV2Prepare(&capture,jobs,++tick));
        CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(bus.Commits==old+1);
        CHECK(Rx25TransportV2Observe(&transport,++tick));CHECK(capture.Phase==Rx25CaptureV2Ready);
    }
    CHECK(Rx25TransportV2RequestStop(&transport,STOP,++tick));CHECK(capture.StopOffered);
    CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(deliver(256));CHECK(deliver(1024));
    CHECK(capture.PeerConfirmed && capture.Completions==2 && bus.References==1);
    {RX25_CAPTURE_V2_OUTPUT out;CHECK(Rx25CaptureV2ReadOutput(&capture,&out));CHECK(!out.ReleaseAllowed && !out.CpuWriteAllowed);}
    CHECK(!Rx25TransportV2RequestStop(&transport,STOP+1,++tick));CHECK(transport.Isolated);return 1;
}
static void save(void) {savedBus=bus;savedTransport=transport;savedCapture=capture;}
static void restore(void) {bus=savedBus;transport=savedTransport;capture=savedCapture;work=capture;tick=capture.Now;cases++;}
static int faults(void)
{
    unsigned n,k;ULONG before,callbacks;
    CHECK(verified());event(128);save();
    /* Live fault wins over an older successful COMPLETE head. */
    for(n=0;n<2;n++) {
        restore();if(n) bus.Incarnation++;else {bus.Status|=1;bus.Reasons=1;}
        CHECK(!Rx25TransportV2ReadHead(&transport));CHECK(capture.Owned && !capture.Completions && bus.References==1);
        CHECK(!bus.AckCount || bus.AckCount==savedBus.AckCount);
    }
    /* Inject a fault inside capture Current after it has tentatively completed. */
    restore();CHECK(Rx25TransportV2ReadHead(&transport));bus.CallbackFault=1;before=bus.AckCount;
    CHECK(!Rx25TransportV2Deliver(&transport,++tick));
    CHECK(capture.Owned && !capture.Completions && capture.Phase==Rx25CaptureV2Fault && bus.AckCount==before);
    /* Every actual callback failure position in ReadHead + Deliver + ACK. */
    restore();before=bus.Calls;CHECK(Rx25TransportV2ReadHead(&transport));
    CHECK(Rx25TransportV2Deliver(&transport,++tick));CHECK(Rx25TransportV2Ack(&transport));callbacks=bus.Calls-before;
    for(n=1;n<=callbacks;n++) for(k=0;k<2;k++) {
        int ok;restore();bus.FailAt=bus.Calls+n;bus.FailPartial=k;
        ok=Rx25TransportV2ReadHead(&transport) && Rx25TransportV2Deliver(&transport,++tick) && Rx25TransportV2Ack(&transport);
        CHECK(!ok && transport.Isolated && capture.Phase==Rx25CaptureV2Fault && bus.References==1);
        before=bus.Commits;CHECK(!Rx25TransportV2Send(&transport,++tick));CHECK(bus.Commits==before);callbackFailures++;
    }
    /* A fault or reset at every read position cannot be hidden by old success. */
    for(n=1;n<=62;n++) {
        restore();bus.FaultAt=bus.Calls+n;
        CHECK(!Rx25TransportV2ReadHead(&transport));CHECK(capture.Owned && !capture.Completions);flips++;
        restore();bus.ResetAt=bus.Calls+n;
        CHECK(!Rx25TransportV2ReadHead(&transport));CHECK(capture.Owned && !capture.Completions);flips++;
    }
    restore();bus.Words[4]|=512;CHECK(Rx25TransportV2ReadHead(&transport));
    CHECK(!Rx25TransportV2Deliver(&transport,++tick));CHECK(capture.Owned && !capture.Completions);
    /* Invalid, future, truncated IDs/identities, reserved fields, retire tag. */
    for(n=0;n<40;n++) {
        restore();bus.Words[n]^=1;
        if(n<=3 || (n>=10 && n<=30) || n>=35 || n==5) {
            int ok=Rx25TransportV2ReadHead(&transport) && Rx25TransportV2Deliver(&transport,++tick);
            CHECK(!ok && capture.Owned && !capture.Completions);flips++;
        }
    }
    CHECK(configured());CHECK(prepare(0));save();
    before=bus.Calls;CHECK(Rx25TransportV2Send(&transport,++tick));callbacks=bus.Calls-before;
    for(n=1;n<=callbacks;n++) for(k=0;k<2;k++) {
        restore();bus.FailAt=bus.Calls+n;bus.FailPartial=k;
        CHECK(!Rx25TransportV2Send(&transport,++tick));CHECK(transport.Isolated && capture.Owned && bus.References==1);
        before=bus.Commits;CHECK(!Rx25TransportV2Send(&transport,++tick));CHECK(bus.Commits==before);callbackFailures++;
    }
    /* Busy native ready cannot consume a submit before the bridge COMMIT. */
    restore();bus.Status|=2;before=bus.Commits;CHECK(!Rx25TransportV2Send(&transport,++tick));
    CHECK(capture.SubmitOffered && bus.Commits==before && !transport.Isolated);
    restore();bus.ClockDelay=1;CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(!capture.SubmitOffered);
    CHECK(configured());CHECK(Rx25TransportV2RequestStop(&transport,STOP,++tick));
    CHECK(Rx25TransportV2Send(&transport,++tick));CHECK(deliver(256));CHECK(deliver(1024));return 1;
}
static int codec(void)
{
    ULONG w[26],n;RX25_TRANSPORT_V2_EVENT e;
    CHECK(Rx25TransportV2EncodeFrame(INC,&binding,jobs,1,STOP,w));
    CHECK(w[0]==0x55667788 && w[1]==0x11223344 && w[10]==0x45678000 && w[11]==0x123);
    CHECK(w[12]==3 && w[13]==0x66778899 && w[23]==1 && w[24]==0x309 && w[25]==0x11223344);
    CHECK(!Rx25TransportV2EncodeFrame(0,&binding,jobs,1,STOP,w));
    CHECK(!Rx25TransportV2EncodeFrame(INC,&binding,jobs,2,STOP,w));
    CHECK(configured());event(1);
    /* Retire metadata without the flag is intentionally ignored. */
    bus.Words[7]=~0u;bus.Words[8]=~0u;bus.Words[9]=~0u;bus.Words[34]=~0u;
    CHECK(Rx25TransportV2DecodeEvent(bus.Words,&e));CHECK(!e.RetireBytes && !e.RetireSuccess && !e.RetireSequence);
    for(n=0;n<64;n++) {
        ULONGLONG v=1ULL<<n;Rx25TransportV2Put64(w,v);CHECK(Rx25TransportV2Get64(w)==v);flips++;
    }
    return 1;
}
static int boundaries(void)
{
    unsigned n,bit;ULONG callbacks,before;
    CHECK(configured());CHECK(prepare(0));bus.Online=0;
    CHECK(!Rx25TransportV2Send(&transport,++tick));CHECK(capture.Owned && bus.References==1 && transport.Isolated);
    CHECK(configured());CHECK(submit(0));image(jobs);event(16);bus.Words[8]^=1;
    CHECK(Rx25TransportV2ReadHead(&transport));CHECK(!Rx25TransportV2Deliver(&transport,++tick));CHECK(capture.Owned);
    CHECK(configured());CHECK(submit(0));image(jobs);event(16);save();
    for(n=10;n<=30;n++) for(bit=0;bit<32;bit++) {
        restore();bus.Words[n]^=1u<<bit;
        CHECK(!(Rx25TransportV2ReadHead(&transport) && Rx25TransportV2Deliver(&transport,++tick)));
        CHECK(capture.Owned && transport.Isolated && bus.AckCount==savedBus.AckCount);flips++;
    }
    for(n=0;n<4;n++) for(bit=0;bit<32;bit++) {
        restore();bus.Words[n]^=1u<<bit;
        CHECK(!Rx25TransportV2ReadHead(&transport));CHECK(capture.Owned && transport.Isolated);flips++;
    }
    /* Test 64-bit ACK encoding above 2^32 without claiming hardware generated
     * that many records. The real RTL fixture IDs start at 1 as required. */
    CHECK(configured());transport.AckedId=0xabcdef0100000000ULL;
    CHECK(Rx25TransportV2RequestStop(&transport,STOP,++tick));CHECK(Rx25TransportV2Send(&transport,++tick));
    CHECK(deliver(256));CHECK(bus.Ack[2]==1 && bus.Ack[3]==0xabcdef01);
    CHECK(fresh());before=bus.Calls;CHECK(Rx25TransportV2Configure(&transport));callbacks=bus.Calls-before;
    for(n=1;n<=callbacks;n++) {
        CHECK(fresh());bus.FailAt=bus.Calls+n;bus.FailPartial=1;
        CHECK(!Rx25TransportV2Configure(&transport));CHECK(transport.Isolated && !bus.References);
        before=bus.Commits;CHECK(!Rx25TransportV2Configure(&transport));CHECK(bus.Commits==before);callbackFailures++;
    }
    /* No fabricated VERIFIED command may result from a bad sampled image. */
    CHECK(configured());CHECK(submit(0));image(jobs);bus.Memory[8191]^=1;event(16);
    CHECK(Rx25TransportV2ReadHead(&transport));CHECK(!Rx25TransportV2Deliver(&transport,++tick));
    CHECK(capture.Owned && !capture.VerifiedOffered && !transport.Delivered && bus.References==1);
    CHECK(fresh());CHECK(Rx25TransportV2Configure(&transport));tick+=limits.Job;
    CHECK(!Rx25TransportV2ReadHead(&transport));CHECK(transport.Isolated && !bus.References);
    for(n=0;n<3;n++) {
        CHECK(fresh());memset(&transport,0,sizeof(transport));
        if(n==0) bus.Magic^=1;else if(n==1) bus.Version^=1;else bus.Caps^=1;
        CHECK(!Rx25TransportV2Init(&transport,INC,&binding,&ops,&capture,&work,&captureOps,&limits));
        CHECK(transport.Isolated && !transport.Recognized && !bus.Writes && !bus.References);
    }
    CHECK(configured());bus.CallbackFault=1;
    CHECK(!Rx25TransportV2Prepare(&transport,jobs,++tick));
    CHECK(transport.Isolated && capture.Owned && capture.Phase==Rx25CaptureV2Fault && bus.References==1);
    return 1;
}
static int vectors(const char *path)
{
    FILE *f=0;ULONG w[26],n,op;unsigned j=0;
    CHECK(!fopen_s(&f,path,"w") && f);fprintf(f,"RX25CMD2\n%016llx\n",INC);
    for(n=0;n<6;n++) {
        op=n==0?1:n==5?4:(n & 1)?2:3;if(n==3) j=1;
        CHECK(Rx25TransportV2EncodeFrame(INC,&binding,n?jobs+j:0,op==3,op==4?STOP:0,w));
        fprintf(f,"COMMAND %u\n",op);
        {unsigned k;for(k=0;k<26;k++) fprintf(f,"%03x %08x f\n",0x100+k*4,w[k]);}
        fprintf(f,"010 %08x f\n",op);
    }
    fprintf(f,"END 6\n");CHECK(!fclose(f));return 1;
}
static int replay(const char *path); /* Actual RTL fixture consumer below. */
int main(int argc,char **argv)
{
    if(!normal() || !faults() || !codec() || !boundaries()) return 1;
    if(argc==3 && !strcmp(argv[1],"--vectors")) {if(!vectors(argv[2])) return 1;}
    else if(argc==3 && !strcmp(argv[1],"--replay")) {if(!replay(argv[2])) return 1;}
    else if(argc!=1) return 2;
    printf("RX25_TRANSPORT_V2_TEST_PASS checks=%u cases=%u callback_failures=%u bit_checks=%u replay_commands=%u replay_events=%u\n",
        checks,cases,callbackFailures,flips,replayCommands,replayEvents);return 0;
}
static int readImage(FILE *f,UCHAR *p)
{
    unsigned k,v;
    for(k=0;k<8192;k++) {CHECK(fscanf_s(f,"%x",&v)==1 && v<=255);p[k]=(UCHAR)v;}
    return 1;
}
static int readWrites(FILE *f,ULONG (*writes)[3],unsigned count)
{
    unsigned n;
    for(n=0;n<count;n++) CHECK(fscanf_s(f,"%x %x %x",writes[n],writes[n]+1,writes[n]+2)==3);
    return 1;
}
static int replay(const char *path)
{
    FILE *f=0;char tag[20]={0};ULONGLONG inc;unsigned op,k,jobIndex=0,records=0;
    ULONG status,reasons,count,expectedWrites[27][3],start;
    unsigned endCommands,endEvents,endRecords,endStalls;static UCHAR baseline[8192];
    CHECK(!fopen_s(&f,path,"r") && f);
    CHECK(fscanf_s(f,"%19s %llx",tag,(unsigned)sizeof(tag),&inc)==2 && !strcmp(tag,"RX25BUS2") && inc==INC);
    CHECK(fresh());
    for(;;) {
        CHECK(fscanf_s(f,"%19s",tag,(unsigned)sizeof(tag))==1);
        if(!strcmp(tag,"END")) break;
        if(!strcmp(tag,"COMMAND")) {
            CHECK(fscanf_s(f,"%u %x %x",&op,&status,&reasons)==3);
            CHECK(op>=1 && op<=4);bus.Status=status;bus.Reasons=reasons;bus.Count=0;
            if(op==2) {
                CHECK(fscanf_s(f,"%19s",tag,(unsigned)sizeof(tag))==1 && !strcmp(tag,"BASELINE"));
                CHECK(readImage(f,baseline));CHECK(!memcmp(baseline,bus.Memory,8192));
            }
            CHECK(readWrites(f,expectedWrites,27));
            if(op==2) {
                CHECK(jobIndex<2);CHECK(Rx25TransportV2Observe(&transport,++tick));
                CHECK(prepare(jobIndex++));
            } else if(op==4) CHECK(Rx25TransportV2RequestStop(&transport,STOP,++tick));
            start=bus.LogUsed;
            if(op==1) CHECK(Rx25TransportV2Configure(&transport));
            else CHECK(Rx25TransportV2Send(&transport,++tick));
            CHECK(bus.LogUsed-start==27);
            for(k=0;k<27;k++) CHECK(!memcmp(expectedWrites[k],bus.Log[start+k],3*sizeof(ULONG)));
            replayCommands++;
        } else if(!strcmp(tag,"EVENT")) {
            CHECK(fscanf_s(f,"%x %x %x",&status,&reasons,&count)==3);
            CHECK(count>0 && count<=8);bus.Status=status;bus.Reasons=reasons;bus.Count=count;
            for(k=0;k<40;k++) CHECK(fscanf_s(f,"%x",bus.Words+k)==1);
            bus.Head=Rx25TransportV2Get64(bus.Words+2);
            if(bus.Words[4] & 16) {
                CHECK(fscanf_s(f,"%19s",tag,(unsigned)sizeof(tag))==1 && !strcmp(tag,"IMAGE"));
                CHECK(readImage(f,bus.Memory));records++;
            }
            CHECK(Rx25TransportV2ReadHead(&transport));CHECK(transport.Held);
            CHECK(Rx25TransportV2Deliver(&transport,++tick));
            CHECK(fscanf_s(f,"%19s",tag,(unsigned)sizeof(tag))==1 && !strcmp(tag,"ACK"));
            CHECK(readWrites(f,expectedWrites,5));start=bus.LogUsed;
            CHECK(Rx25TransportV2Ack(&transport));CHECK(bus.LogUsed-start==5);
            for(k=0;k<5;k++) CHECK(!memcmp(expectedWrites[k],bus.Log[start+k],3*sizeof(ULONG)));
            replayEvents++;
        } else {CHECK(!"unknown RTL trace token");}
    }
    CHECK(fscanf_s(f,"%u %u %u %u",&endCommands,&endEvents,&endRecords,&endStalls)==4);
    CHECK(endCommands==6 && replayCommands==6 && endEvents==11 && replayEvents==11 && endRecords==2 && records==2 && endStalls>0);
    CHECK(fscanf_s(f,"%19s",tag,(unsigned)sizeof(tag))==EOF && feof(f));CHECK(!fclose(f));
    CHECK(capture.Completions==2 && capture.PeerConfirmed && !capture.Owned && !transport.Isolated);
    CHECK(bus.References==1 && transport.Acks==11 && bus.AckCount==11);
    {RX25_CAPTURE_V2_OUTPUT out;CHECK(Rx25CaptureV2ReadOutput(&capture,&out));CHECK(!out.ReleaseAllowed && !out.CpuWriteAllowed);}
    return 1;
}
