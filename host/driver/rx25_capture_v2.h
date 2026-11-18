#pragma once
/* Executable OFFLINE capture/transport contract, not an installed DMA adapter.
 * Include Windows.h or ntddk.h first. Allocate outside the kernel stack (>16KiB).
 * One caller holds the mapping/lifecycle lock through every operation and all
 * callbacks. Callbacks cannot reenter, retain caller pointers, or use user claims.
 * Retain takes an exclusive, write-frozen mapping lease for this object's entire
 * lifetime; failure takes no lease. No release/recovery/fence operation exists.
 * A real platform must implement and validate the visibility and read callbacks;
 * a callback returning 1 in a test does not prove actual CPU/DMA visibility. */
#include "rx25_snapshot_v2.h"

enum RX25_CAPTURE_V2_PHASE {
    Rx25CaptureV2Empty, Rx25CaptureV2AwaitReady, Rx25CaptureV2Ready,
    Rx25CaptureV2SubmitPending, Rx25CaptureV2SubmitReply, Rx25CaptureV2WaitRetire,
    Rx25CaptureV2Polling, Rx25CaptureV2VerifiedPending, Rx25CaptureV2VerifiedReply,
    Rx25CaptureV2WaitComplete, Rx25CaptureV2Stopped, Rx25CaptureV2Fault
};
enum RX25_CAPTURE_V2_VISIBILITY {
    Rx25CaptureV2BaselineBefore=1, Rx25CaptureV2BaselineAfter,
    Rx25CaptureV2AfterFirstPublish, Rx25CaptureV2BeforeLastPublish
};
enum RX25_CAPTURE_V2_FAULT {
    Rx25CaptureV2External=1, Rx25CaptureV2FileClose=2, Rx25CaptureV2D0Exit=4,
    Rx25CaptureV2Removed=8, Rx25CaptureV2Reset=16, Rx25CaptureV2Provider=32,
    Rx25CaptureV2Deadline=64, Rx25CaptureV2Bridge=128, Rx25CaptureV2Image=256,
    Rx25CaptureV2ClockFault=512
};
typedef struct _RX25_CAPTURE_V2_OPS {
    void *Context;
    int (*Retain)(void *, const RX25_SNAPSHOT_V2_BINDING *);
    int (*Current)(void *, const RX25_SNAPSHOT_V2_BINDING *);
    int (*Visibility)(void *, enum RX25_CAPTURE_V2_VISIBILITY);
    int (*ReadPublish)(void *, ULONG, ULONG *);
    int (*CopyMapping)(void *, UCHAR *, ULONG);
    int (*ReadClock)(void *, ULONGLONG *);
} RX25_CAPTURE_V2_OPS;
typedef struct _RX25_CAPTURE_V2_LIMITS {
    ULONGLONG Job, Verify, Complete, Stop;
} RX25_CAPTURE_V2_LIMITS;
/* Logical trusted bridge samples, NOT a packed BAR/IOCTL or mailbox ABI.
 * Task tags all task reply pulses in this sample. StopBinding/Sequence tag
 * STOP/peer pulses. Ready levels have normal pre-step ready/valid semantics.
 * The bridge must assemble coherent, non-torn status from the same incarnation. */
typedef struct _RX25_CAPTURE_V2_INPUT {
    RX25_SNAPSHOT_V2_EVENT Task;
    RX25_SNAPSHOT_V2_BINDING StopBinding;
    ULONGLONG StopSequence;
    ULONG FaultReasons, JobReady, JobAccepted, JobRejected;
    ULONG RetireValid, RetireSuccess, RetireBytes;
    ULONG VerifiedReady, VerifiedAccepted, VerifiedRejected, Completed;
    ULONG StopRequest, StopAccepted, StopRejected, PeerConfirmed;
} RX25_CAPTURE_V2_INPUT;
typedef struct _RX25_CAPTURE_V2_OUTPUT {
    RX25_SNAPSHOT_V2_EVENT Task;
    RX25_SNAPSHOT_V2_BINDING StopBinding;
    ULONGLONG StopSequence;
    ULONG SubmitValid, VerifiedValid, VerifiedSuccess, StopValid, FaultValid;
    ULONG CanPrepare, ReferenceHeld, Owned, PeerConfirmed, ReleaseAllowed, CpuWriteAllowed;
} RX25_CAPTURE_V2_OUTPUT;
typedef struct _RX25_CAPTURE_V2 {
    RX25_SNAPSHOT_V2 Observer;
    RX25_SNAPSHOT_V2_EVENT Task;
    RX25_CAPTURE_V2_OPS Ops;
    RX25_CAPTURE_V2_LIMITS Limits;
    enum RX25_CAPTURE_V2_PHASE Phase;
    ULONGLONG Now, TaskStart, RetireStart, DeliveryStart, StopStart, StopSequence;
    ULONG ReferenceHeld, Owned, AdmissionReady, SubmitOffered, VerifiedOffered;
    ULONG Stopping, StopOffered, StopAcknowledged, PeerConfirmed, FaultReasons;
    ULONG Captures, Retries, Completions, StaleEvents;
    UCHAR Image[RX25_SNAPSHOT_V2_BYTES];
} RX25_CAPTURE_V2;

static __inline int Rx25CaptureV2Expired(const RX25_CAPTURE_V2 *a);

static __inline void Rx25CaptureV2Fail(RX25_CAPTURE_V2 *a, ULONG reason)
{
    a->FaultReasons|=reason;a->Phase=Rx25CaptureV2Fault;
    a->AdmissionReady=0;Rx25SnapshotV2Fail(&a->Observer);
    /* Preserve Owned, the lease, and any already offered payload/valid. The
     * bridge carries FaultValid with priority. Offered requests may drain a
     * handshake but can never restore successful accounting in this state. */
}
static __inline int Rx25CaptureV2Clock(RX25_CAPTURE_V2 *a, ULONGLONG now)
{
    if (now<a->Now) {Rx25CaptureV2Fail(a,Rx25CaptureV2ClockFault);return 0;}
    a->Now=now;return 1;
}
static __inline int Rx25CaptureV2RefreshClock(RX25_CAPTURE_V2 *a)
{
    ULONGLONG now=0;
    if (!a->Ops.ReadClock(a->Ops.Context,&now)) {Rx25CaptureV2Fail(a,Rx25CaptureV2Provider);return 0;}
    if (!Rx25CaptureV2Clock(a,now)) return 0;
    if (Rx25CaptureV2Expired(a)) {Rx25CaptureV2Fail(a,Rx25CaptureV2Deadline);return 0;}
    return 1;
}
static __inline int Rx25CaptureV2Open(RX25_CAPTURE_V2 *a,
    const RX25_SNAPSHOT_V2_BINDING *b, const RX25_CAPTURE_V2_OPS *ops,
    const RX25_CAPTURE_V2_LIMITS *limits, ULONGLONG now)
{
    if (!a || !b || !ops || !limits ||
        Rx25SnapshotV2Overlaps(a,sizeof(*a),b,sizeof(*b)) ||
        Rx25SnapshotV2Overlaps(a,sizeof(*a),ops,sizeof(*ops)) ||
        Rx25SnapshotV2Overlaps(a,sizeof(*a),limits,sizeof(*limits))) return 0;
    if (a->Phase!=Rx25CaptureV2Empty || !ops->Retain || !ops->Current ||
        !ops->Visibility || !ops->ReadPublish || !ops->CopyMapping || !ops->ReadClock ||
        !limits->Job || !limits->Verify || !limits->Complete || !limits->Stop) return 0;
    if (!Rx25SnapshotV2Open(&a->Observer,b)) return 0;
    a->Ops=*ops;a->Limits=*limits;a->Now=now;
    if (!a->Ops.Retain(a->Ops.Context,b)) {Rx25CaptureV2Fail(a,Rx25CaptureV2Provider);return 0;}
    a->ReferenceHeld=1;
    if (!a->Ops.Current(a->Ops.Context,b)) {Rx25CaptureV2Fail(a,Rx25CaptureV2Provider);return 0;}
    a->Phase=Rx25CaptureV2AwaitReady;return Rx25CaptureV2RefreshClock(a);
}
static __inline int Rx25CaptureV2Prepare(RX25_CAPTURE_V2 *a,
    const RX25_SNAPSHOT_V2_JOB *j, ULONGLONG now)
{
    if (!a || !j || Rx25SnapshotV2Overlaps(a,sizeof(*a),j,sizeof(*j))) return 0;
    if (a->Phase!=Rx25CaptureV2Ready || !a->AdmissionReady || a->Owned || a->Stopping) return 0;
    if (!Rx25CaptureV2Clock(a,now)) return 0;
    /* Reject before provider calls or a native job_valid is offered. */
    if (a->Observer.LastSequence==~0ULL || j->Sequence!=a->Observer.LastSequence+1 ||
        !j->RequestId || j->Generation<=a->Observer.LastGeneration || j->Generation>65535 ||
        j->SourceKind!=RX25_SNAPSHOT_V2_PATTERN || (j->Length!=16 && j->Length!=128) ||
        (j->SourceOffset & 15) || j->SourceOffset>=4096 || j->Length>4096-j->SourceOffset ||
        (j->TargetOffset & 15) || j->TargetOffset>4064 || j->Length>4096-j->TargetOffset) return 0;
    a->Owned=1;a->AdmissionReady=0;a->Task.Binding=a->Observer.Binding;a->Task.Job=*j;
    a->TaskStart=now;a->Phase=Rx25CaptureV2SubmitPending;
    if (!a->Ops.Current(a->Ops.Context,&a->Task.Binding) ||
        !a->Ops.Visibility(a->Ops.Context,Rx25CaptureV2BaselineBefore) ||
        !a->Ops.CopyMapping(a->Ops.Context,a->Image,8192) ||
        !a->Ops.Visibility(a->Ops.Context,Rx25CaptureV2BaselineAfter) ||
        !a->Ops.Current(a->Ops.Context,&a->Task.Binding)) {
        Rx25CaptureV2Fail(a,Rx25CaptureV2Provider);return 0;
    }
    if (!Rx25SnapshotV2Arm(&a->Observer,j,a->Image,8192)) {
        Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;
    }
    if (!Rx25CaptureV2RefreshClock(a)) return 0;
    a->SubmitOffered=1;return 1;
}
static __inline int Rx25CaptureV2TaskMatches(const RX25_CAPTURE_V2 *a, const RX25_SNAPSHOT_V2_EVENT *e)
{
    return Rx25SnapshotV2BindingMatches(&a->Task.Binding,&e->Binding) &&
        Rx25SnapshotV2JobMatches(&a->Task.Job,&e->Job);
}
static __inline int Rx25CaptureV2Expired(const RX25_CAPTURE_V2 *a)
{
    if (a->Stopping && !a->PeerConfirmed && a->Now-a->StopStart>=a->Limits.Stop) return 1;
    switch (a->Phase) {
    case Rx25CaptureV2SubmitPending:case Rx25CaptureV2SubmitReply:case Rx25CaptureV2WaitRetire:
        return a->Now-a->TaskStart>=a->Limits.Job;
    case Rx25CaptureV2Polling:case Rx25CaptureV2VerifiedPending:
        return a->Now-a->RetireStart>=a->Limits.Verify;
    case Rx25CaptureV2VerifiedReply:case Rx25CaptureV2WaitComplete:
        return a->Now-a->DeliveryStart>=a->Limits.Complete;
    default:return 0;
    }
}
static __inline void Rx25CaptureV2Poll(RX25_CAPTURE_V2 *a)
{
    ULONG first=0,last=0,offset=4096+a->Task.Job.TargetOffset+4;
    enum RX25_SNAPSHOT_V2_RESULT result;
    if (!a->Ops.ReadPublish(a->Ops.Context,offset,&first) ||
        !a->Ops.Visibility(a->Ops.Context,Rx25CaptureV2AfterFirstPublish) ||
        !a->Ops.CopyMapping(a->Ops.Context,a->Image,8192) ||
        !a->Ops.Visibility(a->Ops.Context,Rx25CaptureV2BeforeLastPublish) ||
        !a->Ops.ReadPublish(a->Ops.Context,offset,&last) ||
        !a->Ops.Current(a->Ops.Context,&a->Task.Binding)) {
        Rx25CaptureV2Fail(a,Rx25CaptureV2Provider);return;
    }
    a->Captures++;
    result=Rx25SnapshotV2Check(&a->Observer,&a->Task.Binding,&a->Task.Job,a->Image,8192,first,last);
    if (!Rx25CaptureV2RefreshClock(a)) return;
    if (result==Rx25SnapshotV2Pending || result==Rx25SnapshotV2Stale) {a->Retries++;return;}
    if (result!=Rx25SnapshotV2Success || !Rx25SnapshotV2Take(&a->Observer,&a->Task)) {
        Rx25CaptureV2Fail(a,Rx25CaptureV2Image);return;
    }
    a->VerifiedOffered=1;a->Phase=Rx25CaptureV2VerifiedPending;
}
/* One coherent bridge sample per call. now is a caller-supplied monotonic
 * clock in the same units as Limits. Deadline wins even on the success tick. */
static __inline int Rx25CaptureV2Advance(RX25_CAPTURE_V2 *a,
    const RX25_CAPTURE_V2_INPUT *in, ULONGLONG now)
{
    ULONG submit,verified,stop,taskFlags,stopFlags;
    int matched,stopMatched,completed=0;
    if (!a || !in || Rx25SnapshotV2Overlaps(a,sizeof(*a),in,sizeof(*in)) ||
        a->Phase==Rx25CaptureV2Empty) return 0;
    submit=a->SubmitOffered;verified=a->VerifiedOffered;stop=a->StopOffered;
    if (!Rx25CaptureV2Clock(a,now)) return 0;
    if (in->FaultReasons) Rx25CaptureV2Fail(a,in->FaultReasons);
    if (a->Phase!=Rx25CaptureV2Fault && Rx25CaptureV2Expired(a)) Rx25CaptureV2Fail(a,Rx25CaptureV2Deadline);
    if (a->Phase!=Rx25CaptureV2Fault && !a->Ops.Current(a->Ops.Context,&a->Observer.Binding))
        Rx25CaptureV2Fail(a,Rx25CaptureV2Provider);
    if (a->Phase!=Rx25CaptureV2Fault) (void)Rx25CaptureV2RefreshClock(a);
    if (a->Phase==Rx25CaptureV2Fault) {
        if (submit && in->JobReady) a->SubmitOffered=0;
        if (verified && in->VerifiedReady) a->VerifiedOffered=0;
        return 0;
    }
    a->AdmissionReady=in->JobReady!=0;
    matched=Rx25CaptureV2TaskMatches(a,&in->Task);
    taskFlags=in->JobAccepted || in->JobRejected || in->RetireValid ||
        in->VerifiedAccepted || in->VerifiedRejected || in->Completed;
    if (taskFlags && (!matched || !a->Owned)) a->StaleEvents++;
    stopMatched=Rx25SnapshotV2BindingMatches(&a->Observer.Binding,&in->StopBinding) &&
        in->StopSequence && (!a->Stopping || in->StopSequence==a->StopSequence);
    stopFlags=in->StopRequest || in->StopAccepted || in->StopRejected || in->PeerConfirmed;
    if (stopFlags && !stopMatched) a->StaleEvents++;
    /* Validate fault-bearing STOP/peer replies BEFORE committing Completed.
     * A peer pulse while this sample still owns a task is early, even when
     * Completed is also asserted; distinct native edges need ordered records. */
    if (stopMatched && (in->StopRejected ||
        (in->StopAccepted && (!a->Stopping || (!stop && !a->StopAcknowledged))) ||
        (in->PeerConfirmed && (!a->Stopping || a->Owned ||
            !(a->StopAcknowledged || (stop && in->StopAccepted)))))) {
        Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;
    }
    if (in->StopRequest && stopMatched && !a->Stopping) {
        a->Stopping=1;a->StopSequence=in->StopSequence;a->StopStart=now;a->AdmissionReady=0;
    }
    if (submit && in->JobReady) {a->SubmitOffered=0;a->Phase=Rx25CaptureV2SubmitReply;}
    if (verified && in->VerifiedReady) {
        a->VerifiedOffered=0;a->DeliveryStart=now;a->Phase=Rx25CaptureV2VerifiedReply;
    }
    if (taskFlags && matched && a->Owned) {
        if (in->JobRejected || in->VerifiedRejected ||
            (in->JobAccepted && in->VerifiedAccepted)) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
        if (in->JobAccepted) {
            if (a->Phase==Rx25CaptureV2SubmitReply) a->Phase=Rx25CaptureV2WaitRetire;
            else if (a->Phase==Rx25CaptureV2SubmitPending) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
            else a->StaleEvents++;
        }
        if (in->RetireValid) {
            if (!in->RetireSuccess || in->RetireBytes!=a->Task.Job.Length) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
            if (a->Phase==Rx25CaptureV2WaitRetire) {
                if (Rx25SnapshotV2Retire(&a->Observer,&a->Task.Binding,&a->Task.Job,1,in->RetireBytes)!=Rx25SnapshotV2Success) {
                    Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;
                }
                a->RetireStart=now;a->Phase=Rx25CaptureV2Polling;
            } else if (a->Phase==Rx25CaptureV2SubmitPending || a->Phase==Rx25CaptureV2SubmitReply) {
                Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;
            } else a->StaleEvents++;
        }
        if (in->VerifiedAccepted) {
            if (a->Phase==Rx25CaptureV2VerifiedReply) a->Phase=Rx25CaptureV2WaitComplete;
            else if (a->Phase!=Rx25CaptureV2WaitComplete) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
            else a->StaleEvents++;
        }
        if (in->Completed) {
            if (a->Phase!=Rx25CaptureV2WaitComplete) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
            a->Owned=0;a->Completions++;a->AdmissionReady=0;completed=1;
            a->Phase=a->Stopping ? Rx25CaptureV2Stopped : Rx25CaptureV2AwaitReady;
        }
    }
    if (stopMatched) {
        if (in->StopRejected) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
        if (in->StopAccepted) {
            if (!a->Stopping || (!stop && !a->StopAcknowledged)) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
            a->StopOffered=0;a->StopAcknowledged=1;
        }
        if (in->PeerConfirmed) {
            if (!a->Stopping || !a->StopAcknowledged || a->Owned) {Rx25CaptureV2Fail(a,Rx25CaptureV2Bridge);return 0;}
            a->PeerConfirmed=1;a->Phase=Rx25CaptureV2Stopped;
        }
    }
    if (a->Phase==Rx25CaptureV2Polling) Rx25CaptureV2Poll(a);
    if (a->Phase==Rx25CaptureV2Fault) return 0;
    if (!completed && a->Phase==Rx25CaptureV2AwaitReady && in->JobReady && !a->Stopping) a->Phase=Rx25CaptureV2Ready;
    /* STOP cannot strand a previously offered job behind pipeline's stop gate. */
    if (a->Stopping && !a->StopAcknowledged && a->Phase!=Rx25CaptureV2SubmitPending && a->Phase!=Rx25CaptureV2SubmitReply)
        a->StopOffered=1;
    if (a->Stopping && !a->Owned && a->Phase!=Rx25CaptureV2Stopped) a->Phase=Rx25CaptureV2Stopped;
    return 1;
}
static __inline int Rx25CaptureV2ReadOutput(const RX25_CAPTURE_V2 *a, RX25_CAPTURE_V2_OUTPUT *out)
{
    RX25_CAPTURE_V2_OUTPUT empty={0};
    if (!a || !out || Rx25SnapshotV2Overlaps(a,sizeof(*a),out,sizeof(*out))) return 0;
    *out=empty;out->Task=a->Task;out->StopBinding=a->Observer.Binding;out->StopSequence=a->StopSequence;
    out->SubmitValid=a->SubmitOffered;out->VerifiedValid=a->VerifiedOffered;out->VerifiedSuccess=1;
    out->StopValid=a->StopOffered;out->FaultValid=a->Phase==Rx25CaptureV2Fault;
    out->CanPrepare=a->Phase==Rx25CaptureV2Ready && a->AdmissionReady && !a->Owned && !a->Stopping;
    out->ReferenceHeld=a->ReferenceHeld;out->Owned=a->Owned;out->PeerConfirmed=a->PeerConfirmed;
    /* ReleaseAllowed and CpuWriteAllowed deliberately remain zero. */
    return 1;
}
