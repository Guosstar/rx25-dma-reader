/* Explicit-device, read-only observation. This program never submits work.
 * Reuse the frozen shared ABI, but call only QUERY and BATCH_READ. */
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdarg.h>
#include <wchar.h>
#include "../rx25dma_public.h"

C_ASSERT(sizeof(RX25_DMA_INFO) == 64);
C_ASSERT(sizeof(RX25_BATCH_REQUEST) == 24);
C_ASSERT(sizeof(RX25_BATCH_RESULT) == 816);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Owner) == 208);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Payload) == 272);
C_ASSERT(IOCTL_RX25_DMA_QUERY == 0x22e400);
C_ASSERT(IOCTL_RX25_BATCH_READ == 0x22e420);

typedef struct _RX25_INSPECTION {
    const char *Result;
    const char *SnapshotState;
    const char *PressureState;
    DWORD DeviceError, QueryError, ReadError, QueryBytes, ReadBytes;
    unsigned Ioctls;
    int SnapshotValid;
    RX25_DMA_INFO Info;
    RX25_BATCH_RESULT Snapshot;
} RX25_INSPECTION;

static int InspectQueryIdentity(const RX25_DMA_INFO *p)
{
    return p->Size == sizeof(*p) && p->Version == 1 && p->Role == RX25_DMA_ROLE_A &&
           p->Caps == 0xf && p->BufferBytes == RX25_DMA_BYTES && p->CqOffset == 0x1000 &&
           p->BufferId != 0 && p->Reserved0 == 0 && p->Reserved1 == 0 &&
           (p->Flags == 7 || p->Flags == 15 || p->Flags == 31) &&
           !(p->DmaAddress & 4095u) && p->DmaAddress <= MAXULONGLONG - RX25_DMA_BYTES;
}

static void InspectClassify(RX25_INSPECTION *p)
{
    const RX25_BATCH_RESULT *r = &p->Snapshot;
    ULONG localOr = 0, peerOr = 0;
    unsigned index;
    for (index = 0; index < 16; index++) {
        localOr |= r->LocalPressure[index]; peerOr |= r->PeerPressure[index];
    }
    p->PressureState = !localOr && !peerOr ? "empty" :
        ((r->LocalPressure[1] & 16u) && (r->PeerPressure[1] & 16u) ? "captured" : "published");
    if ((r->Owner[2] & 0x40u) || (r->Batch[1] & 0x10u) ||
        (r->LocalPressure[1] & 8u) || (r->PeerPressure[1] & 8u)) p->SnapshotState = "fault_snapshot";
    else if (r->Owner[2] & 4u) p->SnapshotState = "pending_snapshot";
    else if (r->Owner[2] & 32u) p->SnapshotState = "captured_snapshot";
    else if (r->Batch[1] & 6u) p->SnapshotState = "running_snapshot";
    else if ((r->Batch[1] & 1u) || (r->Owner[2] & 16u)) p->SnapshotState = "spent_snapshot";
    else if (r->Owner[2] & 8u) p->SnapshotState = "armed_snapshot";
    else p->SnapshotState = "initial_snapshot";
}

static int InspectAppend(char *buffer, size_t capacity, size_t *used, const char *format, ...)
{
    int count;
    va_list arguments;
    va_start(arguments, format);
    count = _vsnprintf_s(buffer + *used, capacity - *used, _TRUNCATE, format, arguments);
    va_end(arguments);
    if (count < 0) return 0;
    *used += (size_t)count;
    return 1;
}

static int InspectWriteEvidence(HANDLE output, const RX25_INSPECTION *p)
{
    char buffer[16384];
    size_t used = 0;
    unsigned index;
    ULONG word;
    DWORD written = 0;
    const RX25_BATCH_RESULT *r = &p->Snapshot;
    if (!InspectAppend(buffer, sizeof(buffer), &used,
        "{\n  \"schema\":\"rx25-readonly-inspection-v1\",\n"
        "  \"result\":\"%s\",\n  \"snapshot_state\":\"%s\",\n  \"pressure_state\":\"%s\",\n"
        "  \"snapshot_valid\":%s,\n  \"read_only\":true,\n  \"commands_issued\":0,\n"
        "  \"batch_test_pass\":false,\n  \"hardware_test_pass\":false,\n"
        "  \"driver_build_identity_proven\":false,\n  \"image_identity_proven\":false,\n"
        "  \"ioctl_attempts\":%u,\n  \"device_error\":%lu,\n  \"query_error\":%lu,\n"
        "  \"read_error\":%lu,\n  \"query_bytes\":%lu,\n  \"read_bytes\":%lu,\n"
        "  \"buffer_id\":\"0x%016llx\",\n  \"rx_block_lock\":%s,\n  \"rx_high_ber\":%s,\n"
        "  \"batch_spent\":%s,\n  \"owner_flags\":%lu,\n  \"batch_flags\":%lu,\n"
        "  \"raw_query_dwords\":[",
        p->Result, p->SnapshotState, p->PressureState, p->SnapshotValid ? "true" : "false",
        p->Ioctls, p->DeviceError, p->QueryError, p->ReadError, p->QueryBytes, p->ReadBytes,
        p->Info.BufferId, r->Observations[2] & 1u ? "true" : "false",
        r->Observations[2] & 2u ? "true" : "false", r->Batch[1] & 1u ? "true" : "false",
        r->Owner[2], r->Batch[1])) return 0;
    for (index = 0; index < sizeof(p->Info)/sizeof(word); index++) {
        CopyMemory(&word, (const UCHAR *)&p->Info + index * sizeof(word), sizeof(word));
        if (!InspectAppend(buffer, sizeof(buffer), &used, "%s%lu", index ? "," : "", word)) return 0;
    }
    if (!InspectAppend(buffer, sizeof(buffer), &used, "],\n  \"raw_snapshot_dwords\":[")) return 0;
    for (index = 0; index < sizeof(*r)/sizeof(word); index++) {
        CopyMemory(&word, (const UCHAR *)r + index * sizeof(word), sizeof(word));
        if (!InspectAppend(buffer, sizeof(buffer), &used, "%s%lu", index ? "," : "", word)) return 0;
    }
    if (!InspectAppend(buffer, sizeof(buffer), &used, "]\n}\n")) return 0;
    return WriteFile(output, buffer, (DWORD)used, &written, NULL) && written == used;
}

int wmain(int argc, wchar_t **argv)
{
    HANDLE output, device;
    RX25_INSPECTION evidence = {0};
    RX25_BATCH_REQUEST request = {sizeof(request), RX25_BATCH_ABI_VERSION, 0, 0, 0};
    int written;
    if (argc != 6 || wcscmp(argv[1], L"--inspect") || wcscmp(argv[2], L"--device") ||
        !*argv[3] || wcscmp(argv[4], L"--output") || !*argv[5]) {
        fwprintf(stderr, L"Usage: %ls --inspect --device EXPLICIT_A_PATH --output NEW_JSON_FILE\n", argv[0]);
        return 2;
    }
    output = CreateFileW(argv[5], GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (output == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "RX25_INSPECT_OUTPUT_OPEN_FAILED error=%lu\n", GetLastError());
        return 2;
    }
    evidence.Result = "device_open_failed"; evidence.SnapshotState = "unread"; evidence.PressureState = "unread";
    /* The existing read IOCTLs require both access rights; neither operation writes work. */
    device = CreateFileW(argv[3], GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (device == INVALID_HANDLE_VALUE) { evidence.DeviceError = GetLastError(); goto save; }
    evidence.Ioctls++;
    if (!DeviceIoControl(device, IOCTL_RX25_DMA_QUERY, NULL, 0, &evidence.Info, sizeof(evidence.Info),
        &evidence.QueryBytes, NULL)) {
        evidence.QueryError = GetLastError(); evidence.Result = "query_failed"; goto close_device;
    }
    if (evidence.QueryBytes != sizeof(evidence.Info)) { evidence.Result = "query_size_mismatch"; goto close_device; }
    if (!InspectQueryIdentity(&evidence.Info)) { evidence.Result = "query_identity_mismatch"; goto close_device; }
    request.BufferId = evidence.Info.BufferId;
    evidence.Ioctls++;
    if (!DeviceIoControl(device, IOCTL_RX25_BATCH_READ, &request, sizeof(request), &evidence.Snapshot,
        sizeof(evidence.Snapshot), &evidence.ReadBytes, NULL)) {
        evidence.ReadError = GetLastError();
        evidence.Result = evidence.ReadError == ERROR_INVALID_FUNCTION || evidence.ReadError == ERROR_NOT_SUPPORTED ?
            "batch_read_unsupported" : "batch_read_failed";
        goto close_device;
    }
    if (evidence.ReadBytes != sizeof(evidence.Snapshot) || evidence.Snapshot.Size != sizeof(evidence.Snapshot)) {
        evidence.Result = "batch_size_mismatch"; goto close_device;
    }
    if (evidence.Snapshot.BufferId != evidence.Info.BufferId ||
        !Rx25BatchValidIdentity(&evidence.Snapshot, evidence.Info.Role)) {
        evidence.Result = "batch_identity_mismatch"; goto close_device;
    }
    evidence.SnapshotValid = 1; evidence.Result = "snapshot_recorded";
    InspectClassify(&evidence);
close_device:
    CloseHandle(device);
save:
    written = InspectWriteEvidence(output, &evidence);
    CloseHandle(output);
    if (!written) { fprintf(stderr, "RX25_INSPECT_EVIDENCE_WRITE_FAILED\n"); return 1; }
    printf("RX25_INSPECT_%s result=%s state=%s pressure=%s; observation only\n",
        evidence.SnapshotValid ? "RECORDED" : "FAILED", evidence.Result, evidence.SnapshotState, evidence.PressureState);
    return evidence.SnapshotValid ? 0 : 1;
}
