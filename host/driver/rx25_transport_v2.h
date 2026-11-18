#pragma once
/* OFFLINE trusted register adapter. Include Windows.h or ntddk.h first.
 * This is not MMIO/WDF, an IOCTL, a fence, or a mapping-release interface.
 * All entry points AND capture/provider calls share one external lifecycle /
 * single-consumer lock. Ops are trusted, bounded, non-reentrant callbacks.
 * Read32/Write32 access one aligned DWORD; byte lane 0 is bits 7:0. A successful
 * Write32 accepts exactly once. Flush orders/completes these register accesses
 * only; it NEVER proves PCIe DMA drain or CPU/DMA memory visibility. Failure
 * may be partial/indeterminate: isolate, preserve ownership, never retry a
 * command or ACK. Initial storage is zero; no reopen/reset/recovery API exists.
 * Capture and Work are distinct external allocations (>16KiB EACH), outside
 * kernel stacks. Work is a private tentative copy using the SAME retained lease,
 * not an independently retained/releasable owner. Callers cannot inspect Work
 * or mutate Capture while an operation runs. No callback retains stack pointers.
 */
#include "rx25_capture_v2.h"

#define RX25_TRANSPORT_V2_MAGIC 0x32424852u
#define RX25_TRANSPORT_V2_VERSION 0x00020000u
#define RX25_TRANSPORT_V2_CAPS 0x0000000fu
#define RX25_TRANSPORT_V2_FRAME_WORDS 26u
#define RX25_TRANSPORT_V2_EVENT_WORDS 40u
#define RX25_TRANSPORT_V2_FAULT_MASK 0x3ffu
#define RX25_TRANSPORT_V2_STATUS_MASK 0xffffu
#define RX25_TRANSPORT_V2_LIVE_FAULT (1u | (1u<<10))
#define RX25_TRANSPORT_V2_TASK_FLAGS (4u|8u|16u|32u|64u|128u)
enum RX25_TRANSPORT_V2_COMMAND {Rx25TransportV2Config=1, Rx25TransportV2Job,
    Rx25TransportV2Verified, Rx25TransportV2Stop};
typedef struct _RX25_TRANSPORT_V2_OPS {
    void *Context;
    int (*Read32)(void *, ULONG, ULONG *);
    int (*Write32)(void *, ULONG, ULONG, ULONG);
    int (*Flush)(void *);
} RX25_TRANSPORT_V2_OPS;
typedef struct _RX25_TRANSPORT_V2_EVENT {
    ULONGLONG Incarnation, Id, RetireSequence, StopSequence;
    RX25_SNAPSHOT_V2_EVENT Task;
    ULONG Flags, Reasons, Status, RetireBytes, RetireSuccess, VerifiedSuccess;
} RX25_TRANSPORT_V2_EVENT;
typedef struct _RX25_TRANSPORT_V2 {
    RX25_TRANSPORT_V2_OPS Ops;
    RX25_CAPTURE_V2_OPS CaptureOps;
    RX25_CAPTURE_V2_LIMITS Limits;
    RX25_SNAPSHOT_V2_BINDING Binding;
    RX25_CAPTURE_V2 *Capture, *Work;
    ULONGLONG Incarnation, AckedId, ConfigStart, ConfigNow;
    RX25_TRANSPORT_V2_EVENT Event;
    ULONG Initialized, Recognized, ConfigSent, Configured, Isolated, FaultSent;
    ULONG Held, Delivered, StopSent, HardwareReasons, FaultReasons, Events, Acks;
} RX25_TRANSPORT_V2;

static __inline ULONGLONG Rx25TransportV2Get64(const ULONG *w)
{ return (ULONGLONG)w[0] | ((ULONGLONG)w[1]<<32); }
static __inline void Rx25TransportV2Put64(ULONG *w, ULONGLONG value)
{ w[0]=(ULONG)value;w[1]=(ULONG)(value>>32); }
static __inline int Rx25TransportV2BindingValid(const RX25_SNAPSHOT_V2_BINDING *b)
{
    return b && b->LocalEpoch && b->PeerEpoch && b->SessionId && b->WindowId && b->BufferId &&
        b->BufferBytes==8192 && b->PeerCaps==0x10f && !(b->DmaAddress & 4095) &&
        b->DmaAddress<=~0ULL-8192;
}
static __inline void Rx25TransportV2EncodeBinding(ULONG *w, const RX25_SNAPSHOT_V2_BINDING *b)
{
    Rx25TransportV2Put64(w,b->LocalEpoch);Rx25TransportV2Put64(w+2,b->PeerEpoch);
    Rx25TransportV2Put64(w+4,b->SessionId);Rx25TransportV2Put64(w+6,b->WindowId);
    /* Register order is base THEN buffer ID; it is not C struct field order. */
    Rx25TransportV2Put64(w+8,b->DmaAddress);Rx25TransportV2Put64(w+10,b->BufferId);
    w[12]=b->BufferBytes;w[13]=b->PeerCaps;
}
static __inline void Rx25TransportV2DecodeBinding(const ULONG *w, RX25_SNAPSHOT_V2_BINDING *b)
{
    b->LocalEpoch=Rx25TransportV2Get64(w);b->PeerEpoch=Rx25TransportV2Get64(w+2);
    b->SessionId=Rx25TransportV2Get64(w+4);b->WindowId=Rx25TransportV2Get64(w+6);
    b->DmaAddress=Rx25TransportV2Get64(w+8);b->BufferId=Rx25TransportV2Get64(w+10);
    b->BufferBytes=w[12];b->PeerCaps=w[13];
}
static __inline void Rx25TransportV2EncodeJob(ULONG *w, const RX25_SNAPSHOT_V2_JOB *j)
{
    Rx25TransportV2Put64(w,j->Sequence);w[2]=j->RequestId;w[3]=j->Generation;
    w[4]=j->SourceOffset;w[5]=j->TargetOffset;w[6]=j->Length;
}
static __inline int Rx25TransportV2EncodeFrame(ULONGLONG incarnation,
    const RX25_SNAPSHOT_V2_BINDING *b, const RX25_SNAPSHOT_V2_JOB *j,
    ULONG success, ULONGLONG stop, ULONG *words)
{
    ULONG k;
    if (!incarnation || !Rx25TransportV2BindingValid(b) || !words || success>1 ||
        (j && j->SourceKind!=RX25_SNAPSHOT_V2_PATTERN) ||
        Rx25SnapshotV2Overlaps(words,26*sizeof(ULONG),b,sizeof(*b)) ||
        (j && Rx25SnapshotV2Overlaps(words,26*sizeof(ULONG),j,sizeof(*j)))) return 0;
    for(k=0;k<26;k++) words[k]=0;
    Rx25TransportV2Put64(words,incarnation);Rx25TransportV2EncodeBinding(words+2,b);
    if(j) Rx25TransportV2EncodeJob(words+16,j);
    words[23]=success;Rx25TransportV2Put64(words+24,stop);return 1;
}
/* Pure decoder; no callbacks or inferred success. Ready in event.Status is
 * pre-edge historical data and is NEVER used as capture transport handshake. */
static __inline int Rx25TransportV2DecodeEvent(const ULONG *w, RX25_TRANSPORT_V2_EVENT *e)
{
    ULONG k;
    RX25_TRANSPORT_V2_EVENT zero={0};
    if (!w || !e || Rx25SnapshotV2Overlaps(w,40*sizeof(ULONG),e,sizeof(*e))) return 0;
    *e=zero;e->Incarnation=Rx25TransportV2Get64(w);e->Id=Rx25TransportV2Get64(w+2);
    e->Flags=w[4];e->Reasons=w[5];e->Status=w[6];
    if (!e->Incarnation || !e->Id || e->Id==~0ULL || !e->Flags || (e->Flags & ~0xfffu) ||
        (e->Reasons & ~RX25_TRANSPORT_V2_FAULT_MASK) || (e->Status & ~RX25_TRANSPORT_V2_STATUS_MASK) ||
        w[31]>1) return 0;
    for(k=35;k<40;k++) if(w[k]) return 0;
    Rx25TransportV2DecodeBinding(w+10,&e->Task.Binding);
    if (!Rx25TransportV2BindingValid(&e->Task.Binding)) return 0;
    e->Task.Job.Sequence=Rx25TransportV2Get64(w+24);e->Task.Job.RequestId=w[26];
    e->Task.Job.Generation=w[27];e->Task.Job.SourceOffset=w[28];
    e->Task.Job.TargetOffset=w[29];e->Task.Job.Length=w[30];
    /* Current protocol has only internal pattern, never a B host-memory proof. */
    e->Task.Job.SourceKind=RX25_SNAPSHOT_V2_PATTERN;e->VerifiedSuccess=w[31];
    e->StopSequence=Rx25TransportV2Get64(w+32);
    if(e->Flags & 16) {
        if(w[34]>1) return 0;
        e->RetireSuccess=w[34];e->RetireBytes=w[7];e->RetireSequence=Rx25TransportV2Get64(w+8);
    }
    return 1;
}
static __inline void Rx25TransportV2Fail(RX25_TRANSPORT_V2 *t, ULONG reason)
{
    t->Isolated=1;t->FaultReasons|=reason;
    if(t->Capture && t->Capture->Phase!=Rx25CaptureV2Empty) Rx25CaptureV2Fail(t->Capture,reason);
    /* Best effort atomic HOST_FAULT. Do not retry after indeterminate I/O.
     * It intentionally need not have a valid command frame. */
    if(!t->FaultSent && t->Initialized && t->Recognized) {
        t->FaultSent=1;
        (void)t->Ops.Write32(t->Ops.Context,0x10,0x80000000u,15);
        (void)t->Ops.Flush(t->Ops.Context);
    }
}
static __inline int Rx25TransportV2Read(RX25_TRANSPORT_V2 *t, ULONG offset, ULONG *value)
{
    if(!t->Ops.Read32(t->Ops.Context,offset,value)) {Rx25TransportV2Fail(t,Rx25CaptureV2Provider);return 0;}
    return 1;
}
/* Locked lifecycle + ordered DWORD reads. Two identity/status observations
 * bracket each live sample; arbitrary reset ABA cannot be solved here. The
 * external lifecycle manager MUST never reuse incarnation after reset. */
static __inline int Rx25TransportV2Live(RX25_TRANSPORT_V2 *t, ULONG *status, ULONG *count, ULONGLONG *id)
{
    ULONG s0,s1,r0,r1,n,il,ih,jl,jh,lo,hi;
    ULONGLONG now;
    if(!t || !t->Initialized || t->Isolated || !status || !count || !id) return 0;
    if(t->ConfigSent && !t->Configured) {
        if(!t->CaptureOps.ReadClock(t->CaptureOps.Context,&now) || now<t->ConfigNow ||
           now-t->ConfigStart>=t->Limits.Job) {Rx25TransportV2Fail(t,Rx25CaptureV2Deadline);return 0;}
        t->ConfigNow=now;
    }
    if(!Rx25TransportV2Read(t,0x0c,&s0) || !Rx25TransportV2Read(t,0x14,&r0) ||
       !Rx25TransportV2Read(t,0x18,&il) || !Rx25TransportV2Read(t,0x1c,&ih) ||
       !Rx25TransportV2Read(t,0x2c,&n) || !Rx25TransportV2Read(t,0x20,&lo) ||
       !Rx25TransportV2Read(t,0x24,&hi) || !Rx25TransportV2Read(t,0x18,&jl) ||
       !Rx25TransportV2Read(t,0x1c,&jh) || !Rx25TransportV2Read(t,0x14,&r1) ||
       !Rx25TransportV2Read(t,0x0c,&s1)) return 0;
    t->HardwareReasons|=r0|r1;
    if((s0|s1) & (RX25_TRANSPORT_V2_LIVE_FAULT | ~RX25_TRANSPORT_V2_STATUS_MASK) || r0 || r1 ||
       (((ULONGLONG)ih<<32)|il)!=t->Incarnation || il!=jl || ih!=jh || n>8 ||
       (t->Configured && ((s0 & 0x88)!=0x88 || (s1 & 0x88)!=0x88)) ||
       (!n && (lo || hi)) || (n && (!lo && !hi))) {
        Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;
    }
    *status=s1;*count=n;*id=((ULONGLONG)hi<<32)|lo;return 1;
}
static __inline int Rx25TransportV2Init(RX25_TRANSPORT_V2 *t,
    ULONGLONG incarnation, const RX25_SNAPSHOT_V2_BINDING *b,
    const RX25_TRANSPORT_V2_OPS *ops, RX25_CAPTURE_V2 *capture, RX25_CAPTURE_V2 *work,
    const RX25_CAPTURE_V2_OPS *captureOps, const RX25_CAPTURE_V2_LIMITS *limits)
{
    ULONG magic,version,caps,s,n;ULONGLONG id;
    if(!t || !ops || !capture || !work || !captureOps || !limits || !incarnation ||
       !Rx25TransportV2BindingValid(b) || !ops->Read32 || !ops->Write32 || !ops->Flush ||
       !captureOps->Retain || !captureOps->Current || !captureOps->Visibility || !captureOps->ReadPublish ||
       !captureOps->CopyMapping || !captureOps->ReadClock || !limits->Job || !limits->Verify || !limits->Complete || !limits->Stop ||
       Rx25SnapshotV2Overlaps(t,sizeof(*t),capture,sizeof(*capture)) ||
       Rx25SnapshotV2Overlaps(t,sizeof(*t),work,sizeof(*work)) ||
       Rx25SnapshotV2Overlaps(capture,sizeof(*capture),work,sizeof(*work)) ||
       Rx25SnapshotV2Overlaps(t,sizeof(*t),b,sizeof(*b)) ||
       Rx25SnapshotV2Overlaps(t,sizeof(*t),ops,sizeof(*ops)) ||
       Rx25SnapshotV2Overlaps(t,sizeof(*t),captureOps,sizeof(*captureOps)) ||
       Rx25SnapshotV2Overlaps(t,sizeof(*t),limits,sizeof(*limits))) return 0;
    if(t->Initialized || t->Isolated || capture->Phase!=Rx25CaptureV2Empty || work->Phase!=Rx25CaptureV2Empty) return 0;
    t->Ops=*ops;t->CaptureOps=*captureOps;t->Limits=*limits;t->Binding=*b;
    t->Capture=capture;t->Work=work;t->Incarnation=incarnation;t->Initialized=1;
    if(!Rx25TransportV2Read(t,0,&magic) || !Rx25TransportV2Read(t,4,&version) || !Rx25TransportV2Read(t,8,&caps)) return 0;
    if(magic!=RX25_TRANSPORT_V2_MAGIC || version!=RX25_TRANSPORT_V2_VERSION || caps!=RX25_TRANSPORT_V2_CAPS) {
        Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;
    }
    t->Recognized=1;
    if(!Rx25TransportV2Live(t,&s,&n,&id) || (s & ((1u<<1)|(1u<<2)|(1u<<3)|(1u<<4))) || n || !(s & (1u<<13))) {
        Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;
    }
    return 1;
}
/* Read into a private held slot. Never ACK inside a read or a decoder. */
static __inline int Rx25TransportV2ReadHead(RX25_TRANSPORT_V2 *t)
{
    ULONG s,n,k,words[40];ULONGLONG before,after;
    if(!t || t->Held || !Rx25TransportV2Live(t,&s,&n,&before)) return 0;
    if(!n) return 1;
    for(k=0;k<40;k++) if(!Rx25TransportV2Read(t,0x200+k*4,words+k)) return 0;
    if(!Rx25TransportV2Live(t,&s,&n,&after)) return 0;
    if(!n || before!=after || !Rx25TransportV2DecodeEvent(words,&t->Event) ||
       t->Event.Id!=before || t->Event.Id!=t->AckedId+1 || t->Event.Incarnation!=t->Incarnation ||
       !Rx25SnapshotV2BindingMatches(&t->Binding,&t->Event.Task.Binding)) {
        Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;
    }
    t->Held=1;t->Delivered=0;return 1;
}
/* Evaluate on private Work; faults discovered during capture's callbacks
 * cannot commit tentative success/completion or clear the real Owned flag. */
static __inline int Rx25TransportV2Advance(RX25_TRANSPORT_V2 *t, const RX25_CAPTURE_V2_INPUT *in, ULONGLONG now)
{
    ULONG s,n;ULONGLONG id;int ok;
    if(!Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    *t->Work=*t->Capture;ok=Rx25CaptureV2Advance(t->Work,in,now);
    if(!Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    *t->Capture=*t->Work;
    if(!ok) {Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;}
    return 1;
}
static __inline int Rx25TransportV2Deliver(RX25_TRANSPORT_V2 *t, ULONGLONG now)
{
    RX25_CAPTURE_V2_INPUT in={0};RX25_TRANSPORT_V2_EVENT *e;
    ULONG s,n,f;ULONGLONG id;
    if(!t || !t->Held || t->Delivered || t->Isolated || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    e=&t->Event;f=e->Flags;
    if(!n || id!=e->Id || e->Reasons || (e->Status & RX25_TRANSPORT_V2_LIVE_FAULT) ||
       (f & (2u|8u|64u|512u|2048u))) {Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;}
    if(!t->Configured) {
        if(!t->ConfigSent || f!=1 || !(s & (1u<<3)) || !(s & (1u<<7))) {
            Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;
        }
        /* CFG_OK authenticates the fixed binding before retaining/opening. */
        if(!Rx25CaptureV2Open(t->Capture,&t->Binding,&t->CaptureOps,&t->Limits,now) ||
           !Rx25TransportV2Live(t,&s,&n,&id) || !n || id!=e->Id) {
            Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;
        }
        t->Configured=1;
    } else {
        if((f & 3) || ((f & RX25_TRANSPORT_V2_TASK_FLAGS) &&
           (!t->Capture->Owned || !Rx25CaptureV2TaskMatches(t->Capture,&e->Task))) ||
           ((f & 16) && e->RetireSequence!=e->Task.Job.Sequence) ||
           ((f & (256u|1024u)) && (!t->StopSent || e->StopSequence!=t->Capture->StopSequence)) ||
           ((f & 32) && e->VerifiedSuccess!=1)) {
            Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;
        }
        in.Task=e->Task;in.StopBinding=e->Task.Binding;in.StopSequence=e->StopSequence;
        in.JobAccepted=(f & 4)!=0;in.RetireValid=(f & 16)!=0;
        in.RetireSuccess=e->RetireSuccess;in.RetireBytes=e->RetireBytes;
        in.VerifiedAccepted=(f & 32)!=0;in.Completed=(f & 128)!=0;
        in.StopAccepted=(f & 256)!=0;in.PeerConfirmed=(f & 1024)!=0;
        if(!Rx25TransportV2Advance(t,&in,now)) return 0;
    }
    t->Delivered=1;t->Events++;return 1;
}
static __inline int Rx25TransportV2Write(RX25_TRANSPORT_V2 *t, ULONG offset, ULONG value)
{
    if(!t->Ops.Write32(t->Ops.Context,offset,value,15)) {Rx25TransportV2Fail(t,Rx25CaptureV2Provider);return 0;}
    return 1;
}
static __inline int Rx25TransportV2Flush(RX25_TRANSPORT_V2 *t)
{
    if(!t->Ops.Flush(t->Ops.Context)) {Rx25TransportV2Fail(t,Rx25CaptureV2Provider);return 0;}
    return 1;
}
static __inline int Rx25TransportV2Ack(RX25_TRANSPORT_V2 *t)
{
    ULONG s,n;ULONGLONG id;
    if(!t || !t->Held || !t->Delivered || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(!n || id!=t->Event.Id) {Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;}
    if(!Rx25TransportV2Write(t,0x30,(ULONG)t->Incarnation) ||
       !Rx25TransportV2Write(t,0x34,(ULONG)(t->Incarnation>>32)) ||
       !Rx25TransportV2Write(t,0x38,(ULONG)id) || !Rx25TransportV2Write(t,0x3c,(ULONG)(id>>32)) ||
       !Rx25TransportV2Flush(t) || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(!n || id!=t->Event.Id) {Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;}
    if(!Rx25TransportV2Write(t,0x40,1) || !Rx25TransportV2Flush(t) || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(n && id!=t->Event.Id+1) {Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;}
    t->AckedId=t->Event.Id;t->Held=0;t->Delivered=0;t->Acks++;return 1;
}
static __inline int Rx25TransportV2FrameWrite(RX25_TRANSPORT_V2 *t, ULONG command,
    const RX25_SNAPSHOT_V2_JOB *job, ULONG success, ULONGLONG stop)
{
    ULONG words[26],k,s,n;ULONGLONG id;
    if(!Rx25TransportV2EncodeFrame(t->Incarnation,&t->Binding,job,success,stop,words)) return 0;
    for(k=0;k<26;k++) if(!Rx25TransportV2Write(t,0x100+k*4,words[k])) return 0;
    if(!Rx25TransportV2Flush(t) || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(t->Configured && (!t->Capture->Ops.Current(t->Capture->Ops.Context,&t->Binding) ||
       !Rx25CaptureV2RefreshClock(t->Capture))) {Rx25TransportV2Fail(t,Rx25CaptureV2Provider);return 0;}
    if(!Rx25TransportV2Live(t,&s,&n,&id) || !Rx25TransportV2Write(t,0x10,command) ||
       !Rx25TransportV2Flush(t) || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    return 1;
}
static __inline int Rx25TransportV2Configure(RX25_TRANSPORT_V2 *t)
{
    ULONG s,n;ULONGLONG id;
    if(!t || t->ConfigSent || t->Configured || t->Held || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(n || (s & (1u<<1)) || !(s & (1u<<13))) return 0;
    if(!t->CaptureOps.ReadClock(t->CaptureOps.Context,&t->ConfigStart)) {Rx25TransportV2Fail(t,Rx25CaptureV2Provider);return 0;}
    t->ConfigNow=t->ConfigStart;
    if(!Rx25TransportV2FrameWrite(t,1,0,0,0)) return 0;
    t->ConfigSent=1;return Rx25TransportV2Live(t,&s,&n,&id);
}
/* A NEW live observation may grant admission only while no offered submit is
 * being consumed. Historical event-ready bits are deliberately ignored. */
static __inline int Rx25TransportV2Observe(RX25_TRANSPORT_V2 *t, ULONGLONG now)
{
    ULONG s,n;ULONGLONG id;RX25_CAPTURE_V2_INPUT in={0};
    if(!t || !t->Configured || t->Held || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(n) return 0; /* process ordered events before an idle/ready sample */
    if(!t->Capture->SubmitOffered) in.JobReady=(s & (1u<<11)) && !(s & ((1u<<1)|(1u<<2)|(1u<<4)));
    return Rx25TransportV2Advance(t,&in,now);
}
static __inline int Rx25TransportV2RequestStop(RX25_TRANSPORT_V2 *t, ULONGLONG sequence, ULONGLONG now)
{
    RX25_CAPTURE_V2_INPUT in={0};
    if(!t || !t->Configured || !sequence || t->Held) return 0;
    if(t->Capture->Stopping && sequence!=t->Capture->StopSequence) {Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;}
    in.StopRequest=1;in.StopBinding=t->Binding;in.StopSequence=sequence;
    return Rx25TransportV2Advance(t,&in,now);
}
/* Reserve on the REAL capture before baseline callbacks. A failure after
 * reservation must preserve that reservation, not roll it back with Work. */
static __inline int Rx25TransportV2Prepare(RX25_TRANSPORT_V2 *t, const RX25_SNAPSHOT_V2_JOB *job, ULONGLONG now)
{
    ULONG s,n;ULONGLONG id;int ok;
    if(!t || !t->Configured || t->Held || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(n || !(s & (1u<<11)) || (s & ((1u<<1)|(1u<<2)|(1u<<4)))) return 0;
    ok=Rx25CaptureV2Prepare(t->Capture,job,now);
    if(!Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(!ok && t->Capture->Phase==Rx25CaptureV2Fault) Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);
    return ok;
}
/* Transport acceptance is a flushed, healthy complete bridge COMMIT. This
 * consumes capture's offered valid, NOT native acceptance. JOB_OK/VERIFY_OK
 * remain separate ordered replies. Never resubmit after a successful COMMIT. */
static __inline int Rx25TransportV2Send(RX25_TRANSPORT_V2 *t, ULONGLONG now)
{
    RX25_CAPTURE_V2_OUTPUT out;RX25_CAPTURE_V2_INPUT in={0};
    ULONG s,n,op=0;ULONGLONG id;
    if(!t || !t->Configured || t->Held || !Rx25TransportV2Live(t,&s,&n,&id)) return 0;
    if(n || (s & (1u<<1))) return 0;
    if(!Rx25CaptureV2ReadOutput(t->Capture,&out)) return 0;
    if(out.FaultValid) {Rx25TransportV2Fail(t,Rx25CaptureV2Bridge);return 0;}
    if(!Rx25CaptureV2Clock(t->Capture,now) || Rx25CaptureV2Expired(t->Capture)) {
        Rx25TransportV2Fail(t,Rx25CaptureV2Deadline);return 0;
    }
    if(out.SubmitValid) op=2;
    else if(out.VerifiedValid) op=3;
    else if(out.StopValid && !t->StopSent) op=4;
    if(!op) return 1;
    if(!Rx25TransportV2FrameWrite(t,op,out.Task.Job.Sequence?&out.Task.Job:0,op==3?out.VerifiedSuccess:0,out.StopSequence)) return 0;
    if(op==4) {t->StopSent=1;return 1;}
    in.JobReady=op==2;in.VerifiedReady=op==3;
    return Rx25TransportV2Advance(t,&in,t->Capture->Now);
}
