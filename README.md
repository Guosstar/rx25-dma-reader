# RX25 — Driverless PCIe DMA memory reader

A two-board FPGA system that reads the physical memory of a machine **without installing any
driver, service or helper process on that machine**.

> **Read-only, authorised use only.** The backend cannot write to the target (`fWritable = FALSE`,
> no write path implemented). Use it only on systems you own or are explicitly authorised to test.
> See [Intended use and restrictions](#intended-use-and-restrictions).

One board sits in the *initiating* host (which runs a normal Windows driver), the other sits in
the *target* host with nothing installed at all. The two boards talk over a private 25G optical
link. To the target operating system the second board is just an unconfigured PCIe endpoint with
a yellow exclamation mark.

```
  initiator host                                target host
  ┌──────────────────────────┐                 ┌──────────────────────────┐
  │ tool / PCILeech          │                 │  (no driver, no agent)   │
  │   ↓ LeechCore API        │                 │                          │
  │ leechcore.dll  (rx25)    │                 │                          │
  │   ↓ IOCTL                │                 │                          │
  │ rx25dma.sys              │                 │                          │
  │   ↓ BAR + common buffer  │                 │                          │
  │ A board  ──── 25G ────►  │  PL11 frames    │  B board                 │
  │          ◄──── 25G ────  │                 │    ↓ MRd / completion    │
  └──────────────────────────┘                 │  target physical memory  │
                                               └──────────────────────────┘
```

## Status

| Capability | State |
|---|---|
| Read target physical memory, no driver on target | **works** |
| 16 B / 4 KiB / 8 KiB reads, unaligned and page-crossing | **works** |
| Error on unreadable ranges does not poison later requests | **works** |
| PCILeech integration, unmodified binary | **works** (`-device rx25`) |
| 200 consecutive reads, identical content | **passed** |
| Survives target power cycle without touching the initiator | **no** — see Known limitations |
| Byte-exact comparison against an independent source | **not done** |

## Repository layout

```
rtl/          FPGA sources: src/ (SystemVerilog + XDC), ip/, build TCL at the root
third_party/  corundum + taxi, vendored (BSD-3), needed by the build
host/
  leechcore/  LeechCore device backend + the LcRead fix
  driver/     Windows KMDF driver for the initiating board
tools/        host-side test and probe scripts
docs/         architecture, reproduction steps, current status
```

The TCL scripts resolve `src/` and `ip/` relative to their own directory and `third_party/` one
level up, which is why the layout above is fixed — do not flatten `rtl/`.

## How it works in one paragraph

The initiator driver exposes an 8 KiB common buffer: `0x0000-0x0FFF` for payload, `0x1000-0x101F`
for a completion queue. To perform a read, the host poisons the payload area, submits a 32-byte
descriptor (slot, length, remote physical address, host IOVA, request id, generation) and rings a
doorbell. The A board packs the request into a PL11 frame and sends it over the optical link. The B
board validates the request, issues an `MRd` into its own host's physical memory, waits for the
completion and returns the payload in a PL11 data frame. The A board writes the payload into the
common buffer and publishes a CQ entry. The host polls for the CQ generation, verifies the echoed
request id, and reads the payload back.

A single descriptor moves at most 256 bytes; a 4 KiB page is split into 16 descriptors and a
descriptor never straddles a page boundary.

## Quick start

1. Build the FPGA images — see `docs/reproduce.md`.
2. Load the initiator image into the A board, the responder image into the B board.
3. Install `rx25dma.sys` on the initiator host only.
4. Build `leechcore.dll` with the `rx25` backend.
5. Run `tools/scripts/lc_rx25_test.cmd` as administrator.

Expected output for a working setup:

```
create : OK
[1] 0x10000000 len 16     SUCCESS
[2] 0x10000000 len 4096   SUCCESS
[3] reserved address      typed failure (informational)
[4] recovery              SUCCESS
[5] second page x2        SUCCESS, identical
[6] long run 200 reads    bad=0
[7] LcRead 6 cases        all match
RESULT: PASS
```

## Platform requirements

The target host must permit the endpoint to perform DMA to the address ranges you intend to read.
That permission is decided by the platform (firmware and operating system policy), not by this
project, and the default differs between machines. Record what your target allows, test the exact
addresses you need, and do not assume a range is readable just because another machine allowed it.

Reads inside a permitted range still fail per-address for reserved regions; those failures are
reported as typed errors rather than silently returning zeros.

## Known limitations

- **Target power cycle forces an initiator reconfiguration.** When the responder board loses power,
  the request engine in the initiator latches a terminal fault state and stops completing
  requests. The fault is not published to software today, so the symptom is a plain timeout. Root
  cause is analysed in `docs/status.md`; the fix is a state machine change, not yet implemented.
- **Descriptor alignment.** Lengths must be multiples of 16 bytes, at least 16 and at most 256;
  addresses must be 16-byte aligned. Sub-16-byte tails return `PARTIAL_COMPLETION` / `NOT_ISSUED`.
- **Address window is 1 TiB.** Larger physical addresses are outside the advertised range.
- **No independent content verification yet.** The current content evidence is structural (PE
  headers found by scanning) plus self-consistency, not a byte comparison against a trusted
  source.
- **Session ownership is not fully specified.** The common buffer is reused and zeroed on open;
  zeroing is not proof that older transactions have drained.

## Intended use and restrictions

This project is published as a **hardware engineering reference** for FPGA, PCIe and DMA work,
and for memory analysis on machines that you own or are explicitly authorised in writing to
examine.

**The backend is read-only by construction.** The RX25 LeechCore device advertises
`fWritable = FALSE` and implements no scatter-write entry point, so it cannot write to the
target's memory. It reads; it does not modify, corrupt or persist anything on the target.

### Permitted

- your own lab equipment, test benches and development boards;
- security research and forensics under a written scope with the system owner;
- studying the RTL, the link protocol and the driver as a worked example.

### Prohibited

Do not use this project, in whole or in part, to:

- access any system that you do not own and are not authorised to test;
- cause damage, data loss, service disruption or any other destructive effect, on any system;
- defeat protections on third-party, production or shared infrastructure;
- violate computer-misuse, privacy, export-control or any other applicable law.

The authors provide this material for legitimate engineering and research. **You are solely
responsible for how you use it and for complying with the law in your jurisdiction.** Nothing here
is a grant of permission to access a system you do not control.

## License

Host-side code that links against LeechCore inherits LeechCore's GPL-3.0. See `LICENSE`.
PCILeech itself is AGPL-3.0 and is **not** redistributed here; use your own build.

## Acknowledgements

Built on [LeechCore](https://github.com/ufrisk/LeechCore) by Ulf Frisk.
