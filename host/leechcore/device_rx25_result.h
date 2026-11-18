// RX25 host-side result/ownership model. Internal C contract, NOT a wire or IOCTL ABI.
// No hardware access, request emission, automatic retry, tag reuse or drain claim.
#ifndef RX25_RESULT_H
#define RX25_RESULT_H
#include "leechcore.h"
#define RX25_RESULT_MODEL_VERSION 1u
#define RX25_RESULT_UNIT_MAX 0x1000u

typedef enum RX25_RESULT_REASON {
    Rx25ResultOk=0, Rx25ResultLocalReject, Rx25ResultUr, Rx25ResultCa,
    Rx25ResultNativeTimeout, Rx25ResultFirmwareTimeout, Rx25ResultPartial,
    Rx25ResultPoison, Rx25ResultMalformed, Rx25ResultLinkLost,
    Rx25ResultHostSample, Rx25ResultRemoved, Rx25ResultStopped
} RX25_RESULT_REASON;

typedef struct RX25_RESULT_EXPECTATION {
    DWORD Version;
    QWORD Epoch, Task, Address;
    DWORD Requested;
} RX25_RESULT_EXPECTATION;

typedef struct RX25_RESULT_COMPLETION {
    DWORD Version;
    QWORD Epoch, Task, Address;
    DWORD Requested, ValidBytes;
    RX25_RESULT_REASON Reason;
    DWORD Issued, PcieStatus, NativeRcError, Source;
} RX25_RESULT_COMPLETION;

typedef struct RX25_RESULT_READER {
    QWORD Epoch, NextTask, RangeStart, RangeBytes;
    DWORD DeadlineTicks, ElapsedTicks, Submitted, ErrorCount;
    BOOL Owned, Fault, Stopped, HasFirstError;
    RX25_RESULT_EXPECTATION Expected;
    RX25_RESULT_COMPLETION FirstError;
    LC_READ_PAGE_RESULT FirstResult;
    PMEM_SCATTER Page;
    PBYTE Destination;
} RX25_RESULT_READER;

BOOL Rx25ResultInit(RX25_RESULT_READER *reader, QWORD epoch, QWORD start, QWORD bytes, DWORD deadline);
LC_READ_PAGE_RESULT Rx25ResultBegin(RX25_RESULT_READER *reader, PMEM_SCATTER page, RX25_RESULT_EXPECTATION *expected);
LC_READ_PAGE_RESULT Rx25ResultApply(RX25_RESULT_READER *reader, const RX25_RESULT_COMPLETION *completion, const BYTE *payload, DWORD payloadBytes);
LC_READ_PAGE_RESULT Rx25ResultTick(RX25_RESULT_READER *reader, DWORD elapsed);
VOID Rx25ResultStop(RX25_RESULT_READER *reader);
#endif
