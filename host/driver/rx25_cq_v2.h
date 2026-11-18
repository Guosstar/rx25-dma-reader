#pragma once
/* Include Windows.h or ntddk.h first. Pure snapshot validator, no MMIO/DMA.
 * Caller owns a fixed session mapping, unique increasing generation, real
 * acquire barriers, and independent payload/guard checks. This is not a fence. */
#define RX25_CQ_V2_MAGIC 0x32514352u
typedef struct _RX25_CQ_V2 {
    ULONG RequestId, Publish, Bytes, SequenceLow, ErrorDetail, SequenceHigh, Magic, Reserved;
} RX25_CQ_V2;
enum RX25_CQ_V2_RESULT { Rx25CqV2Pending, Rx25CqV2Success, Rx25CqV2Stale, Rx25CqV2Invalid };
static __inline enum RX25_CQ_V2_RESULT Rx25CqV2Check(
    const RX25_CQ_V2 *cq, ULONG firstPublish, ULONG lastPublish,
    ULONG requestId, ULONG generation, ULONGLONG sequence, ULONG length)
{
    ULONGLONG observed;
    if (!requestId || !generation || generation>65535 || !sequence ||
        (length!=16 && length!=128)) return Rx25CqV2Invalid;
    if (firstPublish!=lastPublish || cq->Publish!=firstPublish || !(lastPublish>>16))
        return Rx25CqV2Pending;
    if ((lastPublish & 65535)!=generation) return Rx25CqV2Stale;
    observed=((ULONGLONG)cq->SequenceHigh<<32)|cq->SequenceLow;
    if (cq->RequestId!=requestId || observed!=sequence) return Rx25CqV2Stale;
    if ((lastPublish>>16)!=1 || cq->Bytes!=length || cq->ErrorDetail ||
        cq->Magic!=RX25_CQ_V2_MAGIC || cq->Reserved) return Rx25CqV2Invalid;
    return Rx25CqV2Success;
}
