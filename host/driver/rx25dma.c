/* RX25 buffer-only KMDF driver. Never starts host-memory DMA.
 * FIRST16 and BATCH issue only address-free diagnostics with native RQ disabled.
 * A separate hardware submission/quiescence implementation is required before
 * this interface can be used for transfers. No user BAR or kernel VA mapping.
 */
#pragma warning(push)
#pragma warning(disable:4324) /* KMDF's deliberately aligned request union. */
#include <ntddk.h>
#include <wdf.h>
#pragma warning(pop)
#include <initguid.h>
#include "rx25dma_public.h"
#include "rx25_job.h"

C_ASSERT(sizeof(RX25_DMA_INFO) == 64);
C_ASSERT(sizeof(RX25_DMA_TRANSFER) == 24);
C_ASSERT(sizeof(RX25_JOB_REQUEST) == 64);
C_ASSERT(sizeof(RX25_JOB_PLAN) == 152);
C_ASSERT(sizeof(RX25_DMA_SNAPSHOT_REQUEST) == 24);
C_ASSERT(sizeof(RX25_DMA_SNAPSHOT) == 8240);
C_ASSERT(FIELD_OFFSET(RX25_DMA_SNAPSHOT, Image) == 48);
C_ASSERT(sizeof(RX25_FIRST16_REQUEST) == 24);
C_ASSERT(sizeof(RX25_FIRST16_RESULT) == 96);
C_ASSERT(sizeof(RX25_BATCH_REQUEST) == 24);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_REQUEST, BufferId) == 8);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_REQUEST, Nonce) == 16);
C_ASSERT(sizeof(RX25_BATCH_RESULT) == 816);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Batch) == 16);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, LocalPressure) == 80);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, PeerPressure) == 144);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Owner) == 208);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Payload) == 272);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Observations) == 784);

typedef struct _DEVICE_CONTEXT {
    PUCHAR Bar;
    SIZE_T BarBytes;
    ULONG Caps;
    ULONG Role;
    BOOLEAN Online;
    WDFWAITLOCK Lock;
    WDFDMAENABLER Dma;
    WDFCOMMONBUFFER Buffer;
    PUCHAR Cpu;
    PHYSICAL_ADDRESS Logical;
    LONG64 NextId;
    ULONGLONG Generation;
} DEVICE_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, DeviceContext)

typedef struct _FILE_CONTEXT {
    ULONGLONG BufferId;
    BOOLEAN Closed;
    ULONGLONG Generation;
} FILE_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(FILE_CONTEXT, FileContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD Rx25DeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE Rx25Prepare;
EVT_WDF_DEVICE_RELEASE_HARDWARE Rx25Release;
EVT_WDF_DEVICE_D0_ENTRY Rx25D0Entry;
EVT_WDF_DEVICE_D0_EXIT Rx25D0Exit;
EVT_WDF_DEVICE_FILE_CREATE Rx25FileCreate;
EVT_WDF_FILE_CLEANUP Rx25FileCleanup;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL Rx25Ioctl;

static ULONG Reg(DEVICE_CONTEXT *ctx, ULONG offset)
{
    return READ_REGISTER_ULONG((PULONG)(ctx->Bar + offset));
}

static BOOLEAN Idle(DEVICE_CONTEXT *ctx)
{
    return ctx->Bar && Reg(ctx, 0) == 0x35325852 && Reg(ctx, 4) == 1 &&
           Reg(ctx, 8) == ctx->Caps && Reg(ctx, 12) == 0 &&
           (Reg(ctx, 16) & 0x104) == 0;
}

/* Startup only: identity and no fatal/error bits.  Deliberately does NOT
 * require the control word to be zero -- a bring-up tool that dies between
 * "arm the descriptor engine" and "restore control" must not leave the device
 * unstartable, which is exactly what an Idle() gate here caused once.  The
 * per-command Idle() checks stay as they are. */
static BOOLEAN Healthy(DEVICE_CONTEXT *ctx)
{
    return ctx->Bar && Reg(ctx, 0) == 0x35325852 && Reg(ctx, 4) == 1 &&
           Reg(ctx, 8) == ctx->Caps && (Reg(ctx, 16) & 0x104) == 0;
}

/* Fixed bank reads only. gateOnly avoids 128 payload MMIO reads before START;
 * ARM's real pressure budget must not be spent copying an unused payload. */
static VOID ReadBatch(DEVICE_CONTEXT *ctx, RX25_BATCH_RESULT *result,
                      ULONGLONG bufferId, BOOLEAN gateOnly)
{
    static const ULONG observations[8] = {0x48,0x4c,0x50,0x7c,0x80,0x84,0x88,0x8c};
    ULONG index;
    RtlZeroMemory(result, sizeof(*result));
    result->Size = sizeof(*result); result->Version = RX25_BATCH_ABI_VERSION;
    result->BufferId = bufferId;
    for (index = 0; index < 16; index++) {
        if (!gateOnly || index < 3 || index >= 14) result->Batch[index] = Reg(ctx, RX25_BATCH_BAR_BASE + index*4);
        if (!gateOnly || index < 3) {
            result->LocalPressure[index] = Reg(ctx, RX25_BATCH_LOCAL_PRESSURE + index*4);
            result->PeerPressure[index] = Reg(ctx, RX25_BATCH_PEER_PRESSURE + index*4);
        }
        result->Owner[index] = Reg(ctx, RX25_BATCH_OWNER + index*4);
    }
    if (!gateOnly) {
        for (index = 0; index < 128; index++) result->Payload[index] = Reg(ctx, RX25_BATCH_PAYLOAD + index*4);
        for (index = 0; index < 8; index++) result->Observations[index] = Reg(ctx, observations[index]);
    } else result->Observations[2] = Reg(ctx, 0x50);
    KeMemoryBarrier();
}

static VOID DropResources(DEVICE_CONTEXT *ctx)
{
    /* This version has no path that enables hardware or publishes DMA work. */
    ctx->Online = FALSE;
    ctx->Generation++;
    ctx->Cpu = NULL;
    ctx->Logical.QuadPart = 0;
    if (ctx->Buffer) {
        WdfObjectDelete(ctx->Buffer);
        ctx->Buffer = NULL;
    }
    if (ctx->Dma) {
        WdfObjectDelete(ctx->Dma);
        ctx->Dma = NULL;
    }
    if (ctx->Bar) {
        MmUnmapIoSpace(ctx->Bar, ctx->BarBytes);
        ctx->Bar = NULL;
        ctx->BarBytes = 0;
    }
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING path)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, Rx25DeviceAdd);
    return WdfDriverCreate(driver, path, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
}

NTSTATUS Rx25DeviceAdd(WDFDRIVER driver, PWDFDEVICE_INIT init)
{
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_FILEOBJECT_CONFIG files;
    WDF_IO_QUEUE_CONFIG queue;
    WDFDEVICE device;
    DEVICE_CONTEXT *ctx;
    NTSTATUS status;
    UNREFERENCED_PARAMETER(driver);
    WdfDeviceInitSetDeviceType(init, FILE_DEVICE_UNKNOWN);
    WdfDeviceInitSetExclusive(init, TRUE);
    WdfDeviceInitSetIoType(init, WdfDeviceIoBuffered);
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = Rx25Prepare;
    pnp.EvtDeviceReleaseHardware = Rx25Release;
    pnp.EvtDeviceD0Entry = Rx25D0Entry;
    pnp.EvtDeviceD0Exit = Rx25D0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(init, &pnp);
    WDF_FILEOBJECT_CONFIG_INIT(&files, Rx25FileCreate, NULL, Rx25FileCleanup);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, FILE_CONTEXT);
    WdfDeviceInitSetFileObjectConfig(init, &files, &attributes);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, DEVICE_CONTEXT);
    attributes.ExecutionLevel = WdfExecutionLevelPassive;
    attributes.SynchronizationScope = WdfSynchronizationScopeNone;
    status = WdfDeviceCreate(&init, &attributes, &device);
    if (!NT_SUCCESS(status)) return status;
    ctx = DeviceContext(device);
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = device;
    status = WdfWaitLockCreate(&attributes, &ctx->Lock);
    if (!NT_SUCCESS(status)) return status;
    WdfDeviceSetAlignmentRequirement(device, 15); /* 16-byte alignment mask. */
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queue, WdfIoQueueDispatchSequential);
    queue.EvtIoDeviceControl = Rx25Ioctl;
    status = WdfIoQueueCreate(device, &queue, WDF_NO_OBJECT_ATTRIBUTES, WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) return status;
    return WdfDeviceCreateDeviceInterface(device, &GUID_DEVINTERFACE_RX25_DMA, NULL);
}

NTSTATUS Rx25Prepare(WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated)
{
    DEVICE_CONTEXT *ctx = DeviceContext(device);
    WDF_DMA_ENABLER_CONFIG dma;
    WDF_COMMON_BUFFER_CONFIG common;
    ULONG index;
    NTSTATUS status = STATUS_DEVICE_CONFIGURATION_ERROR;
    UNREFERENCED_PARAMETER(raw);
    WdfWaitLockAcquire(ctx->Lock, NULL);
    for (index = 0; index < WdfCmResourceListGetCount(translated); index++) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR resource = WdfCmResourceListGetDescriptor(translated, index);
        if (resource && resource->Type == CmResourceTypeMemory) {
            /* RX25 BAR0 is the first memory BAR, with the fixed 8KiB ABI. */
            if (resource->u.Memory.Length != RX25_DMA_BYTES) goto done;
            ctx->BarBytes = resource->u.Memory.Length;
            ctx->Bar = MmMapIoSpaceEx(resource->u.Memory.Start, ctx->BarBytes, PAGE_READWRITE | PAGE_NOCACHE);
            break;
        }
    }
    if (!ctx->Bar || Reg(ctx, 0) != 0x35325852 || Reg(ctx, 4) != 1) goto done;
    ctx->Caps = Reg(ctx, 8);
    if (ctx->Caps == 0xF) ctx->Role = RX25_DMA_ROLE_A;
    else if (ctx->Caps == 0x30F) ctx->Role = RX25_DMA_ROLE_B;
    else goto done;
    if (!Healthy(ctx)) { status = STATUS_DEVICE_BUSY; goto done; }
    WDF_DMA_ENABLER_CONFIG_INIT(&dma, WdfDmaProfileScatterGather64Duplex, RX25_DMA_BYTES);
    status = WdfDmaEnablerCreate(device, &dma, WDF_NO_OBJECT_ATTRIBUTES, &ctx->Dma);
    if (!NT_SUCCESS(status)) goto done;
    WDF_COMMON_BUFFER_CONFIG_INIT(&common, PAGE_SIZE - 1);
    status = WdfCommonBufferCreateWithConfig(ctx->Dma, RX25_DMA_BYTES, &common,
                                           WDF_NO_OBJECT_ATTRIBUTES, &ctx->Buffer);
    if (!NT_SUCCESS(status)) goto done;
    ctx->Cpu = WdfCommonBufferGetAlignedVirtualAddress(ctx->Buffer);
    ctx->Logical = WdfCommonBufferGetAlignedLogicalAddress(ctx->Buffer);
    if (!ctx->Cpu || (ctx->Logical.QuadPart & (PAGE_SIZE - 1)) ||
        (ULONGLONG)ctx->Logical.QuadPart > MAXULONGLONG - RX25_DMA_BYTES) {
        status = STATUS_DEVICE_CONFIGURATION_ERROR;
        goto done;
    }
    RtlZeroMemory(ctx->Cpu, RX25_DMA_BYTES);
done:
    if (!NT_SUCCESS(status)) DropResources(ctx);
    WdfWaitLockRelease(ctx->Lock);
    return status;
}

NTSTATUS Rx25Release(WDFDEVICE device, WDFCMRESLIST translated)
{
    DEVICE_CONTEXT *ctx = DeviceContext(device);
    UNREFERENCED_PARAMETER(translated);
    WdfWaitLockAcquire(ctx->Lock, NULL);
    DropResources(ctx);
    WdfWaitLockRelease(ctx->Lock);
    return STATUS_SUCCESS;
}

NTSTATUS Rx25D0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE previous)
{
    DEVICE_CONTEXT *ctx = DeviceContext(device);
    NTSTATUS status;
    UNREFERENCED_PARAMETER(previous);
    WdfWaitLockAcquire(ctx->Lock, NULL);
    ctx->Online = ctx->Buffer && Idle(ctx);
    status = ctx->Online ? STATUS_SUCCESS : STATUS_DEVICE_NOT_READY;
    WdfWaitLockRelease(ctx->Lock);
    return status;
}

NTSTATUS Rx25D0Exit(WDFDEVICE device, WDF_POWER_DEVICE_STATE target)
{
    DEVICE_CONTEXT *ctx = DeviceContext(device);
    UNREFERENCED_PARAMETER(target);
    WdfWaitLockAcquire(ctx->Lock, NULL);
    ctx->Online = FALSE;
    WdfWaitLockRelease(ctx->Lock);
    return STATUS_SUCCESS;
}

VOID Rx25FileCreate(WDFDEVICE device, WDFREQUEST request, WDFFILEOBJECT file)
{
    DEVICE_CONTEXT *ctx = DeviceContext(device);
    FILE_CONTEXT *session = FileContext(file);
    NTSTATUS status = STATUS_DEVICE_NOT_READY;
    WdfWaitLockAcquire(ctx->Lock, NULL);
    /* Healthy, not Idle: a tool that armed the descriptor engine and then died
     * must not lock every future open out of the device.  The per-command Idle
     * checks still refuse to run commands while the engine is armed. */
    if (ctx->Online && Healthy(ctx)) {
        session->BufferId = (ULONGLONG)InterlockedIncrement64(&ctx->NextId);
        session->Generation = ctx->Generation;
        session->Closed = FALSE;
        RtlZeroMemory(ctx->Cpu, RX25_DMA_BYTES);
        status = STATUS_SUCCESS;
    }
    WdfWaitLockRelease(ctx->Lock);
    WdfRequestComplete(request, status);
}

VOID Rx25FileCleanup(WDFFILEOBJECT file)
{
    DEVICE_CONTEXT *ctx = DeviceContext(WdfFileObjectGetDevice(file));
    WdfWaitLockAcquire(ctx->Lock, NULL);
    FileContext(file)->Closed = TRUE;
    /* Retain the common buffer until PnP release, never free in file cleanup. */
    WdfWaitLockRelease(ctx->Lock);
}

VOID Rx25Ioctl(WDFQUEUE queue, WDFREQUEST request, size_t outputBytes,
               size_t inputBytes, ULONG code)
{
    DEVICE_CONTEXT *ctx = DeviceContext(WdfIoQueueGetDevice(queue));
    WDFFILEOBJECT file = WdfRequestGetFileObject(request);
    FILE_CONTEXT *session = file ? FileContext(file) : NULL;
    RX25_DMA_TRANSFER transfer;
    PVOID input, output;
    size_t information = 0;
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    WdfWaitLockAcquire(ctx->Lock, NULL);
    /* Session validity only.  The engine-state check (Idle) used to sit here
     * too, and it made every buffer read fail while a job was in flight: the
     * four BAR reads it performs can come back stale while the card is doing
     * DMA, so a perfectly legal poll of the completion ring was refused with
     * STATUS_DEVICE_NOT_READY.  Commands that actually change engine state
     * keep their own Idle checks. */
    if (!session || session->Closed || !session->BufferId ||
        session->Generation != ctx->Generation || !ctx->Online) {
        status = STATUS_DEVICE_NOT_READY;
        goto done;
    }
    if (code == IOCTL_RX25_DMA_QUERY) {
        RX25_DMA_INFO info;
        if (inputBytes != 0) { status = STATUS_INVALID_PARAMETER; goto done; }
        status = WdfRequestRetrieveOutputBuffer(request, sizeof(info), &output, NULL);
        if (!NT_SUCCESS(status)) goto done;
        RtlZeroMemory(&info, sizeof(info));
        info.Size = sizeof(info);
        info.Version = RX25_DMA_ABI_VERSION;
        info.Flags = RX25_DMA_FLAG_COMMON_BUFFER | RX25_DMA_FLAG_BUFFER_ONLY |
                     RX25_DMA_FLAG_NEVER_ARMED | RX25_DMA_FLAG_PLAN_SUPPORTED;
        if (ctx->Role == RX25_DMA_ROLE_A) info.Flags |= RX25_DMA_FLAG_SNAPSHOT_SUPPORTED;
        info.Role = ctx->Role;
        info.Caps = ctx->Caps;
        info.BufferBytes = RX25_DMA_BYTES;
        info.CqOffset = ctx->Role == RX25_DMA_ROLE_A ? 0x1000 : RX25_DMA_NO_CQ;
        info.BufferId = session->BufferId;
        info.DmaAddress = (ULONGLONG)ctx->Logical.QuadPart;
        info.Control = Reg(ctx, 12);
        info.Status = Reg(ctx, 16);
        info.ObsStatus = Reg(ctx, 0x50);
        RtlCopyMemory(output, &info, sizeof(info));
        information = sizeof(info);
        goto done;
    }
    if (code == IOCTL_RX25_BATCH_READ || Rx25BatchCommandOffset(code)) {
        RX25_BATCH_REQUEST diag;
        RX25_BATCH_RESULT result;
        ULONG commandOffset = Rx25BatchCommandOffset(code);
        ULONG ownerFlags, ownerNonce, ownerRejects, ownerCompleted;
        if (inputBytes != sizeof(diag) || outputBytes != sizeof(result) ||
            ctx->Role != RX25_DMA_ROLE_A) { status = STATUS_INVALID_PARAMETER; goto done; }
        status = WdfRequestRetrieveInputBuffer(request, sizeof(diag), &input, NULL);
        if (!NT_SUCCESS(status)) goto done;
        /* METHOD_BUFFERED aliases the input and output. */
        RtlCopyMemory(&diag, input, sizeof(diag));
        if (!Rx25BatchValidRequest(&diag, session->BufferId, code)) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        status = WdfRequestRetrieveOutputBuffer(request, sizeof(result), &output, NULL);
        if (!NT_SUCCESS(status)) goto done;
        if (commandOffset) {
            ReadBatch(ctx, &result, session->BufferId, TRUE);
            if (!Rx25BatchValidIdentity(&result, ctx->Role)) { status = STATUS_NOT_SUPPORTED; goto done; }
            if (!Rx25BatchValidCommand(&result, ctx->Role, code, diag.Nonce)) {
                status = STATUS_DEVICE_BUSY; goto done;
            }
            /* Only these three literal, aligned single-DWORD command addresses
             * are reachable. No register control, descriptor, address or reset. */
            WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + commandOffset), diag.Nonce);
            KeMemoryBarrier();
        }
        ownerFlags = Reg(ctx, RX25_BATCH_OWNER + 8);
        ownerNonce = Reg(ctx, RX25_BATCH_OWNER + 12);
        ownerRejects = Reg(ctx, RX25_BATCH_OWNER + 16);
        ownerCompleted = Reg(ctx, RX25_BATCH_OWNER + 32);
        ReadBatch(ctx, &result, session->BufferId, FALSE);
        if (result.Owner[2] != ownerFlags || result.Owner[3] != ownerNonce ||
            result.Owner[4] != ownerRejects || result.Owner[8] != ownerCompleted ||
            result.Owner[2] != Reg(ctx, RX25_BATCH_OWNER + 8) ||
            result.Owner[3] != Reg(ctx, RX25_BATCH_OWNER + 12) ||
            result.Owner[4] != Reg(ctx, RX25_BATCH_OWNER + 16) ||
            result.Owner[8] != Reg(ctx, RX25_BATCH_OWNER + 32) || !Idle(ctx)) {
            status = STATUS_DEVICE_BUSY; goto done;
        }
        if (!Rx25BatchValidIdentity(&result, ctx->Role)) { status = STATUS_NOT_SUPPORTED; goto done; }
        RtlCopyMemory(output, &result, sizeof(result));
        information = sizeof(result); status = STATUS_SUCCESS;
        goto done;
    }
    if (code == IOCTL_RX25_FIRST16_READ || code == IOCTL_RX25_FIRST16_START) {
        RX25_FIRST16_REQUEST diag;
        RX25_FIRST16_RESULT result;
        static const ULONG observationOffsets[8] = {0x48,0x4c,0x50,0x7c,0x80,0x84,0x88,0x8c};
        ULONG index, flags;
        if (inputBytes != sizeof(diag) || outputBytes != sizeof(result) ||
            ctx->Role != RX25_DMA_ROLE_A) { status = STATUS_INVALID_PARAMETER; goto done; }
        status = WdfRequestRetrieveInputBuffer(request, sizeof(diag), &input, NULL);
        if (!NT_SUCCESS(status)) goto done;
        RtlCopyMemory(&diag, input, sizeof(diag));
        if (diag.Size != sizeof(diag) || diag.Version != 1 || diag.Reserved ||
            diag.BufferId != session->BufferId ||
            ((code == IOCTL_RX25_FIRST16_START) ? diag.Nonce == 0 : diag.Nonce != 0)) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        status = WdfRequestRetrieveOutputBuffer(request, sizeof(result), &output, NULL);
        if (!NT_SUCCESS(status)) goto done;
        if (Reg(ctx,0x1c0) != 0x41363146) { status = STATUS_NOT_SUPPORTED; goto done; }
        flags = Reg(ctx,0x1c4);
        if (!(flags & 0x20)) { status = STATUS_DEVICE_CONFIGURATION_ERROR; goto done; }
        if (code == IOCTL_RX25_FIRST16_START) {
            if ((flags & 0xf) || !(flags & 0x10) || (Reg(ctx,0x50) & 3) != 1) {
                status = STATUS_DEVICE_BUSY; goto done;
            }
            // No address/length/control/descriptor fields are user-programmable.
            WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + 0x1c0),diag.Nonce);
            KeMemoryBarrier();
        }
        RtlZeroMemory(&result, sizeof(result));
        result.Size = sizeof(result); result.Version = 1; result.BufferId = session->BufferId;
        for (index=0;index<12;index++) result.Registers[index] = Reg(ctx,0x1c0 + index*4);
        for (index=0;index<8;index++) result.Observations[index] = Reg(ctx,observationOffsets[index]);
        KeMemoryBarrier();
        if (result.Registers[1] != Reg(ctx,0x1c4) || !Idle(ctx)) {
            status = STATUS_DEVICE_BUSY; goto done;
        }
        RtlCopyMemory(output, &result, sizeof(result));
        information = sizeof(result); status = STATUS_SUCCESS;
        goto done;
    }
    if (code == IOCTL_RX25_DMA_SNAPSHOT) {
        RX25_DMA_SNAPSHOT_REQUEST sample;
        RX25_DMA_SNAPSHOT *snapshot;
        ULONG copiedPublish;
        if (inputBytes != sizeof(sample) || ctx->Role != RX25_DMA_ROLE_A) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        status = WdfRequestRetrieveInputBuffer(request, sizeof(sample), &input, NULL);
        if (!NT_SUCCESS(status)) goto done;
        /* METHOD_BUFFERED aliases input/output. Save input before initializing output. */
        RtlCopyMemory(&sample, input, sizeof(sample));
        if (!Rx25DmaValidSnapshot(&sample, session->BufferId, RX25_DMA_BYTES)) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        status = WdfRequestRetrieveOutputBuffer(request, sizeof(*snapshot), &output, NULL);
        if (!NT_SUCCESS(status)) goto done;
        snapshot = (RX25_DMA_SNAPSHOT *)output;
        RtlZeroMemory(snapshot, FIELD_OFFSET(RX25_DMA_SNAPSHOT, Image));
        snapshot->Size = sizeof(*snapshot);
        snapshot->Version = RX25_DMA_ABI_VERSION;
        snapshot->Flags = RX25_SNAPSHOT_CPU_ONLY | RX25_SNAPSHOT_NEVER_ARMED;
        snapshot->BufferBytes = RX25_DMA_BYTES;
        snapshot->BufferId = session->BufferId;
        snapshot->DmaAddress = (ULONGLONG)ctx->Logical.QuadPart;
        snapshot->CqOffset = sample.CqOffset;
        snapshot->FirstPublish = *(volatile ULONG *)(ctx->Cpu + sample.CqOffset + 4);
        KeMemoryBarrier();
        RtlCopyMemory(snapshot->Image, ctx->Cpu, RX25_DMA_BYTES);
        KeMemoryBarrier();
        snapshot->LastPublish = *(volatile ULONG *)(ctx->Cpu + sample.CqOffset + 4);
        RtlCopyMemory(&copiedPublish, snapshot->Image + sample.CqOffset + 4, sizeof(copiedPublish));
        if (snapshot->FirstPublish == snapshot->LastPublish && copiedPublish == snapshot->FirstPublish) {
            snapshot->Flags |= RX25_SNAPSHOT_PUBLISH_STABLE;
        }
        if (!Idle(ctx)) { status = STATUS_DEVICE_NOT_READY; goto done; }
        information = sizeof(*snapshot);
        goto done;
    }
    if (code == IOCTL_RX25_DMA_SUBMIT) {
        RX25_DMA_SUBMIT submit;
        ULONG base;
        if (inputBytes != sizeof(submit) || ctx->Role != RX25_DMA_ROLE_A) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        status = WdfRequestRetrieveInputBuffer(request, sizeof(submit), &input, NULL);
        if (!NT_SUCCESS(status)) goto done;
        RtlCopyMemory(&submit, input, sizeof(submit));
        if (!ctx->Bar ||
            !Rx25DmaValidSubmit(&submit, session->BufferId,
                                (ULONGLONG)ctx->Logical.QuadPart, RX25_DMA_BYTES)) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        base = RX25_SLOT_BASE + submit.Slot * RX25_SLOT_STRIDE;
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + base + 0x00), (ULONG)submit.RemotePa);
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + base + 0x04), (ULONG)(submit.RemotePa >> 32));
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + base + 0x08), (ULONG)submit.HostIova);
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + base + 0x0c), (ULONG)(submit.HostIova >> 32));
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + base + 0x10), submit.RequestId);
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + base + 0x14),
                             (ULONG)submit.Generation | (submit.Length << 16));
        KeMemoryBarrier();
        /* Doorbell is dword 6 bit0 and must be the last write: the slot is
         * latched only when the flags dword arrives. */
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + base + 0x18), 1u);
        status = STATUS_SUCCESS;
        information = 0;
        goto done;
    }
    if (code == IOCTL_RX25_DMA_CONTROL) {
        RX25_DMA_CONTROL control;
        ULONG word;
        if (inputBytes != sizeof(control) || ctx->Role != RX25_DMA_ROLE_A) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        status = WdfRequestRetrieveInputBuffer(request, sizeof(control), &input, NULL);
        if (!NT_SUCCESS(status)) goto done;
        RtlCopyMemory(&control, input, sizeof(control));
        if (!ctx->Bar || !Rx25DmaValidControl(&control, session->BufferId)) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        word = control.Value & 5u;   /* ENABLE | QD8, nothing else */
        WRITE_REGISTER_ULONG((PULONG)(ctx->Bar + 0x0c), word);
        KeMemoryBarrier();
        information = 0;
        status = STATUS_SUCCESS;
        goto done;
    }
    if (code == IOCTL_RX25_DMA_REGREAD) {
        RX25_DMA_REG reg;
        ULONG value;
        if (inputBytes != sizeof(reg) || outputBytes != sizeof(value) ||
            ctx->Role != RX25_DMA_ROLE_A) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        /* METHOD_BUFFERED aliases input and output: copy the request out
         * before the reply overwrites the same system buffer. */
        status = WdfRequestRetrieveInputBuffer(request, sizeof(reg), &input, NULL);
        if (!NT_SUCCESS(status)) goto done;
        RtlCopyMemory(&reg, input, sizeof(reg));
        if (!ctx->Bar || !Rx25DmaValidReg(&reg, session->BufferId)) {
            status = STATUS_INVALID_PARAMETER; goto done;
        }
        status = WdfRequestRetrieveOutputBuffer(request, sizeof(value), &output, NULL);
        if (!NT_SUCCESS(status)) goto done;
        KeMemoryBarrier();
        value = Reg(ctx, reg.Offset);
        RtlCopyMemory(output, &value, sizeof(value));
        information = sizeof(value);
        status = STATUS_SUCCESS;
        goto done;
    }
    if (code == IOCTL_RX25_DMA_PLAN) {
        RX25_JOB_REQUEST job;
        RX25_JOB_PLAN plan;
        RX25_DMA_INFO local;
        if (inputBytes != sizeof(job)) { status = STATUS_INVALID_PARAMETER; goto done; }
        status = WdfRequestRetrieveInputBuffer(request, sizeof(job), &input, NULL);
        if (!NT_SUCCESS(status)) goto done;
        RtlCopyMemory(&job, input, sizeof(job));
        RtlZeroMemory(&local, sizeof(local));
        local.Size = sizeof(local);
        local.Version = 1;
        local.Role = ctx->Role;
        local.Caps = ctx->Caps;
        local.BufferBytes = RX25_DMA_BYTES;
        local.CqOffset = ctx->Role == RX25_DMA_ROLE_A ? 0x1000 : RX25_DMA_NO_CQ;
        local.BufferId = session->BufferId;
        local.DmaAddress = (ULONGLONG)ctx->Logical.QuadPart;
        local.Control = Reg(ctx, 12);
        local.Status = Reg(ctx, 16);
        if (!Rx25JobPlan(&job, &local, &plan)) { status = STATUS_INVALID_PARAMETER; goto done; }
        status = WdfRequestRetrieveOutputBuffer(request, sizeof(plan), &output, NULL);
        if (!NT_SUCCESS(status)) goto done;
        RtlCopyMemory(output, &plan, sizeof(plan));
        information = sizeof(plan);
        goto done; /* Planning never writes registers or modifies buffers. */
    }
    if (code != IOCTL_RX25_DMA_READ && code != IOCTL_RX25_DMA_WRITE) goto done;
    status = WdfRequestRetrieveInputBuffer(request, sizeof(transfer), &input, NULL);
    if (!NT_SUCCESS(status)) goto done;
    RtlCopyMemory(&transfer, input, sizeof(transfer));
    if (!Rx25DmaValidTransfer(&transfer, session->BufferId, RX25_DMA_BYTES)) {
        status = STATUS_INVALID_PARAMETER;
        goto done;
    }
    if (code == IOCTL_RX25_DMA_READ) {
        if (inputBytes != sizeof(transfer)) { status = STATUS_INVALID_PARAMETER; goto done; }
        status = WdfRequestRetrieveOutputBuffer(request, transfer.Length, &output, NULL);
        if (!NT_SUCCESS(status)) goto done;
        KeMemoryBarrier();
        RtlCopyMemory(output, ctx->Cpu + transfer.Offset, transfer.Length);
        information = transfer.Length;
    } else {
        if (inputBytes != sizeof(transfer) + transfer.Length || outputBytes != 0) {
            status = STATUS_INVALID_PARAMETER;
            goto done;
        }
        RtlCopyMemory(ctx->Cpu + transfer.Offset, (PUCHAR)input + sizeof(transfer), transfer.Length);
        KeMemoryBarrier();
        status = STATUS_SUCCESS;
    }
done:
    WdfWaitLockRelease(ctx->Lock);
    WdfRequestCompleteWithInformation(request, status, NT_SUCCESS(status) ? information : 0);
}
