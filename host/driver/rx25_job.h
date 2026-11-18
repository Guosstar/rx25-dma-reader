#pragma once
#include "rx25dma_public.h"

/* This contract computes a plan only. It performs no I/O and authenticates no
 * remote lease. A future dispatcher must establish the peer's mapping lifetime
 * and prevent remote requests outside that mapping before enabling hardware.
 */
#define RX25_JOB_PLAN_ONLY 1u
#define RX25_JOB_PEER_UNVERIFIED 2u

#pragma pack(push, 8)
typedef struct _RX25_JOB_REQUEST {
    ULONG Size, Version;
    ULONGLONG BufferId, PeerBufferId, PeerDmaAddress;
    ULONG PeerBufferBytes, SourceOffset, TargetOffset, Length;
    ULONG RequestId, Generation, TimeoutUs, Reserved;
} RX25_JOB_REQUEST;

typedef struct _RX25_JOB_WRITE { ULONG Offset, Value; } RX25_JOB_WRITE;

typedef struct _RX25_JOB_PLAN {
    ULONG Size, Version, Flags, WriteCount;
    ULONGLONG BufferId, PeerBufferId, DataDmaAddress, CqDmaAddress;
    ULONG Descriptor[8];
    RX25_JOB_WRITE Writes[7];
    ULONG FenceReadOffset, DoorbellOffset, DoorbellValue, Reserved;
} RX25_JOB_PLAN;

typedef struct _RX25_JOB_CQ {
    ULONG RequestId, Publish, Bytes, Sequence, ErrorDetail, Reserved[3];
} RX25_JOB_CQ;
#pragma pack(pop)

static __inline int Rx25JobPlan(const RX25_JOB_REQUEST *request, const RX25_DMA_INFO *local,
                               RX25_JOB_PLAN *plan)
{
    ULONG i;
    const ULONGLONG maximum = ~(ULONGLONG)0;
    if (request->Size != sizeof(*request) || request->Version != 1 || request->Reserved ||
        local->Size != sizeof(*local) || local->Version != 1 ||
        local->Role != RX25_DMA_ROLE_A || local->Caps != 0xF ||
        local->BufferBytes != RX25_DMA_BYTES || local->CqOffset != 0x1000 ||
        !local->BufferId || request->BufferId != local->BufferId || !request->PeerBufferId ||
        local->Control != 0 || (local->Status & 0x104) ||
        (local->DmaAddress & 0xFFF) || local->DmaAddress > maximum - RX25_DMA_BYTES ||
        request->PeerBufferBytes != RX25_DMA_BYTES || (request->PeerDmaAddress & 0xFFF) ||
        request->PeerDmaAddress > maximum - RX25_DMA_BYTES ||
        !request->RequestId || !request->Generation || request->Generation > 0xFFFF ||
        request->TimeoutUs < 1000 || request->TimeoutUs > 10000000 ||
        (request->Length != 16 && request->Length != 128) ||
        (request->SourceOffset & 15) || (request->TargetOffset & 15) ||
        ((request->SourceOffset & 0xFFF) + request->Length > 0x1000) ||
        !Rx25DmaValidRange(request->PeerBufferBytes, request->SourceOffset, request->Length) ||
        !Rx25DmaValidRange(0x1000, request->TargetOffset, request->Length) ||
        !Rx25DmaValidRange(local->BufferBytes, 0x1000 + request->TargetOffset, 32)) return 0;
    /* Numeric IOVA overlap is legal in different device/host address spaces.
     * Only an authenticated peer lease can establish mapping ownership. */
    plan->Size = sizeof(*plan);
    plan->Version = 1;
    plan->Flags = RX25_JOB_PLAN_ONLY | RX25_JOB_PEER_UNVERIFIED;
    plan->WriteCount = 7;
    plan->BufferId = local->BufferId;
    plan->PeerBufferId = request->PeerBufferId;
    plan->DataDmaAddress = local->DmaAddress + request->TargetOffset;
    plan->CqDmaAddress = plan->DataDmaAddress + 0x1000;
    plan->Descriptor[0] = (ULONG)(request->PeerDmaAddress + request->SourceOffset);
    plan->Descriptor[1] = (ULONG)((request->PeerDmaAddress + request->SourceOffset) >> 32);
    plan->Descriptor[2] = (ULONG)plan->DataDmaAddress;
    plan->Descriptor[3] = (ULONG)(plan->DataDmaAddress >> 32);
    plan->Descriptor[4] = request->RequestId;
    plan->Descriptor[5] = (request->Length << 16) | request->Generation;
    plan->Descriptor[6] = 1;
    plan->Descriptor[7] = 0;
    for (i = 0; i < 7; i++) {
        ULONG word = i < 6 ? i : 7;
        plan->Writes[i].Offset = 0x1000 + word * 4;
        plan->Writes[i].Value = plan->Descriptor[word];
    }
    plan->FenceReadOffset = 0x10;
    plan->DoorbellOffset = 0x1018;
    plan->DoorbellValue = 1;
    plan->Reserved = 0;
    return 1;
}

enum RX25_CQ_RESULT {
    Rx25CqPending, Rx25CqSuccess, Rx25CqStale, Rx25CqInvalid, Rx25CqHardwareError
};

/* Caller reads publish -> acquire barrier -> body -> acquire -> publish again.
 * Memory ordering and physical DMA observations cannot be proved by this pure
 * function. Sequence must come from a valid session baseline, never a guess.
 */
static __inline enum RX25_CQ_RESULT Rx25JobCompletion(
    const RX25_JOB_REQUEST *request, const RX25_JOB_CQ *cq,
    ULONG firstPublish, ULONG lastPublish, ULONG expectedSequence)
{
    ULONG status;
    if (firstPublish != lastPublish || cq->Publish != firstPublish) return Rx25CqPending;
    status = lastPublish >> 16;
    if (!status) return Rx25CqPending;
    if ((lastPublish & 0xFFFF) != request->Generation) return Rx25CqStale;
    if (cq->RequestId != request->RequestId || cq->Sequence != expectedSequence ||
        cq->Reserved[0] || cq->Reserved[1] || cq->Reserved[2] || status > 8 ||
        cq->Bytes > request->Length) return Rx25CqInvalid;
    if (status != 1) return Rx25CqHardwareError;
    return cq->Bytes == request->Length && !cq->ErrorDetail ? Rx25CqSuccess : Rx25CqInvalid;
}

/* Offline ownership model, not a hardware quiescence implementation. */
enum RX25_JOB_STATE { Rx25JobIdle, Rx25JobPrepared, Rx25JobInFlight,
                     Rx25JobPublished, Rx25JobVerified, Rx25JobQuarantined };
enum RX25_JOB_EVENT { Rx25EventPrepare, Rx25EventDoorbellAfterFence,
    Rx25EventCompletionSuccess, Rx25EventPayloadAndGuardsMatch,
    Rx25EventFailureOrTimeout };

static __inline enum RX25_JOB_STATE Rx25JobNext(enum RX25_JOB_STATE state,
                                               enum RX25_JOB_EVENT event)
{
    if (state == Rx25JobQuarantined) return state; /* Late CQ cannot recycle it. */
    if (event == Rx25EventFailureOrTimeout) return Rx25JobQuarantined;
    if (state == Rx25JobIdle && event == Rx25EventPrepare) return Rx25JobPrepared;
    if (state == Rx25JobPrepared && event == Rx25EventDoorbellAfterFence) return Rx25JobInFlight;
    if (state == Rx25JobInFlight && event == Rx25EventCompletionSuccess) return Rx25JobPublished;
    if (state == Rx25JobPublished && event == Rx25EventPayloadAndGuardsMatch) return Rx25JobVerified;
    return Rx25JobQuarantined; /* Invalid event order is a lifecycle fault. */
}

static __inline int Rx25JobCanRelease(enum RX25_JOB_STATE state,
                                      int aMappingRevoked, int bMappingRevoked)
{
    if (state == Rx25JobIdle || state == Rx25JobPrepared) return 1; /* Never armed. */
    return aMappingRevoked && bMappingRevoked;
}
