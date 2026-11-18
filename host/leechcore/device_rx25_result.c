#include "device_rx25_result.h"
#include <string.h>

static LC_READ_PAGE_RESULT Rx25ReasonMap(RX25_RESULT_REASON reason)
{
    switch(reason) {
        case Rx25ResultOk: return LC_READ_PAGE_RESULT_SUCCESS;
        case Rx25ResultLocalReject: return LC_READ_PAGE_RESULT_NOT_ISSUED;
        case Rx25ResultUr: return LC_READ_PAGE_RESULT_UNSUPPORTED_REQUEST;
        case Rx25ResultCa: return LC_READ_PAGE_RESULT_COMPLETER_ABORT;
        case Rx25ResultNativeTimeout:
        case Rx25ResultFirmwareTimeout: return LC_READ_PAGE_RESULT_NO_COMPLETION;
        case Rx25ResultPartial: return LC_READ_PAGE_RESULT_PARTIAL_COMPLETION;
        case Rx25ResultPoison:
        case Rx25ResultMalformed: return LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
        case Rx25ResultLinkLost:
        case Rx25ResultHostSample:
        case Rx25ResultRemoved: return LC_READ_PAGE_RESULT_TRANSPORT_ERROR;
        case Rx25ResultStopped: return LC_READ_PAGE_RESULT_NOT_ISSUED;
        default: return LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
    }
}

static VOID Rx25RecordError(RX25_RESULT_READER *r, const RX25_RESULT_COMPLETION *c, LC_READ_PAGE_RESULT result)
{
    if(r->ErrorCount != 0xffffffffu) r->ErrorCount++;
    if(!r->HasFirstError) {
        r->HasFirstError=TRUE;
        r->FirstError=*c;
        r->FirstResult=result;
    }
}

BOOL Rx25ResultInit(RX25_RESULT_READER *r, QWORD epoch, QWORD start, QWORD bytes, DWORD deadline)
{
    if(!r) return FALSE;
    memset(r,0,sizeof(*r));
    // Initializing this offline model is not permission to reset a live session.
    if(!epoch || !bytes || start>((QWORD)-1)-bytes || !deadline) {
        r->Fault=TRUE;
        return FALSE;
    }
    r->Epoch=epoch;r->NextTask=1;r->RangeStart=start;r->RangeBytes=bytes;r->DeadlineTicks=deadline;
    return TRUE;
}

LC_READ_PAGE_RESULT Rx25ResultBegin(RX25_RESULT_READER *r, PMEM_SCATTER p, RX25_RESULT_EXPECTATION *expected)
{
    if(p) p->f=FALSE;
    if(!r || !p || !expected || r->Owned || r->Fault || r->Stopped || !r->Epoch ||
       !r->NextTask || p->version!=MEM_SCATTER_VERSION || !p->pb || p->cb<8 ||
       p->cb>RX25_RESULT_UNIT_MAX || (p->qwA&3) || (p->cb&3) ||
       p->qwA<r->RangeStart || p->qwA-r->RangeStart>r->RangeBytes ||
       p->cb>r->RangeBytes-(p->qwA-r->RangeStart) || p->cb>0x1000u-(DWORD)(p->qwA&0xfff))
        return LC_READ_PAGE_RESULT_NOT_ISSUED;
    r->Expected.Version=RX25_RESULT_MODEL_VERSION;
    r->Expected.Epoch=r->Epoch;r->Expected.Task=r->NextTask++;
    r->Expected.Address=p->qwA;r->Expected.Requested=p->cb;
    r->Page=p;r->Destination=p->pb;r->Owned=TRUE;r->ElapsedTicks=0;
    if(r->Submitted!=0xffffffffu) r->Submitted++;
    *expected=r->Expected;
    return LC_READ_PAGE_RESULT_NONE;
}

LC_READ_PAGE_RESULT Rx25ResultApply(RX25_RESULT_READER *r, const RX25_RESULT_COMPLETION *c, const BYTE *payload, DWORD payloadBytes)
{
    LC_READ_PAGE_RESULT result;
    RX25_RESULT_COMPLETION missing;
    if(!r) return LC_READ_PAGE_RESULT_NOT_ISSUED;
    if(!c) { memset(&missing,0,sizeof(missing));missing.Reason=Rx25ResultMalformed;c=&missing; }
    if(r->Fault || r->Stopped || !r->Owned) {
        Rx25RecordError(r,c,LC_READ_PAGE_RESULT_PROTOCOL_ERROR);r->Fault=TRUE;
        return LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
    }
    result=Rx25ReasonMap(c->Reason);
    if(c->Version!=RX25_RESULT_MODEL_VERSION || c->Epoch!=r->Expected.Epoch ||
       c->Task!=r->Expected.Task || c->Address!=r->Expected.Address ||
       c->Requested!=r->Expected.Requested || c->ValidBytes>c->Requested || c->Issued>1 ||
       c->PcieStatus>7 || !r->Page || !r->Page->pb || r->Page->version!=MEM_SCATTER_VERSION ||
       r->Page->qwA!=r->Expected.Address || r->Page->cb!=r->Expected.Requested ||
       r->Page->pb!=r->Destination) {
        result=LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
    } else if(c->Reason==Rx25ResultLocalReject || c->Reason==Rx25ResultStopped) {
        if(c->Issued || c->ValidBytes || payloadBytes || c->PcieStatus || c->NativeRcError)
            result=LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
    } else if(!c->Issued) {
        result=LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
    } else if(c->Reason==Rx25ResultOk) {
        if(c->PcieStatus || c->NativeRcError) result=LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
        else if(c->ValidBytes!=c->Requested) result=LC_READ_PAGE_RESULT_PARTIAL_COMPLETION;
        else if(!payload || payloadBytes!=c->Requested) result=LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
    } else if((c->Reason==Rx25ResultUr && c->PcieStatus!=1) ||
              (c->Reason==Rx25ResultCa && c->PcieStatus!=4) ||
              (c->Reason==Rx25ResultPartial && (!c->ValidBytes || c->ValidBytes>=c->Requested))) {
        result=LC_READ_PAGE_RESULT_PROTOCOL_ERROR;
    }
    if(result==LC_READ_PAGE_RESULT_SUCCESS) {
        memcpy(r->Page->pb,payload,c->Requested);
        r->Page->f=TRUE;r->Owned=FALSE;r->Page=NULL;r->Destination=NULL;
    } else {
        Rx25RecordError(r,c,result);
        if(result==LC_READ_PAGE_RESULT_NOT_ISSUED) { r->Owned=FALSE;r->Page=NULL;r->Destination=NULL; }
        else r->Fault=TRUE; // keep ownership quarantined; no cancel/tag reuse claim
    }
    return result;
}

LC_READ_PAGE_RESULT Rx25ResultTick(RX25_RESULT_READER *r, DWORD elapsed)
{
    RX25_RESULT_COMPLETION c;
    if(!r || !r->Owned || r->Fault || r->Stopped) return LC_READ_PAGE_RESULT_NOT_ISSUED;
    if(elapsed<r->DeadlineTicks-r->ElapsedTicks) {
        r->ElapsedTicks+=elapsed;
        return LC_READ_PAGE_RESULT_NONE;
    }
    memset(&c,0,sizeof(c));
    c.Version=r->Expected.Version;c.Epoch=r->Expected.Epoch;c.Task=r->Expected.Task;
    c.Address=r->Expected.Address;c.Requested=r->Expected.Requested;
    c.Reason=Rx25ResultFirmwareTimeout;c.Issued=1;
    r->ElapsedTicks=r->DeadlineTicks;
    return Rx25ResultApply(r,&c,NULL,0);
}

VOID Rx25ResultStop(RX25_RESULT_READER *r)
{
    if(r) r->Stopped=TRUE; // stopping does not clear ownership or certify a drain
}
