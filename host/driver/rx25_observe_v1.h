#pragma once
/* Pure PL11-v1 loop_mem observation checker. Include Windows.h/ntddk.h first.
 * No I/O, submission, allocation, barriers, lifecycle transition or release.
 * CPU_ONLY fixtures can match; a match is NOT evidence of device DMA.
 * The caller owns valid, non-overlapping storage and a serialized session.
 * Keep the 8KiB images off the kernel stack. No v2/RCQ2 interpretation here. */
#include "rx25_job.h"

enum RX25_OBSERVE_V1_RESULT {
    Rx25ObserveV1Invalid = 0, Rx25ObserveV1Pending = 1,
    Rx25ObserveV1Stale = 2, Rx25ObserveV1FixtureMatch = 3,
    Rx25ObserveV1DataMismatch = 4, Rx25ObserveV1GuardMismatch = 5,
    Rx25ObserveV1HardwareError = 6
};

static __inline ULONG Rx25ObserveV1Load32(const UCHAR *p)
{
    return (ULONG)p[0] | ((ULONG)p[1] << 8) | ((ULONG)p[2] << 16) | ((ULONG)p[3] << 24);
}

static __inline enum RX25_OBSERVE_V1_RESULT Rx25ObserveV1Check(
    const RX25_DMA_INFO *local, const RX25_JOB_REQUEST *job, ULONG expectedSequence,
    const UCHAR *baseline, ULONG baselineBytes,
    const RX25_DMA_SNAPSHOT *snapshot, ULONG snapshotBytes, ULONG *failureOffset)
{
    RX25_JOB_PLAN plan;
    RX25_JOB_CQ cq;
    enum RX25_CQ_RESULT cr;
    ULONG k, cqOffset, stable;
    const UCHAR *p;
    if (failureOffset) *failureOffset = ~(ULONG)0;
    if (!local || !job || !baseline || !snapshot || baselineBytes != RX25_DMA_BYTES ||
        snapshotBytes != sizeof(*snapshot) || !Rx25JobPlan(job, local, &plan)) return Rx25ObserveV1Invalid;
    cqOffset = 0x1000 + job->TargetOffset;
    if (snapshot->Size != sizeof(*snapshot) || snapshot->Version != 1 ||
        snapshot->BufferBytes != RX25_DMA_BYTES || snapshot->BufferId != local->BufferId ||
        snapshot->DmaAddress != local->DmaAddress || snapshot->CqOffset != cqOffset || snapshot->Reserved ||
        (snapshot->Flags & 3) != 3 || (snapshot->Flags & ~7u)) return Rx25ObserveV1Invalid;
    /* A fresh baseline has no published completion or stale CQ body. */
    for (k = cqOffset; k < cqOffset + 32; k++) if (baseline[k]) return Rx25ObserveV1Invalid;
    p = snapshot->Image + cqOffset;
    cq.RequestId = Rx25ObserveV1Load32(p);
    cq.Publish = Rx25ObserveV1Load32(p + 4);
    cq.Bytes = Rx25ObserveV1Load32(p + 8);
    cq.Sequence = Rx25ObserveV1Load32(p + 12);
    cq.ErrorDetail = Rx25ObserveV1Load32(p + 16);
    for (k = 0; k < 3; k++) cq.Reserved[k] = Rx25ObserveV1Load32(p + 20 + 4 * k);
    stable = snapshot->FirstPublish == snapshot->LastPublish && cq.Publish == snapshot->FirstPublish;
    if (!!(snapshot->Flags & RX25_SNAPSHOT_PUBLISH_STABLE) != !!stable) return Rx25ObserveV1Invalid;
    if (!stable) return Rx25ObserveV1Pending;
    cr = Rx25JobCompletion(job, &cq, snapshot->FirstPublish, snapshot->LastPublish, expectedSequence);
    if (cr == Rx25CqPending) return Rx25ObserveV1Pending;
    if (cr == Rx25CqStale) return Rx25ObserveV1Stale;
    if (cr == Rx25CqHardwareError) return Rx25ObserveV1HardwareError;
    if (cr != Rx25CqSuccess) return Rx25ObserveV1Invalid;
    for (k = 0; k < RX25_DMA_BYTES; k++) {
        if (k >= job->TargetOffset && k - job->TargetOffset < job->Length) {
            /* v1 loop_mem ignores cfg_addr and restarts k=0 for EACH record.
             * Current 16/128B jobs fit one record and cannot cross 4KiB. */
            ULONG pos = k - job->TargetOffset;
            ULONGLONG value = 0xa5a5000000000000ULL | (ULONGLONG)(pos / 8);
            UCHAR wanted = (UCHAR)(value >> ((pos & 7) * 8));
            if (snapshot->Image[k] != wanted) {
                if (failureOffset) *failureOffset = k;
                return Rx25ObserveV1DataMismatch;
            }
        } else if (k < cqOffset || k - cqOffset >= 32) {
            if (snapshot->Image[k] != baseline[k]) {
                if (failureOffset) *failureOffset = k;
                return Rx25ObserveV1GuardMismatch;
            }
        }
    }
    return Rx25ObserveV1FixtureMatch;
}
