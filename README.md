# Spoolworks

A native macOS app for Creality filament spool tags — read them, write them, and (in progress)
keep an inventory of the spools you own.

> **Derived from [DnG-Crafts/K2-RFID](https://github.com/DnG-Crafts/K2-RFID).** The tag format,
> the material databases and the reverse-engineering groundwork are theirs. This repository
> started as the macOS port of that project (contributed back as
> [DnG-Crafts/K2-RFID#51](https://github.com/DnG-Crafts/K2-RFID/pull/51)) and continues here as a
> separate app with a wider scope.

## The five screens

Built to the Claude Design handoff (`Filament Management App Design`), in its **Modernist** system:
flat, square-cornered, 2 pt rules, one red accent on a warm ground.

| Screen | What it does |
|---|---|
| **Inventory** | Every spool you own, filterable by where it is and how much is left, with a detail rail carrying its full usage history. |
| **Printer & CFS** | The printer's live slots, read from `material_box_info.json` over SSH every 30 s, folded into the inventory. |
| **Intake** | Log incoming spools without leaving the reader — scan a Creality tag, or describe a third-party spool and tag it. |
| **Read / identify** | Put a tag on the reader and see *which of your spools it is*, not just what bytes it holds. |
| **Write tag** | Program a tag for a third-party spool, or replace a damaged one. |

**Materials** and **Printers** are windows rather than sidebar entries — `Manage ▸ Materials`
(⇧⌘1) and `Manage ▸ Printers` (⇧⌘2). The design's sidebar has exactly five entries, but both
screens are still needed: the catalogue turns a filament id into a name on Intake and Write, and
the printer list is where the address and password the CFS poll uses are entered.

The former **Reader** screen is gone. Its diagnostics are the right-hand column of Read / identify,
and its one setting — show key material — moved into the Tag Memory window (⌘M), which is the only
place its effect is visible.

## How a spool is identified

Identity comes from the tag payload, because a spool carries **two** tags with different UIDs and
the same payload, and the CFS reports no UID at all.

The design says identity is "the tag's serial + filament ID". **That is not enough on real
hardware.** In this repository's own K2 Plus dump, all four slots report `serialNum 000001` —
Windows hard-codes it, so every factory spool of one material shares it. Colour is therefore part
of the key, which separates white from red from black. It still cannot separate two spools of the
*same* filament and colour (`T1B` and `T1D` in that dump, which is exactly why the firmware groups
them as auto-refill partners), so reconciliation binds slots to their incumbent spool first. A
spool stays attached to the slot it was last seen in rather than swapping histories with its twin
on every poll.

One other correction: **length code `0165` is 500 g, not 1 kg.** The design's decoded-field panel
says 1 kg; `Utils.cs:172-188`, the ESP32 firmware and the printer dump all disagree. 1 kg is `0330`.

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
swift run SpoolworksTests   # 409 tests, no reader required
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
| `SpoolworksCore` | All domain logic — PC/SC, MIFARE, crypto, codec, materials, colour, printer, **spool inventory**. No UI. |
| `SpoolworksUI` | The SwiftUI app, as a library so its state machine is testable |
| `Spoolworks` | Two-line executable; `@main` only |
| `SpoolworksDiag` | Diagnostic CLI (`spooldiag`) |
| `SpoolworksTests` | 409 tests, runnable without hardware |

`SpoolworksCore` imports no UI framework, so the entire codec, database and colour layer is
testable against a `MockTransport` that simulates a MIFARE card.

### `reference/`

Inputs that are not source, kept because the build tools, the specs and the tests depend on them:

| Path | Used by |
|---|---|
| `reference/colors.db` | `Tools/build-color-table.sh`, which regenerates `colors.bin` |
| `reference/arduino-aes/` | `Tools/aes-reference-check.sh`, which compiles the ESP32 firmware's AES natively to generate golden vectors |
| `Resources/AppIcon.icns` | `Tools/make-app.sh`. Generated from the design tokens by `Tools/make-icon.swift` — regenerate it if the palette changes |
| `reference/seeds/` | Provenance for the `{k1,k2,hi}.json` catalogues bundled in `SpoolworksCore/Resources` |
| `reference/printer-dumps/` | Real files pulled off a K2 Plus. `material_box_info.json` is also a test fixture: it is what proves the serial-collision problem above is real, not hypothetical |

## Reading the source citations

`SPEC/` and the doc comments cite upstream paths such as `Windows/CFS-RFID/MainForm.cs:445` and
`Arduino/ESP32/Spool_ID/Spool_ID.ino:174`. **Those refer to
[DnG-Crafts/K2-RFID](https://github.com/DnG-Crafts/K2-RFID), not to this repository** — they are
the evidence trail for how the tag format was established, and are deliberately left intact.

## Licensing

**MIT** — see [`LICENSE`](LICENSE). [`NOTICE`](NOTICE) credits the work this is built on:
DnG-Crafts/K2-RFID, whose reverse engineering of the tag format made the whole thing possible; the
meodai colour-name dataset; and Creality's material data.

## Known limitations

- **Ad-hoc signed**, so first launch needs a right-click. Notarisation requires a paid Apple
  Developer account.
- **Printer upload and the CFS poll have never run against a real printer.** The UI is now wired to the real
  `SSHTransport` (it previously used a stand-in that threw "not implemented" from every method),
  and the transport itself is tested — but no database has been uploaded to, and no CFS polled
  from, a real printer since that wiring landed.
- **The Intake screen's "write both tags" hands off to the Write screen** rather than writing
  inline. Programming a blank tag rewrites its sector keys irreversibly, so it goes through the
  confirmation and read-back verification that path already has.
- The Creality Cloud profile download validates the CDN host against an allow-list that is an
  educated guess; it fails closed.
- `Format Tag` and Spoolman integration from the Windows app are not implemented.
