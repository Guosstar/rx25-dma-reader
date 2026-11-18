// RX25 built-in device boundary.
//
// Two personalities live here:
//   * production  - talks to the RX25 driver over its documented IOCTL ABI and
//                   performs a real remote read: SUBMIT one descriptor, wait
//                   for the completion queue to advance, copy the payload out.
//   * test mock   - only in an RX25_ENABLE_TEST_MOCK build, synthesises content
//                   so the result/ownership model can be exercised offline.
//
// The production path never invents data.  If the driver rejects a request, or
// the peer never completes it, the page comes back with a typed failure and the
// reader quarantines itself (Rx25ResultApply sets Fault), which is what stops a
// tag or buffer from being reused without a drain proof.
//
// Chunking: the firmware accepts at most 256 B per descriptor
// (C_MAX_REQUEST_BYTES), while a LeechCore page is normally 4 KiB.  Each page
// is split into aligned chunks and every chunk runs the full
// begin/submit/complete/apply cycle.  A descriptor never straddles a 4 KiB
// boundary; the result model enforces that independently.

#include "leechcore_device.h"
#include "leechcore_internal.h"
#include "oscompatibility.h"
#include "device_rx25_result.h"
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <winioctl.h>
#include <setupapi.h>
#include <mmsystem.h>
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "winmm.lib")
// Shared with the driver; the ABI must not be duplicated by hand.
#include "../../../drivers/rx25dma/rx25dma_public.h"

// {70CF91AE-6425-4EBD-A161-BE86A29D1153}
static const GUID GUID_DEVINTERFACE_RX25_LOCAL =
    {0x70cf91ae,0x6425,0x4ebd,{0xa1,0x61,0xbe,0x86,0xa2,0x9d,0x11,0x53}};

#define RX25_CQ_OFFSET      0x1000u
#define RX25_DATA_OFFSET    0x0000u
#define RX25_POISON         0xCCu
#define RX25_REQ_ID         0x5041u       /* low half of the descriptor RequestId */
#define RX25_CHUNK_MAX      256u          /* C_MAX_REQUEST_BYTES in the firmware */
#define RX25_CQ_POLL_MS     4000u
// Completions normally land in well under a millisecond, but the default
// Windows timer granularity turns Sleep(1) into a 15.6 ms wait.  The poll loop
// therefore spins briefly first and only then falls back to a (raised
// resolution) sleep.
#define RX25_SPIN_ITERS     200u
#define RX25_DEADLINE_MS    5000u
#define RX25_ADDRESS_LIMIT  0x10000000000ull   /* 1 TiB: covers x86-64 PA space */
#endif /* _WIN32 */

static BOOL Rx25OpenError(PPLC_CONFIG_ERRORINFO ppError, const char *text)
{
    SIZE_T i,n=strlen(text);
    PLC_CONFIG_ERRORINFO error;
    if(ppError) {
        *ppError=NULL;
        error=LocalAlloc(LMEM_ZEROINIT,sizeof(*error)+(n+1)*sizeof(WCHAR));
        if(error) {
            error->dwVersion=LC_CONFIG_ERRORINFO_VERSION;
            error->cbStruct=(DWORD)(sizeof(*error)+(n+1)*sizeof(WCHAR));
            error->cwszUserText=(DWORD)n;
            for(i=0;i<n;i++) error->wszUserText[i]=(WCHAR)(BYTE)text[i];
            *ppError=error;
        }
    }
#ifdef _WIN32
    SetLastError(ERROR_NOT_READY);
#endif
    return FALSE;
}

//-----------------------------------------------------------------------------
// TEST MOCK (unchanged behaviour, still gated behind the explicit build flag)
//-----------------------------------------------------------------------------
#ifdef RX25_ENABLE_TEST_MOCK
typedef struct RX25_MOCK_CONTEXT {
    RX25_RESULT_READER Reader;
    DWORD Mode;
} RX25_MOCK_CONTEXT;

static BOOL Rx25MockReadEx(PLC_CONTEXT ctx, DWORD count, PPMEM_SCATTER pages, PLC_READ_PAGE_RESULT results)
{
    RX25_MOCK_CONTEXT *mock=ctx->hDevice;
    DWORD i,j;
    BYTE payload[RX25_RESULT_UNIT_MAX];
    RX25_RESULT_EXPECTATION request;
    RX25_RESULT_COMPLETION c;
    if(!mock || !pages || !results || !count || count>64) return FALSE;
    for(i=0;i<count;i++) {
        results[i]=Rx25ResultBegin(&mock->Reader,pages[i],&request);
        if(results[i]!=LC_READ_PAGE_RESULT_NONE) continue;
        memset(&c,0,sizeof(c));
        c.Version=request.Version;c.Epoch=request.Epoch;c.Task=request.Task;
        c.Address=request.Address;c.Requested=request.Requested;c.ValidBytes=request.Requested;c.Issued=1;
        for(j=0;j<request.Requested;j++) payload[j]=(BYTE)((request.Address+j)^0x5a);
        switch(mock->Mode) {
            case 1:c.Reason=Rx25ResultUr;c.PcieStatus=1;c.ValidBytes=0;break;
            case 2:c.Reason=Rx25ResultCa;c.PcieStatus=4;c.ValidBytes=0;break;
            case 3:c.Reason=Rx25ResultFirmwareTimeout;c.ValidBytes=0;break;
            case 4:c.Reason=Rx25ResultPartial;c.ValidBytes=request.Requested/2;break;
            case 5:c.Reason=Rx25ResultPoison;c.ValidBytes=0;break;
            case 6:c.Task++;break;
            case 7:c.Reason=Rx25ResultLocalReject;c.Issued=0;c.ValidBytes=0;break;
            default:break;
        }
        results[i]=Rx25ResultApply(&mock->Reader,&c,c.ValidBytes?payload:NULL,c.ValidBytes);
    }
    return TRUE;
}
static VOID Rx25MockRead(PLC_CONTEXT ctx, DWORD count, PPMEM_SCATTER pages)
{
    DWORD i;
    LC_READ_PAGE_RESULT results[64];
    if(!Rx25MockReadEx(ctx,count,pages,results) && pages)
        for(i=0;i<count;i++) if(pages[i]) pages[i]->f=FALSE;
}
static VOID Rx25MockClose(PLC_CONTEXT ctx)
{
    RX25_MOCK_CONTEXT *mock=ctx->hDevice;
    if(mock) { Rx25ResultStop(&mock->Reader);LocalFree(mock); }
    ctx->hDevice=NULL;
}
static BOOL Rx25MockOpen(PLC_CONTEXT ctx)
{
    DWORD i;
    const char *suffix=ctx->Config.szDevice+strlen("rx25mock://test");
    const char *options[]={"",",case=ur",",case=ca",",case=timeout",",case=partial",",case=poison",",case=wrongid",",case=notissued"};
    RX25_MOCK_CONTEXT *mock;
    if(_strnicmp(ctx->Config.szDevice,"rx25mock://test",strlen("rx25mock://test"))) return FALSE;
    for(i=0;i<sizeof(options)/sizeof(options[0]);i++) if(!_stricmp(suffix,options[i])) break;
    if(i==sizeof(options)/sizeof(options[0])) return FALSE;
    mock=LocalAlloc(LMEM_ZEROINIT,sizeof(*mock));
    if(!mock) return FALSE;
    if(!Rx25ResultInit(&mock->Reader,0x52583235,0,0x2000,64)) { LocalFree(mock);return FALSE; }
    mock->Mode=i;
    if(!LcMemMap_AddRange(ctx,0,0x2000,0)) { LocalFree(mock);return FALSE; }
    ctx->hDevice=mock;ctx->pfnReadScatter=Rx25MockRead;ctx->pfnReadScatterEx=Rx25MockReadEx;
    ctx->pfnClose=Rx25MockClose;ctx->fMultiThread=FALSE;ctx->Config.fVolatile=TRUE;
    ctx->Config.fWritable=FALSE;ctx->Config.paMax=0x2000;
    strncpy_s(ctx->Config.szDeviceName,sizeof(ctx->Config.szDeviceName),"rx25mock",_TRUNCATE);
    return TRUE;
}
#endif /* RX25_ENABLE_TEST_MOCK */

//-----------------------------------------------------------------------------
// PRODUCTION: driver-backed remote read
//-----------------------------------------------------------------------------
#ifdef _WIN32

typedef struct RX25_DEV_CONTEXT {
    HANDLE hDev;
    QWORD  BufferId;
    QWORD  DmaAddress;
    ULONG  CqOffset;
    ULONG  Caps;
    ULONG  Role;
    WORD   Generation;
    BOOL   TimerRaised;      // timeBeginPeriod(1) succeeded, must be undone
    RX25_RESULT_READER Reader;
} RX25_DEV_CONTEXT;

static ULONGLONG Rx25NowMs(VOID)
{
    LARGE_INTEGER f,c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (ULONGLONG)((c.QuadPart*1000ull)/f.QuadPart);
}

// Locate the control device object published by the RX25 driver.  The interface
// GUID, not the instance path, is the stable handle: the PCI bus number changes
// between boots and between machines.
static BOOL Rx25FindDevice(char *path, size_t cch)
{
    HDEVINFO set;
    SP_DEVICE_INTERFACE_DATA ifc;
    PSP_DEVICE_INTERFACE_DETAIL_DATA_A det;
    DWORD i,need;
    BOOL found=FALSE;
    if(!path || cch<8) return FALSE;
    set=SetupDiGetClassDevsA(&GUID_DEVINTERFACE_RX25_LOCAL,NULL,NULL,
                             DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);
    if(set==INVALID_HANDLE_VALUE) return FALSE;
    for(i=0;i<256 && !found;i++) {
        memset(&ifc,0,sizeof(ifc));
        ifc.cbSize=sizeof(ifc);
        if(!SetupDiEnumDeviceInterfaces(set,NULL,&GUID_DEVINTERFACE_RX25_LOCAL,i,&ifc)) break;
        need=0;
        SetupDiGetDeviceInterfaceDetailA(set,&ifc,NULL,0,&need,NULL);
        if(!need) continue;
        det=(PSP_DEVICE_INTERFACE_DETAIL_DATA_A)LocalAlloc(LMEM_ZEROINIT,need);
        if(!det) break;
        det->cbSize=sizeof(*det);
        if(SetupDiGetDeviceInterfaceDetailA(set,&ifc,det,need,NULL,NULL)) {
            strncpy_s(path,cch,det->DevicePath,_TRUNCATE);
            found=TRUE;
        }
        LocalFree(det);
    }
    SetupDiDestroyDeviceInfoList(set);
    return found;
}

static BOOL Rx25IoctlRead(RX25_DEV_CONTEXT *dev, ULONG offset, PVOID dst, DWORD cb)
{
    RX25_DMA_TRANSFER t;
    DWORD bytes=0;
    BOOL ok;
    if(!dev || !dev->hDev || !dst || !cb) return FALSE;
    ZeroMemory(&t,sizeof(t));
    t.Size=sizeof(t);
    t.Version=RX25_DMA_ABI_VERSION;
    t.BufferId=dev->BufferId;
    t.Offset=offset;
    t.Length=cb;
    // The driver copies the common buffer into WdfRequestRetrieveOutputBuffer
    // with transfer.Length bytes; a NULL output buffer makes it fail, which is
    // how the first version of this function silently read nothing at all.
    ok=DeviceIoControl(dev->hDev,IOCTL_RX25_DMA_READ,&t,sizeof(t),dst,cb,&bytes,NULL)!=0;
    return ok && bytes==cb;
}

static BOOL Rx25IoctlWrite(RX25_DEV_CONTEXT *dev, ULONG offset, const void *src, DWORD cb)
{
    RX25_DMA_TRANSFER t;
    BYTE *in;
    DWORD bytes=0;
    BOOL ok;
    if(!dev || !dev->hDev || !src || !cb || cb>RX25_DMA_BYTES) return FALSE;
    in=(BYTE*)LocalAlloc(LMEM_ZEROINIT,sizeof(t)+cb);
    if(!in) return FALSE;
    ZeroMemory(&t,sizeof(t));
    t.Size=sizeof(t);
    t.Version=RX25_DMA_ABI_VERSION;
    t.BufferId=dev->BufferId;
    t.Offset=offset;
    t.Length=cb;
    memcpy(in,&t,sizeof(t));
    memcpy(in+sizeof(t),src,cb);
    ok=DeviceIoControl(dev->hDev,IOCTL_RX25_DMA_WRITE,in,(DWORD)(sizeof(t)+cb),NULL,0,&bytes,NULL)!=0;
    LocalFree(in);
    return ok;
}

// CONTROL (BAR0+0x0C bit0) is deliberately never written here.  The validated
// D1 path issues reads with CONTROL left at 0 because this initiator profile
// ties arm to C_ARM_ALWAYS; writing it would be an untested change to the only
// configuration that is known to work on hardware.

static BOOL Rx25Submit(RX25_DEV_CONTEXT *dev, ULONGLONG remotePa, ULONG length,
                       ULONG requestId, WORD generation)
{
    RX25_DMA_SUBMIT s;
    DWORD bytes=0;
    if(!dev || !dev->hDev) return FALSE;
    ZeroMemory(&s,sizeof(s));
    s.Size=sizeof(s);
    s.Version=RX25_DMA_ABI_VERSION;
    s.BufferId=dev->BufferId;
    s.Slot=0;
    s.Length=length;
    s.RemotePa=remotePa;
    s.HostIova=dev->DmaAddress;
    s.RequestId=requestId;
    s.Generation=generation;
    return DeviceIoControl(dev->hDev,IOCTL_RX25_DMA_SUBMIT,&s,sizeof(s),NULL,0,&bytes,NULL)!=0;
}

// Completion queue entry layout (asmcehnk_rx25_bar.sv, cqw_index 0..4):
//   dword0 request_id          <- the RequestId this host submitted
//   dword1 {status, generation} <- written LAST, so it is the publication marker
//   dword2 payload bytes
//   dword3 sequence
//   dword4 detail              <- cq_detail is hardwired to 0 in this firmware
// The write order is 0,2,3,4,...,1.  That ordering is what makes a single read
// a stable snapshot: once generation has advanced, every other dword of the
// same entry was already written.  A first version of this backend read dword0
// as "sequence" and matched on generation alone, which could not tell this
// request's completion from another one with a colliding 16-bit generation.
static BOOL Rx25ReadCq(RX25_DEV_CONTEXT *dev, ULONG *rid, WORD *gen, WORD *status, ULONG *bytesOut)
{
    BYTE cq[32];
    if(!Rx25IoctlRead(dev,dev->CqOffset,cq,sizeof(cq))) return FALSE;
    memcpy(rid,cq+0,4);
    memcpy(gen,cq+4,2);
    memcpy(status,cq+6,2);
    memcpy(bytesOut,cq+8,4);
    return TRUE;
}

// Run one descriptor to completion and translate the outcome into the shared
// result model.  A quarantine set by a failed chunk makes every later chunk
// NOT_ISSUED by itself, so no tag is reused after an unproven drain.
static LC_READ_PAGE_RESULT Rx25RunChunk(RX25_DEV_CONTEXT *dev, PMEM_SCATTER page,
                                        DWORD offsetInPage, DWORD length,
                                        RX25_RESULT_EXPECTATION *expected)
{
    MEM_SCATTER chunk;
    RX25_RESULT_COMPLETION c;
    LC_READ_PAGE_RESULT r;
    ULONG rid=0,cqBytes=0;
    WORD gen=0,status=0,target=0;
    ULONG expectedRid=0;
    ULONGLONG start;
    BOOL matched=FALSE;
    BYTE poison[RX25_CHUNK_MAX];

    memset(&chunk,0,sizeof(chunk));
    chunk.version=MEM_SCATTER_VERSION;
    chunk.qwA=page->qwA+offsetInPage;
    chunk.pb=page->pb+offsetInPage;
    chunk.cb=length;

    r=Rx25ResultBegin(&dev->Reader,&chunk,expected);
    if(r!=LC_READ_PAGE_RESULT_NONE) return r;

    // Poison first: a completion that returns bytes while leaving the pattern
    // untouched is a bookkeeping bug, not a successful read.
    memset(poison,RX25_POISON,length);
    if(!Rx25IoctlWrite(dev,RX25_DATA_OFFSET,poison,length)) {
        memset(&c,0,sizeof(c));
        c.Version=RX25_RESULT_MODEL_VERSION;c.Epoch=expected->Epoch;c.Task=expected->Task;
        c.Address=expected->Address;c.Requested=expected->Requested;
        c.Reason=Rx25ResultLinkLost;c.Issued=0;
        return Rx25ResultApply(&dev->Reader,&c,NULL,0);
    }

    // The completion tag is not ours to invent: the peer publishes the last
    // generation it completed, and the next one is baseline+1.  Deriving it
    // from a local counter desynchronises after any timeout or foreign reader
    // (that is exactly how the direct tool does it, and how the D1 run passed).
    if(!Rx25ReadCq(dev,&rid,&gen,&status,&cqBytes)) {
        memset(&c,0,sizeof(c));
        c.Version=RX25_RESULT_MODEL_VERSION;c.Epoch=expected->Epoch;c.Task=expected->Task;
        c.Address=expected->Address;c.Requested=expected->Requested;
        c.Reason=Rx25ResultLinkLost;c.Issued=0;
        return Rx25ResultApply(&dev->Reader,&c,NULL,0);
    }
    target=(WORD)(gen+1u);
    // The 16-bit generation travels inside the RequestId, so matching on both
    // the echoed RequestId and the generation is what ties a completion to the
    // request this host actually issued.  Anything else (a late reply, a stale
    // entry left from a previous session, a collision after 16-bit wrap) fails
    // the identity check and stays unmatched.
    expectedRid=RX25_REQ_ID|((ULONG)target<<16);

    if(!Rx25Submit(dev,chunk.qwA,length,expectedRid,target)) {
        memset(&c,0,sizeof(c));
        c.Version=RX25_RESULT_MODEL_VERSION;c.Epoch=expected->Epoch;c.Task=expected->Task;
        c.Address=expected->Address;c.Requested=expected->Requested;
        c.Reason=Rx25ResultLocalReject;c.Issued=0;
        return Rx25ResultApply(&dev->Reader,&c,NULL,0);
    }

    start=Rx25NowMs();
    // Spin first: a completion that arrives before the first CQ read is picked
    // up without any scheduler round trip.  Only after RX25_SPIN_ITERS empty
    // polls do we sleep, and the timer resolution is raised at open so that
    // sleep costs ~1 ms instead of the default 15.6 ms.
    {
        DWORD spin;
        for(spin=0;spin<RX25_SPIN_ITERS && !matched;spin++) {
            if(!Rx25ReadCq(dev,&rid,&gen,&status,&cqBytes)) break;
            if(gen==target && rid==expectedRid) matched=TRUE;
            else YieldProcessor();
        }
    }
    while(!matched && Rx25NowMs()-start<RX25_CQ_POLL_MS) {
        if(!Rx25ReadCq(dev,&rid,&gen,&status,&cqBytes)) break;
        if(gen==target && rid==expectedRid) { matched=TRUE; break; }
        Sleep(1);
    }

    memset(&c,0,sizeof(c));
    c.Version=RX25_RESULT_MODEL_VERSION;
    c.Epoch=expected->Epoch;c.Task=expected->Task;
    c.Address=expected->Address;c.Requested=expected->Requested;
    c.Issued=1;

    if(!matched) {
        c.Reason=Rx25ResultFirmwareTimeout;
        return Rx25ResultApply(&dev->Reader,&c,NULL,0);
    }

    // Firmware status codes (asmcehnk_rx25_req_engine.sv):
    //   1 = record committed, payload valid
    //   4 = no completion within C_TIMEOUT_CYCLES; engine returns to IDLE
    //   5 = short record or local MWr error; engine returns to IDLE
    //   6 = protocol error; engine latches S_FAULT and needs a reset
    // 5 and 6 are delivery faults, not PCIe completion statuses, so they must
    // never be reported as CA/Poison.
    switch(status) {
        case 1: c.Reason=Rx25ResultOk;c.ValidBytes=cqBytes;break;
        case 4: c.Reason=Rx25ResultFirmwareTimeout;c.ValidBytes=0;break;
        case 5: c.Reason=Rx25ResultMalformed;c.ValidBytes=0;break;
        case 6: c.Reason=Rx25ResultMalformed;c.ValidBytes=0;break;
        default:c.Reason=Rx25ResultMalformed;c.ValidBytes=0;break;
    }

    if(c.Reason==Rx25ResultOk) {
        if(cqBytes!=length) {
            c.Reason=(cqBytes&&cqBytes<length)?Rx25ResultPartial:Rx25ResultMalformed;
            c.ValidBytes=(cqBytes<length)?cqBytes:0;
        } else if(!Rx25IoctlRead(dev,RX25_DATA_OFFSET,chunk.pb,length)) {
            c.Reason=Rx25ResultLinkLost;c.ValidBytes=0;
        }
    }
    {
        LC_READ_PAGE_RESULT out=Rx25ResultApply(&dev->Reader,&c,
            (c.Reason==Rx25ResultOk)?chunk.pb:NULL,(c.Reason==Rx25ResultOk)?c.ValidBytes:0);
        // Resume policy -- deliberately narrow.  Clearing the quarantine is
        // allowed only when this request's own completion was observed
        // (identity matched: RequestId AND generation) AND the request engine
        // provably returned to IDLE after publishing it:
        //   4 = waited for a completion until the firmware timeout, then S_CQ
        //   5 = short record or local MWr error, then S_CQ
        // Everything else keeps the quarantine and its first-error record:
        // unknown status, status 1 with a length mismatch, status 1 whose
        // payload read failed (local I/O, buffer state unknown), status 6
        // (engine in S_FAULT, needs a reset), and no completion at all.
        //
        // Residual risk, stated on purpose: status 5 covers BOTH "peer replied
        // SHORT" and "local MWr failed", and this firmware publishes no detail
        // (cq_detail is hardwired to 0), so the two cannot be separated here.
        // Identity matching is the strongest evidence available today; a
        // firmware detail field is the prerequisite for widening this further.
        if(matched && (status==4||status==5) && out!=LC_READ_PAGE_RESULT_SUCCESS) {
            // Keep the first-error record across the reset: the reader is the
            // only place that evidence lives, and a silent re-init would erase
            // the reason the session was ever disturbed.
            DWORD errs=dev->Reader.ErrorCount;
            BOOL hasErr=dev->Reader.HasFirstError;
            RX25_RESULT_COMPLETION firstErr=dev->Reader.FirstError;
            LC_READ_PAGE_RESULT firstRes=dev->Reader.FirstResult;
            Rx25ResultInit(&dev->Reader,dev->Reader.Epoch+1,0,RX25_ADDRESS_LIMIT,RX25_DEADLINE_MS);
            dev->Reader.ErrorCount=errs;
            dev->Reader.HasFirstError=hasErr;
            dev->Reader.FirstError=firstErr;
            dev->Reader.FirstResult=firstRes;
        }
        return out;
    }
}

static BOOL Rx25ReadEx(PLC_CONTEXT ctx, DWORD count, PPMEM_SCATTER pages, PLC_READ_PAGE_RESULT results)
{
    RX25_DEV_CONTEXT *dev=(RX25_DEV_CONTEXT*)ctx->hDevice;
    DWORD i;
    if(!dev || !pages || !results || !count) return FALSE;
    for(i=0;i<count;i++) {
        PMEM_SCATTER p=pages[i];
        DWORD done=0;
        RX25_RESULT_EXPECTATION expected;
        LC_READ_PAGE_RESULT r;
        if(!p) { results[i]=LC_READ_PAGE_RESULT_UNSPECIFIED_ERROR;continue; }
        p->f=FALSE;
        if(!p->pb || !p->cb) { results[i]=LC_READ_PAGE_RESULT_UNSPECIFIED_ERROR;continue; }
        // SUBMIT rejects a RemotePa that is not 16 B aligned, so say so up
        // front instead of turning it into an unexplained local reject.
        if((p->qwA&15)||(p->cb&3)) { results[i]=LC_READ_PAGE_RESULT_NOT_ISSUED;continue; }
        r=LC_READ_PAGE_RESULT_SUCCESS;
        while(done<p->cb) {
            DWORD room=0x1000u-(DWORD)((p->qwA+done)&0xfffu);
            DWORD len=p->cb-done;
            if(len>RX25_CHUNK_MAX) len=RX25_CHUNK_MAX;
            if(len>room) len=room;
            len&=~(DWORD)15;              // SUBMIT only accepts 16 B multiples
            if(len<16) {                  // sub-16 B tail cannot be described at all
                r=done?LC_READ_PAGE_RESULT_PARTIAL_COMPLETION:LC_READ_PAGE_RESULT_NOT_ISSUED;
                break;
            }
            r=Rx25RunChunk(dev,p,done,len,&expected);
            if(r!=LC_READ_PAGE_RESULT_SUCCESS) break;
            done+=len;
        }
        results[i]=r;
        p->f=(r==LC_READ_PAGE_RESULT_SUCCESS);
    }
    return TRUE;
}

static VOID Rx25Read(PLC_CONTEXT ctx, DWORD count, PPMEM_SCATTER pages)
{
    DWORD i,k;
    LC_READ_PAGE_RESULT results[64];
    if(!pages) return;
    // LcRead can hand us an arbitrarily long scatter; walk it in batches
    // instead of refusing anything larger than 64 pages.
    for(i=0;i<count;i+=64) {
        DWORD n=(count-i>64)?64u:(count-i);
        if(!Rx25ReadEx(ctx,n,pages+i,results))
            for(k=0;k<n;k++) if(pages[i+k]) pages[i+k]->f=FALSE;
    }
}

static VOID Rx25Close(PLC_CONTEXT ctx)
{
    RX25_DEV_CONTEXT *dev=(RX25_DEV_CONTEXT*)ctx->hDevice;
    if(dev) {
        // Stopping refuses new work; it does not certify a drain.
        Rx25ResultStop(&dev->Reader);
        if(dev->TimerRaised) timeEndPeriod(1);
        if(dev->hDev && dev->hDev!=INVALID_HANDLE_VALUE) CloseHandle(dev->hDev);
        LocalFree(dev);
    }
    ctx->hDevice=NULL;
}

static BOOL Rx25ProductionOpen(PLC_CONTEXT ctx, PPLC_CONFIG_ERRORINFO ppError, const char *explicitPath)
{
    char path[512];
    RX25_DMA_INFO info;
    RX25_DEV_CONTEXT *dev;
    DWORD bytes=0;

    if(explicitPath && explicitPath[0]) {
        strncpy_s(path,sizeof(path),explicitPath,_TRUNCATE);
    } else if(!Rx25FindDevice(path,sizeof(path))) {
        return Rx25OpenError(ppError,
            "RX25_NOT_READY: no RX25 device interface found. Card present and driver loaded?");
    }

    dev=(RX25_DEV_CONTEXT*)LocalAlloc(LMEM_ZEROINIT,sizeof(*dev));
    if(!dev) return Rx25OpenError(ppError,"RX25_NOT_READY: out of memory.");
    dev->hDev=CreateFileA(path,GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL,NULL);
    if(dev->hDev==INVALID_HANDLE_VALUE) {
        DWORD err=GetLastError();
        LocalFree(dev);
        if(err==ERROR_ACCESS_DENIED)
            return Rx25OpenError(ppError,
                "RX25_NOT_READY: access denied opening the RX25 control device; run elevated.");
        if(err==ERROR_NOT_READY)
            return Rx25OpenError(ppError,
                "RX25_NOT_READY: device gate closed (BAR magic or status bit8). Re-enumerate the card.");
        return Rx25OpenError(ppError,"RX25_NOT_READY: cannot open the RX25 control device.");
    }

    memset(&info,0,sizeof(info));
    if(!DeviceIoControl(dev->hDev,IOCTL_RX25_DMA_QUERY,NULL,0,&info,sizeof(info),&bytes,NULL) ||
       bytes!=sizeof(info) || info.Size!=sizeof(info) || info.Version!=RX25_DMA_ABI_VERSION) {
        CloseHandle(dev->hDev);LocalFree(dev);
        return Rx25OpenError(ppError,"RX25_NOT_READY: QUERY rejected or ABI mismatch.");
    }
    if(info.Role!=RX25_DMA_ROLE_A) {
        CloseHandle(dev->hDev);LocalFree(dev);
        return Rx25OpenError(ppError,
            "RX25_NOT_READY: card reports the far (B) role; the local tool needs initiator.");
    }
    if(!info.BufferId || info.BufferBytes!=RX25_DMA_BYTES ||
       info.CqOffset==RX25_DMA_NO_CQ || info.CqOffset>=RX25_DMA_BYTES) {
        CloseHandle(dev->hDev);LocalFree(dev);
        return Rx25OpenError(ppError,"RX25_NOT_READY: QUERY returned an unusable buffer layout.");
    }

    dev->BufferId=info.BufferId;
    dev->DmaAddress=info.DmaAddress;
    dev->CqOffset=info.CqOffset;
    dev->Caps=info.Caps;
    dev->Role=info.Role;
    dev->Generation=1;

    if(!Rx25ResultInit(&dev->Reader,0x52583235u,0,RX25_ADDRESS_LIMIT,RX25_DEADLINE_MS)) {
        CloseHandle(dev->hDev);LocalFree(dev);
        return Rx25OpenError(ppError,"RX25_NOT_READY: result reader initialisation failed.");
    }
    if(!LcMemMap_AddRange(ctx,0,RX25_ADDRESS_LIMIT,0)) {
        CloseHandle(dev->hDev);LocalFree(dev);
        return Rx25OpenError(ppError,"RX25_NOT_READY: cannot publish the physical address range.");
    }

    dev->TimerRaised=(timeBeginPeriod(1)==TIMERR_NOERROR);

    ctx->hDevice=dev;
    ctx->pfnReadScatter=Rx25Read;
    ctx->pfnReadScatterEx=Rx25ReadEx;
    ctx->pfnClose=Rx25Close;
    ctx->fMultiThread=FALSE;
    ctx->Config.fVolatile=TRUE;
    ctx->Config.fWritable=FALSE;
    ctx->Config.paMax=RX25_ADDRESS_LIMIT;
    strncpy_s(ctx->Config.szDeviceName,sizeof(ctx->Config.szDeviceName),"rx25",_TRUNCATE);
    return TRUE;
}

#endif /* _WIN32 */

_Success_(return)
BOOL DeviceRX25_Open(PLC_CONTEXT ctx, PPLC_CONFIG_ERRORINFO ppError)
{
    if(ppError) *ppError=NULL;
    if(!ctx || ctx->version!=LC_CONTEXT_VERSION)
        return Rx25OpenError(ppError,"RX25_NOT_READY: invalid LeechCore device context.");
#ifdef RX25_ENABLE_TEST_MOCK
    if(!ctx->Config.szRemote[0] && Rx25MockOpen(ctx)) return TRUE;
#endif
#ifdef _WIN32
    if(ctx->Config.szRemote[0])
        return Rx25OpenError(ppError,"RX25_NOT_READY: remote (network) mode is not implemented for RX25.");
    {
        const char *name=ctx->Config.szDevice;
        const char *path="";
        if(0==_strnicmp(name,"rx25://",7)) path=name+7;
        else if(0!=_strnicmp(name,"rx25",4))
            return Rx25OpenError(ppError,"RX25_NOT_READY: device string does not name an RX25 endpoint.");
        return Rx25ProductionOpen(ctx,ppError,path);
    }
#else
    return Rx25OpenError(ppError,"RX25_NOT_READY: the RX25 production backend is Windows-only.");
#endif
}
