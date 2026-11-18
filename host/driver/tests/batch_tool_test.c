/* Reuse the tool's exact result verifier without calling its hardware entry. */
#define wmain Rx25BatchHardwareEntryNotCalled
#include "batch_diag_tool.c"
#undef wmain

static unsigned tests;
#define CHECK(c) do { tests++; if (!(c)) { printf("FAIL %u: %s\n", __LINE__, #c); return 1; } } while (0)

static void SetPressure(ULONG *p, ULONG nonce, ULONG packets)
{
    ZeroMemory(p, 16 * sizeof(*p));
    p[0] = RX25_PRESSURE_SIGNATURE; p[1] = 0x1d5; p[2] = nonce;
    p[3] = p[4] = p[7] = p[8] = p[15] = packets;
    p[5] = p[6] = 4 * packets;
    p[9] = p[10] = p[11] = 40; p[12] = 1;
}

int main(void)
{
    RX25_BATCH_RESULT good = {0}, r;
    ULONG nonce = 0x25111400;
    unsigned i, j;
    good.Size = sizeof(good); good.Version = 1; good.BufferId = 1;
    good.Batch[0] = RX25_BATCH_SIGNATURE; good.Batch[1] = 0xe9; good.Batch[2] = nonce;
    good.Batch[3] = good.Batch[4] = 32; good.Batch[5] = 512; good.Batch[6] = 0xffffffff;
    good.Batch[7] = 192; good.Batch[8] = 256; good.Batch[11] = 16;
    good.Batch[14] = 32; good.Batch[15] = 16;
    good.Owner[0] = RX25_BATCH_OWNER_SIGNATURE; good.Owner[1] = 1; good.Owner[2] = 0x3b;
    good.Owner[3] = nonce; good.Owner[5] = good.Owner[6] = good.Owner[8] = 3; good.Observations[2] = 1;
    SetPressure(good.LocalPressure, nonce, 96);
    SetPressure(good.PeerPressure, nonce, 128);
    for (i = 0; i < 64; i++) { good.Payload[i*2] = i; good.Payload[i*2+1] = 0xa5a50000; }
    CHECK(FinalPass(&good, nonce));
    CHECK(PressurePass(good.LocalPressure, nonce, 96));
    CHECK(PressurePass(good.PeerPressure, nonce, 128));
    CHECK(!PressurePass(good.LocalPressure, nonce, 128));
    CHECK(!PressurePass(good.PeerPressure, nonce, 96));
    CHECK(!FinalPass(&good, nonce + 32));
    for (i = 0; i < 128; i++) {
        r = good; r.Payload[i] ^= 1;
        CHECK(!FinalPass(&r, nonce));
    }
    for (i = 0; i < 32; i++) {
        r = good; r.Batch[6] ^= 1u << i;
        CHECK(!FinalPass(&r, nonce));
    }
    r = good; r.Batch[5] = 496; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[3]--; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[4]--; CHECK(!FinalPass(&r, nonce));
    r = good; r.Owner[4]++; CHECK(!FinalPass(&r, nonce));
    r = good; r.Owner[7]++; CHECK(!FinalPass(&r, nonce));
    r = good; r.Owner[8]--; CHECK(!FinalPass(&r, nonce));
    r = good; r.Owner[5] = 2; CHECK(!FinalPass(&r, nonce));
    r = good; r.Owner[5] = 4; CHECK(!FinalPass(&r, nonce));
    r = good; r.Owner[6] = 2; CHECK(!FinalPass(&r, nonce));
    r = good; r.Owner[6] = 4; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[7]--; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[7]++; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[8]--; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[8]++; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[11] = 1; CHECK(FinalPass(&r, nonce));
    r = good; r.Batch[11] = 16; CHECK(FinalPass(&r, nonce));
    r = good; r.Batch[11] = 0; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[11] = 17; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[11] = 0xffffffff; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[10]++; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[12]++; CHECK(!FinalPass(&r, nonce));
    r = good; r.Batch[13]++; CHECK(!FinalPass(&r, nonce));
    r = good; r.Observations[2] |= 2; CHECK(!FinalPass(&r, nonce));
    r = good; r.Observations[2] = 0; CHECK(Rx25BatchValidIdentity(&r, 1)); CHECK(!FinalPass(&r, nonce));
    r = good; r.Observations[2] = 2; CHECK(Rx25BatchValidIdentity(&r, 1)); CHECK(!FinalPass(&r, nonce));
    r = good; r.Observations[2] = 3; CHECK(Rx25BatchValidIdentity(&r, 1)); CHECK(!FinalPass(&r, nonce));
    for (i = 0; i < 2; i++) {
        static const unsigned exactFields[] = {3,4,5,6,7,8,14,15};
        ULONG *p;
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[1] |= 8; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[2] += 32; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[9] = 39; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[10] = 39; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[11] = 39; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[12] = 0; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[4]--; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[6]--; CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[8]--; CHECK(!FinalPass(&r, nonce));
        for (j = 0; j < sizeof(exactFields)/sizeof(exactFields[0]); j++) {
            r = good; p = i ? r.PeerPressure : r.LocalPressure;
            p[exactFields[j]]++; CHECK(!FinalPass(&r, nonce));
            r = good; p = i ? r.PeerPressure : r.LocalPressure;
            p[exactFields[j]]--; CHECK(!FinalPass(&r, nonce));
        }
        /* Equal counters with the wrong common packet count must not pass. */
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        SetPressure(p, nonce, i ? 127 : 95); CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        SetPressure(p, nonce, i ? 129 : 97); CHECK(!FinalPass(&r, nonce));
        r = good; p = i ? r.PeerPressure : r.LocalPressure;
        p[9] = p[10] = p[11] = 41; p[12] = 2; CHECK(FinalPass(&r, nonce));
    }
    printf("PASS %u native-tool verifier assertions (no device access)\n", tests);
    return 0;
}
