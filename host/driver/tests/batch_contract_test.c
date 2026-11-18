#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include "../rx25dma_public.h"

C_ASSERT(sizeof(RX25_BATCH_REQUEST) == 24);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_REQUEST, BufferId) == 8);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_REQUEST, Nonce) == 16);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_REQUEST, Reserved) == 20);
C_ASSERT(sizeof(RX25_BATCH_RESULT) == 816);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Batch) == 16);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, LocalPressure) == 80);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, PeerPressure) == 144);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Owner) == 208);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Payload) == 272);
C_ASSERT(FIELD_OFFSET(RX25_BATCH_RESULT, Observations) == 784);

static unsigned tests;
#define CHECK(c) do { tests++; if (!(c)) { printf("FAIL %u: %s\n", __LINE__, #c); return 1; } } while (0)

static RX25_BATCH_RESULT Initial(void)
{
    RX25_BATCH_RESULT r = {0};
    r.Size = sizeof(r); r.Version = 1; r.BufferId = 0x251114;
    r.Batch[0] = RX25_BATCH_SIGNATURE; r.Batch[1] = 0x60;
    r.Batch[14] = 32; r.Batch[15] = 16;
    r.Owner[0] = RX25_BATCH_OWNER_SIGNATURE; r.Owner[1] = 1; r.Owner[2] = 3;
    r.Observations[2] = 1;
    return r;
}

static RX25_BATCH_RESULT Armed(void)
{
    RX25_BATCH_RESULT r = Initial();
    r.Owner[2] |= 8; r.Owner[3] = 0x25111400;
    r.LocalPressure[0] = r.PeerPressure[0] = RX25_PRESSURE_SIGNATURE;
    r.LocalPressure[1] = r.PeerPressure[1] = 3;
    r.LocalPressure[2] = r.PeerPressure[2] = r.Owner[3];
    return r;
}

int main(void)
{
    RX25_BATCH_REQUEST q = {sizeof(q), 1, 0x251114, 0, 0}, t;
    RX25_BATCH_RESULT r, a = Armed(), initial = Initial();
    ULONG codes[3] = {IOCTL_RX25_BATCH_ARM, IOCTL_RX25_BATCH_START, IOCTL_RX25_BATCH_CAPTURE};
    ULONG offsets[3] = {0xb00, 0xb04, 0xb08};
    ULONG nonces[] = {0,1,31,33,0xffffffff};
    unsigned i;
    CHECK(IOCTL_RX25_BATCH_READ == 0x22e420);
    CHECK(IOCTL_RX25_BATCH_ARM == 0x22e424);
    CHECK(IOCTL_RX25_BATCH_START == 0x22e428);
    CHECK(IOCTL_RX25_BATCH_CAPTURE == 0x22e42c);
    CHECK(IOCTL_RX25_FIRST16_READ == 0x22e418);
    CHECK(IOCTL_RX25_FIRST16_START == 0x22e41c);
    CHECK(sizeof(RX25_FIRST16_REQUEST) == 24 && sizeof(RX25_FIRST16_RESULT) == 96);
    CHECK(Rx25BatchValidRequest(&q, q.BufferId, IOCTL_RX25_BATCH_READ));
    CHECK(!Rx25BatchValidRequest(&q, q.BufferId, IOCTL_RX25_DMA_READ));
    CHECK(!Rx25BatchValidRequest(&q, q.BufferId, CTL_CODE(FILE_DEVICE_UNKNOWN, 0x904, METHOD_BUFFERED, 3)));
    for (i = 0; i < 3; i++) {
        CHECK(Rx25BatchCommandOffset(codes[i]) == offsets[i]);
        t = q; t.Nonce = 0x25111400;
        CHECK(Rx25BatchValidRequest(&t, q.BufferId, codes[i]));
        CHECK(!Rx25BatchValidRequest(&q, q.BufferId, codes[i]));
    }
    CHECK(Rx25BatchCommandOffset(IOCTL_RX25_BATCH_READ) == 0);
    CHECK(Rx25BatchCommandOffset(0xffffffff) == 0);
    for (i = 0; i < sizeof(nonces)/sizeof(nonces[0]); i++) CHECK(!Rx25BatchValidNonce(nonces[i]));
    CHECK(Rx25BatchValidNonce(32)); CHECK(Rx25BatchValidNonce(0xffffffe0));
    t = q; t.Nonce = 32; CHECK(!Rx25BatchValidRequest(&t, q.BufferId, IOCTL_RX25_BATCH_READ));
    t = q; t.Size--; CHECK(!Rx25BatchValidRequest(&t, q.BufferId, IOCTL_RX25_BATCH_READ));
    t = q; t.Version++; CHECK(!Rx25BatchValidRequest(&t, q.BufferId, IOCTL_RX25_BATCH_READ));
    t = q; t.Reserved++; CHECK(!Rx25BatchValidRequest(&t, q.BufferId, IOCTL_RX25_BATCH_READ));
    CHECK(!Rx25BatchValidRequest(&q, q.BufferId+1, IOCTL_RX25_BATCH_READ));
    t = q; t.BufferId = 0; CHECK(!Rx25BatchValidRequest(&t, 0, IOCTL_RX25_BATCH_READ));
    CHECK(Rx25BatchValidIdentity(&initial, RX25_DMA_ROLE_A));
    CHECK(!Rx25BatchValidIdentity(&initial, RX25_DMA_ROLE_B));
    CHECK(Rx25BatchValidCommand(&initial, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_ARM, 32));
    CHECK(!Rx25BatchValidCommand(&initial, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_START, 32));
    CHECK(!Rx25BatchValidCommand(&initial, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_CAPTURE, 32));
    CHECK(Rx25BatchValidIdentity(&a, RX25_DMA_ROLE_A));
    CHECK(Rx25BatchValidCommand(&a, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_START, a.Owner[3]));
    CHECK(!Rx25BatchValidCommand(&a, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_ARM, a.Owner[3]));
    CHECK(!Rx25BatchValidCommand(&a, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_START, a.Owner[3]+32));
    CHECK(!Rx25BatchValidCommand(&a, RX25_DMA_ROLE_B, IOCTL_RX25_BATCH_START, a.Owner[3]));
    for (i = 0; i < 8; i++) {
        r = a;
        if (i == 0) r.Batch[0] ^= 1;
        if (i == 1) r.Owner[0] ^= 1;
        if (i == 2) r.Owner[1]++;
        if (i == 3) r.Batch[14]--;
        if (i == 4) r.Batch[15]--;
        if (i == 5) r.Batch[1] &= ~0x40u;
        if (i == 6) r.Size--;
        if (i == 7) r.Owner[9] = 1;
        CHECK(!Rx25BatchValidIdentity(&r, RX25_DMA_ROLE_A));
    }
    for (i = 0; i < 2; i++) {
        ULONG *bank;
        r = a; bank = i ? r.PeerPressure : r.LocalPressure;
        bank[0] ^= 1; CHECK(!Rx25BatchValidIdentity(&r, RX25_DMA_ROLE_A));
        r = a; bank = i ? r.PeerPressure : r.LocalPressure;
        bank[2] += 32; CHECK(!Rx25BatchValidIdentity(&r, RX25_DMA_ROLE_A));
        r = a; bank = i ? r.PeerPressure : r.LocalPressure;
        bank[1] = 1; CHECK(!Rx25BatchValidCommand(&r, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_START, a.Owner[3]));
        r = a; bank = i ? r.PeerPressure : r.LocalPressure;
        bank[1] |= 8; CHECK(!Rx25BatchValidCommand(&r, RX25_DMA_ROLE_A, IOCTL_RX25_BATCH_START, a.Owner[3]));
    }
    r = a; r.Owner[2] &= ~2u; CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_START, a.Owner[3]));
    r = a; r.Owner[2] |= 4; CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_START, a.Owner[3]));
    r = a; r.Owner[2] |= 0x40; CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_START, a.Owner[3]));
    CHECK(Rx25BatchValidIdentity(&r, 1)); /* READ retains fault evidence. */
    for (i = 0; i < 4; i++) {
        if (i == 1) continue;
        r = a; r.Observations[2] = i; r.Batch[1] &= ~0x20u;
        CHECK(Rx25BatchValidIdentity(&r, 1)); /* READ keeps link-down / high-BER evidence. */
        CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_START, a.Owner[3]));
        r = initial; r.Observations[2] = i;
        CHECK(Rx25BatchValidIdentity(&r, 1));
        CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_ARM, a.Owner[3]));
        r = a; r.Owner[2] |= 16; r.Batch[1] = 0x51; r.Batch[2] = a.Owner[3]; r.Observations[2] = i;
        CHECK(Rx25BatchValidIdentity(&r, 1));
        CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_CAPTURE, a.Owner[3]));
    }
    r = a; r.Owner[2] |= 16; r.Batch[1] = 0x69; r.Batch[2] = a.Owner[3];
    CHECK(Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_CAPTURE, a.Owner[3]));
    r.Batch[1] = 0x71; /* stopped fault snapshot is capturable */
    CHECK(Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_CAPTURE, a.Owner[3]));
    r.Batch[1] |= 4; CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_CAPTURE, a.Owner[3]));
    r.Batch[1] = 0x63; CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_CAPTURE, a.Owner[3]));
    r.Batch[1] = 0x69; r.Owner[2] |= 32;
    CHECK(!Rx25BatchValidCommand(&r, 1, IOCTL_RX25_BATCH_CAPTURE, a.Owner[3]));
    r = initial; r.Owner[2] |= 8; CHECK(!Rx25BatchValidIdentity(&r, 1));
    r = initial; r.LocalPressure[3] = 1; CHECK(!Rx25BatchValidIdentity(&r, 1));
    r = a; r.Owner[2] |= 0x80; CHECK(!Rx25BatchValidIdentity(&r, 1));
    r = a; r.Batch[1] |= 0x100; CHECK(!Rx25BatchValidIdentity(&r, 1));
    printf("PASS %u BATCH contract assertions; 11 compile-time size/offset checks (no device access)\n", tests);
    return 0;
}
