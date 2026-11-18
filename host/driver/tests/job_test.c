#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <string.h>
#include "../rx25_job.h"

static unsigned tests;
#define CHECK(condition) do { tests++; if (!(condition)) { \
    printf("FAIL job line %u: %s\n", __LINE__, #condition); return 1; } } while (0)

int main(int argc, char **argv)
{
    RX25_DMA_INFO local = {0};
    RX25_JOB_REQUEST request = {0}, saved;
    RX25_JOB_PLAN plan;
    RX25_JOB_CQ cq = {0};
    enum RX25_JOB_STATE state;
    FILE *vectors = NULL;
    unsigned n, word;
    CHECK(sizeof(request) == 64 && sizeof(plan) == 152 && sizeof(cq) == 32);
    CHECK(IOCTL_RX25_DMA_PLAN == 0x22E40C);
    local.Size = sizeof(local); local.Version = 1; local.Role = 1; local.Caps = 0xF;
    local.BufferBytes = 8192; local.CqOffset = 4096; local.BufferId = 17;
    local.DmaAddress = 0x12345678000ULL; local.Status = 2;
    request.Size = sizeof(request); request.Version = 1; request.BufferId = 17;
    request.PeerBufferId = 29; request.PeerDmaAddress = 0x23456789000ULL;
    request.PeerBufferBytes = 8192; request.RequestId = 0x10203040;
    request.Generation = 0x1234; request.Length = 16; request.TimeoutUs = 100000;
    saved = request;
    if (argc == 2 && fopen_s(&vectors, argv[1], "w")) return 1;
    for (n = 0; n < 2; n++) {
        request.Length = n ? 128 : 16;
        request.SourceOffset = n ? 0xF80 : 0x30;
        request.TargetOffset = n ? 0x100 : 0;
        request.RequestId = saved.RequestId + n;
        request.Generation = saved.Generation + n;
        CHECK(Rx25JobPlan(&request, &local, &plan));
        CHECK(plan.Flags == 3 && plan.WriteCount == 7 && plan.Reserved == 0);
        CHECK(plan.Descriptor[0] == (n ? 0x56789F80u : 0x56789030u));
        CHECK(plan.Descriptor[1] == 0x234);
        CHECK(plan.Descriptor[2] == (n ? 0x45678100u : 0x45678000u));
        CHECK(plan.Descriptor[3] == 0x123);
        CHECK(plan.Descriptor[4] == 0x10203040 + n);
        CHECK(plan.Descriptor[5] == (n ? 0x00801235u : 0x00101234u));
        CHECK(plan.Descriptor[6] == 1 && plan.Descriptor[7] == 0);
        CHECK(plan.CqDmaAddress == (n ? 0x12345679100ULL : 0x12345679000ULL));
        CHECK(plan.FenceReadOffset == 0x10 && plan.DoorbellOffset == 0x1018 && plan.DoorbellValue == 1);
        for (word = 0; word < 7; word++) {
            CHECK(plan.Writes[word].Offset == (word == 6 ? 0x101C : 0x1000 + word * 4));
            CHECK(plan.Writes[word].Offset != plan.DoorbellOffset);
        }
        if (vectors) for (word = 0; word < 8; word++) fprintf(vectors, "%08lx\n", plan.Descriptor[word]);
        cq.RequestId = request.RequestId; cq.Publish = 0x10000 | request.Generation;
        cq.Bytes = request.Length; cq.Sequence = n;
        CHECK(Rx25JobCompletion(&request, &cq, 0, 0, n) == Rx25CqPending);
        CHECK(Rx25JobCompletion(&request, &cq, 0, cq.Publish, n) == Rx25CqPending);
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n) == Rx25CqSuccess);
        cq.RequestId++;
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n) == Rx25CqInvalid);
        cq.RequestId--;
        cq.Publish--;
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n) == Rx25CqStale);
        cq.Publish++;
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n + 1) == Rx25CqInvalid);
        cq.Bytes--;
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n) == Rx25CqInvalid);
        cq.Bytes++;
        cq.ErrorDetail = 1;
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n) == Rx25CqInvalid);
        cq.ErrorDetail = 0;
        cq.Reserved[2] = 1;
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n) == Rx25CqInvalid);
        cq.Reserved[2] = 0;
        cq.Publish = 0x40000 | request.Generation; cq.Bytes = 0;
        CHECK(Rx25JobCompletion(&request, &cq, cq.Publish, cq.Publish, n) == Rx25CqHardwareError);
    }
    if (vectors && fclose(vectors)) return 1;
    request = saved;
#define REJECT(field, value) do { request = saved; request.field = value; \
    CHECK(!Rx25JobPlan(&request, &local, &plan)); } while (0)
    REJECT(Size, 63); REJECT(Version, 2); REJECT(Reserved, 1);
    REJECT(BufferId, 18); REJECT(PeerBufferId, 0); REJECT(PeerBufferBytes, 4096);
    REJECT(PeerDmaAddress, 0xFFFFFFFFFFFFF000ULL);
    REJECT(PeerDmaAddress, 0x23456789004ULL);
    REJECT(RequestId, 0); REJECT(Generation, 0); REJECT(Generation, 65536);
    REJECT(Length, 0); REJECT(Length, 32); REJECT(TimeoutUs, 999); REJECT(TimeoutUs, 10000001);
    REJECT(SourceOffset, 8192); REJECT(SourceOffset, 0xFFFFFFF0); REJECT(SourceOffset, 4);
    REJECT(TargetOffset, 4096); REJECT(TargetOffset, 4080); REJECT(TargetOffset, 4);
    request = saved; request.Length = 128; request.SourceOffset = 0xFF0;
    CHECK(!Rx25JobPlan(&request, &local, &plan)); /* Current MRd cannot cross 4KiB. */
    request.SourceOffset = 0x1000;
    CHECK(Rx25JobPlan(&request, &local, &plan));
    request = saved; request.PeerDmaAddress = local.DmaAddress;
    CHECK(Rx25JobPlan(&request, &local, &plan)); /* Different address domains. */
    local.Role = 2;
    CHECK(!Rx25JobPlan(&request, &local, &plan));
    local.Role = 1; local.Control = 1;
    CHECK(!Rx25JobPlan(&request, &local, &plan));
    local.Control = 0; local.Status = 0x102;
    CHECK(!Rx25JobPlan(&request, &local, &plan));
    local.Status = 2;
    state = Rx25JobNext(Rx25JobIdle, Rx25EventPrepare);
    CHECK(state == Rx25JobPrepared && Rx25JobCanRelease(state, 0, 0));
    state = Rx25JobNext(state, Rx25EventDoorbellAfterFence);
    CHECK(state == Rx25JobInFlight && !Rx25JobCanRelease(state, 0, 0));
    state = Rx25JobNext(state, Rx25EventCompletionSuccess);
    CHECK(state == Rx25JobPublished && !Rx25JobCanRelease(state, 0, 0));
    state = Rx25JobNext(state, Rx25EventPayloadAndGuardsMatch);
    CHECK(state == Rx25JobVerified && !Rx25JobCanRelease(state, 1, 0));
    CHECK(!Rx25JobCanRelease(state, 0, 1) && Rx25JobCanRelease(state, 1, 1));
    state = Rx25JobNext(Rx25JobInFlight, Rx25EventFailureOrTimeout);
    CHECK(state == Rx25JobQuarantined);
    CHECK(Rx25JobNext(state, Rx25EventCompletionSuccess) == Rx25JobQuarantined);
    CHECK(Rx25JobNext(state, Rx25EventPrepare) == Rx25JobQuarantined);
    CHECK(!Rx25JobCanRelease(state, 0, 0) && !Rx25JobCanRelease(state, 1, 0));
    CHECK(Rx25JobCanRelease(state, 1, 1));
    CHECK(Rx25JobNext(Rx25JobIdle, Rx25EventCompletionSuccess) == Rx25JobQuarantined);
    /* Exhaust every event prefix of length five. Once armed, local busy/idle
     * is deliberately absent from release criteria; both mappings must end. */
    for (n = 0; n < 3125; n++) {
        unsigned prefix = n, step;
        int armed = 0;
        state = Rx25JobIdle;
        for (step = 0; step < 5; step++) {
            enum RX25_JOB_EVENT event = (enum RX25_JOB_EVENT)(prefix % 5);
            prefix /= 5;
            if (state == Rx25JobPrepared && event == Rx25EventDoorbellAfterFence) armed = 1;
            state = Rx25JobNext(state, event);
            if (armed) CHECK(!Rx25JobCanRelease(state, 0, 0));
            if (state == Rx25JobQuarantined) CHECK(Rx25JobNext(state, Rx25EventCompletionSuccess) == state);
        }
    }
    printf("PASS %u job/CQ/lifecycle assertions; vectors=2; no hardware I/O\n", tests);
    return 0;
}
