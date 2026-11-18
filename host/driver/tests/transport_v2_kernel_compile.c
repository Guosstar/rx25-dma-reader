/* Compatibility/static-analysis probe only. Never linked or loaded. */
#include <ntddk.h>
#include "../rx25_transport_v2.h"
int Rx25TransportV2KernelCompileProbe(RX25_TRANSPORT_V2 *t, ULONGLONG now)
{
    if(!Rx25TransportV2ReadHead(t)) return 0;
    if(t->Held) return Rx25TransportV2Deliver(t,now) && Rx25TransportV2Ack(t);
    return Rx25TransportV2Observe(t,now) && Rx25TransportV2Send(t,now);
}
