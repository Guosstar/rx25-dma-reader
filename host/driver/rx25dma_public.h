#pragma once

/* Include ntddk.h or Windows.h + winioctl.h before this shared ABI. */
#define RX25_DMA_ABI_VERSION 1u
#define RX25_DMA_ROLE_A 1u
#define RX25_DMA_ROLE_B 2u
#define RX25_DMA_FLAG_COMMON_BUFFER 1u
#define RX25_DMA_FLAG_BUFFER_ONLY 2u
#define RX25_DMA_FLAG_NEVER_ARMED 4u
#define RX25_DMA_FLAG_PLAN_SUPPORTED 8u
#define RX25_DMA_FLAG_SNAPSHOT_SUPPORTED 16u
#define RX25_DMA_BYTES 0x2000u
#define RX25_DMA_NO_CQ 0xffffffffu
#define IOCTL_RX25_DMA_QUERY CTL_CODE(FILE_DEVICE_UNKNOWN, 0x900, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_RX25_DMA_READ  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x901, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_RX25_DMA_WRITE CTL_CODE(FILE_DEVICE_UNKNOWN, 0x902, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_RX25_DMA_PLAN CTL_CODE(FILE_DEVICE_UNKNOWN, 0x903, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
/* 0x904 remains unsupported for the historical negative-IOCTL regression. */
#define IOCTL_RX25_DMA_SNAPSHOT CTL_CODE(FILE_DEVICE_UNKNOWN, 0x905, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
/* Board-local diagnostic only: fixed 16B peer pattern, RQ stays disabled. */
#define IOCTL_RX25_FIRST16_READ CTL_CODE(FILE_DEVICE_UNKNOWN, 0x906, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_RX25_FIRST16_START CTL_CODE(FILE_DEVICE_UNKNOWN, 0x907, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
/* Fixed board-local batch diagnostic only. No address, length, or DMA control. */
#define IOCTL_RX25_BATCH_READ CTL_CODE(FILE_DEVICE_UNKNOWN, 0x908, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_RX25_BATCH_ARM CTL_CODE(FILE_DEVICE_UNKNOWN, 0x909, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_RX25_BATCH_START CTL_CODE(FILE_DEVICE_UNKNOWN, 0x90a, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_RX25_BATCH_CAPTURE CTL_CODE(FILE_DEVICE_UNKNOWN, 0x90b, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
/* Arbitrary remote physical address submit: writes one 32 B descriptor slot and
 * rings the +0x18 doorbell. Driver-free PA read on the peer (see
 * PROJECT_GOAL_DRIVERLESS_PA.md, milestone M4). */
#define IOCTL_RX25_DMA_SUBMIT CTL_CODE(FILE_DEVICE_UNKNOWN, 0x90c, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
/* Control word at BAR0+0x0C (bit0 ENABLE, bit2 QD8).  The descriptor engine
 * arms no slot and starts no job until bit0 is set; without this ioctl a
 * driverless-PA run has no way to turn the request path on at all. */
#define IOCTL_RX25_DMA_CONTROL CTL_CODE(FILE_DEVICE_UNKNOWN, 0x90d, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
/* Read one dword from the BAR0 register file (0x00..0x88, 4 B aligned).  Used
 * for READY, the outcome counters, and as the "what did the engine actually
 * do" half of every read attempt. */
#define IOCTL_RX25_DMA_REGREAD CTL_CODE(FILE_DEVICE_UNKNOWN, 0x90e, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define RX25_REG_LAST 0x88u
#define RX25_SLOT_BASE 0x1000u
#define RX25_SLOT_STRIDE 0x20u
#define RX25_SLOT_COUNT 8u
#define RX25_BATCH_ABI_VERSION 1u
#define RX25_BATCH_SIGNATURE 0x41323342u
#define RX25_PRESSURE_SIGNATURE 0x31535250u
#define RX25_BATCH_OWNER_SIGNATURE 0x31544342u
#define RX25_BATCH_BAR_BASE 0x800u
#define RX25_BATCH_LOCAL_PRESSURE 0x840u
#define RX25_BATCH_PEER_PRESSURE 0x880u
#define RX25_BATCH_OWNER 0x8c0u
#define RX25_BATCH_PAYLOAD 0x900u
#define RX25_BATCH_ARM_OFFSET 0xb00u
#define RX25_BATCH_START_OFFSET 0xb04u
#define RX25_BATCH_CAPTURE_OFFSET 0xb08u
#define RX25_SNAPSHOT_CPU_ONLY 1u
#define RX25_SNAPSHOT_NEVER_ARMED 2u
#define RX25_SNAPSHOT_PUBLISH_STABLE 4u

/* {70CF91AE-6425-4EBD-A161-BE86A29D1153} */
DEFINE_GUID(GUID_DEVINTERFACE_RX25_DMA,
    0x70cf91ae, 0x6425, 0x4ebd, 0xa1, 0x61, 0xbe, 0x86, 0xa2, 0x9d, 0x11, 0x53);

#pragma pack(push, 8)
typedef struct _RX25_DMA_INFO {
    ULONG Size;
    ULONG Version;
    ULONG Flags;
    ULONG Role;
    ULONG Caps;
    ULONG BufferBytes;
    ULONG CqOffset;
    ULONG Reserved0;
    ULONGLONG BufferId;
    ULONGLONG DmaAddress;
    ULONG Control;
    ULONG Status;
    ULONG ObsStatus;
    ULONG Reserved1;
} RX25_DMA_INFO;

typedef struct _RX25_DMA_TRANSFER {
    ULONG Size;
    ULONG Version;
    ULONGLONG BufferId;
    ULONG Offset;
    ULONG Length;
} RX25_DMA_TRANSFER;

typedef struct _RX25_DMA_SNAPSHOT_REQUEST {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG CqOffset, Reserved;
} RX25_DMA_SNAPSHOT_REQUEST;

typedef struct _RX25_FIRST16_REQUEST {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG Nonce, Reserved;
} RX25_FIRST16_REQUEST;

typedef struct _RX25_FIRST16_RESULT {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG Registers[12];
    ULONG Observations[8];
} RX25_FIRST16_RESULT;

typedef struct _RX25_BATCH_REQUEST {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG Nonce, Reserved;
} RX25_BATCH_REQUEST;

/* An observation, not a host-memory completion/drain certificate. */
typedef struct _RX25_BATCH_RESULT {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG Batch[16];
    ULONG LocalPressure[16];
    ULONG PeerPressure[16];
    ULONG Owner[16];
    ULONG Payload[128];
    ULONG Observations[8];
} RX25_BATCH_RESULT;

/* One descriptor slot write. RemotePa is the peer physical address the request
 * carries in PL11 w3; HostIova is this machine's 8 KiB common buffer, whose
 * first 4 KiB receives the data and whose +0x1000 holds the CQ entry. */
typedef struct _RX25_DMA_SUBMIT {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG Slot;
    ULONG Length;          /* bytes, 16..256, multiple of 16 */
    ULONGLONG RemotePa;    /* 16 B aligned, must not cross a 4 KiB page */
    ULONGLONG HostIova;    /* 4 KiB aligned, inside the common buffer */
    ULONG RequestId;
    USHORT Generation;
    USHORT Reserved;
} RX25_DMA_SUBMIT;

/* One control-word write. Value is masked to the two defined bits so a caller
 * cannot reach any other register through this path. */
typedef struct _RX25_DMA_CONTROL {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG Value;
    ULONG Reserved;
} RX25_DMA_CONTROL;

/* One BAR0 dword read. Offset is restricted to the 0x00..0x88 register file. */
typedef struct _RX25_DMA_REG {
    ULONG Size, Version;
    ULONGLONG BufferId;
    ULONG Offset;
    ULONG Reserved;
} RX25_DMA_REG;

/* A raw observation, never a VERIFIED/completion or PCIe-drain certificate.
 * This buffer-only driver has never armed DMA. The stable flag also permits
 * zero publish (pending); it does not mean a request completed. */
typedef struct _RX25_DMA_SNAPSHOT {
    ULONG Size, Version, Flags, BufferBytes;
    ULONGLONG BufferId, DmaAddress;
    ULONG CqOffset, FirstPublish, LastPublish, Reserved;
    UCHAR Image[RX25_DMA_BYTES];
} RX25_DMA_SNAPSHOT;
#pragma pack(pop)

/* Subtraction prevents Offset+Length integer wrap. Shared with host tests. */
static __inline int Rx25DmaValidRange(ULONG capacity, ULONG offset, ULONG length)
{
    return length != 0 && offset <= capacity && length <= capacity - offset;
}

static __inline int Rx25DmaValidTransfer(const RX25_DMA_TRANSFER *transfer,
                                        ULONGLONG bufferId, ULONG capacity)
{
    return transfer->Size == sizeof(*transfer) &&
           transfer->Version == RX25_DMA_ABI_VERSION &&
           transfer->BufferId == bufferId &&
           Rx25DmaValidRange(capacity, transfer->Offset, transfer->Length);
}

static __inline int Rx25DmaValidSnapshot(const RX25_DMA_SNAPSHOT_REQUEST *request,
                                        ULONGLONG bufferId, ULONG capacity)
{
    return request->Size == sizeof(*request) && request->Version == RX25_DMA_ABI_VERSION &&
           bufferId != 0 && request->BufferId == bufferId && !request->Reserved &&
           capacity == RX25_DMA_BYTES && request->CqOffset >= 0x1000 &&
           !(request->CqOffset & 15) && Rx25DmaValidRange(capacity, request->CqOffset, 32);
}

static __inline int Rx25BatchValidNonce(ULONG nonce)
{
    return nonce != 0 && !(nonce & 31u);
}

/* Bounds for one descriptor submit. Everything here is checkable without the
 * device: slot index, 16 B alignment, one 4 KiB page, CQ entry inside the
 * common buffer. RemotePa itself is intentionally unbounded -- the whole point
 * of the driver-free target is that any 64-bit physical address is legal. */
static __inline int Rx25DmaValidSubmit(const RX25_DMA_SUBMIT *submit, ULONGLONG bufferId,
                                       ULONGLONG dmaAddress, ULONG capacity)
{
    ULONGLONG pageOffset;
    if (submit->Size != sizeof(*submit) || submit->Version != RX25_DMA_ABI_VERSION ||
        bufferId == 0 || submit->BufferId != bufferId || submit->Reserved ||
        submit->Slot >= RX25_SLOT_COUNT) return 0;
    if (submit->Length < 16 || submit->Length > 256 || (submit->Length & 15u)) return 0;
    if (submit->RemotePa & 15ull) return 0;
    if (((submit->RemotePa & 0xfffull) + submit->Length) > 4096ull) return 0;
    if (submit->HostIova & 0xfffull) return 0;
    if (submit->HostIova < dmaAddress) return 0;
    pageOffset = submit->HostIova - dmaAddress;
    if (pageOffset > capacity || capacity - (ULONG)pageOffset < 0x1020u) return 0;
    return 1;
}

static __inline int Rx25DmaValidControl(const RX25_DMA_CONTROL *control, ULONGLONG bufferId)
{
    return control->Size == sizeof(*control) &&
           control->Version == RX25_DMA_ABI_VERSION &&
           bufferId != 0 && control->BufferId == bufferId &&
           !(control->Value & ~5u) && !control->Reserved;
}

static __inline int Rx25DmaValidReg(const RX25_DMA_REG *reg, ULONGLONG bufferId)
{
    return reg->Size == sizeof(*reg) && reg->Version == RX25_DMA_ABI_VERSION &&
           bufferId != 0 && reg->BufferId == bufferId && !reg->Reserved &&
           !(reg->Offset & 3u) && reg->Offset <= RX25_REG_LAST;
}

static __inline ULONG Rx25BatchCommandOffset(ULONG code){
    if (code == IOCTL_RX25_BATCH_ARM) return RX25_BATCH_ARM_OFFSET;
    if (code == IOCTL_RX25_BATCH_START) return RX25_BATCH_START_OFFSET;
    if (code == IOCTL_RX25_BATCH_CAPTURE) return RX25_BATCH_CAPTURE_OFFSET;
    return 0;
}

static __inline int Rx25BatchValidRequest(const RX25_BATCH_REQUEST *request,
                                          ULONGLONG bufferId, ULONG code)
{
    if (code != IOCTL_RX25_BATCH_READ && !Rx25BatchCommandOffset(code)) return 0;
    return request->Size == sizeof(*request) && request->Version == RX25_BATCH_ABI_VERSION &&
           bufferId != 0 && request->BufferId == bufferId && request->Reserved == 0 &&
           (code == IOCTL_RX25_BATCH_READ ? request->Nonce == 0 : Rx25BatchValidNonce(request->Nonce));
}

/* Initial pressure banks are all zero. Once armed, both must be published with
 * the owner's nonce; neither mixed banks nor another personality is accepted. */
static __inline int Rx25BatchValidIdentity(const RX25_BATCH_RESULT *result, ULONG role)
{
    ULONG index, localOr = 0, peerOr = 0, flags = result->Owner[2];
    if (role != RX25_DMA_ROLE_A || result->Size != sizeof(*result) ||
        result->Version != RX25_BATCH_ABI_VERSION || !result->BufferId ||
        result->Batch[0] != RX25_BATCH_SIGNATURE || !(result->Batch[1] & 0x40u) ||
        (result->Batch[1] & ~0xffu) || result->Batch[14] != 32 || result->Batch[15] != 16 ||
        result->Owner[0] != RX25_BATCH_OWNER_SIGNATURE || result->Owner[1] != 1 ||
        !(flags & 1u) || (flags & ~0x7fu)) return 0;
    for (index = 9; index < 16; index++) if (result->Owner[index]) return 0;
    for (index = 0; index < 16; index++) {
        localOr |= result->LocalPressure[index];
        peerOr |= result->PeerPressure[index];
    }
    if (!localOr && !peerOr) return !(flags & (8u | 16u | 32u));
    return result->LocalPressure[0] == RX25_PRESSURE_SIGNATURE &&
           result->PeerPressure[0] == RX25_PRESSURE_SIGNATURE &&
           Rx25BatchValidNonce(result->Owner[3]) &&
           result->LocalPressure[2] == result->Owner[3] &&
           result->PeerPressure[2] == result->Owner[3];
}

static __inline int Rx25BatchValidCommand(const RX25_BATCH_RESULT *result, ULONG role,
                                          ULONG code, ULONG nonce)
{
    ULONG flags = result->Owner[2], batch = result->Batch[1];
    if (!Rx25BatchValidIdentity(result, role) || !Rx25BatchValidNonce(nonce) ||
        (result->Observations[2] & 3u) != 1u ||
        (flags & 7u) != 3u || (flags & 0x40u)) return 0;
    if (code == IOCTL_RX25_BATCH_ARM) {
        return !(flags & 0x38u) && result->Owner[3] == 0 &&
               (batch & 0x7fu) == 0x60u && result->Batch[2] == 0;
    }
    if (result->Owner[3] != nonce) return 0;
    if (code == IOCTL_RX25_BATCH_START) {
        return (flags & 0x38u) == 8u && (batch & 0x7fu) == 0x60u &&
               result->Batch[2] == 0 &&
               (result->LocalPressure[1] & 0xbu) == 3u &&
               (result->PeerPressure[1] & 0xbu) == 3u;
    }
    if (code == IOCTL_RX25_BATCH_CAPTURE) {
        return (flags & 0x38u) == 0x18u && (batch & 7u) == 1u &&
               (batch & 0x18u) != 0 && result->Batch[2] == nonce;
    }
    return 0;
}
