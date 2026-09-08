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
| **Inventory** | Every spool you own, filterable by where it is and how much is left, with a detail rail carrying its full usage history. Location and % remaining are edited in place — the places are a list you keep, and every correction to the figure writes the line that explains it. Slots the printer reports stay the printer's to set. |
| **Printer & CFS** | The printer's live slots, read from `material_box_info.json` over SSH every 30 s, folded into the inventory. |
| **Intake** | Log incoming spools without leaving the reader — scan a Creality tag, or describe a third-party spool and tag it. Its colour can be read off the spool with a camera. |
| **Read / identify** | Put a tag on the reader and see *which of your spools it is*, not just what bytes it holds. |
| **Write tag** | Program a tag for a third-party spool, or replace a damaged one — and log it to stock. |

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

## Reading a spool's colour with the camera

Intake's Method B needs a colour for a spool that has no tag to read it from, and typing a hex code
means guessing. **Intake ▸ Colour ▸ Scan…** opens the camera instead: fill the small box with
filament, hold still until the corners turn green, take the reading.

It does not average the pixels, because averaging them is wrong. Filament is a 1.75 mm cylinder
wound in a spiral, so a close-up of a wrap is a corrugated surface — a specular highlight along
every strand, deep shadow in every valley, and the spool's core showing through the gaps. Measured
against a synthetic wrap of known colour, a plain average is **ΔE 7.6** out on shading alone and
**ΔE 21** once a quarter of the target is core; this reads **ΔE 1.3** and **ΔE 1.4**. It samples 400
points across the box, finds the dominant colour, and averages the best-lit slice of it — so shadow
and shine are discarded rather than mixed in. `docs/DECISIONS.md` D-010 has the reasoning and the
numbers.

**It is not a colorimeter, and the camera's white balance is why.** A spool under a warm lamp reads
warm, and auto white balance actively tries to neutralise a large field of one colour. The reading
is a good way to pick a swatch; it is offered into a field you can still type over, never applied
silently. An iPhone used as a Continuity Camera is much the better instrument — it focuses at a few
centimetres, which a built-in Mac camera cannot.

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
- Programming a blank tag rewrites its sector keys irreversibly. A blank tag authorises that
  itself — its sector 1 is still on the factory key and holds no record, so there is nothing
  on it to lose — and `TagService.writeTag` re-derives the claim from its own authentication
  and refuses if the two disagree. A tag that is already programmed is never re-keyed.
- Block 0 is never written.

## Building

No Xcode needed — Command Line Tools are enough.

```bash
swift build
swift run SpoolworksTests   # 556 tests, no reader or camera required
Tools/make-app.sh           # assemble Spoolworks.app
Tools/make-dmg.sh           # build the disk image into dist/
```

The app is signed with a local certificate if you have one and ad-hoc otherwise; either way there
is no Apple Developer ID, so the first launch needs a right-click ▸ **Open**.

### Stop the app asking for keychain access on every build

A keychain item records which application may read it, and an application is identified by its code
signature. **An ad-hoc signature has no stable identity** — every rebuild looks like a different
app, so Spoolworks has to be re-authorised for its own saved SSH password each time.

Fix it once, with a local self-signed certificate:

1. Open **Keychain Access** ▸ menu **Keychain Access** ▸ **Certificate Assistant** ▸
   **Create a Certificate…**
2. Name: `Spoolworks Local Signing` · Identity Type: **Self Signed Root** ·
   Certificate Type: **Code Signing**
3. Create, then Continue past the self-signed warning.

`Tools/make-app.sh` picks it up automatically, and the signature becomes

```
designated => identifier "com.obsidiang.spoolworks" and certificate leaf = H"…"
```

which is identical for every build. Authorise once and it holds. Override the name with
`SPOOLWORKS_SIGN_IDENTITY`; without a certificate the build falls back to ad-hoc and simply keeps
asking.

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
| `SpoolworksTests` | 556 tests, runnable without hardware |

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
| `reference/filamentcolors-swatches.json` | The fetch behind `Resources/filament-swatches.json`, kept with its upstream database version so the cache can be revalidated |
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
- **Verify by read-back cannot be switched off.** The design offers it as a checkbox; making it
  one would let someone disable the check that distinguishes "the reader returned `90 00`" from
  "the bytes are on the tag". It is shown as always-on instead.
- The Creality Cloud profile download validates the CDN host against an allow-list that is an
  educated guess; it fails closed.
- **The colour scanner has not been checked against a reference.** Its accuracy is measured against
  synthetic wraps with a known albedo, which validates the algorithm but not the camera in front of
  it; no reading has been compared with a colorimeter, and the camera's own white balance is an
  uncorrected error term. See D-010.
- `Format Tag` and Spoolman integration from the Windows app are not implemented.
