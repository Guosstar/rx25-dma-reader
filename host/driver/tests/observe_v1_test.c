#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <string.h>
#include "../rx25_observe_v1.h"

static unsigned checks;
static RX25_DMA_INFO local;
static RX25_JOB_REQUEST job;
static RX25_DMA_SNAPSHOT sample;
static UCHAR baseline[8192];
#define CHECK(c) do { checks++; if (!(c)) { printf("FAIL observe-v1 line %u: %s\n", __LINE__, #c); return 1; } } while (0)
static void put32(UCHAR *p, ULONG v)
{
    unsigned k;
    for (k = 0; k < 4; k++) p[k] = (UCHAR)(v >> (k * 8));
}
static void fixture(ULONG length)
{
    ULONG k, cqOffset;
    memset(&local, 0, sizeof(local)); memset(&job, 0, sizeof(job)); memset(&sample, 0, sizeof(sample));
    local.Size = sizeof(local); local.Version = 1; local.Flags = 31;
    local.Role = 1; local.Caps = 15; local.BufferBytes = 8192; local.CqOffset = 4096;
    local.BufferId = 17; local.DmaAddress = 0x12345678000ULL; local.Status = 2;
    job.Size = sizeof(job); job.Version = 1; job.BufferId = 17; job.PeerBufferId = 29;
    job.PeerDmaAddress = 0x23456789000ULL; job.PeerBufferBytes = 8192;
    job.SourceOffset = length == 16 ? 0x30 : 0xf80;
    job.TargetOffset = length == 16 ? 0 : 0x100;
    job.Length = length; job.RequestId = 0x10203040; job.Generation = 0x1234; job.TimeoutUs = 100000;
    cqOffset = 4096 + job.TargetOffset;
    for (k = 0; k < 8192; k++) baseline[k] = (UCHAR)(k * 37 + 19);
    memset(baseline + cqOffset, 0, 32);
    sample.Size = sizeof(sample); sample.Version = 1; sample.Flags = 7; sample.BufferBytes = 8192;
    sample.BufferId = local.BufferId; sample.DmaAddress = local.DmaAddress; sample.CqOffset = cqOffset;
    sample.FirstPublish = sample.LastPublish = 0x11234;
    memcpy(sample.Image, baseline, 8192);
    for (k = 0; k < length; k++) {
        ULONGLONG word = 0xa5a5000000000000ULL | (k / 8);
        sample.Image[job.TargetOffset + k] = (UCHAR)(word >> ((k & 7) * 8));
    }
    put32(sample.Image + cqOffset, job.RequestId);
    put32(sample.Image + cqOffset + 4, sample.FirstPublish);
    put32(sample.Image + cqOffset + 8, length);
    put32(sample.Image + cqOffset + 12, 7);
}
static enum RX25_OBSERVE_V1_RESULT verdict(ULONG *offset)
{
    return Rx25ObserveV1Check(&local, &job, 7, baseline, 8192, &sample, sizeof(sample), offset);
}
static int replay(const char *path)
{
    FILE *f = NULL;
    UCHAR magic[8];
    ULONG count, k, expected, sequence, offset;
    if (fopen_s(&f, path, "rb") || !f) return 1;
    CHECK(fread(magic, 1, 8, f) == 8 && !memcmp(magic, "RX25V1F1", 8));
    CHECK(fread(&count, 4, 1, f) == 1 && count && count <= 256);
    for (k = 0; k < count; k++) {
        CHECK(fread(&expected, 4, 1, f) == 1 && expected <= Rx25ObserveV1HardwareError);
        CHECK(fread(&sequence, 4, 1, f) == 1);
        CHECK(fread(&local, sizeof(local), 1, f) == 1);
        CHECK(fread(&job, sizeof(job), 1, f) == 1);
        CHECK(fread(baseline, 8192, 1, f) == 1);
        CHECK(fread(&sample, sizeof(sample), 1, f) == 1);
        CHECK((ULONG)Rx25ObserveV1Check(&local, &job, sequence, baseline, 8192,
                                      &sample, sizeof(sample), &offset) == expected);
    }
    CHECK(fgetc(f) == EOF && !ferror(f));
    CHECK(fclose(f) == 0);
    printf("RX25_OBSERVE_V1_REPLAY_PASS records=%lu CPU_fixtures_only=1 dma_submitted=0 release_allowed=0\n", count);
    return 0;
}
int main(int argc, char **argv)
{
    ULONG offset, k, bit, length;
    RX25_DMA_SNAPSHOT_REQUEST request = {24, 1, 17, 4096, 0};
    CHECK(sizeof(RX25_DMA_SNAPSHOT_REQUEST) == 24 && sizeof(sample) == 8240);
    CHECK(FIELD_OFFSET(RX25_DMA_SNAPSHOT, Image) == 48 && IOCTL_RX25_DMA_SNAPSHOT == 0x22e414);
    CHECK(Rx25DmaValidSnapshot(&request, 17, 8192));
    request.CqOffset = 8160; CHECK(Rx25DmaValidSnapshot(&request, 17, 8192));
    request.CqOffset = 8176; CHECK(!Rx25DmaValidSnapshot(&request, 17, 8192));
    request.CqOffset = 4097; CHECK(!Rx25DmaValidSnapshot(&request, 17, 8192));
    request.CqOffset = 4080; CHECK(!Rx25DmaValidSnapshot(&request, 17, 8192));
    request.CqOffset = 4096; request.Reserved = 1; CHECK(!Rx25DmaValidSnapshot(&request, 17, 8192));
    request.Reserved = 0; CHECK(!Rx25DmaValidSnapshot(&request, 18, 8192));
    CHECK(!Rx25DmaValidSnapshot(&request, 0, 8192));
    CHECK(!Rx25DmaValidSnapshot(&request, 17, 4096));
    request.Size--; CHECK(!Rx25DmaValidSnapshot(&request, 17, 8192)); request.Size++;
    request.Version++; CHECK(!Rx25DmaValidSnapshot(&request, 17, 8192));
    for (length = 16; length <= 128; length *= 8) {
        fixture(length); CHECK(verdict(&offset) == Rx25ObserveV1FixtureMatch && offset == ~0u);
        /* Every bit of the full image must affect acceptance, including all guards and CQ. */
        for (k = 0; k < 8192; k++) for (bit = 0; bit < 8; bit++) {
            sample.Image[k] ^= (UCHAR)(1u << bit);
            CHECK(verdict(&offset) != Rx25ObserveV1FixtureMatch);
            sample.Image[k] ^= (UCHAR)(1u << bit);
        }
        sample.Image[job.TargetOffset] ^= 1;
        CHECK(verdict(&offset) == Rx25ObserveV1DataMismatch && offset == job.TargetOffset);
        sample.Image[job.TargetOffset] ^= 1;
        sample.Image[8191] ^= 1;
        CHECK(verdict(&offset) == Rx25ObserveV1GuardMismatch && offset == 8191);
        sample.Image[8191] ^= 1;
        sample.FirstPublish = 0; sample.Flags = 3;
        CHECK(verdict(&offset) == Rx25ObserveV1Pending);
        sample.FirstPublish = sample.LastPublish; sample.Flags = 3;
        CHECK(verdict(&offset) == Rx25ObserveV1Invalid); /* No falsely missing stable flag. */
        fixture(length); sample.FirstPublish++; sample.LastPublish++;
        put32(sample.Image + sample.CqOffset + 4, sample.FirstPublish);
        CHECK(verdict(&offset) == Rx25ObserveV1Stale);
        fixture(length); sample.BufferId++;
        CHECK(verdict(&offset) == Rx25ObserveV1Invalid);
        fixture(length); sample.DmaAddress += 4096;
        CHECK(verdict(&offset) == Rx25ObserveV1Invalid);
        fixture(length); sample.Reserved = 1;
        CHECK(verdict(&offset) == Rx25ObserveV1Invalid);
        fixture(length); sample.Flags |= 8;
        CHECK(verdict(&offset) == Rx25ObserveV1Invalid);
        fixture(length); sample.Flags &= ~RX25_SNAPSHOT_NEVER_ARMED;
        CHECK(verdict(&offset) == Rx25ObserveV1Invalid);
        fixture(length); baseline[sample.CqOffset] = 1;
        CHECK(verdict(&offset) == Rx25ObserveV1Invalid);
        fixture(length);
        CHECK(Rx25ObserveV1Check(&local, &job, 7, baseline, 8191, &sample, sizeof(sample), &offset) == Rx25ObserveV1Invalid);
        CHECK(Rx25ObserveV1Check(&local, &job, 7, baseline, 8192, &sample, sizeof(sample)-1, &offset) == Rx25ObserveV1Invalid);
        CHECK(Rx25ObserveV1Check(NULL, &job, 7, baseline, 8192, &sample, sizeof(sample), &offset) == Rx25ObserveV1Invalid);
        CHECK(Rx25ObserveV1Check(&local, &job, 7, baseline, 8192, &sample, sizeof(sample), NULL) == Rx25ObserveV1FixtureMatch);
        CHECK(Rx25ObserveV1Check(&local, &job, 8, baseline, 8192, &sample, sizeof(sample), &offset) == Rx25ObserveV1Invalid);
    }
    printf("RX25_OBSERVE_V1_TEST_PASS checks=%u image_bit_corruptions=131072 CPU_fixtures_only=1 dma_submitted=0\n", checks);
    if (argc == 3 && !strcmp(argv[1], "--fixtures")) return replay(argv[2]);
    return argc == 1 ? 0 : 1;
}
