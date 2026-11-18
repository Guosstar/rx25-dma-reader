# Reproducing the current state

Everything below was executed on 2026-11-18 and produced the results in `docs/status.md`.
Bitstreams and flash images are **not** in this repository — they are build products. The hashes
listed here identify the exact binaries used for the recorded runs.

## 1. Toolchain

| Component | Version used |
|---|---|
| Vivado | 2024.2 (build 1730312347) |
| FPGA | `xcku3p` (Kintex UltraScale+) |
| MSVC platform toolset | `v145` (Visual Studio 2026) |
| Windows SDK | 10.0.26100.0 |
| Initiator host | Windows 10 `10.0.19045` |
| Target host | Windows 10 `10.0.19045`, 31.7 GB RAM |
| Driver | `rx25dma.sys` 0.1.4.3, provider `RX25 Development` |

### Two build gotchas that cost time

- The `.vcxproj` requests `PlatformToolset=v143`. If only a newer toolset is installed, MSBuild
  stops with `MSB8020`. The correct value is the one present under
  `MSBuild\Microsoft\VC\v180\Platforms\x64\PlatformToolsets\*` — on Visual Studio 2026 that is
  **`v145`**, not `v180` (v180 is only the targets directory name).
- The project's post-build step copies output to a drive that need not exist. Build with
  `/p:PostBuildEventUseInBuild=false` or the build fails after a successful link.

## 2. Build the FPGA images

```bash
cd rtl
vivado -mode batch -source vivado_build_rx25_as02.tcl
```

The scripts take the role-specific parameters; the responder is the same RTL with the
`PARAM_RX25_ADDR_MODE` / `PARAM_RX25_REAL_MEM` parameters asserted.

**Always program a fresh bitstream once and check that `DONE` goes high before trusting it.**
Bitstream generation is not reproducible byte-for-byte: the same routed checkpoint produced two
files with different hashes, one of which did not configure. Treat "bitgen returned success" as
necessary but not sufficient.

### Entry points

| Script | Use |
|---|---|
| `vivado_generate_project_as02.tcl` | create the project; single source of truth for parameters |
| `vivado_build_rx25_as02.tcl` | full build for the initiator image |
| `vivado_build_rx25_resp.tcl` | full build for the responder image |
| `vivado_program_as02.tcl` | load a `.bit` over JTAG (`AS02_PROGRAM_BIT`, `AS02_PROGRAM_TARGET`) |
| `flash_rx25.tcl` | build an MCS and burn it to the on-board QSPI |

Three helper scripts (`vivado_bit_rx25_init_tmp.tcl`, `vivado_bit_rx25_resp.tcl`,
`vivado_rebuild_rx25_id.tcl`) regenerate a bitstream from an existing `routed.dcp` and still carry
the authoring machine's absolute paths. They are kept for reference; edit the two `set dcp` /
`set out` lines before using them.

## 3. Load the boards

- JTAG: `vivado -mode batch -source vivado_program_as02.tcl` with `AS02_PROGRAM_BIT` and
  `AS02_PROGRAM_TARGET` set.
- Persistent: `flash_rx25.tcl` builds a `write_cfgmem -size 32 -interface SPIx4` image and burns
  it with `program_hw_cfgmem` (never `program_hw_devices`, which only loads the FPGA). Part is
  `mt25qu256`.

After burning the responder image the board boots on its own; no JTAG is needed at power-up. That
was verified: after a full power cycle the board enumerated as `1234:c070` and reported
`CAPS=0x30F` with `Command=0x0007`.

## 4. Build the driver

`host/driver/rx25dma.vcxproj`, `Release|x64`. Install on the initiating host only. The target host
must have **no** driver bound to the device — that is the whole point, and it shows up as
`CM_PROB_FAILED_INSTALL` with a plain functional description.

## 5. Build LeechCore with the rx25 backend

The files in `host/leechcore/` are the customisations on top of upstream LeechCore (GPL-3.0):

| File | Origin |
|---|---|
| `device_rx25.c`, `device_rx25_result.c/.h` | added by this project |
| `leechcore.c` | upstream, plus the `LcRead` fix described below |
| `leechcore.h` | upstream, unchanged |

Upstream LeechCore itself is **not** vendored here. Clone it, then copy the four files above over
the corresponding files in `LeechCore/leechcore/`:

```bash
git clone https://github.com/ufrisk/LeechCore
cp host/leechcore/*.c host/leechcore/*.h LeechCore/leechcore/
```

The helper script `tools/scripts/build_leechcore_link.cmd` expects that result at
`<root>/pcileech-as02-3p/LeechCore` — adjust `SLN` if you keep the checkout elsewhere.

Build:

```bat
msbuild LeechCore.sln /t:leechcore /p:Configuration=Release /p:Platform=x64 ^
        /p:PostBuildEventUseInBuild=false /p:PlatformToolset=v145
```

Output: `LeechCore\files\leechcore.dll`.

### The `LcRead` fix that is included

Upstream `LcRead` computes the middle-chunk length as

```c
cb - (fFirst ? 0x1000 - (pa & 0xfff) : 0) - (fLast ? (pa + cb) & 0xfff : 0)
```

For a sub-page read that starts page-aligned, `fFirst` is still set (because `cb < 0x1000`), so the
expression subtracts a whole page from a smaller request and underflows to ~4 GiB.
`LcAllocScatter3` rejects it before anything reaches the device. The fix clamps the first partial
page to the request size:

```c
if(fFirst) { cbFirst = 0x1000 - (pa & 0xfff); if(cbFirst > cb) { cbFirst = cb; } }
```

## 6. Run the acceptance tests

All test entry points require an elevated shell because the device is admin-only.

```bat
tools\scripts\A_rebuild_and_test.cmd     :: rebuild dll, then [1]..[7] plus a 200-read soak
tools\scripts\A_pcileech_check.cmd       :: drive the stock pcileech.exe through the same dll
```

`lc_rx25_test.py` covers seven groups:

| # | What |
|---|---|
| 1 | 16-byte read of a known-good page |
| 2 | full 4 KiB page (16 descriptors) |
| 3 | reserved address — informational, a typed failure is normal |
| 4 | recovery after that failure |
| 5 | second page read twice, self-consistency |
| 6 | 200 consecutive reads, identical content |
| 7 | `LcRead` at 16/32/4096/8192 B, unaligned start, page crossing |

## 7. Reference hashes

These identify the binaries behind the results in `docs/status.md`. They will differ if you rebuild.

| Artefact | Size | SHA256 |
|---|---|---|
| A bitstream (initiator) | 6,699,246 | `998ddc8a70f2806d3d97ec2aec4bac219fc0232793bafda6ea6134faa582a082` |
| B bitstream (responder) | 6,972,858 | `6b07465fd2c625a116d9f235d423d3c9dcb9b05058f91028681f5420cec14349` |
| B flash image (MCS) | 19,612,607 | `8e09a33f180a5e6faef97413f12cb8a5a6101781110b02fdd434bdb39d0231ba` |
| `leechcore.dll` | 176,128 | `58716549c9dfc31257a76a7b4624df32dc2919adbab80c14394ea12c42d536d4` |
| `rx25dma.sys` | — | `b74653e176ed84507117e1d9b12c4961da2975d9f19b2508b1fcbac8d70e4258` |

Timing at build: A `WNS +0.003 / WHS +0.010`, B `WNS +0.004 / WHS +0.007`.

## 8. Target platform

The target host must allow the endpoint to perform DMA to the address ranges you want to read.
That is a platform decision, taken outside this project. Confirm it on your own machine and test
the exact addresses you intend to use — a range that is readable on one host is not automatically
readable on another, and reserved regions fail even on a permissive host.

Failures in that direction are reported as typed errors (`PROTOCOL_ERROR`, `NO_COMPLETION`,
`NOT_ISSUED`), never as zero-filled success.

## 9. Integrating with PCILeech

No changes to PCILeech are needed if it can be pointed at the device name:

```
pcileech.exe info -device rx25
pcileech.exe dump -device rx25 -min 0x10000000 -max 0x10000fff -out page.raw
```

If your build hard-codes a different device string, either pass the option through or interpose a
thin adapter that rewrites the device name to `rx25` before calling `LcCreateEx`.

`A_pcileech_check.cmd` compares a PCILeech dump against the same page read through the LeechCore
API and reports `MATCH` only when the bytes are identical.
