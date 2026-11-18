#include <Windows.h>
#include <stdio.h>
#include <string.h>
#include "../rx25_snapshot_v2.h"
static unsigned checks,flips;
static RX25_SNAPSHOT_V2 observer,goodObserver;
static UCHAR baseline[8192],image[8192],clean[8192];
static RX25_SNAPSHOT_V2_BINDING binding={0xa526111200000001ULL,0xb526111200000001ULL,1,2,3,0x12345678000ULL,8192,0x10f};
static RX25_SNAPSHOT_V2_JOB job={1,0x12345678,1,0,0,16,1};
#define CHECK(x) do { checks++; if(!(x)) { printf("FAIL snapshot line %u: %s\n",__LINE__,#x); return 1; } } while(0)
static void store32(UCHAR *p,ULONG value)
{
    unsigned k;for(k=0;k<4;k++) p[k]=(UCHAR)(value>>(k*8));
}
/* Independent fixture construction, not the validator's byte decoder. */
static void makeImage(const RX25_SNAPSHOT_V2_JOB *j)
{
    unsigned n,k;
    ULONG cq[8]={j->RequestId,0x10000|j->Generation,j->Length,(ULONG)j->Sequence,0,
        (ULONG)(j->Sequence>>32),0x32514352,0};
    memcpy(image,baseline,sizeof(image));
    for(n=0;n<j->Length/8;n++) {
        ULONGLONG word=0xa5a5000000000000ULL+(ULONGLONG)(j->SourceOffset/8+n);
        for(k=0;k<8;k++) image[j->TargetOffset+n*8+k]=(UCHAR)(word>>(8*k));
    }
    for(n=0;n<8;n++) store32(image+4096+j->TargetOffset+n*4,cq[n]);
}
static int fresh(const RX25_SNAPSHOT_V2_BINDING *b,const RX25_SNAPSHOT_V2_JOB *j,int retired)
{
    memset(&observer,0,sizeof(observer));
    if(!Rx25SnapshotV2Open(&observer,b) || !Rx25SnapshotV2Arm(&observer,j,baseline,sizeof(baseline))) return 0;
    return !retired || Rx25SnapshotV2Retire(&observer,b,j,1,j->Length)==Rx25SnapshotV2Success;
}
static enum RX25_SNAPSHOT_V2_RESULT checkImage(const RX25_SNAPSHOT_V2_BINDING *b,const RX25_SNAPSHOT_V2_JOB *j)
{
    return Rx25SnapshotV2Check(&observer,b,j,image,sizeof(image),0x10000|j->Generation,0x10000|j->Generation);
}
static int unitTests(void)
{
    RX25_SNAPSHOT_V2_BINDING b;
    RX25_SNAPSHOT_V2_JOB j;
    RX25_SNAPSHOT_V2_EVENT event;
    unsigned n,k,bit,pass;
    enum RX25_SNAPSHOT_V2_RESULT result;
    CHECK(sizeof(RX25_CQ_V2)==32);
    for(k=0;k<8192;k++) baseline[k]=(UCHAR)((k*29)^(k>>4)^0x5a);
    for(n=0;n<10;n++) {
        b=binding;memset(&observer,0,sizeof(observer));
        switch(n) {
        case 0:b.LocalEpoch=0;break;case 1:b.PeerEpoch=0;break;case 2:b.SessionId=0;break;
        case 3:b.WindowId=0;break;case 4:b.BufferId=0;break;case 5:b.BufferBytes=4096;break;
        case 6:b.PeerCaps=0xf;break;case 7:b.DmaAddress++;break;
        case 8:b.DmaAddress=0xffffffffffffe000ULL;break;default:b.DmaAddress=~0ULL;break;
        }
        CHECK(!Rx25SnapshotV2Open(&observer,&b) && observer.State==Rx25SnapshotV2Empty);
    }
    b=binding;b.DmaAddress=0xffffffffffffd000ULL;
    CHECK(fresh(&b,&job,0));
    CHECK(!Rx25SnapshotV2Open(&observer,&binding));
    for(n=0;n<16;n++) {
        memset(&observer,0,sizeof(observer));CHECK(Rx25SnapshotV2Open(&observer,&binding));j=job;
        switch(n) {
        case 0:j.Sequence=0;break;case 1:j.RequestId=0;break;case 2:j.Generation=0;break;
        case 3:j.Generation=65536;break;case 4:j.Length=0;break;case 5:j.Length=32;break;
        case 6:j.Length=4096;break;case 7:j.SourceOffset=1;break;case 8:j.SourceOffset=4096;break;
        case 9:j.SourceOffset=~0u;break;case 10:j.SourceOffset=4080;j.Length=128;break;
        case 11:j.TargetOffset=1;break;case 12:j.TargetOffset=4080;break;case 13:j.TargetOffset=~0u;break;
        case 14:j.TargetOffset=4000;j.Length=128;break;default:j.SourceKind=2;break;
        }
        CHECK(!Rx25SnapshotV2Arm(&observer,&j,baseline,sizeof(baseline)) && observer.State==Rx25SnapshotV2Ready);
    }
    CHECK(!Rx25SnapshotV2Open(NULL,&binding));
    memset(&observer,0,sizeof(observer));CHECK(!Rx25SnapshotV2Open(&observer,NULL));
    CHECK(!Rx25SnapshotV2Open(&observer,&observer.Binding));
    CHECK(Rx25SnapshotV2Open(&observer,&binding));
    CHECK(!Rx25SnapshotV2Arm(&observer,&job,baseline,8191));
    CHECK(!Rx25SnapshotV2Arm(&observer,&job,NULL,8192));
    CHECK(!Rx25SnapshotV2Arm(&observer,NULL,baseline,8192));
    CHECK(!Rx25SnapshotV2Arm(&observer,&job,observer.Baseline,8192));
    CHECK(!Rx25SnapshotV2Arm(&observer,&observer.Job,baseline,8192));
    CHECK(Rx25SnapshotV2Overlaps((const void *)(ULONG_PTR)(~(ULONG_PTR)0-3),8,baseline,8192));
    CHECK(!Rx25SnapshotV2Overlaps(baseline,0,image,8192));
    CHECK(fresh(&binding,&job,0));makeImage(&job);
    CHECK(checkImage(&binding,&job)==Rx25SnapshotV2NotReady);
    CHECK(!Rx25SnapshotV2Take(&observer,&event));
    CHECK(Rx25SnapshotV2Retire(&observer,&binding,&job,1,16)==Rx25SnapshotV2Success);
    CHECK(Rx25SnapshotV2Retire(&observer,&binding,&job,1,16)==Rx25SnapshotV2NotReady);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,image,8191,0x10001,0x10001)==Rx25SnapshotV2Invalid);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,NULL,8192,0x10001,0x10001)==Rx25SnapshotV2Invalid);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,observer.Baseline,8192,0x10001,0x10001)==Rx25SnapshotV2Invalid);
    CHECK(Rx25SnapshotV2Retire(&observer,NULL,&job,1,16)==Rx25SnapshotV2Invalid);
    CHECK(Rx25SnapshotV2Check(NULL,&binding,&job,image,8192,0,0)==Rx25SnapshotV2Invalid);
    CHECK(Rx25SnapshotV2Retire(NULL,&binding,&job,1,16)==Rx25SnapshotV2Invalid);
    CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Success);
    CHECK(!Rx25SnapshotV2Arm(&observer,&job,baseline,8192));
    CHECK(checkImage(&binding,&job)==Rx25SnapshotV2NotReady);
    CHECK(!Rx25SnapshotV2Take(&observer,NULL));
    CHECK(Rx25SnapshotV2Take(&observer,&event));
    CHECK(Rx25SnapshotV2BindingMatches(&event.Binding,&binding) && Rx25SnapshotV2JobMatches(&event.Job,&job));
    CHECK(!Rx25SnapshotV2Take(&observer,&event));
    CHECK(!Rx25SnapshotV2Arm(&observer,&job,baseline,8192));
    j=job;j.Sequence=2;CHECK(!Rx25SnapshotV2Arm(&observer,&j,baseline,8192));
    j.Generation=2;CHECK(Rx25SnapshotV2Arm(&observer,&j,baseline,8192));
    makeImage(&j);CHECK(Rx25SnapshotV2Retire(&observer,&binding,&j,1,16)==Rx25SnapshotV2Success);
    CHECK(checkImage(&binding,&j)==Rx25SnapshotV2Success);CHECK(Rx25SnapshotV2Take(&observer,&event));

    /* Every trusted capture/retire identity field must match the pending task. */
    for(n=0;n<15;n++) {
        b=binding;j=job;CHECK(fresh(&binding,&job,0));makeImage(&job);
        switch(n) {
        case 0:b.LocalEpoch++;break;case 1:b.PeerEpoch++;break;case 2:b.SessionId++;break;
        case 3:b.WindowId++;break;case 4:b.BufferId++;break;case 5:b.DmaAddress+=8192;break;
        case 6:b.BufferBytes++;break;case 7:b.PeerCaps++;break;case 8:j.Sequence++;break;
        case 9:j.RequestId++;break;case 10:j.Generation++;break;case 11:j.SourceOffset+=16;break;
        case 12:j.TargetOffset+=16;break;case 13:j.Length=128;break;default:j.SourceKind++;break;
        }
        CHECK(Rx25SnapshotV2Retire(&observer,&b,&j,1,16)==Rx25SnapshotV2Stale);
        CHECK(!observer.Retired && observer.State==Rx25SnapshotV2Armed);
        CHECK(Rx25SnapshotV2Retire(&observer,&binding,&job,1,16)==Rx25SnapshotV2Success);
        CHECK(checkImage(&b,&j)==Rx25SnapshotV2Stale && observer.State==Rx25SnapshotV2Armed);
        CHECK(!Rx25SnapshotV2Take(&observer,&event));
        CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Success);
    }
    for(n=0;n<3;n++) {
        CHECK(fresh(&binding,&job,0));makeImage(&job);
        CHECK(Rx25SnapshotV2Retire(&observer,&binding,&job,n!=0,n==1?15:17)==Rx25SnapshotV2Isolated);
        CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Isolated);
        CHECK(!Rx25SnapshotV2Take(&observer,&event));
        CHECK(!Rx25SnapshotV2Open(&observer,&binding));
    }
    /* Publish instability is not a completed image and cannot emit an event. */
    CHECK(fresh(&binding,&job,1));makeImage(&job);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,image,8192,0,0x10001)==Rx25SnapshotV2Pending);
    CHECK(observer.State==Rx25SnapshotV2Armed && !Rx25SnapshotV2Take(&observer,&event));
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,image,8192,0x10001,0)==Rx25SnapshotV2Pending);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,image,8192,0x10001,0x10002)==Rx25SnapshotV2Pending);
    store32(image+4100,0);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,image,8192,0,0)==Rx25SnapshotV2Pending);
    store32(image+4100,0x10002);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,image,8192,0x10002,0x10002)==Rx25SnapshotV2Stale);
    CHECK(observer.State==Rx25SnapshotV2Armed && !Rx25SnapshotV2Take(&observer,&event));
    store32(image+4100,0x20001);
    CHECK(Rx25SnapshotV2Check(&observer,&binding,&job,image,8192,0x20001,0x20001)==Rx25SnapshotV2Invalid);
    CHECK(observer.State==Rx25SnapshotV2Fault);

    /* A verified event stays owned by this helper until taken exactly once. */
    CHECK(fresh(&binding,&job,1));makeImage(&job);
    CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Success);
    j=job;j.Sequence=2;j.Generation=2;
    CHECK(!Rx25SnapshotV2Arm(&observer,&j,baseline,8192));
    CHECK(!Rx25SnapshotV2Take(&observer,(RX25_SNAPSHOT_V2_EVENT *)(void *)observer.Baseline));
    CHECK(observer.State==Rx25SnapshotV2Verified);
    CHECK(Rx25SnapshotV2Take(&observer,&event));
    CHECK(!Rx25SnapshotV2Take(&observer,&event));

    /* Full 64-bit sequence progress may not wrap, even with a fresh generation. */
    j=job;j.Sequence=~0ULL;CHECK(fresh(&binding,&j,1));makeImage(&j);
    CHECK(checkImage(&binding,&j)==Rx25SnapshotV2Success);
    CHECK(Rx25SnapshotV2Take(&observer,&event));
    j.Sequence=1;j.Generation=2;
    CHECK(!Rx25SnapshotV2Arm(&observer,&j,baseline,8192));

    /* Baseline is copied at arm, not a caller pointer that can be rewritten. */
    CHECK(fresh(&binding,&job,1));makeImage(&job);baseline[200]^=1;
    CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Success);baseline[200]^=1;
    Rx25SnapshotV2Fail(&observer);
    CHECK(!Rx25SnapshotV2Take(&observer,&event));
    CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Isolated);
    CHECK(!Rx25SnapshotV2Arm(&observer,&job,baseline,8192));
    Rx25SnapshotV2Fail(NULL);

    /* Exhaust all bits of two whole images, including data, CQ, and guards.
     * Second case uses 64-bit Sequence, generation 65535, and the 128B edge. */
    for(pass=0;pass<2;pass++) {
        j=job;if(pass) {j.Sequence=0x100000001ULL;j.Generation=65535;j.Length=128;j.SourceOffset=3968;j.TargetOffset=3968;}
        CHECK(fresh(&binding,&j,1));makeImage(&j);goodObserver=observer;memcpy(clean,image,8192);
        for(k=0;k<8192;k++) for(bit=0;bit<8;bit++) {
            observer=goodObserver;image[k]^=(UCHAR)(1u<<bit);result=checkImage(&binding,&j);flips++;
            if(result==Rx25SnapshotV2Success) {
                printf("FAIL snapshot corruption accepted pass=%u offset=%u bit=%u\n",pass,k,bit);return 1;
            }
            CHECK(!Rx25SnapshotV2Take(&observer,&event));
            if(k<4096 || k>=4096+j.TargetOffset+32 || k<4096+j.TargetOffset) {
                int data=k>=j.TargetOffset && k-j.TargetOffset<j.Length;
                CHECK(result==(data?Rx25SnapshotV2DataMismatch:Rx25SnapshotV2GuardMismatch));
                CHECK(observer.State==Rx25SnapshotV2Fault && observer.FailureOffset==k);
            }
            image[k]^=(UCHAR)(1u<<bit);
        }
        observer=goodObserver;CHECK(!memcmp(image,clean,8192));
        CHECK(checkImage(&binding,&j)==Rx25SnapshotV2Success);
        CHECK(Rx25SnapshotV2Take(&observer,&event));
        j.Sequence++;j.Generation=pass?1:2;
        CHECK(pass ? !Rx25SnapshotV2Arm(&observer,&j,baseline,8192) : Rx25SnapshotV2Arm(&observer,&j,baseline,8192));
    }
    /* Sweep each legal source and target position for each supported length. */
    for(pass=0;pass<2;pass++) for(n=0;n<=4064;n+=16) {
        j=job;j.Length=pass?128:16;j.TargetOffset=n;
        if(j.Length>4096-n) continue;
        j.SourceOffset=(4096-j.Length-n)&~15u;
        CHECK(fresh(&binding,&j,1));makeImage(&j);CHECK(checkImage(&binding,&j)==Rx25SnapshotV2Success);
        CHECK(Rx25SnapshotV2Take(&observer,&event));
    }
    /* Nearby 16B-aligned CQ ranges can overlap between sequential jobs. */
    j=job;CHECK(fresh(&binding,&j,1));makeImage(&j);CHECK(checkImage(&binding,&j)==Rx25SnapshotV2Success);
    CHECK(Rx25SnapshotV2Take(&observer,&event));memcpy(baseline,image,8192);
    j.Sequence=2;j.Generation=2;j.TargetOffset=16;j.SourceOffset=128;j.Length=128;
    CHECK(Rx25SnapshotV2Arm(&observer,&j,baseline,8192));makeImage(&j);
    CHECK(Rx25SnapshotV2Retire(&observer,&binding,&j,1,128)==Rx25SnapshotV2Success);
    CHECK(checkImage(&binding,&j)==Rx25SnapshotV2Success);CHECK(Rx25SnapshotV2Take(&observer,&event));
    /* Fault at any state cancels a queued event and never permits re-open. */
    for(n=0;n<4;n++) {
        memset(&observer,0,sizeof(observer));
        if(n) CHECK(Rx25SnapshotV2Open(&observer,&binding));
        if(n>=2) CHECK(Rx25SnapshotV2Arm(&observer,&job,baseline,8192));
        if(n==3) {makeImage(&job);CHECK(Rx25SnapshotV2Retire(&observer,&binding,&job,1,16)==Rx25SnapshotV2Success);
            CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Success);}
        Rx25SnapshotV2Fail(&observer);
        CHECK(!Rx25SnapshotV2Take(&observer,&event));CHECK(!Rx25SnapshotV2Open(&observer,&binding));
        CHECK(Rx25SnapshotV2Retire(&observer,&binding,&job,1,16)==Rx25SnapshotV2Isolated);
        CHECK(checkImage(&binding,&job)==Rx25SnapshotV2Isolated);
    }
    printf("RX25_SNAPSHOT_V2_TEST_PASS checks=%u flipped_bits=%u\n",checks,flips);
    return 0;
}
static int fixtures(const char *path)
{
    FILE *f=NULL;
    char tag[32]={0};
    unsigned records=0,successes=0,isolated=0,lastCase=0,caseId,fault,n,value,endCount=0;
    ULONG firstPublish,lastPublish;
    RX25_SNAPSHOT_V2_BINDING b;
    RX25_SNAPSHOT_V2_JOB j;
    RX25_SNAPSHOT_V2_EVENT event;
    enum RX25_SNAPSHOT_V2_RESULT result;
    if(fopen_s(&f,path,"r") || !f) return 2;
    if(fscanf_s(f,"%31s",tag,(unsigned)sizeof(tag))!=1 || strcmp(tag,"RX25SNAP2")) goto malformed;
    memset(&observer,0,sizeof(observer));
    while(fscanf_s(f,"%31s",tag,(unsigned)sizeof(tag))==1) {
        if(!strcmp(tag,"END")) {
            if(fscanf_s(f,"%u",&endCount)!=1 || endCount!=records) goto malformed;
            if(fscanf_s(f,"%31s",tag,(unsigned)sizeof(tag))!=EOF) goto malformed;
            break;
        }
        if(strcmp(tag,"RECORD") || fscanf_s(f,"%u %u",&caseId,&fault)!=2 || !caseId || fault>1) goto malformed;
        if(fscanf_s(f,"%llx %llx %llx %llx %llx %llx %lx %lx",&b.LocalEpoch,&b.PeerEpoch,&b.SessionId,
            &b.WindowId,&b.BufferId,&b.DmaAddress,&b.BufferBytes,&b.PeerCaps)!=8) goto malformed;
        if(fscanf_s(f,"%llx %lx %lx %lx %lx %lx %lx",&j.Sequence,&j.RequestId,&j.Generation,&j.SourceOffset,
            &j.TargetOffset,&j.Length,&j.SourceKind)!=7) goto malformed;
        /* These samples come from the RTL memory, not expected job values. */
        if(fscanf_s(f,"%lx %lx",&firstPublish,&lastPublish)!=2) goto malformed;
        for(n=0;n<8192;n++) {if(fscanf_s(f,"%2x",&value)!=1 || value>255) goto malformed;baseline[n]=(UCHAR)value;}
        for(n=0;n<8192;n++) {if(fscanf_s(f,"%2x",&value)!=1 || value>255) goto malformed;image[n]=(UCHAR)value;}
        if(caseId!=lastCase) {memset(&observer,0,sizeof(observer));if(!Rx25SnapshotV2Open(&observer,&b)) goto malformed;lastCase=caseId;}
        if(!Rx25SnapshotV2Arm(&observer,&j,baseline,8192) ||
           Rx25SnapshotV2Retire(&observer,&b,&j,1,j.Length)!=Rx25SnapshotV2Success) goto malformed;
        if(fault) Rx25SnapshotV2Fail(&observer);
        result=Rx25SnapshotV2Check(&observer,&b,&j,image,sizeof(image),firstPublish,lastPublish);
        if(fault) {
            if(result!=Rx25SnapshotV2Isolated || Rx25SnapshotV2Take(&observer,&event)) goto malformed;
            isolated++;
        } else {
            if(result!=Rx25SnapshotV2Success || !Rx25SnapshotV2Take(&observer,&event) ||
                !Rx25SnapshotV2BindingMatches(&event.Binding,&b) || !Rx25SnapshotV2JobMatches(&event.Job,&j)) goto malformed;
            successes++;
        }
        records++;
    }
    if(ferror(f) || endCount!=records || records!=14 || successes!=13 || isolated!=1) goto malformed;
    fclose(f);
    printf("RX25_SNAPSHOT_V2_RTL_FIXTURES_PASS records=%u verified_images=%u quarantined_images=%u\n",records,successes,isolated);
    return 0;
malformed:
    printf("FAIL snapshot RTL fixture record=%u\n",records);fclose(f);return 1;
}
int main(int argc,char **argv)
{
    int result;
    if(argc!=1 && !(argc==3 && !strcmp(argv[1],"--fixtures"))) return 2;
    result=unitTests();if(result) return result;
    return argc==3 ? fixtures(argv[2]) : 0;
}
