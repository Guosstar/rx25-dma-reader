#include <ntddk.h>
#include "../rx25_observe_v1.h"
enum RX25_OBSERVE_V1_RESULT Rx25ObserveV1KernelCompile(
    const RX25_DMA_INFO *local, const RX25_JOB_REQUEST *job, ULONG sequence,
    const UCHAR *baseline, const RX25_DMA_SNAPSHOT *snapshot, ULONG *offset)
{
    return Rx25ObserveV1Check(local, job, sequence, baseline, RX25_DMA_BYTES,
                             snapshot, sizeof(*snapshot), offset);
}
