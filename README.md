# Spoolworks

A native macOS app for Creality filament spool tags — read them, write them, and (in progress)
keep an inventory of the spools you own.

> **Derived from [DnG-Crafts/K2-RFID](https://github.com/DnG-Crafts/K2-RFID).** The tag format,
> the material databases and the reverse-engineering groundwork are theirs. This repository
> started as the macOS port of that project (contributed back as
> [DnG-Crafts/K2-RFID#51](https://github.com/DnG-Crafts/K2-RFID/pull/51)) and continues here as a
> separate app with a wider scope.

## Status

The tag read/write app is complete and works against real hardware. **Spool inventory is the
reason this repo exists and is not built yet.**

## What it does today

| | |
|---|---|
| **Read** | Place a tag on the reader — it is read and decoded automatically. |
| **Write** | Choose printer, brand, material, weight and colour, then present a tag. It is written automatically and verified by reading it back. |
| **Reader** | Device and slot detail, ATR, UID, firmware, rescan. |
| **Materials** | The filament catalogue, seeded from the bundled Creality databases. |
| **Printers** | Push a material database to a printer over SSH so it recognises custom filament IDs. |

## Requirements

- macOS 14 (Sonoma) or later
- A PC/SC USB reader — developed against an **ACS ACR1552**; an **ACR122U** speaks the same
  command set. No driver to install: macOS ships PC/SC.
- Blank **MIFARE Classic 1K** tags

## Scope — read this before buying tags

Spoolworks **programs blank MIFARE Classic 1K tags and reads back tags it wrote.**

It **cannot read a genuine Creality factory tag.** Those sectors are protected with keys Creality
has not published. Neither can the Windows app, the Android app, or the Arduino firmware: all
three know exactly two keys — the factory default `FFFFFFFFFFFF` and a key derived from the card
UID. That is a property of the original project, not a gap here. See
[`docs/DECISIONS.md`](docs/DECISIONS.md) D-009.

## Safety

Writing to a tag is the one destructive thing this app does, so:

- A full dump of every readable sector is captured **before the first write**.
- Every write is **verified** by reading the record back byte for byte. A reader returning
  `90 00` means the command was accepted, not that the bytes landed.
- Sector-trailer access bits are validated for the plain/inverted redundancy MIFARE requires — a
  mismatched pair permanently locks the sector.
- Programming a blank tag rewrites its sector keys irreversibly, and always asks first.
- Block 0 is never written.

## Building

No Xcode needed — Command Line Tools are enough.

```bash
swift build
swift run SpoolworksTests   # 352 tests, no reader required
Tools/make-app.sh           # assemble Spoolworks.app
Tools/make-dmg.sh           # build the disk image into dist/
```

The app is ad-hoc signed (there is no Apple Developer ID for this project), so the first launch
needs a right-click ▸ **Open**.

### Diagnostics

`spooldiag` is a read-only CLI for hardware bring-up (only `write --confirm` modifies a tag):

```bash
swift run spooldiag readers   # list readers, grouped by physical device
swift run spooldiag watch     # wait for a tag, report type and UID
swift run spooldiag dump      # dump every readable sector, decrypting sector 1
swift run spooldiag keys      # probe which keys open which sectors
swift run spooldiag read      # read and decode a spool record
```

## Layout

| Target | What it is |
|---|---|
| `CPCSC` | C shim isolating `PCSC.framework`, whose modulemap forbids Swift import |
| `SpoolworksCore` | All domain logic — PC/SC, MIFARE, crypto, codec, materials, colour, printer. No UI. |
| `SpoolworksUI` | The SwiftUI app, as a library so its state machine is testable |
| `Spoolworks` | Two-line executable; `@main` only |
| `SpoolworksDiag` | Diagnostic CLI (`spooldiag`) |
| `SpoolworksTests` | 352 tests, runnable without hardware |

`SpoolworksCore` imports no UI framework, so the entire codec, database and colour layer is
testable against a `MockTransport` that simulates a MIFARE card.

### `reference/`

Inputs that are not source, kept because the build tools and the specs depend on them:

| Path | Used by |
|---|---|
| `reference/colors.db` | `Tools/build-color-table.sh`, which regenerates `colors.bin` |
| `reference/arduino-aes/` | `Tools/aes-reference-check.sh`, which compiles the ESP32 firmware's AES natively to generate golden vectors |
| `reference/app-icon.ico` | `Tools/make-app.sh` — **a placeholder inherited from the Windows app; replace with the Spoolworks mark** |
| `reference/seeds/` | Provenance for the `{k1,k2,hi}.json` catalogues bundled in `SpoolworksCore/Resources` |
| `reference/printer-dumps/` | Real files pulled off a K2 Plus, used to validate the database format |

## Reading the source citations

`SPEC/` and the doc comments cite upstream paths such as `Windows/CFS-RFID/MainForm.cs:445` and
`Arduino/ESP32/Spool_ID/Spool_ID.ino:174`. **Those refer to
[DnG-Crafts/K2-RFID](https://github.com/DnG-Crafts/K2-RFID), not to this repository** — they are
the evidence trail for how the tag format was established, and are deliberately left intact.

## Licensing

The upstream project publishes no `LICENSE` file, so the terms under which this derivative may be
distributed are unsettled. Resolve that with the upstream author before releasing binaries.

## Known limitations

- **Ad-hoc signed**, so first launch needs a right-click. Notarisation requires a paid Apple
  Developer account.
- **Printer upload is verified against real hardware for connectivity, paths and shell
  capabilities, but no database has been uploaded** — that path is mock-tested only.
- The Creality Cloud profile download validates the CDN host against an allow-list that is an
  educated guess; it fails closed.
- `Format Tag` and Spoolman integration from the Windows app are not implemented.
