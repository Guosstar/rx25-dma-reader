# Current status

Last updated: 2026-11-18 21:30

## 1. What is verified

| Capability | Evidence |
|---|---|
| Driverless read of target physical memory | 15 structurally valid PE images found by scanning 24,560 pages |
| 16 B / 4 KiB / 8 KiB, aligned and unaligned | `LcRead` vs scatter reference, 6 cases, byte-identical |
| Errors do not poison later requests | 5 rounds of good/bad alternation, every good read recovered |
| 200 consecutive reads | `bad=0`, identical content, ~5 ms for the batch |
| Stock PCILeech binary | `info` rc=0, two dumps byte-identical to our own read |
| Request accounting | A issued 465 requests; B counted 465 requests and 1,395 words (= 465 × 3) |
| Content is not synthesised locally | B's buffer holds the same bytes the host received |

### Content evidence, stated precisely

Scanning 24,560 pages returned 24,464 successes and 96 typed failures, and 15 candidates passed
the PE header screen (`MZ`, `e_lfanew → PE\0\0`, known machine type, plausible section table).

That is **structural evidence, not an oracle**. It cannot catch a read that returns another valid
PE image from the wrong address, a repeated stale page, or a correct header with a wrong body. The
scanner also only checks the header fields — it does not verify `SizeOfOptionalHeader`, does not
validate full section bounds, and does not compare against independent expected content.

A byte-exact comparison against a trusted source is still outstanding. Until it exists, the
honest statement is: the data is structurally plausible and self-consistent, and the target-side
counters prove the transfers really happened.

## 2. Known defect: terminal fault on peer power loss

**Symptom.** If the responder host loses power, the initiator stops completing requests. It never
recovers on its own; the FPGA has to be reconfigured by hand.

**Measured behaviour** (four-phase register probe, one 16-byte read per phase):

| Register | normal | peer powered off | peer back on, initiator untouched | initiator reconfigured |
|---|---|---|---|---|
| `0x010` STATUS | `0x3` | `0x0` | `0x3` | `0x3` |
| `0x050` bit0 block_lock | 1 | **0** | 1 | 1 |
| `0x034` timeout | 0 | **1** | **1, unchanged** | 0 |
| read result | success | timeout | timeout, `STATUS=0x103` | success |

The link and the transceiver lock come back on their own. The request engine does not. The
`timeout` counter advancing once and then freezing is the tell: the engine is not waiting, it is
finished.

**Root cause.** `asmcehnk_rx25_req_engine.sv` has a single exit from payload-wait on timeout:

```systemverilog
end else if (timeout_cnt >= 32'(C_TIMEOUT_CYCLES)) begin
    timeouts  <= timeouts + 32'd1;
    cq_status <= 16'd6;      // written, but cq_valid is NOT raised
    state_reg <= S_FAULT;    // terminal until reset
end
```

`S_FAULT` never leaves. `STATUS.FATAL` is wired to a constant zero, and the status-6 entry is never
published to the completion queue, so software sees a plain timeout with no explanation. The slot
stays busy, `CORE_BUSY` comes up, and every later open is refused.

**Why it matters beyond the inconvenience.** The engine treats two very different situations
identically:

- *nothing received at all* (peer absent) — there is no partially emitted posted TLP to flush, so
  returning to `IDLE` and reporting a retryable error would be safe;
- *part of a frame received, payload started* — a posted TLP may be in flight, and `S_FAULT` is the
  right answer.

**Planned fix**, in order:

1. publish status 6 (raise `cq_valid`) and drive `STATUS.FATAL` from `state_reg == S_FAULT`, so the
   condition becomes visible instead of silent;
2. only enter `S_FAULT` when at least one payload word of the frame was received; otherwise return
   to `IDLE` with status 4;
3. add a software-writable BAR bit that resets the request engine, so recovery does not require
   reconfiguring the whole FPGA.

Item 2 is what turns "peer rebooted, reflash the initiator" into "peer rebooted, retry the read".

## 3. Open items

| # | Item | Blocking reason |
|---|---|---|
| 1 | Independent byte-exact content verification | no trusted address/content source on the target host |
| 2 | The terminal-fault fix above | needs RTL change, rebuild and reflash of both boards |
| 3 | Session ownership | buffer is zeroed on open; zeroing is not proof of drain |
| 4 | Completion detail field | `cq_detail` is hardwired to 0, so status 5 cannot be split into "peer short" vs "local write error" |
| 5 | Start-up / abnormal matrix | only the plain path and one power-cycle case have been exercised |
| 6 | Soak beyond 200 reads, with latency percentiles | current number is a coarse average from a rounded timer |
| 7 | Initiator flash image | the initiator board still has to be loaded over JTAG after a power cycle |

## 4. Test coverage, honestly

What has actually been run:

- 125 reads through the direct IOCTL tool: 120 successes, 5 expected failures, 100-read stability
- 200 reads through the LeechCore API, identical content
- one 4 KiB page, 16 descriptors, one call
- 24,560-page scan with typed results per page
- two dumps through an unmodified PCILeech binary, byte-compared against our read
- one full power cycle of the responder host

What has **not** been run:

- fault injection (wrong request id, stale generation, late completion)
- process kill mid-read, session reopen, device re-enumeration under load
- long soak with mixed addresses and lengths
- any byte comparison against an independent source

## 5. Reading the counters correctly

Two counters mislead if taken at face value:

- `0x03C rx_good` / `0x040 rx_bad` are **always zero** — they are not wired to frame counting. One
  successful read increments `0x048 tx_pkt` and `0x04C rx_pkt` by one each; use those.
- `0x030` bit 12 does **not** track the optical link; it stays set with the peer powered off. Use
  `0x010` bits 0/1 and `0x050` bit 0.

`0x0F8` (responder gate) is a latched value cleared only at reset. It answers "has anything ever
gone wrong since reset", not "is the current request healthy".

`arm_acc` in `0x0F4` is an 8-bit saturating counter — it stops at 255. Use `dbg_requests`
(`0x060`) for request accounting.
