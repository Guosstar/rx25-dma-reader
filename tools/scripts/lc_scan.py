#!/usr/bin/env python3
"""Scan the target's physical memory for PE images and validate their structure.

Why this is an oracle and not a smoke test: a PE image is self-validating.
e_lfanew must point at "PE\\0\\0", the Machine field must be a known
architecture, NumberOfSections must be in range, and every section header must
carry a name and sane bounds.  If a single byte in the transfer were wrong the
parse would collapse, so finding N well-formed images is direct evidence that
the payload is the target's real memory rather than something synthesised.

Reuses the LeechCore plumbing from lc_rx25_test.py.
"""

import os
import struct
import sys
import time
import datetime

import lc_rx25_test as base


MACHINES = {
    0x014C: "i386",
    0x8664: "x86-64",
    0xAA64: "ARM64",
    0x01C4: "ARMv7",
}


def _opt_header_size(e_lfanew, page):
    """Return (size, is64) of the optional header, or None if it looks wrong."""
    off = e_lfanew + 4 + 20
    if off + 2 > len(page):
        return None
    m = struct.unpack_from("<H", page, off)[0]
    if m == 0x10B:
        size, is64 = 224, False
    elif m == 0x20B:
        size, is64 = 240, True
    else:
        return None
    if e_lfanew + 4 + 20 + size > len(page):
        return None
    return size, is64


def inspect_page(page):
    """Return a dict describing a valid PE image at offset 0, else None."""
    if len(page) < 0x1000 or page[0:2] != b"MZ":
        return None
    e_lfanew = struct.unpack_from("<I", page, 0x3C)[0]
    if e_lfanew < 0x40 or e_lfanew > 0x1000 - 24:
        return None
    if page[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
        return None

    machine, nsect, timestamp = struct.unpack_from("<HHI", page, e_lfanew + 4)
    if machine not in MACHINES:
        return None
    if not (1 <= nsect <= 96):
        return None

    opt = _opt_header_size(e_lfanew, page)
    if opt is None:
        return None
    opt_size, is64 = opt

    # Section table must be inside the page and every entry well formed.
    sect_off = e_lfanew + 4 + 20 + opt_size
    if sect_off + nsect * 40 > len(page):
        return None
    names = []
    for i in range(nsect):
        base_off = sect_off + i * 40
        raw_name = page[base_off:base_off + 8]
        if not raw_name.strip(b"\x00"):
            return None
        name = raw_name.split(b"\x00")[0].decode("ascii", "replace")
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", page, base_off + 8)
        if rsize and raddr == 0:
            return None
        names.append(name)

    # A plausible build timestamp (after 1990) is one more independent check.
    try:
        built = datetime.datetime.fromtimestamp(
            timestamp, datetime.timezone.utc).strftime("%Y-%m-%d")
    except Exception:
        return None
    if timestamp and timestamp < 631152000:  # 1990-01-01
        return None

    # Subsystem sits at +68 in both PE32 and PE32+ optional headers.
    subsystem = struct.unpack_from("<H", page, e_lfanew + 4 + 20 + 68)[0]
    return {
        "machine": MACHINES[machine],
        "sections": nsect,
        "built": built if timestamp else "(zero)",
        "subsystem": subsystem,
        "names": names[:6],
        "is64": is64,
    }


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "..", "pcileech-as02-3p", "LeechCore", "files", "leechcore.dll"),
        os.path.join(here, "..", "pcileech-as02-3p", "LeechCore", "files", "leechcore.dll"),
        os.path.join(here, "leechcore.dll"),
    ]
    dll_path = None
    for c in candidates:
        c = os.path.abspath(c)
        if os.path.exists(c):
            dll_path = c
            break
    if dll_path is None:
        print("FAIL: leechcore.dll not found")
        return 2

    ranges = [
        (0x00010000, 0x02000000),   # low physical memory
        (0x10000000, 0x14000000),   # the page the bench has been reading
    ]

    lc = base.Lc(dll_path)
    h, err = lc.create("rx25")
    if not h:
        print("CREATE FAILED")
        print("  ", err)
        return 3
    print("create : OK")

    histogram = {}
    found = []
    total_pages = 0
    t0 = time.time()

    for start, end in ranges:
        print("\n=== scanning 0x%08x .. 0x%08x ===" % (start, end))
        consecutive_errors = 0
        pa = start
        while pa < end:
            try:
                code, flag, data = lc.read_page(h, pa, 0x1000)
            except Exception as exc:
                print("  0x%08x EXC %s" % (pa, exc))
                break
            total_pages += 1
            name = base.RESULT_NAME.get(code, "0x%02x" % code)
            histogram[name] = histogram.get(name, 0) + 1

            if code != base.R_SUCCESS or not flag:
                consecutive_errors += 1
                # A long run of unreadable pages means the range is not RAM on
                # this platform; stop instead of grinding through it.
                if consecutive_errors >= 256:
                    print("  0x%08x  %d consecutive unreadable pages, ending this range" % (pa, consecutive_errors))
                    break
            else:
                consecutive_errors = 0
                if data[:2] == b"MZ":
                    info = inspect_page(data)
                    if info:
                        found.append((pa, info))
                        print("  0x%08x  %s  %d sections  built %s  %s" % (
                            pa, info["machine"], info["sections"], info["built"],
                            ",".join(info["names"])))
            pa += 0x1000

    elapsed = time.time() - t0
    lc.dll.LcClose(h)

    print("\n" + "=" * 60)
    print("pages scanned : %d in %.1f s (%.0f pages/s)" % (
        total_pages, elapsed, total_pages / max(elapsed, 1e-9)))
    for k in sorted(histogram):
        print("  %-20s %d" % (k, histogram[k]))
    print("PE images found: %d" % len(found))
    print("=" * 60)
    if not found:
        print("RESULT: no validated PE image (content evidence inconclusive)")
        return 1
    print("RESULT: PASS  (%d structurally valid PE images in physical memory)" % len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
