#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include "../rx25dma_public.h"

static unsigned tests;
#define CHECK(condition) do { tests++; if (!(condition)) { \
    printf("FAIL line %u: %s\n", __LINE__, #condition); return 1; } } while (0)

int main(void)
{
    RX25_DMA_TRANSFER request = {sizeof(request), RX25_DMA_ABI_VERSION, 123, 0, 16};
    unsigned index;
    unsigned seed = 0x251112;
    CHECK(sizeof(RX25_DMA_INFO) == 64);
    CHECK(sizeof(request) == 24);
    CHECK(FIELD_OFFSET(RX25_DMA_INFO, DmaAddress) == 40);
    CHECK(FIELD_OFFSET(RX25_DMA_INFO, Control) == 48);
    CHECK(FIELD_OFFSET(RX25_DMA_TRANSFER, Offset) == 16);
    CHECK(IOCTL_RX25_DMA_QUERY == 0x22E400);
    CHECK(IOCTL_RX25_DMA_READ == 0x22E404);
    CHECK(IOCTL_RX25_DMA_WRITE == 0x22E408);
    CHECK(Rx25DmaValidTransfer(&request, 123, 8192));
    CHECK(!Rx25DmaValidTransfer(&request, 124, 8192));
    request.Size--;
    CHECK(!Rx25DmaValidTransfer(&request, 123, 8192));
    request.Size++;
    request.Version++;
    CHECK(!Rx25DmaValidTransfer(&request, 123, 8192));
    request.Version--;
    CHECK(Rx25DmaValidRange(8192, 0, 8192));
    CHECK(Rx25DmaValidRange(8192, 8191, 1));
    CHECK(Rx25DmaValidRange(8192, 4095, 32));
    CHECK(!Rx25DmaValidRange(8192, 8191, 2));
    CHECK(!Rx25DmaValidRange(8192, 8192, 1));
    CHECK(!Rx25DmaValidRange(8192, 0, 0));
    CHECK(!Rx25DmaValidRange(8192, 0xffffffff, 16));
    CHECK(!Rx25DmaValidRange(8192, 1, 0xffffffff));
    /* Compare shared kernel range validation to independent 64-bit arithmetic. */
    for (index = 0; index < 100000; index++) {
        unsigned capacity, offset, length;
        unsigned long long end;
        seed = seed * 1664525u + 1013904223u;
        capacity = seed & 0xffff;
        seed = seed * 1664525u + 1013904223u;
        offset = index & 1 ? seed : seed & 0xffff;
        seed = seed * 1664525u + 1013904223u;
        length = index & 2 ? seed : seed & 0xffff;
        end = (unsigned long long)offset + length;
        CHECK(!!Rx25DmaValidRange(capacity, offset, length) == (length != 0 && end <= capacity));
    }
    printf("PASS %u contract assertions (no device access)\n", tests);
    return 0;
}
