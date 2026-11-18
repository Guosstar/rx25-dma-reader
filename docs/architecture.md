# Architecture

## 1. Roles

| Board | Role | Host driver | Bitstream CAPS |
|---|---|---|---|
| A | initiator — issues reads, owns the common buffer | `rx25dma.sys` | `0x00F` |
| B | responder — performs `MRd` into its own host memory | none | `0x30F` |

The two roles are the same RTL with different parameters; `CAPS` is how each board reports which
personality it was built with.

## 2. Data path

```
host tool
  LcReadScatterEx / LcRead
    → leechcore.dll  (device_rx25.c)
      → IOCTL_RX25_DMA_{QUERY,READ,WRITE,SUBMIT,CONTROL}
        → rx25dma.sys  → BAR0 + 8 KiB common buffer
          → A board: PL11 request frame over SFP0
            → B board: validate → arm → MRd to target PA
              → target memory controller → completion
            ← B board: PL11 data frame with payload
          ← A board: write payload + publish CQ entry
        ← host: poll CQ generation, verify echoed request id, copy payload
```

## 3. Common buffer layout

8 KiB, page-aligned, allocated once per PnP start (`PrepareHardware`) and released only at
`ReleaseHardware`. Each `open` zeroes it and hands the session a new `BufferId`.

| Offset | Size | Use |
|---|---|---|
| `0x0000` | `0x1000` | payload area, poisoned with `0xCC` before every descriptor |
| `0x1000` | `0x20` | completion queue entry |

## 4. Descriptor

One 32-byte descriptor per slot, up to 8 slots. Layout is defined by `RX25_DMA_SUBMIT` in
`host/driver/rx25dma_public.h`; the driver validates every field before writing to the card:

| Constraint | Value |
|---|---|
| length | 16…256, multiple of 16 |
| `remote_pa` | 16-byte aligned, must not let `(pa & 0xFFF) + length` exceed 4096 |
| `host_iova` | 16-byte aligned, at least `0x1020` bytes must remain in the buffer |
| slot | < 8 |

`request_id` carries a 16-bit generation in its upper half, so a completion can be tied to the
exact request that produced it.

## 5. Completion queue entry

32 bytes, written dword by dword in the order **0, 2, 3, 4, …, 1** — dword 1 last. That ordering
is the publication marker: once `generation` advances, every other dword of the same entry is
already in memory, so a single read is a coherent snapshot.

| Dword | Contents |
|---|---|
| 0 | echoed `request_id` |
| 1 | `{status[31:16], generation[15:0]}` — written last |
| 2 | payload byte count |
| 3 | frame sequence |
| 4 | detail (currently always 0 in this firmware) |

### Status values

| Value | Meaning | Engine state after |
|---|---|---|
| 1 | record committed, payload valid | IDLE |
| 4 | no completion before the firmware timeout | IDLE |
| 5 | short record, or local memory-write error | IDLE |
| 6 | protocol error | terminal (`S_FAULT`) |

Values 5 and 6 are delivery faults, not PCIe completion statuses. They must never be surfaced as
`CA`/`Poison`.

The host accepts a completion only when **both** the generation and the echoed `request_id` match
what it submitted.

## 6. PL11 frame format

Private wire format between the two FPGAs. 6 × 64-bit header words, then 0..N payload words
(payload length always a multiple of 16). A receiver re-synchronises on `MAGIC` in word 0.

| Word | Bits | Field |
|---|---|---|
| w0 | `[31:0]` | magic `0x31314C50` (`"PL11"`) |
| | `[47:32]` | version |
| | `[63:48]` | type: 1 request, 2 data |
| w1 | `[31:0]` | request id |
| | `[47:32]` | sequence within the request, 0-based |
| | `[63:48]` | flags: bit0 = last record |
| w2 | `[31:0]` | payload bytes in this frame, or total length for a request |
| | `[63:32]` | status (responses only) |
| w3 | `[63:0]` | target physical address (request only) |
| w4 | `[63:0]` | host IOVA (response only, echo) |
| w5 | `[63:0]` | reserved, zero |

## 7. BAR0 register map

| Offset | Name | Notes |
|---|---|---|
| `0x000` | MAGIC | `0x35325852` |
| `0x004` | VERSION | 1 |
| `0x008` | CAPS | `0x00F` initiator / `0x30F` responder |
| `0x00C` | CONTROL | bit0 arm, bit2 QD8 |
| `0x010` | STATUS | bit0 READY, bit1 LINK_PEER, bit2 FATAL, bit7 QD8_ACTIVE, bit8 CORE_BUSY |
| `0x014` | SLOTS | 8 |
| `0x018` | descriptor stride | `0x20` |
| `0x01C` | CQ offset | `0x1000` |
| `0x024` | success | completed requests |
| `0x028` | parser_err | |
| `0x02C` | desc_reject | |
| `0x030` | link | `0x80001000` |
| `0x034` | timeout | firmware-side request timeouts |
| `0x038` | stale | |
| `0x03C` / `0x040` / `0x044` | rx_good / rx_bad / rx_ovf | **currently always 0 — not wired to frame counting** |
| `0x048` / `0x04C` | tx_pkt / rx_pkt | valid: one successful read increments each by 1 |
| `0x050` | link health | bit0 `block_lock`, bit1 `high_ber` |
| `0x054…0x060` | responder header diagnostics | length, remaining, header-ok, request count |
| `0x0F4` / `0x0F8` | responder gate | latched, cleared only by reset |

`STATUS.FATAL` and `0x050` are the only link-health indicators that are actually meaningful today.
`0x030` bit 12 does **not** track the optical link — it stays set even when the peer is powered
off.

## 8. Firmware state machines

**Initiator request engine** — `IDLE → (descriptor) → TX header → TX payload → wait completion →
DRAIN → CQ → IDLE`. Two escape hatches: the firmware timeout (status 4) and payload-wait timeout
(status 6, `S_FAULT`).

`S_FAULT` is terminal by design: a partially emitted posted TLP cannot be cancelled, so the engine
refuses further work until the FPGA is reconfigured. See `docs/status.md` for why that is too
coarse today.

**Responder** — validates the request frame, arms the guard (epoch / task / requester id), issues
`MRd`, waits for the completion, then returns the data frame. Guard state is sticky and reported
in `0x0F8`.

## 9. Host backend

`host/leechcore/device_rx25.c` implements the LeechCore device interface:

- `pfnReadScatter` / `pfnReadScatterEx` — split a page into ≤256 B descriptors and drive the
  submit/poll sequence
- `pfnClose` — release the session

The result model in `device_rx25_result.c` enforces ownership: a page is only reported successful
when the completion identity matched, the byte count matched, and the payload was actually read
back. A quarantine flag stops tag reuse after a failure that has no drain proof.
