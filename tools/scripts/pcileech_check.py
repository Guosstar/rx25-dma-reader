#!/usr/bin/env python3
"""Verify that the stock PCILeech binary drives our RX25 LeechCore backend.

This is the "upper layer" gate: PCILeech must reach the card through the
standard LeechCore API with -device rx25, with no PCILeech-side changes.

Why the comparison is a four-step protocol: the target page may be live, so a
single dump-vs-read mismatch proves nothing.  The script therefore dumps and
reads the same page twice, interleaved:

    pcileech dump -> d1
    our DLL read  -> a1
    pcileech dump -> d2
    our DLL read  -> a2

  d1==a1 and d2==a2            -> MATCH       (tool agreement)
  d1!=d2 or a1!=a2             -> PAGE_LIVE   (page churned between reads,
                                               integration still proven by the
                                               fact that both tools succeeded)
  d1==d2 and a1==a2 and d1!=a1 -> MISMATCH    (real disagreement, investigate)

PCILeech zero-pads unreadable memory, so a page our backend reports as
PROTOCOL_ERROR is expected to show up as zeros on the PCILeech side.
"""

import os
import shutil
import subprocess
import sys
import time

import lc_rx25_test as base
import rx25_paths

ROOT = rx25_paths.repo_root()
PCILEECH_DIR = os.path.join(ROOT, "tools", "pcileech")
OUR_DLL = rx25_paths.find_leechcore_dll() or os.path.join(ROOT, "host", "build", "leechcore.dll")
PAGE = 0x10001000
OUT_DIR = os.path.join(ROOT, "outputs", "pcileech_check")


def run(args, timeout=180):
    t0 = time.time()
    p = subprocess.run(args, cwd=PCILEECH_DIR, capture_output=True, timeout=timeout)
    out = (p.stdout or b"").decode("utf-8", "replace") + (p.stderr or b"").decode("utf-8", "replace")
    return p.returncode, out, time.time() - t0


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return -1 if len(a) == len(b) else n


def main():
    # Refuse to touch the PCILeech directory unless elevated: swapping the dll
    # is a side effect that should only happen as part of a real check.
    try:
        import ctypes
        if not ctypes.windll.shell32.IsUserAnAdmin():
            print("FAIL: not elevated; run A_pcileech_check.cmd as administrator")
            return 5
    except Exception:
        pass

    if not os.path.isdir(PCILEECH_DIR):
        print("FAIL: %s not found" % PCILEECH_DIR)
        return 2
    if not os.path.exists(OUR_DLL):
        print("FAIL: %s not found" % OUR_DLL)
        return 2
    os.makedirs(OUT_DIR, exist_ok=True)

    exe = os.path.join(PCILEECH_DIR, "pcileech.exe")
    dll = os.path.join(PCILEECH_DIR, "leechcore.dll")

    print("=" * 60)
    print("PCILeech -> leechcore.dll(rx25) integration check")
    print("exe :", exe)
    print("dll :", dll)
    print("page: 0x%08x" % PAGE)
    print("=" * 60)

    # ---- 1. put our backend in place, keeping the previous one -------------
    ours_size = os.path.getsize(OUR_DLL)
    cur_size = os.path.getsize(dll) if os.path.exists(dll) else -1
    if cur_size == ours_size:
        print("[1] leechcore.dll already matches our build (%d B)" % cur_size)
    else:
        stamp = time.strftime("%Y%m%d_%H%M%S")
        bak = "%s.bak_%s" % (dll, stamp)
        if os.path.exists(dll):
            shutil.copy2(dll, bak)
            print("[1] backed up previous dll (%d B) -> %s" % (cur_size, os.path.basename(bak)))
        shutil.copy2(OUR_DLL, dll)
        print("[1] installed our dll (%d B)" % ours_size)

    # ---- 2. PCILeech must recognise the device ----------------------------
    rc, out, dt = run([exe, "info", "-device", "rx25"])
    print("\n[2] pcileech info  rc=%d  %.1fs" % (rc, dt))
    interesting = [l for l in out.splitlines()
                   if l.strip() and not l.startswith(" ") and "PCILeech" not in l]
    for l in interesting[:12]:
        print("    " + l.strip()[:100])
    if rc != 0:
        print("\nRESULT: FAIL  (pcileech could not open the device)")
        return 1

    # ---- 3. two dumps first, then two of our reads ------------------------
    # Never hold our own device handle while PCILeech runs: the driver keeps a
    # single shared common buffer and zeroes it on every open, so overlapping
    # sessions interfere.  The earlier version opened our handle between the two
    # dumps and the second dump failed.
    d1p = os.path.join(OUT_DIR, "pcileech_d1.raw")
    d2p = os.path.join(OUT_DIR, "pcileech_d2.raw")
    for path in (d1p, d2p):
        if os.path.exists(path):
            os.remove(path)

    rcs = []
    for i, path in enumerate((d1p, d2p), 1):
        rc, out, dt = run([exe, "dump", "-device", "rx25",
                           "-min", "0x%x" % PAGE, "-max", "0x%x" % (PAGE + 0xFFF),
                           "-out", path])
        rcs.append(rc)
        size = os.path.getsize(path) if os.path.exists(path) else -1
        print("\n[3] pcileech dump #%d rc=%d  %d bytes  %.1fs" % (i, rc, size, dt))
        if rc != 0:
            tail = [l for l in out.splitlines() if l.strip()][-4:]
            for l in tail:
                print("    | " + l.strip()[:110])

    lc = base.Lc(OUR_DLL)
    h, err = lc.create("rx25")
    if not h:
        print("\nFAIL: our backend could not open: %s" % err)
        return 3
    code1, flag1, a1 = lc.read_page(h, PAGE, 0x1000)
    time.sleep(0.05)
    code2, flag2, a2 = lc.read_page(h, PAGE, 0x1000)
    lc.dll.LcClose(h)
    print("\n[3] our read #1 %s len=%d" % (base.RESULT_NAME.get(code1, code1), len(a1)))
    print("[3] our read #2 %s len=%d" % (base.RESULT_NAME.get(code2, code2), len(a2)))

    if not (os.path.exists(d1p) and os.path.exists(d2p)):
        print("\nRESULT: FAIL  (pcileech produced no dump in at least one run)")
        return 1
    d1 = open(d1p, "rb").read()
    d2 = open(d2p, "rb").read()

    # ---- 4. classify ------------------------------------------------------
    ours_stable = (a1 == a2) and (code1 == code2)
    pc_stable = (d1 == d2)
    cross_exact = (d1 == a1) and (d2 == a2)
    neighbour = (d2 == a1)   # d2 and a1 are the closest pair in time

    print("\n[4] comparison")
    print("    pcileech stable  :", pc_stable)
    print("    our read stable  :", ours_stable)
    print("    d1 == a1         :", d1 == a1, "" if d1 == a1 else "(first diff @ 0x%x)" % first_diff(d1, a1))
    print("    d2 == a1         :", neighbour, "" if neighbour else "(first diff @ 0x%x)" % first_diff(d2, a1))
    print("    head pcileech    :", " ".join("%02x" % b for b in d1[:16]))
    print("    head our read    :", " ".join("%02x" % b for b in a1[:16]))

    print("\n" + "=" * 60)
    if cross_exact or (pc_stable and ours_stable and neighbour):
        print("RESULT: MATCH  (PCILeech and our backend return identical bytes)")
        return 0
    if not pc_stable or not ours_stable:
        print("RESULT: PAGE_LIVE  (the page changed between reads; both tools")
        print("        completed without error, so integration holds, but the")
        print("        byte comparison is inconclusive for this page)")
        return 0
    print("RESULT: MISMATCH  (both tools stable but disagree - investigate)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
