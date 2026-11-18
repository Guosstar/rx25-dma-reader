/* Compile-only compatibility probe. Never linked into or loaded as a driver. */
#include <ntddk.h>
#include "../rx25_capture_v2.h"
int Rx25CaptureV2KernelCompileProbe(RX25_CAPTURE_V2 *adapter,
    const RX25_CAPTURE_V2_INPUT *sample, RX25_CAPTURE_V2_OUTPUT *output,
    const RX25_SNAPSHOT_V2_JOB *job, ULONGLONG now)
{
    if(!Rx25CaptureV2Advance(adapter,sample,now)) return 0;
    if(!Rx25CaptureV2ReadOutput(adapter,output)) return 0;
    return !output->CanPrepare || Rx25CaptureV2Prepare(adapter,job,now);
}
