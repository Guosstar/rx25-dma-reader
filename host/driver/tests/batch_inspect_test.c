/* Invoke the exact tool entry using mocked Win32 calls; no device is opened. */
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
static HANDLE WINAPI InspectMockCreateFileW(LPCWSTR,DWORD,DWORD,LPSECURITY_ATTRIBUTES,DWORD,DWORD,HANDLE);
static BOOL WINAPI InspectMockDeviceIoControl(HANDLE,DWORD,LPVOID,DWORD,LPVOID,DWORD,LPDWORD,LPOVERLAPPED);
static BOOL WINAPI InspectMockWriteFile(HANDLE,LPCVOID,DWORD,LPDWORD,LPOVERLAPPED);
static BOOL WINAPI InspectMockCloseHandle(HANDLE);
static DWORD WINAPI InspectMockGetLastError(void);
#define CreateFileW InspectMockCreateFileW
#define DeviceIoControl InspectMockDeviceIoControl
#define WriteFile InspectMockWriteFile
#define CloseHandle InspectMockCloseHandle
#define GetLastError InspectMockGetLastError
#define wmain InspectToolEntry
#include "batch_inspect_tool.c"
#undef wmain
#undef CreateFileW
#undef DeviceIoControl
#undef WriteFile
#undef CloseHandle
#undef GetLastError

typedef struct _MOCK_STATE {
    unsigned Opens, Ioctls, Writes, Closes, Unexpected;
    DWORD Codes[4], LastError, QueryBytes, ReadBytes, QueryFailure, ReadFailure;
    int OutputOpenFailure, DeviceOpenFailure, WriteFailure, ShortWrite;
    RX25_DMA_INFO Info;
    RX25_BATCH_RESULT Snapshot;
    char Text[16384];
} MOCK_STATE;
static MOCK_STATE mock;
static unsigned checks, cases;
static HANDLE outputHandle = (HANDLE)(ULONG_PTR)1, deviceHandle = (HANDLE)(ULONG_PTR)2;
#define CHECK(c) do { checks++; if (!(c)) { printf("FAIL line=%u case=%u: %s\n", __LINE__, cases, #c); return 1; } } while (0)

static void ResetMock(void)
{
    ZeroMemory(&mock, sizeof(mock)); cases++;
    mock.QueryBytes = sizeof(mock.Info); mock.ReadBytes = sizeof(mock.Snapshot);
    mock.Info.Size = sizeof(mock.Info); mock.Info.Version = 1; mock.Info.Flags = 31;
    mock.Info.Role = RX25_DMA_ROLE_A; mock.Info.Caps = 0xf; mock.Info.BufferBytes = 8192;
    mock.Info.CqOffset = 0x1000; mock.Info.BufferId = 0x251114; mock.Info.DmaAddress = 0x100000000ULL;
    mock.Info.ObsStatus = 1;
    mock.Snapshot.Size = sizeof(mock.Snapshot); mock.Snapshot.Version = 1; mock.Snapshot.BufferId = mock.Info.BufferId;
    mock.Snapshot.Batch[0] = RX25_BATCH_SIGNATURE; mock.Snapshot.Batch[1] = 0x60;
    mock.Snapshot.Batch[14] = 32; mock.Snapshot.Batch[15] = 16;
    mock.Snapshot.Owner[0] = RX25_BATCH_OWNER_SIGNATURE; mock.Snapshot.Owner[1] = 1;
    mock.Snapshot.Owner[2] = 3; mock.Snapshot.Observations[2] = 1;
}

static void Published(void)
{
    mock.Snapshot.Owner[2] = 0xb; mock.Snapshot.Owner[3] = 0x25111400;
    mock.Snapshot.LocalPressure[0] = mock.Snapshot.PeerPressure[0] = RX25_PRESSURE_SIGNATURE;
    mock.Snapshot.LocalPressure[1] = mock.Snapshot.PeerPressure[1] = 3;
    mock.Snapshot.LocalPressure[2] = mock.Snapshot.PeerPressure[2] = mock.Snapshot.Owner[3];
}

static int RunTool(void)
{
    wchar_t *args[] = {L"inspect-test", L"--inspect", L"--device", L"explicit-A-interface", L"--output", L"new-evidence.json"};
    return InspectToolEntry(6, args);
}

static int ReadOnlySequence(unsigned expected)
{
    unsigned index;
    if (mock.Unexpected || mock.Ioctls != expected || mock.Ioctls > 2) return 0;
    for (index = 0; index < mock.Ioctls; index++)
        if (mock.Codes[index] != (DWORD)(index ? IOCTL_RX25_BATCH_READ : IOCTL_RX25_DMA_QUERY)) return 0;
    return 1;
}

static HANDLE WINAPI InspectMockCreateFileW(LPCWSTR name,DWORD access,DWORD share,LPSECURITY_ATTRIBUTES security,
                                            DWORD creation,DWORD attributes,HANDLE templateFile)
{
    unsigned index = mock.Opens++;
    if (share || security || templateFile || attributes != FILE_ATTRIBUTE_NORMAL || index > 1) mock.Unexpected++;
    if (!index) {
        if (wcscmp(name, L"new-evidence.json") || access != GENERIC_WRITE || creation != CREATE_NEW) mock.Unexpected++;
        if (mock.OutputOpenFailure) { mock.LastError = ERROR_FILE_EXISTS; return INVALID_HANDLE_VALUE; }
        return outputHandle;
    }
    if (wcscmp(name, L"explicit-A-interface") || access != (GENERIC_READ | GENERIC_WRITE) || creation != OPEN_EXISTING) mock.Unexpected++;
    if (mock.DeviceOpenFailure) { mock.LastError = ERROR_ACCESS_DENIED; return INVALID_HANDLE_VALUE; }
    return deviceHandle;
}

static BOOL WINAPI InspectMockDeviceIoControl(HANDLE handle,DWORD code,LPVOID input,DWORD inputBytes,
                                              LPVOID output,DWORD outputBytes,LPDWORD returned,LPOVERLAPPED overlapped)
{
    unsigned index = mock.Ioctls++;
    if (index < 4) mock.Codes[index] = code; else mock.Unexpected++;
    if (handle != deviceHandle || overlapped || index > 1) mock.Unexpected++;
    if (code == IOCTL_RX25_DMA_QUERY && index == 0) {
        if (input || inputBytes || outputBytes != sizeof(mock.Info)) mock.Unexpected++;
        if (mock.QueryFailure) { mock.LastError = mock.QueryFailure; return FALSE; }
        CopyMemory(output, &mock.Info, sizeof(mock.Info)); *returned = mock.QueryBytes;
        return TRUE;
    }
    if (code == IOCTL_RX25_BATCH_READ && index == 1) {
        const RX25_BATCH_REQUEST *request = (const RX25_BATCH_REQUEST *)input;
        if (!request || inputBytes != sizeof(*request) || outputBytes != sizeof(mock.Snapshot)) mock.Unexpected++;
        else if (request->Size != 24 || request->Version != 1 || request->BufferId != mock.Info.BufferId ||
                 request->Nonce != 0 || request->Reserved != 0) mock.Unexpected++;
        if (mock.ReadFailure) { mock.LastError = mock.ReadFailure; return FALSE; }
        CopyMemory(output, &mock.Snapshot, sizeof(mock.Snapshot)); *returned = mock.ReadBytes;
        return TRUE;
    }
    mock.Unexpected++; mock.LastError = ERROR_INVALID_FUNCTION; return FALSE;
}

static BOOL WINAPI InspectMockWriteFile(HANDLE handle,LPCVOID data,DWORD count,LPDWORD written,LPOVERLAPPED overlapped)
{
    mock.Writes++;
    if (handle != outputHandle || overlapped || count >= sizeof(mock.Text) || mock.Writes > 1) mock.Unexpected++;
    if (count < sizeof(mock.Text)) { CopyMemory(mock.Text, data, count); mock.Text[count] = 0; }
    if (mock.WriteFailure) { mock.LastError = ERROR_DISK_FULL; *written = 0; return FALSE; }
    *written = mock.ShortWrite ? count - 1 : count;
    return TRUE;
}

static BOOL WINAPI InspectMockCloseHandle(HANDLE handle)
{
    mock.Closes++;
    if (handle != outputHandle && handle != deviceHandle) mock.Unexpected++;
    return TRUE;
}

static DWORD WINAPI InspectMockGetLastError(void) { return mock.LastError; }

int main(int argc, char **argv)
{
    unsigned index;
    FILE *sample = NULL;
    ResetMock(); CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(mock.Opens == 2 && mock.Writes == 1 && mock.Closes == 2);
    CHECK(strstr(mock.Text, "\"snapshot_state\":\"initial_snapshot\""));
    CHECK(strstr(mock.Text, "\"pressure_state\":\"empty\""));
    CHECK(strstr(mock.Text, "\"batch_test_pass\":false") && strstr(mock.Text, "\"hardware_test_pass\":false"));
    CHECK(strstr(mock.Text, "\"commands_issued\":0"));
    for (index = 0; index < 7; index++) {
        wchar_t *args[] = {L"inspect-test", L"--inspect", L"--device", L"explicit-A-interface", L"--output", L"new-evidence.json", L"extra"};
        int count = 6;
        ResetMock();
        if (index == 0) count = 1;
        if (index == 1) args[1] = L"--execute";
        if (index == 2) args[2] = L"--auto-device";
        if (index == 3) args[3] = L"";
        if (index == 4) args[4] = L"--overwrite";
        if (index == 5) args[5] = L"";
        if (index == 6) count = 7;
        CHECK(InspectToolEntry(count, args) == 2); CHECK(mock.Opens == 0 && mock.Writes == 0 && mock.Closes == 0); CHECK(ReadOnlySequence(0));
    }
    ResetMock(); mock.OutputOpenFailure = 1; CHECK(RunTool() == 2); CHECK(mock.Opens == 1 && mock.Ioctls == 0 && mock.Writes == 0 && mock.Closes == 0); CHECK(ReadOnlySequence(0));
    ResetMock(); mock.DeviceOpenFailure = 1; CHECK(RunTool() == 1); CHECK(ReadOnlySequence(0)); CHECK(mock.Writes == 1 && mock.Closes == 1); CHECK(strstr(mock.Text,"device_open_failed"));
    ResetMock(); mock.QueryFailure = ERROR_ACCESS_DENIED; CHECK(RunTool() == 1); CHECK(ReadOnlySequence(1)); CHECK(strstr(mock.Text,"query_failed"));
    for (index = 0; index < 3; index++) {
        ResetMock(); mock.QueryBytes = index == 0 ? 0 : index == 1 ? 63 : 65;
        CHECK(RunTool() == 1); CHECK(ReadOnlySequence(1)); CHECK(strstr(mock.Text,"query_size_mismatch"));
    }
    for (index = 0; index < 10; index++) {
        ResetMock();
        if (index == 0) mock.Info.Size--;
        if (index == 1) mock.Info.Version++;
        if (index == 2) mock.Info.Role = RX25_DMA_ROLE_B;
        if (index == 3) mock.Info.Caps ^= 1;
        if (index == 4) mock.Info.BufferBytes--;
        if (index == 5) mock.Info.CqOffset = 0;
        if (index == 6) mock.Info.BufferId = 0;
        if (index == 7) mock.Info.Reserved0 = 1;
        if (index == 8) mock.Info.Reserved1 = 1;
        if (index == 9) mock.Info.Flags = 0;
        CHECK(RunTool() == 1); CHECK(ReadOnlySequence(1)); CHECK(strstr(mock.Text,"query_identity_mismatch"));
    }
    for (index = 0; index < 3; index++) {
        ResetMock(); mock.ReadFailure = index == 0 ? ERROR_INVALID_FUNCTION : index == 1 ? ERROR_NOT_SUPPORTED : ERROR_BUSY;
        CHECK(RunTool() == 1); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text, index == 2 ? "batch_read_failed" : "batch_read_unsupported"));
    }
    for (index = 0; index < 4; index++) {
        ResetMock();
        if (index < 3) mock.ReadBytes = index == 0 ? 0 : index == 1 ? 815 : 817;
        else mock.Snapshot.Size--;
        CHECK(RunTool() == 1); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"batch_size_mismatch"));
    }
    for (index = 0; index < 9; index++) {
        ResetMock();
        if (index == 0) mock.Snapshot.Version++;
        if (index == 1) mock.Snapshot.BufferId++;
        if (index == 2) mock.Snapshot.Batch[0] ^= 1;
        if (index == 3) mock.Snapshot.Owner[0] ^= 1;
        if (index == 4) mock.Snapshot.Owner[1]++;
        if (index == 5) mock.Snapshot.Owner[2] = 0;
        if (index == 6) mock.Snapshot.Owner[9] = 1;
        if (index == 7) mock.Snapshot.Batch[14]--;
        if (index == 8) mock.Snapshot.Batch[15]--;
        CHECK(RunTool() == 1); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"batch_identity_mismatch"));
    }
    for (index = 0; index < 3; index++) {
        ResetMock(); Published();
        if (index == 0) mock.Snapshot.PeerPressure[2] += 32;
        if (index == 1) ZeroMemory(mock.Snapshot.PeerPressure, sizeof(mock.Snapshot.PeerPressure));
        if (index == 2) { ZeroMemory(mock.Snapshot.LocalPressure, sizeof(mock.Snapshot.LocalPressure)); ZeroMemory(mock.Snapshot.PeerPressure, sizeof(mock.Snapshot.PeerPressure)); }
        CHECK(RunTool() == 1); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"batch_identity_mismatch"));
    }
    for (index = 0; index < 4; index++) {
        ResetMock(); mock.Info.ObsStatus = index; mock.Snapshot.Observations[2] = index;
        CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"\"snapshot_valid\":true"));
        CHECK(strstr(mock.Text, index & 1 ? "\"rx_block_lock\":true" : "\"rx_block_lock\":false"));
        CHECK(strstr(mock.Text, index & 2 ? "\"rx_high_ber\":true" : "\"rx_high_ber\":false"));
    }
    ResetMock(); Published(); CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"armed_snapshot")); CHECK(strstr(mock.Text,"\"pressure_state\":\"published\""));
    ResetMock(); Published(); mock.Snapshot.Owner[2] |= 16; mock.Snapshot.Batch[1] = 0x69;
    CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"spent_snapshot")); CHECK(strstr(mock.Text,"\"batch_spent\":true"));
    ResetMock(); Published(); mock.Snapshot.Owner[2] |= 16; mock.Snapshot.Batch[1] = 0x67;
    CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"running_snapshot"));
    ResetMock(); Published(); mock.Snapshot.Owner[2] |= 48; mock.Snapshot.Batch[1] = 0xe9;
    mock.Snapshot.LocalPressure[1] = mock.Snapshot.PeerPressure[1] = 0x1d5;
    CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"captured_snapshot")); CHECK(strstr(mock.Text,"\"pressure_state\":\"captured\""));
    ResetMock(); mock.Snapshot.Owner[2] = 5;
    CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"pending_snapshot"));
    ResetMock(); mock.Snapshot.Owner[2] = 0x41; mock.Snapshot.Batch[1] = 0x50; mock.Snapshot.Observations[2] = 2;
    CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"fault_snapshot")); CHECK(strstr(mock.Text,"\"rx_high_ber\":true"));
    ResetMock(); Published(); mock.Snapshot.PeerPressure[1] |= 8;
    CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2)); CHECK(strstr(mock.Text,"fault_snapshot"));
    ResetMock(); mock.WriteFailure = 1; CHECK(RunTool() == 1); CHECK(ReadOnlySequence(2)); CHECK(mock.Writes == 1 && mock.Closes == 2);
    ResetMock(); mock.ShortWrite = 1; CHECK(RunTool() == 1); CHECK(ReadOnlySequence(2)); CHECK(mock.Writes == 1 && mock.Closes == 2);
    ResetMock(); CHECK(RunTool() == 0); CHECK(ReadOnlySequence(2));
    if (argc == 2) {
        CHECK(fopen_s(&sample, argv[1], "wb") == 0 && sample != NULL);
        CHECK(fwrite(mock.Text, 1, strlen(mock.Text), sample) == strlen(mock.Text));
        CHECK(fclose(sample) == 0);
    } else CHECK(argc == 1);
    printf("RX25_INSPECT_MOCK_TEST_OK cases=%u checks=%u real_device_opens=0 allowed_ioctls=QUERY,BATCH_READ\n", cases, checks);
    return 0;
}
