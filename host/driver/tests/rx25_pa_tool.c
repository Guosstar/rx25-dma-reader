/* rx25_pa_tool -- one descriptor submit, one read of a peer physical address.
 *
 * Deliberately narrow: no loop, no retry, no scan in this build.  It exists to
 * make D1/D2 of PROJECT_GOAL_DRIVERLESS_PA.md measurable with a single
 * observable event:
 *
 *   1 QUERY            buffer id + physical address of the 8 KiB common buffer
 *   2 REGREAD 0x0C     current control word (ENABLE is off after a fresh load)
 *   3 CONTROL 0x1      arm the descriptor engine; without this no slot is ever
 *                      latched and job_valid never rises
 *   4 READ 0x1000/32   CQ baseline: the generation the peer last published
 *   5 WRITE 0x0000     poison the data page so a "no DMA happened" read is
 *                      distinguishable from a read that returned 0x00
 *   6 SUBMIT           remote_pa = the address under test, host_iova = our
 *                      own buffer, generation = baseline + 1
 *   7 poll CQ          until generation matches or the timeout expires
 *   8 READ 0x0000      the bytes the peer actually produced
 *   9 CONTROL old      restore so other tools keep their "idle" invariant
 *
 * Exit code 0 only when status == 1 (success), bytes == requested length, and
 * the CQ generation matched.  Everything else is a failure with a reason code,
 * because "the read returned something" is not the same as "the read worked".
 */
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <errno.h>
#include <string.h>
#include "../rx25dma_public.h"

#define CQ_OFFSET 0x1000u
#define DATA_OFFSET 0x0000u
#define POISON 0xCCu

static HANDLE device;
static ULONGLONG bufferId;

static int Query(RX25_DMA_INFO *info)
{
    DWORD bytes = 0;
    if (!DeviceIoControl(device, IOCTL_RX25_DMA_QUERY, NULL, 0, info, sizeof(*info), &bytes, NULL))
        return 0;
    return bytes == sizeof(*info) && info->Size == sizeof(*info) && info->Version == 1 &&
           info->BufferId != 0 && info->BufferBytes == RX25_DMA_BYTES;
}

static int RegRead(ULONG offset, ULONG *value)
{
    RX25_DMA_REG reg = {sizeof(reg), 1, 0, 0, 0};
    DWORD bytes = 0;
    reg.BufferId = bufferId;
    reg.Offset = offset;
    return DeviceIoControl(device, IOCTL_RX25_DMA_REGREAD, &reg, sizeof(reg),
                           value, sizeof(*value), &bytes, NULL) && bytes == sizeof(*value);
}

static int ControlWrite(ULONG value)
{
    RX25_DMA_CONTROL control = {sizeof(control), 1, 0, 0, 0};
    DWORD bytes = 0;
    control.BufferId = bufferId;
    control.Value = value;
    return DeviceIoControl(device, IOCTL_RX25_DMA_CONTROL, &control, sizeof(control),
                           NULL, 0, &bytes, NULL) != 0;
}

static int BufferRead(ULONG offset, void *dst, ULONG length)
{
    RX25_DMA_TRANSFER transfer = {sizeof(transfer), 1, 0, 0, 0};
    DWORD bytes = 0;
    transfer.BufferId = bufferId;
    transfer.Offset = offset;
    transfer.Length = length;
    return DeviceIoControl(device, IOCTL_RX25_DMA_READ, &transfer, sizeof(transfer),
                           dst, length, &bytes, NULL) && bytes == length;
}

static int BufferWrite(ULONG offset, const void *src, ULONG length)
{
    RX25_DMA_TRANSFER transfer = {sizeof(transfer), 1, 0, 0, 0};
    UCHAR packet[sizeof(transfer) + 256];
    DWORD bytes = 0;
    transfer.BufferId = bufferId;
    transfer.Offset = offset;
    transfer.Length = length;
    /* The driver wants the header and the payload contiguous in the INPUT
     * buffer and no output buffer at all; passing the payload as the output
     * buffer is rejected before anything is copied. */
    if (length > 256) return 0;
    memcpy(packet, &transfer, sizeof(transfer));
    memcpy(packet + sizeof(transfer), src, length);
    return DeviceIoControl(device, IOCTL_RX25_DMA_WRITE, packet,
                           (DWORD)(sizeof(transfer) + length), NULL, 0, &bytes, NULL) != 0;
}

static int Submit(ULONG slot, ULONGLONG remotePa, ULONGLONG hostIova, ULONG length,
                  ULONG requestId, USHORT generation)
{
    RX25_DMA_SUBMIT submit;
    DWORD bytes = 0;
    ZeroMemory(&submit, sizeof(submit));
    submit.Size = sizeof(submit);
    submit.Version = RX25_DMA_ABI_VERSION;
    submit.BufferId = bufferId;
    submit.Slot = slot;
    submit.Length = length;
    submit.RemotePa = remotePa;
    submit.HostIova = hostIova;
    submit.RequestId = requestId;
    submit.Generation = generation;
    return DeviceIoControl(device, IOCTL_RX25_DMA_SUBMIT, &submit, sizeof(submit),
                           NULL, 0, &bytes, NULL) != 0;
}

static ULONGLONG NowMs(void)
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (ULONGLONG)((c.QuadPart * 1000ull) / f.QuadPart);
}

int wmain(int argc, wchar_t **argv)
{
    RX25_DMA_INFO info;
    UCHAR cq[32], data[256], poison[256];
    ULONG controlBefore = 0, controlAfter = 0, ready = 0, cqGen = 0, cqStatus = 0;
    ULONG cqBytes = 0, cqSeq = 0, cqDetail = 0;
    ULONG counters[8] = {0}, countersAfter[8] = {0};
    ULONGLONG remotePa = 0, hostIova;
    ULONG length = 128, offsetArg = 0, waited, changed = 0, index;
    wchar_t *devicePath = NULL, *outputPath = NULL, *end;
    ULONG regFrom = 0, regCount = 0;
    int regMode = 0;
    USHORT generation;
    HANDLE out = INVALID_HANDLE_VALUE;
    int pass = 0, stage = 0, i, probe = 0, reported = 0, controlWritten = 0, skipArm = 0;
    ULONG armValue = 1;

    for (i = 1; i < argc; i++) {
        if (!wcscmp(argv[i], L"--device") && i + 1 < argc) devicePath = argv[++i];
        else if (!wcscmp(argv[i], L"--read-pa") && i + 1 < argc) {
            errno = 0; remotePa = _wcstoui64(argv[++i], &end, 0);
            if (errno || *end || argv[i][0] == L'-') { fprintf(stderr, "bad --read-pa\n"); return 2; }
        } else if (!wcscmp(argv[i], L"--length") && i + 1 < argc) {
            errno = 0; length = wcstoul(argv[++i], &end, 0);
            if (errno || *end || length < 16 || length > 256 || (length & 15u)) {
                fprintf(stderr, "bad --length\n"); return 2;
            }
        } else if (!wcscmp(argv[i], L"--slot") && i + 1 < argc) {
            errno = 0; offsetArg = wcstoul(argv[++i], &end, 0);
            if (errno || *end || offsetArg >= RX25_SLOT_COUNT) { fprintf(stderr, "bad --slot\n"); return 2; }
        } else if (!wcscmp(argv[i], L"--output") && i + 1 < argc) outputPath = argv[++i];
        else if (!wcscmp(argv[i], L"--probe")) probe = 1;
        else if (!wcscmp(argv[i], L"--armtest") && i + 1 < argc) {
            probe = 2;
            errno = 0; armValue = wcstoul(argv[++i], &end, 0);
            if (errno || *end || (armValue & ~5u)) { fprintf(stderr, "bad --armtest value\n"); return 2; }
        }
        else if (!wcscmp(argv[i], L"--skip-arm")) skipArm = 1;
        else if (!wcscmp(argv[i], L"--regs") && i + 1 < argc) {
            wchar_t *spec = argv[++i];
            wchar_t *colon = wcschr(spec, L':');
            if (!colon) { fprintf(stderr, "bad --regs, want FROM:COUNT\n"); return 2; }
            *colon = 0;
            errno = 0; regFrom = wcstoul(spec, &end, 0);
            if (errno || *end) { fprintf(stderr, "bad --regs from\n"); return 2; }
            errno = 0; regCount = wcstoul(colon + 1, &end, 0);
            if (errno || *end || regCount == 0 || regCount > 256) { fprintf(stderr, "bad --regs count\n"); return 2; }
            regMode = 1;
        }
        else { fprintf(stderr, "unknown argument\n"); return 2; }
    }
    if (regMode) {
        if (!devicePath) {
            fwprintf(stderr, L"Usage: %ls --device DEVICE_PATH --regs FROM:COUNT\n", argv[0]);
            return 2;
        }
    } else if (!devicePath || !outputPath || (!probe && (remotePa & 15ull))) {
        fwprintf(stderr,
            L"Usage: %ls --device DEVICE_PATH --read-pa ADDRESS [--length N] [--slot N] --output NEW_FILE\n"
            L"       %ls --device DEVICE_PATH --probe --output NEW_FILE\n"
            L"       %ls --device DEVICE_PATH --regs FROM:COUNT\n"
            L"   N: 16..256, multiple of 16.  ADDRESS: 16 B aligned, must not cross a 4 KiB page.\n"
            L"   --probe reads the BAR0 identity and counters only; it writes no register.\n",
            argv[0], argv[0], argv[0]);
        return 2;
    }

    if (!regMode) {
        out = CreateFileW(outputPath, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (out == INVALID_HANDLE_VALUE) { fprintf(stderr, "new output file required: %lu\n", GetLastError()); return 2; }
    }

    device = CreateFileW(devicePath, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, NULL);
    if (device == INVALID_HANDLE_VALUE) { fprintf(stderr, "open failed: %lu\n", GetLastError()); goto done; }
    stage = 1;
    if (!Query(&info)) { fprintf(stderr, "QUERY rejected\n"); goto done; }
    bufferId = info.BufferId;
    hostIova = info.DmaAddress;

    if (info.Role != RX25_DMA_ROLE_A && !regMode) {
        fprintf(stderr, "wrong role %lu (expected A=%u): read path disabled\n",
                info.Role, RX25_DMA_ROLE_A);
        goto done;
    }

    if (regMode) {
        ULONG k;
        printf("BAR0 register dump 0x%03lx .. 0x%03lx\n", regFrom, regFrom + (regCount - 1) * 4);
        for (k = 0; k < regCount; k++) {
            ULONG off = regFrom + k * 4, v = 0xdeadbeef;
            if (RegRead(off, &v)) printf("  0x%03lx  0x%08lx\n", off, v);
            else                   printf("  0x%03lx  READ_FAIL\n", off);
        }
        CloseHandle(device);
        return 0;
    }

    stage = 2;
    if (!RegRead(0x00, &ready) || ready != 0x35325852u) { fprintf(stderr, "BAR0 magic wrong\n"); goto done; }
    if (!RegRead(0x10, &ready)) goto done;
    if (!(ready & 1u)) { fprintf(stderr, "engine not READY before arm: status=0x%08lx\n", ready); }
    if (!RegRead(0x0c, &controlBefore)) goto done;

    for (i = 0; i < 8; i++) {
        static const ULONG counterOffsets[8] = {0x24, 0x28, 0x2c, 0x34, 0x38, 0x3c, 0x40, 0x44};
        if (!RegRead(counterOffsets[i], &counters[i])) goto done;
    }

    if (probe == 2) {
        /* Arm the engine and watch what each individual BAR access does.
         * One write, then ten rounds of (magic, control, status): if magic
         * stays 0x35325852 the read path survived; if control/status move,
         * the write landed.  Nothing else is touched. */
        ULONG mc = 0, ct = 0, st = 0;
        DWORD dumped = 0;
        char line[160];
        int n;
        n = sprintf_s(line, sizeof(line), "armtest before: ctl=0x%08lx st=0x%08lx\n", controlBefore, ready);
        WriteFile(out, line, (DWORD)n, &dumped, NULL); printf("%s", line);
        if (!ControlWrite(armValue)) { fprintf(stderr, "CONTROL write rejected\n"); goto done; }
        controlWritten = 1;
        for (i = 0; i < 10; i++) {
            int okm = RegRead(0x00, &mc);
            int okc = RegRead(0x0c, &ct);
            int oks = RegRead(0x10, &st);
            n = sprintf_s(line, sizeof(line), "armtest %2d: magic=%s0x%08lx ctl=%s0x%08lx st=%s0x%08lx\n",
                          i, okm ? "" : "ERR ", mc, okc ? "" : "ERR ", ct, oks ? "" : "ERR ", st);
            WriteFile(out, line, (DWORD)n, &dumped, NULL); printf("%s", line);
            Sleep(20);
        }
        ControlWrite(controlBefore);
        controlWritten = 0;
        pass = (mc == 0x35325852u);
        goto done;
    }
    if (probe) {
        char report[1024];
        int n = 0;
        DWORD dumped = 0;
        n += sprintf_s(report + n, sizeof(report) - n,
            "rx25_pa_tool probe (read only, no register written)\n"
            "  device         %ls\n"
            "  buffer_id      0x%I64x\n"
            "  dma_address    0x%I64x\n"
            "  caps           0x%08lx\n"
            "  control        0x%08lx\n"
            "  status         0x%08lx\n"
            "  success=%lu parser=%lu reject=%lu timeout=%lu stale=%lu good=%lu bad=%lu ovf=%lu\n",
            devicePath, bufferId, hostIova, info.Caps, controlBefore, ready,
            counters[0], counters[1], counters[2], counters[3], counters[4],
            counters[5], counters[6], counters[7]);
        WriteFile(out, report, (DWORD)n, &dumped, NULL);
        printf("%s", report);
        pass = 1;
        goto done;
    }

    stage = 3;
    if (skipArm) {
        controlAfter = controlBefore;
        fprintf(stderr, "skip-arm: CONTROL left at 0x%08lx\n", controlBefore);
    } else {
    if (!ControlWrite(1u)) { fprintf(stderr, "CONTROL write rejected\n"); goto done; }
    controlWritten = 1;
    /* Two independent witnesses for the same event.  0x0C is the control word
     * itself; 0x10 bit0 is READY, which the hardware only computes as
     * link_up && control_enable.  If either one shows the write took, the
     * engine is armed -- and the write must then be undone before exiting,
     * because the driver refuses to start a device whose control word is not
     * zero (Idle() in rx25dma.c). */
    for (i = 0; i < 200; i++) {
        if (!RegRead(0x0c, &controlAfter)) break;
        if (controlAfter == 1u) break;
        if (!RegRead(0x10, &ready)) break;
        if (ready & 1u) { controlAfter = 1u; break; }
        Sleep(1);
    }
    if (controlAfter != 1u) {
        fprintf(stderr, "control did not take: 0x%08lx status=0x%08lx (continuing)\n",
                controlAfter, ready);
    }
    }

    stage = 4;
    if (!BufferRead(CQ_OFFSET, cq, sizeof(cq))) { fprintf(stderr, "CQ baseline read failed\n"); goto done; }
    memcpy(&cqSeq, cq + 0x00, 4);
    memcpy(&cqGen, cq + 0x04, 4);
    generation = (USHORT)((cqGen & 0xffffu) + 1u);

    stage = 5;
    memset(poison, POISON, sizeof(poison));
    if (!BufferWrite(DATA_OFFSET, poison, length)) { fprintf(stderr, "poison write failed\n"); goto done; }

    stage = 6;
    if (!Submit(offsetArg, remotePa, hostIova, length, 0x5041u | ((ULONG)generation << 16), generation)) {
        fprintf(stderr, "SUBMIT rejected\n"); goto done;
    }

    stage = 7;
    {
        ULONGLONG start = NowMs();
        int matched = 0;
        while (NowMs() - start < 4000) {
            if (!BufferRead(CQ_OFFSET, cq, sizeof(cq))) {
                ULONG probeSt = 0, probeCtl = 0;
                int okSt = RegRead(0x10, &probeSt);
                int okCtl = RegRead(0x0c, &probeCtl);
                fprintf(stderr, "CQ poll read failed, winerr=%lu; regread st=%d/0x%08lx ctl=%d/0x%08lx\n",
                        GetLastError(), okSt, probeSt, okCtl, probeCtl);
                break;
            }
            memcpy(&cqSeq, cq + 0x00, 4);
            memcpy(&cqGen, cq + 0x04, 4);
            memcpy(&cqBytes, cq + 0x08, 4);
            memcpy(&cqDetail, cq + 0x10, 4);
            if ((cqGen & 0xffffu) == generation) { matched = 1; break; }
            Sleep(1);
        }
        waited = (ULONG)(NowMs() - start);
        cqStatus = (cqGen >> 16) & 0xffffu;
        if (!matched) { fprintf(stderr, "CQ generation never matched %u (last 0x%08lx) after %lu ms\n",
                                 generation, cqGen, waited); goto done; }
    }

    stage = 8;
    if (!BufferRead(DATA_OFFSET, data, length)) { fprintf(stderr, "data read failed\n"); goto done; }
    for (index = 0; index < length; index++) if (data[index] != POISON) changed++;

    for (i = 0; i < 8; i++) {
        static const ULONG counterOffsets[8] = {0x24, 0x28, 0x2c, 0x34, 0x38, 0x3c, 0x40, 0x44};
        RegRead(counterOffsets[i], &countersAfter[i]);
    }

    pass = cqStatus == 1u && cqBytes == length;

    stage = 9;
    if (controlWritten) { ControlWrite(controlBefore); controlWritten = 0; }

    {
        char report[4096];
        int n = 0;
        n += sprintf_s(report + n, sizeof(report) - n,
            "rx25_pa_tool attempt\n"
            "  device            %ls\n"
            "  buffer_id         0x%I64x\n"
            "  dma_address       0x%I64x\n"
            "  remote_pa         0x%I64x  (page offset 0x%03lx)\n"
            "  length            %lu\n"
            "  slot              %lu\n"
            "  control before    0x%08lx  after arm 0x%08lx  restored\n"
            "  cq generation     %u (baseline 0x%08lx)\n"
            "  cq status         %lu%s\n"
            "  cq bytes          %lu\n"
            "  cq sequence       %lu\n"
            "  cq detail         0x%08lx\n"
            "  waited_ms         %lu\n"
            "  bytes changed     %lu / %lu\n"
            "  counters before   success=%lu parser=%lu reject=%lu timeout=%lu stale=%lu good=%lu bad=%lu ovf=%lu\n"
            "  counters after    success=%lu parser=%lu reject=%lu timeout=%lu stale=%lu good=%lu bad=%lu ovf=%lu\n"
            "  verdict           %s\n",
            devicePath, bufferId, hostIova, remotePa, (unsigned long)(remotePa & 0xfffull), length, offsetArg,
            controlBefore, controlAfter, generation, cqGen & 0xffffu,
            cqStatus, cqStatus == 1 ? " (success)" : cqStatus == 4 ? " (timeout on peer)" :
                                     cqStatus == 2 ? " (parser error)" : cqStatus == 3 ? " (parser error)" : " (unexpected)",
            cqBytes, cqSeq, cqDetail, waited, changed, length,
            counters[0], counters[1], counters[2], counters[3], counters[4], counters[5], counters[6], counters[7],
            countersAfter[0], countersAfter[1], countersAfter[2], countersAfter[3], countersAfter[4],
            countersAfter[5], countersAfter[6], countersAfter[7],
            pass ? "PASS" : "FAIL");
        {
            DWORD dumped = 0;
            WriteFile(out, report, (DWORD)n, &dumped, NULL);
        }
        printf("%s", report);
        reported = 1;
    }

    {
        ULONG written = 0;
        WriteFile(out, "\nhex dump (first 256 B of the data page)\n",
                  (DWORD)(sizeof("\nhex dump (first 256 B of the data page)\n") - 1), &written, NULL);
        for (index = 0; index < length; index += 16) {
            char line[128];
            int n = sprintf_s(line, sizeof(line), "%04lx  ", index);
            ULONG k;
            for (k = 0; k < 16 && index + k < length; k++) n += sprintf_s(line + n, sizeof(line) - n, "%02x ", data[index + k]);
            n += sprintf_s(line + n, sizeof(line) - n, "\n");
            WriteFile(out, line, (DWORD)n, &written, NULL);
            printf("%s", line);
        }
    }

done:
    if (controlWritten) ControlWrite(controlBefore);
    if (!reported && device != INVALID_HANDLE_VALUE) {
        ULONG ctl = 0xdeadbeef, st = 0xdeadbeef, ctr[8] = {0};
        static const ULONG off[8] = {0x24, 0x28, 0x2c, 0x34, 0x38, 0x3c, 0x40, 0x44};
        RegRead(0x0c, &ctl);
        RegRead(0x10, &st);
        for (i = 0; i < 8; i++) RegRead(off[i], &ctr[i]);
        printf("RX25_PA_DIAG stage=%d control=0x%08lx status=0x%08lx "
               "success=%lu parser=%lu reject=%lu timeout=%lu stale=%lu good=%lu bad=%lu ovf=%lu\n",
               stage, ctl, st, ctr[0], ctr[1], ctr[2], ctr[3], ctr[4], ctr[5], ctr[6], ctr[7]);
    }
    if (device != INVALID_HANDLE_VALUE) CloseHandle(device);
    if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
    printf("RX25_PA_%s stage=%d remote_pa=0x%I64x status=%lu bytes=%lu changed=%lu\n",
           pass ? "PASS" : "FAIL", stage, remotePa, cqStatus, cqBytes, changed);
    return pass ? 0 : 1;
}
