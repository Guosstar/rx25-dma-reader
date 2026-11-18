#!/usr/bin/env python3
"""Where the shared pieces live on disk.

These scripts run straight from a checkout, and the LeechCore tree they need is
fetched rather than vendored.  Keeping the search order in one place means the
.cmd wrappers and the Python tools cannot drift apart, and nobody has to edit a
path to get a test running.

LeechCore resolution order, first hit wins:

  1. LEECHCORE_ROOT environment variable
  2. <repo>/third_party/LeechCore          where fetch_leechcore.cmd clones to
  3. <repo>/../LeechCore                   sibling checkout
  4. <repo>/pcileech-as02-3p/LeechCore     legacy private layout

The same order is implemented in build_leechcore_link.cmd and
A_rebuild_and_test.cmd; change both if you change it here.
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

DLL_RELPATHS = [
    os.path.join("files", "leechcore.dll"),
    "leechcore.dll",
]


def repo_root():
    """Absolute path to the repository root."""
    return REPO_ROOT


def leechcore_candidates():
    """Every directory that might hold a LeechCore checkout, in priority order."""
    cands = []
    env = os.environ.get("LEECHCORE_ROOT")
    if env:
        cands.append(env)
    cands.extend([
        os.path.join(REPO_ROOT, "third_party", "LeechCore"),
        os.path.join(REPO_ROOT, "..", "LeechCore"),
        os.path.join(REPO_ROOT, "pcileech-as02-3p", "LeechCore"),
    ])
    return [os.path.abspath(c) for c in cands]


def find_leechcore_root():
    """Directory holding LeechCore.sln, or None."""
    for c in leechcore_candidates():
        if os.path.isfile(os.path.join(c, "LeechCore.sln")):
            return c
    return None


def find_leechcore_dll():
    """Path to the built leechcore.dll, or None if it is not there yet."""
    for c in leechcore_candidates():
        for rel in DLL_RELPATHS:
            p = os.path.join(c, rel)
            if os.path.isfile(p):
                return p
    # Last resort: a dll dropped next to the test scripts.
    local = os.path.join(HERE, "leechcore.dll")
    if os.path.isfile(local):
        return local
    return None


def leechcore_hint():
    """One-line instruction for the error path."""
    return ("run tools\\scripts\\fetch_leechcore.cmd, build it, or point "
            "LEECHCORE_ROOT at a checkout containing LeechCore.sln")
