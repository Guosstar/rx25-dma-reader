#!/usr/bin/env python3
"""Drive the RX25 LeechCore backend through leechcore.dll.

Runs the same acceptance points as the direct tool, but through the public
LeechCore API and with typed per-page results, which is what makes this a
backend test rather than another register poking session.

Must run elevated: the control device object is admin-only.
"""

import ctypes
import os
import sys
import time
from ctypes import wintypes

import rx25_paths

MAX_PATH = 260
LC_CONFIG_VERSION = 0xC0FD0002
MEM_SCATTER_VERSION = 0xC0FE0002
MEM_SCATTER_STACK_SIZE = 12

R_NONE = 0x00
R_SUCCESS = 0x01
R_SUCCESS_AFTER_RETRY = 0x02
R_UNSUPPORTED_REQUEST = 0x03
R_COMPLETER_ABORT = 0x04
R_NO_COMPLETION = 0x05
R_PARTIAL_COMPLETION = 0x06
R_TRANSPORT_ERROR = 0x07
R_PROTOCOL_ERROR = 0x08
R_UNSPECIFIED_ERROR = 0x09
R_NOT_ISSUED = 0x0A

RESULT_NAME = {
    0x00: "NONE", 0x01: "SUCCESS", 0x02: "SUCCESS_AFTER_RETRY",
    0x03: "UNSUPPORTED_REQUEST", 0x04: "COMPLETER_ABORT", 0x05: "NO_COMPLETION",
    0x06: "PARTIAL_COMPLETION", 0x07: "TRANSPORT_ERROR", 0x08: "PROTOCOL_ERROR",
    0x09: "UNSPECIFIED_ERROR", 0x0A: "NOT_ISSUED",
}


class LC_CONFIG(ctypes.Structure):
    _fields_ = [
        ("dwVersion", wintypes.DWORD),
        ("dwPrintfVerbosity", wintypes.DWORD),
        ("szDevice", ctypes.c_char * MAX_PATH),
        ("szRemote", ctypes.c_char * MAX_PATH),
        ("pfn_printf_opt", ctypes.c_void_p),
        ("paMax", ctypes.c_ulonglong),
        ("fVolatile", wintypes.BOOL),
        ("fWritable", wintypes.BOOL),
        ("fRemote", wintypes.BOOL),
        ("fRemoteDisableCompress", wintypes.BOOL),
        ("szDeviceName", ctypes.c_char * MAX_PATH),
    ]


class LC_CONFIG_ERRORINFO(ctypes.Structure):
    _fields_ = [
        ("dwVersion", wintypes.DWORD),
        ("cbStruct", wintypes.DWORD),
        ("_FutureUse", wintypes.DWORD * 16),
        ("fUserInputRequest", wintypes.BOOL),
        ("cwszUserText", wintypes.DWORD),
    ]


class MEM_SCATTER(ctypes.Structure):
    _fields_ = [
        ("version", wintypes.DWORD),
        ("f", wintypes.BOOL),
        ("qwA", ctypes.c_ulonglong),
        ("pb", ctypes.POINTER(ctypes.c_ubyte)),
        ("cb", wintypes.DWORD),
        ("iStack", wintypes.DWORD),
        ("vStack", ctypes.c_ulonglong * MEM_SCATTER_STACK_SIZE),
    ]


PMEM_SCATTER = ctypes.POINTER(MEM_SCATTER)
PPMEM_SCATTER = ctypes.POINTER(PMEM_SCATTER)


class Lc(object):
    def __init__(self, dll_path):
        self.dll = ctypes.WinDLL(dll_path)
        d = self.dll
        d.LcCreateEx.restype = ctypes.c_void_p
        d.LcCreateEx.argtypes = [ctypes.POINTER(LC_CONFIG),
                                 ctypes.POINTER(ctypes.POINTER(LC_CONFIG_ERRORINFO))]
        d.LcClose.restype = None
        d.LcClose.argtypes = [ctypes.c_void_p]
        d.LcMemFree.restype = None
        d.LcMemFree.argtypes = [ctypes.c_void_p]
        d.LcAllocScatter1.restype = wintypes.BOOL
        d.LcAllocScatter1.argtypes = [wintypes.DWORD, ctypes.POINTER(PPMEM_SCATTER)]
        d.LcReadScatterEx.restype = wintypes.BOOL
        d.LcReadScatterEx.argtypes = [ctypes.c_void_p, wintypes.DWORD,
                                      PPMEM_SCATTER, ctypes.POINTER(wintypes.DWORD)]
        # The plain contiguous API.  Every earlier test used only
        # LcReadScatterEx, which is how an underflow in LcRead's middle-buffer
        # length went unnoticed until an external tool hit it.
        d.LcRead.restype = wintypes.BOOL
        d.LcRead.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong,
                             wintypes.DWORD, ctypes.POINTER(ctypes.c_ubyte)]

    def create(self, device="rx25"):
        cfg = LC_CONFIG()
        cfg.dwVersion = LC_CONFIG_VERSION
        cfg.dwPrintfVerbosity = 0
        cfg.szDevice = device.encode("ascii")
        cfg.szRemote = b""
        cfg.pfn_printf_opt = None
        cfg.paMax = 0
        err = ctypes.POINTER(LC_CONFIG_ERRORINFO)()
        h = self.dll.LcCreateEx(ctypes.byref(cfg), ctypes.byref(err))
        if not h:
            msg = ""
            if err:
                n = err.contents.cwszUserText
                if n:
                    base = ctypes.addressof(err.contents) + ctypes.sizeof(LC_CONFIG_ERRORINFO)
                    msg = ctypes.wstring_at(base, n)
                self.dll.LcMemFree(ctypes.cast(err, ctypes.c_void_p))
            return None, (msg or "LcCreateEx failed with no message")
        return h, None

    def read_plain(self, h, addr, length):
        buf = (ctypes.c_ubyte * length)()
        ok = self.dll.LcRead(h, addr, length, buf)
        return bool(ok), bytes(buf)

    def read_range(self, h, addr, length):
        """Reference read of [addr, addr+length) for any alignment.

        The RX25 backend only accepts 16-byte aligned descriptors, so the
        reference must read whole page-aligned pages and slice the requested
        bytes out of them.  An earlier version trimmed the request to the page
        boundary and called read_page() on the raw address, which fails for any
        unaligned start and made valid LcRead results look like test failures.
        """
        out = bytearray()
        end = addr + length
        pos = addr
        while pos < end:
            page = pos & ~0xFFF
            code, flag, data = self.read_page(h, page, 0x1000)
            if code != R_SUCCESS or not flag:
                return None
            start = pos - page
            take = min(end - pos, 0x1000 - start)
            out += data[start:start + take]
            pos += take
        return bytes(out)

    def read_page(self, h, addr, length=0x1000):
        arr = PPMEM_SCATTER()
        if not self.dll.LcAllocScatter1(1, ctypes.byref(arr)):
            raise RuntimeError("LcAllocScatter1 failed")
        m = arr[0]
        m.contents.qwA = addr
        m.contents.cb = length
        res = (wintypes.DWORD * 1)()
        ok = self.dll.LcReadScatterEx(h, 1, arr, res)
        # Snapshot the fields BEFORE freeing: touching m.contents after
        # LcMemFree is a use-after-free and yields garbage (it used to print
        # f=709 on every single line).
        flag = int(m.contents.f)
        data = ctypes.string_at(m.contents.pb, length) if flag else b""
        self.dll.LcMemFree(ctypes.cast(arr, ctypes.c_void_p))
        if not ok:
            raise RuntimeError("LcReadScatterEx returned FALSE (dispatch error)")
        return int(res[0]), flag, data


def _opt_int(name, default=0):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            try:
                return int(sys.argv[i + 1], 0)
            except ValueError:
                pass
    return default


def main():
    dll_path = rx25_paths.find_leechcore_dll()
    if dll_path is None:
        print("FAIL: leechcore.dll not found -- " + rx25_paths.leechcore_hint())
        return 2
    print("=" * 60)
    print("RX25 LeechCore backend test")
    print("dll  :", dll_path)
    print("arch :", "64-bit" if sys.maxsize > 2**32 else "32-bit")
    print("=" * 60)
    if not os.path.exists(dll_path):
        print("FAIL: dll not found. Build it first (build_leechcore_link.cmd).")
        return 2

    lc = Lc(dll_path)
    h, err = lc.create("rx25")
    if not h:
        print("CREATE FAILED")
        print("  ", err)
        return 3
    print("create : OK")

    failures = []
    ref = None

    def attempt(label, addr, length, expect_ok, check_head=True, check_pe=False):
        nonlocal ref
        try:
            code, flag, data = lc.read_page(h, addr, length)
        except Exception as exc:  # dispatch-level failure
            print("%-30s EXC   %s" % (label, exc))
            failures.append(label)
            return None
        name = RESULT_NAME.get(code, "0x%02x" % code)
        print("%-30s %-20s f=%s len=%d" % (label, name, flag, len(data)))
        if expect_ok is None:
            # Informational probe.  Whether a given physical address is
            # readable is a property of the target platform, not of the card,
            # so neither outcome is a failure here.
            print("      (informational; either outcome is acceptable)")
        elif expect_ok:
            if code != R_SUCCESS or not flag:
                failures.append(label)
                print("      expected SUCCESS")
                return None
            if check_head and ref is not None and data[:16] != ref:
                failures.append(label)
                print("      content drift vs reference")
            if check_pe:
                pe = data[0xC0:0xC4]
                # Informational only: "0x10000000 holds a PE image" is a fact
                # about the Linux bench, not a property of the card.  On another
                # target the same physical page holds something else entirely.
                print("      +0xC0 bytes: " + " ".join("%02x" % b for b in pe) +
                      ("  (PE signature, matches the Linux bench)" if pe == b"PE\x00\x00"
                       else "  (not a PE header)"))
        else:
            # Only "not a success" is asserted.  The exact typed failure is
            # informative, not contractual, and must not fail the run.
            if code == R_SUCCESS:
                failures.append(label)
                print("      expected a typed failure, got SUCCESS")
        return data

    print("\n[1] known-good 16 B")
    first = attempt("0x10000000 len 16", 0x10000000, 16, True, check_head=False)
    if first:
        ref = first[:16]
        print("      head: " + " ".join("%02x" % b for b in ref))
        if ref[:2] != b"MZ":
            print("      NOTE: not an MZ header; still used as the reference")

    print("\n[2] one full 4 KiB page (16 chunks of 256 B)")
    attempt("0x10000000 len 4096", 0x10000000, 0x1000, True, check_pe=True)

    print("\n[3] reserved address (informational, platform dependent)")
    attempt("0x000F0000 len 16", 0x000F0000, 16, None)

    print("\n[4] recovery after the failure")
    attempt("0x10000000 len 16", 0x10000000, 16, True)

    # A different page legitimately holds different bytes, so stability is
    # checked by reading it twice, not by comparing it against page 0.
    print("\n[5] second page, read twice (self-consistency)")
    a = attempt("0x10001000 len 256 (a)", 0x10001000, 256, True, check_head=False)
    b = attempt("0x10001000 len 256 (b)", 0x10001000, 256, True, check_head=False)
    if a is not None and b is not None:
        if a != b:
            failures.append("0x10001000 stability")
            print("      two reads of the same page differ")
        else:
            print("      stable: " + " ".join("%02x" % x for x in a[:16]))

    # LcRead takes a different path from LcReadScatterEx: it builds page
    # trampolines and copies the partial head/tail itself.  It carried an
    # unsigned underflow for sub-page reads, so it gets explicit coverage here:
    # sub-page, unaligned, page-crossing and multi-page.
    print("\n[7] LcRead (contiguous API) vs scatter reference")
    cases = [
        (0x10001000, 16,   "sub-page aligned"),
        (0x10001000, 32,   "sub-page aligned"),
        (0x10001000, 4096, "full page"),
        (0x10001004, 8,    "unaligned start"),
        (0x10001FF8, 16,   "page crossing"),
        (0x10001000, 8192, "two pages"),
    ]
    for addr, ln, note in cases:
        same = False
        ok = False
        got = b""
        sref = None
        for _ in range(2):          # the page may be live; allow one retry
            ok, got = lc.read_plain(h, addr, ln)
            sref = lc.read_range(h, addr, ln)
            if sref is not None and ok and got == sref:
                same = True
                break
        if sref is None:
            print("  0x%08x len %-5d reference read failed" % (addr, ln))
            failures.append("LcRead ref 0x%x/%d" % (addr, ln))
            continue
        print("  0x%08x len %-5d %-7s %-7s (%s)" % (
            addr, ln, "ok" if ok else "FAILED",
            "match" if same else "DIFFER", note))
        if not same:
            failures.append("LcRead 0x%x/%d" % (addr, ln))
            if ok:
                for i in range(min(len(got), len(sref))):
                    if got[i] != sref[i]:
                        print("      first diff at byte %d: got %02x want %02x"
                              % (i, got[i], sref[i]))
                        break
            else:
                print("      LcRead returned FALSE (pre-hardware rejection is what"
                      " the underflow looked like)")

    if ref:
        print("\nreference head: " + " ".join("%02x" % b for b in ref))

    # Optional soak through the production API: this is the path a real caller
    # takes, so it exercises the reader's epoch rollover and the chunk loop, not
    # just a single descriptor.
    long_n = _opt_int("--long", 0)
    if long_n > 0:
        print("\n[6] long run, %d reads of 0x10000000 (16 B)" % long_n)
        samples = []
        bad = 0
        t0 = time.time()
        for i in range(long_n):
            t1 = time.time()
            try:
                code, flag, data = lc.read_page(h, 0x10000000, 16)
            except Exception as exc:
                print("  iter %d: EXC %s" % (i + 1, exc))
                bad += 1
                break
            samples.append((time.time() - t1) * 1000.0)
            if code != R_SUCCESS or not flag or data[:16] != ref:
                bad += 1
                print("  iter %d: %s f=%s head=%s" % (
                    i + 1, RESULT_NAME.get(code, code), flag,
                    " ".join("%02x" % b for b in data[:16])))
                if bad >= 3:
                    print("  stopping after 3 failures")
                    break
            if (i + 1) % 100 == 0:
                print("  ... %d/%d  bad=%d" % (i + 1, long_n, bad))
        total = (time.time() - t0) * 1000.0
        if samples:
            print("  done: %d reads, bad=%d, total %.0f ms, avg %.1f ms, min %.1f, max %.1f" % (
                len(samples), bad, total,
                sum(samples) / len(samples), min(samples), max(samples)))
        if bad:
            failures.append("long run (%d bad)" % bad)

    lc.dll.LcClose(h)
    print("\n" + "=" * 60)
    if failures:
        print("RESULT: FAIL  (%d)" % len(failures))
        for f in failures:
            print("  -", f)
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
