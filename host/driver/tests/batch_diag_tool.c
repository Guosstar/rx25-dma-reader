/* Deliberately opt-in native acceptance tool. Never run by offline tests.
 * One ARM, one START, one CAPTURE at most. Failed/uncertain commands are never
 * repeated. Tight native READ polling preserves the short ARM-to-START budget.
 */
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <errno.h>
#include "../rx25dma_public.h"

static LARGE_INTEGER frequency;
static DWORD commandErrors[3];

static int Snapshot(HANDLE device, ULONGLONG id, RX25_BATCH_RESULT *r)
{
    RX25_BATCH_REQUEST q = {sizeof(q), 1, 0, 0, 0};
    DWORD bytes = 0;
    q.BufferId = id;
    return DeviceIoControl(device, IOCTL_RX25_BATCH_READ, &q, sizeof(q), r, sizeof(*r), &bytes, NULL) &&
           bytes == sizeof(*r) && r->BufferId == id && Rx25BatchValidIdentity(r, RX25_DMA_ROLE_A);
}

static void CommandOnce(HANDLE device, ULONGLONG id, ULONG nonce, ULONG code, unsigned index)
{
    RX25_BATCH_REQUEST q = {sizeof(q), 1, 0, 0, 0};
    RX25_BATCH_RESULT r;
    DWORD bytes;
    q.BufferId = id; q.Nonce = nonce;
    commandErrors[index] = DeviceIoControl(device, code, &q, sizeof(q), &r, sizeof(r), &bytes, NULL) ? 0 : GetLastError();
}

static int WaitPhase(HANDLE device, ULONGLONG id, ULONG nonce, unsigned phase, RX25_BATCH_RESULT *r)
{
    LARGE_INTEGER start, now;
    unsigned attempts;
    QueryPerformanceCounter(&start);
    for (attempts = 0; attempts < 4096; attempts++) {
        if (Snapshot(device, id, r)) {
            ULONG owner = r->Owner[2];
            if (owner & 0x40u) return 0;
            if (r->Owner[3] == nonce && !(owner & 4u)) {
                if (phase == 1 && (owner & 0x18u) == 8u) return 1;
                if (phase == 2 && (owner & 0x18u) == 0x18u && (r->Batch[1] & 7u) == 1u &&
                    (r->Batch[1] & 0x18u)) return 1;
                if (phase == 3 && (owner & 0x38u) == 0x38u) return 1;
            }
        }
        QueryPerformanceCounter(&now);
        if ((now.QuadPart - start.QuadPart) > frequency.QuadPart * 2) break;
    }
    return 0;
}

static int PressurePass(const ULONG *p, ULONG nonce, ULONG expectedPackets)
{
    return p[0] == RX25_PRESSURE_SIGNATURE && (p[1] & 0x1ffu) == 0x1d5u && p[2] == nonce &&
           p[3] == expectedPackets && p[4] == expectedPackets &&
           p[5] == 4u * expectedPackets && p[6] == 4u * expectedPackets &&
           p[7] == expectedPackets && p[8] == expectedPackets &&
           p[9] >= 40 && p[10] >= 40 && p[11] >= 40 && p[12] >= 1 &&
           p[14] == 0 && p[15] == expectedPackets;
}

static int FinalPass(const RX25_BATCH_RESULT *r, ULONG nonce)
{
    unsigned index;
    if (!Rx25BatchValidIdentity(r, RX25_DMA_ROLE_A) || (r->Observations[2] & 3u) != 1u ||
        r->Owner[2] != 0x3bu ||
        r->Owner[3] != nonce || r->Owner[4] != 0 || r->Owner[5] != 3 || r->Owner[6] != 3 ||
        r->Owner[7] != 0 || r->Owner[8] != 3 ||
        r->Batch[1] != 0xe9u || r->Batch[2] != nonce || r->Batch[3] != 32 || r->Batch[4] != 32 ||
        r->Batch[5] != 512 || r->Batch[6] != 0xffffffff || r->Batch[7] != 192 ||
        r->Batch[8] != 256 || r->Batch[10] != 0 || r->Batch[11] < 1 || r->Batch[11] > 16 ||
        r->Batch[12] != 0 || r->Batch[13] != 0 || !PressurePass(r->LocalPressure, nonce, 96) ||
        !PressurePass(r->PeerPressure, nonce, 128)) return 0;
    for (index = 0; index < 64; index++)
        if (r->Payload[index*2] != index || r->Payload[index*2+1] != 0xa5a50000u) return 0;
    return 1;
}

int wmain(int argc, wchar_t **argv)
{
    HANDLE device = INVALID_HANDLE_VALUE, output = INVALID_HANDLE_VALUE;
    RX25_DMA_INFO info;
    RX25_BATCH_RESULT r = {0};
    ULONG nonce;
    DWORD bytes = 0;
    wchar_t *end;
    int pass = 0, phase = 0;
    if (argc != 8 || wcscmp(argv[1], L"--execute") || wcscmp(argv[2], L"--device") ||
        wcscmp(argv[4], L"--nonce") || wcscmp(argv[6], L"--output")) {
        fwprintf(stderr, L"Usage (hardware access, explicit opt-in): %ls --execute --device DEVICE_PATH --nonce ALIGNED_NONZERO_U32 --output NEW_816B_FILE\n", argv[0]);
        return 2;
    }
    errno = 0; nonce = wcstoul(argv[5], &end, 0);
    if (errno || !*argv[5] || argv[5][0] == L'-' || *end || !Rx25BatchValidNonce(nonce)) return 2;
    if (!QueryPerformanceFrequency(&frequency)) return 2;
    /* Reserve evidence destination before any hardware command; never overwrite. */
    output = CreateFileW(argv[7], GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (output == INVALID_HANDLE_VALUE) { fprintf(stderr, "New output file required: %lu\n", GetLastError()); return 2; }
    device = CreateFileW(argv[3], GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (device == INVALID_HANDLE_VALUE) goto done;
    if (!DeviceIoControl(device, IOCTL_RX25_DMA_QUERY, NULL, 0, &info, sizeof(info), &bytes, NULL) ||
        bytes != sizeof(info) || info.Size != sizeof(info) || info.Version != 1 ||
        info.Role != RX25_DMA_ROLE_A || info.Caps != 0xf || info.BufferBytes != RX25_DMA_BYTES ||
        !info.BufferId || info.Control != 0 || (info.Status & 0x104u) || (info.ObsStatus & 3u) != 1u ||
        (info.Flags & (RX25_DMA_FLAG_BUFFER_ONLY | RX25_DMA_FLAG_NEVER_ARMED)) !=
            (RX25_DMA_FLAG_BUFFER_ONLY | RX25_DMA_FLAG_NEVER_ARMED)) goto done;
    if (!Snapshot(device, info.BufferId, &r) ||
        !Rx25BatchValidCommand(&r, info.Role, IOCTL_RX25_BATCH_ARM, nonce)) goto done;
    phase = 1;
    CommandOnce(device, info.BufferId, nonce, IOCTL_RX25_BATCH_ARM, 0);
    if (!WaitPhase(device, info.BufferId, nonce, 1, &r) ||
        !Rx25BatchValidCommand(&r, info.Role, IOCTL_RX25_BATCH_START, nonce)) goto done;
    /* No log output, sleep, process launch, or manual interaction in this gap. */
    phase = 2;
    CommandOnce(device, info.BufferId, nonce, IOCTL_RX25_BATCH_START, 1);
    if (!WaitPhase(device, info.BufferId, nonce, 2, &r) ||
        !Rx25BatchValidCommand(&r, info.Role, IOCTL_RX25_BATCH_CAPTURE, nonce)) goto done;
    phase = 3;
    CommandOnce(device, info.BufferId, nonce, IOCTL_RX25_BATCH_CAPTURE, 2);
    if (!WaitPhase(device, info.BufferId, nonce, 3, &r)) goto done;
    pass = FinalPass(&r, nonce);
done:
    if (device != INVALID_HANDLE_VALUE) CloseHandle(device);
    if (!WriteFile(output, &r, sizeof(r), &bytes, NULL) || bytes != sizeof(r)) pass = 0;
    CloseHandle(output);
    printf("RX25_BATCH_%s phase=%d nonce=%08lx owner=%08lx batch=%08lx sent=%lu completed=%lu bytes=%lu arm_error=%lu start_error=%lu capture_error=%lu\n",
        pass ? "PASS" : "FAIL", phase, nonce, r.Owner[2], r.Batch[1], r.Batch[3], r.Batch[4], r.Batch[5],
        commandErrors[0], commandErrors[1], commandErrors[2]);
    printf("Evidence is board-pattern diagnostic only; no B host-memory or host-DMA claim. No command was retried.\n");
    return pass ? 0 : 1;
}
