#pragma once
/* Include Windows.h or ntddk.h first. OFFLINE/trusted-adapter helper only.
 * No DMA reads, CPU barriers, MMIO, timers, fence, mapping release or locks.
 * Storage is >8KiB: allocate separately, never on a kernel stack. All calls
 * require one serialized owner and valid, non-overlapping caller storage.
 * Start from zero-initialized storage. Never zero/reopen an owned or faulted
 * mapping to bypass isolation; recovery requires a separate OS contract. */
#include "rx25_cq_v2.h"
#define RX25_SNAPSHOT_V2_BYTES 8192u
#define RX25_SNAPSHOT_V2_PAGE 4096u
#define RX25_SNAPSHOT_V2_PATTERN 1u
#define RX25_SNAPSHOT_V2_NO_OFFSET (~0u)

typedef struct _RX25_SNAPSHOT_V2_BINDING {
    ULONGLONG LocalEpoch, PeerEpoch, SessionId, WindowId, BufferId, DmaAddress;
    ULONG BufferBytes, PeerCaps;
} RX25_SNAPSHOT_V2_BINDING;
typedef struct _RX25_SNAPSHOT_V2_JOB {
    ULONGLONG Sequence;
    ULONG RequestId, Generation, SourceOffset, TargetOffset, Length, SourceKind;
} RX25_SNAPSHOT_V2_JOB;
typedef struct _RX25_SNAPSHOT_V2_EVENT {
    RX25_SNAPSHOT_V2_BINDING Binding;
    RX25_SNAPSHOT_V2_JOB Job;
} RX25_SNAPSHOT_V2_EVENT;
enum RX25_SNAPSHOT_V2_STATE {
    Rx25SnapshotV2Empty, Rx25SnapshotV2Ready, Rx25SnapshotV2Armed,
    Rx25SnapshotV2Verified, Rx25SnapshotV2Fault
};
enum RX25_SNAPSHOT_V2_RESULT {
    Rx25SnapshotV2Invalid, Rx25SnapshotV2NotReady, Rx25SnapshotV2Pending,
    Rx25SnapshotV2Stale, Rx25SnapshotV2Success, Rx25SnapshotV2DataMismatch,
    Rx25SnapshotV2GuardMismatch, Rx25SnapshotV2Isolated
};
typedef struct _RX25_SNAPSHOT_V2 {
    RX25_SNAPSHOT_V2_BINDING Binding;
    RX25_SNAPSHOT_V2_JOB Job;
    ULONGLONG LastSequence;
    ULONG LastGeneration, Retired, FailureOffset;
    enum RX25_SNAPSHOT_V2_STATE State;
    UCHAR Baseline[RX25_SNAPSHOT_V2_BYTES];
} RX25_SNAPSHOT_V2;

/* Bounds/alias checks do not validate address accessibility or DMA ownership. */
static __inline int Rx25SnapshotV2Overlaps(const void *a, SIZE_T an, const void *b, SIZE_T bn)
{
    ULONG_PTR ap=(ULONG_PTR)a, bp=(ULONG_PTR)b;
    if (!an || !bn) return 0;
    if (an-1>(~(ULONG_PTR)0)-ap || bn-1>(~(ULONG_PTR)0)-bp) return 1;
    return ap<=bp ? bp-ap<an : ap-bp<bn;
}
static __inline int Rx25SnapshotV2BindingMatches(
    const RX25_SNAPSHOT_V2_BINDING *a, const RX25_SNAPSHOT_V2_BINDING *b)
{
    return a->LocalEpoch==b->LocalEpoch && a->PeerEpoch==b->PeerEpoch &&
        a->SessionId==b->SessionId && a->WindowId==b->WindowId &&
        a->BufferId==b->BufferId && a->DmaAddress==b->DmaAddress &&
        a->BufferBytes==b->BufferBytes && a->PeerCaps==b->PeerCaps;
}
static __inline int Rx25SnapshotV2JobMatches(
    const RX25_SNAPSHOT_V2_JOB *a, const RX25_SNAPSHOT_V2_JOB *b)
{
    return a->Sequence==b->Sequence && a->RequestId==b->RequestId &&
        a->Generation==b->Generation && a->SourceOffset==b->SourceOffset &&
        a->TargetOffset==b->TargetOffset && a->Length==b->Length && a->SourceKind==b->SourceKind;
}
static __inline int Rx25SnapshotV2Open(RX25_SNAPSHOT_V2 *o, const RX25_SNAPSHOT_V2_BINDING *b)
{
    if (!o || !b || Rx25SnapshotV2Overlaps(o,sizeof(*o),b,sizeof(*b))) return 0;
    if (o->State!=Rx25SnapshotV2Empty || !b->LocalEpoch || !b->PeerEpoch ||
        !b->SessionId || !b->WindowId || !b->BufferId || b->BufferBytes!=8192 ||
        b->PeerCaps!=0x10f || (b->DmaAddress & 4095) ||
        b->DmaAddress>(~(ULONGLONG)0)-8192) return 0;
    o->Binding=*b;o->LastSequence=0;o->LastGeneration=0;o->Retired=0;
    o->FailureOffset=RX25_SNAPSHOT_V2_NO_OFFSET;o->State=Rx25SnapshotV2Ready;
    return 1;
}
/* Before submission, freeze the trusted pre-task image, excluding CPU writes
 * and other DMA owners. This helper sees an admitted subset, so Sequence may
 * skip forward; pipeline's admission gate still requires consecutive values. */
static __inline int Rx25SnapshotV2Arm(RX25_SNAPSHOT_V2 *o,
    const RX25_SNAPSHOT_V2_JOB *j, const UCHAR *baseline, SIZE_T baselineBytes)
{
    ULONG k;
    if (!o || !j || !baseline || baselineBytes!=8192 ||
        Rx25SnapshotV2Overlaps(o,sizeof(*o),j,sizeof(*j)) ||
        Rx25SnapshotV2Overlaps(o,sizeof(*o),baseline,baselineBytes)) return 0;
    if (o->State!=Rx25SnapshotV2Ready || !j->Sequence || j->Sequence<=o->LastSequence ||
        !j->RequestId || j->Generation<=o->LastGeneration || j->Generation>65535 ||
        j->SourceKind!=RX25_SNAPSHOT_V2_PATTERN || (j->Length!=16 && j->Length!=128) ||
        (j->SourceOffset & 15) || j->SourceOffset>=4096 || j->Length>4096-j->SourceOffset ||
        (j->TargetOffset & 15) || j->TargetOffset>4064 || j->Length>4096-j->TargetOffset) return 0;
    o->Job=*j;
    for (k=0;k<8192;k++) o->Baseline[k]=baseline[k];
    o->LastSequence=j->Sequence;o->LastGeneration=j->Generation;o->Retired=0;
    o->FailureOffset=RX25_SNAPSHOT_V2_NO_OFFSET;o->State=Rx25SnapshotV2Armed;
    return 1;
}
static __inline void Rx25SnapshotV2Fail(RX25_SNAPSHOT_V2 *o)
{
    if (o) o->State=Rx25SnapshotV2Fault;
}
/* Trusted LOCAL output event only; never a fence or a user-provided flag. */
static __inline enum RX25_SNAPSHOT_V2_RESULT Rx25SnapshotV2Retire(RX25_SNAPSHOT_V2 *o,
    const RX25_SNAPSHOT_V2_BINDING *b, const RX25_SNAPSHOT_V2_JOB *j, int success, ULONG bytes)
{
    if (!o) return Rx25SnapshotV2Invalid;
    if (o->State==Rx25SnapshotV2Fault) return Rx25SnapshotV2Isolated;
    if (!b || !j || Rx25SnapshotV2Overlaps(o,sizeof(*o),b,sizeof(*b)) ||
        Rx25SnapshotV2Overlaps(o,sizeof(*o),j,sizeof(*j))) return Rx25SnapshotV2Invalid;
    if (o->State!=Rx25SnapshotV2Armed || o->Retired) return Rx25SnapshotV2NotReady;
    if (!Rx25SnapshotV2BindingMatches(&o->Binding,b) || !Rx25SnapshotV2JobMatches(&o->Job,j))
        return Rx25SnapshotV2Stale;
    if (!success || bytes!=o->Job.Length) { Rx25SnapshotV2Fail(o);return Rx25SnapshotV2Isolated; }
    o->Retired=1;return Rx25SnapshotV2Success;
}
static __inline ULONG Rx25SnapshotV2Load32(const UCHAR *p)
{
    return (ULONG)p[0] | ((ULONG)p[1]<<8) | ((ULONG)p[2]<<16) | ((ULONG)p[3]<<24);
}
/* Immutable CPU-local image captured as publish -> actual acquire/visibility
 * operation -> whole mapping copy -> actual operation -> publish again.
 * Capture adapter must pin this exact mapping/job under a lock; no concurrent
 * rearm/CPU writer/reset. Metadata is trusted capture context, not CQ content.
 * This routine cannot enforce those physical capture preconditions. */
static __inline enum RX25_SNAPSHOT_V2_RESULT Rx25SnapshotV2Check(RX25_SNAPSHOT_V2 *o,
    const RX25_SNAPSHOT_V2_BINDING *b, const RX25_SNAPSHOT_V2_JOB *j,
    const UCHAR *image, SIZE_T imageBytes, ULONG firstPublish, ULONG lastPublish)
{
    RX25_CQ_V2 cq;
    enum RX25_CQ_V2_RESULT cr;
    ULONG k,cqOffset;
    const UCHAR *p;
    if (!o) return Rx25SnapshotV2Invalid;
    if (o->State==Rx25SnapshotV2Fault) return Rx25SnapshotV2Isolated;
    if (!b || !j || !image || imageBytes!=8192 ||
        Rx25SnapshotV2Overlaps(o,sizeof(*o),b,sizeof(*b)) ||
        Rx25SnapshotV2Overlaps(o,sizeof(*o),j,sizeof(*j)) ||
        Rx25SnapshotV2Overlaps(o,sizeof(*o),image,imageBytes)) return Rx25SnapshotV2Invalid;
    if (o->State!=Rx25SnapshotV2Armed || !o->Retired) return Rx25SnapshotV2NotReady;
    if (!Rx25SnapshotV2BindingMatches(&o->Binding,b) || !Rx25SnapshotV2JobMatches(&o->Job,j))
        return Rx25SnapshotV2Stale;
    cqOffset=4096+o->Job.TargetOffset;p=image+cqOffset;
    cq.RequestId=Rx25SnapshotV2Load32(p);cq.Publish=Rx25SnapshotV2Load32(p+4);
    cq.Bytes=Rx25SnapshotV2Load32(p+8);cq.SequenceLow=Rx25SnapshotV2Load32(p+12);
    cq.ErrorDetail=Rx25SnapshotV2Load32(p+16);cq.SequenceHigh=Rx25SnapshotV2Load32(p+20);
    cq.Magic=Rx25SnapshotV2Load32(p+24);cq.Reserved=Rx25SnapshotV2Load32(p+28);
    cr=Rx25CqV2Check(&cq,firstPublish,lastPublish,o->Job.RequestId,o->Job.Generation,o->Job.Sequence,o->Job.Length);
    if (cr==Rx25CqV2Pending) return Rx25SnapshotV2Pending;
    if (cr==Rx25CqV2Stale) return Rx25SnapshotV2Stale;
    if (cr!=Rx25CqV2Success) { Rx25SnapshotV2Fail(o);return Rx25SnapshotV2Invalid; }
    for (k=0;k<8192;k++) {
        if (k>=o->Job.TargetOffset && k-o->Job.TargetOffset<o->Job.Length) {
            ULONG pos=o->Job.SourceOffset+k-o->Job.TargetOffset;
            ULONGLONG value=0xa5a5000000000000ULL | (ULONGLONG)(pos/8);
            UCHAR wanted=(UCHAR)(value>>((pos & 7)*8));
            if (image[k]!=wanted) {
                o->FailureOffset=k;Rx25SnapshotV2Fail(o);return Rx25SnapshotV2DataMismatch;
            }
        } else if (k<cqOffset || k-cqOffset>=32) {
            if (image[k]!=o->Baseline[k]) {
                o->FailureOffset=k;Rx25SnapshotV2Fail(o);return Rx25SnapshotV2GuardMismatch;
            }
        }
    }
    o->State=Rx25SnapshotV2Verified;return Rx25SnapshotV2Success;
}
/* One-shot queued event. The adapter must retain it under backpressure until
 * pipeline verified_valid/ready, then wait for pipeline completed/job_ready
 * before arming another job. Ready here is helper accounting, not admission
 * permission. A serialized consumer must give live fault priority before
 * applying guard COMPLETE, including after Take. This is never a fence. */
static __inline int Rx25SnapshotV2Take(RX25_SNAPSHOT_V2 *o, RX25_SNAPSHOT_V2_EVENT *event)
{
    if (!o || !event || Rx25SnapshotV2Overlaps(o,sizeof(*o),event,sizeof(*event)) ||
        o->State!=Rx25SnapshotV2Verified) return 0;
    event->Binding=o->Binding;event->Job=o->Job;o->State=Rx25SnapshotV2Ready;
    return 1;
}
