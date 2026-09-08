# TEST_MATRIX

Run: `cd macOS && swift run SpoolworksTests` · Hardware: `cd macOS && swift run spooldiag <cmd>`
Status at last update: **556 automated tests passing**, 0 failing.

## Automated — domain (no hardware required)

| Area | Scenario | Type | Status |
|---|---|---|---|
| Hex | byte↔hex round-trip, spaced form, ASCII dump | unit | pass |
| Hex | malformed input (odd length, non-hex) rejected | unit | pass |
| MIFARE key | default key, wrong length rejected, hex parsing | unit | pass |
| Card type | real ACR1552 ATR → Classic 1K; 4K/Ultralight; unknown ATR | unit | pass |
| Geometry | block/sector maths, trailer + manufacturer detection | unit | pass |
| Auth | default key succeeds; wrong key returns false, does not throw | unit | pass |
| Auth | `authenticateAny` finds the right key; throws when none work | unit | pass |
| Auth | **failed auth poisons session until reset** (real hardware bug) | regression | pass |
| Auth | `authenticateAny` recovers after a wrong first key | regression | pass |
| Auth | `dumpAll` still reads factory sectors after an earlier failure | regression | pass |
| Auth | derived key opens a sector locked to that derived key | integration | pass |
| Read/write | write→read round-trip through the mock card | unit | pass |
| Safety | refuses to write block 0 (manufacturer) | unit | pass |
| Safety | refuses trailer write without explicit opt-in | unit | pass |
| Safety | allows trailer write with opt-in, preserving access bits | unit | pass |
| Safety | full backup captured before the first write APDU | unit | pass |
| Safety | non-1K card and non-4-byte UID refused before any APDU | unit | pass |
| Colour scan | sRGB ↔ CIELAB round-trips exactly for primaries and neutrals | unit | pass |
| Colour scan | white lands at L\* 100.0000039, as the standard matrix's row sums predict | unit | pass |
| Colour scan | chromatic angle holds one material across shading (1.8°) where Lab a\*/b\* does not (35) | unit | pass |
| Colour scan | patch means are taken in linear light, not on the encoded codes | unit | pass |
| Colour scan | shaded wrap reads the lit filament: ΔE 1.3 vs mean 7.6, median 4.1 | synthetic | pass |
| Colour scan | clipping specular highlight rejected: ΔE 2.9 vs mean 11.8 | synthetic | pass |
| Colour scan | 25% spool core in frame excluded not diluted: ΔE 1.4 vs mean 21.1 | synthetic | pass |
| Colour scan | shadow + highlight + contamination + noise together: ΔE 3.7 vs mean 35.9 | synthetic | pass |
| Colour scan | white clips on every channel and is still read, with a too-bright warning | synthetic | pass |
| Colour scan | black filament read to ΔE 0.8 — the weakest case for the angle metric | synthetic | pass |
| Colour scan | patch averaging absorbs sensor noise entirely (ΔE < 0.5 vs the clean render) | synthetic | pass |
| Colour scan | underexposed target warns and drops to low confidence rather than drifting | synthetic | pass |
| Colour scan | an exact two-colour tie resolves identically on every run | regression | pass |
| Colour scan | stabiliser: median ignores one ruined frame; steadiness needs a full window | unit | pass |
| Colour scan | stabiliser reports the *worst* confidence in the window, not the average | unit | pass |
| Colour scan | target square is centred and inside the frame at every aspect ratio | unit | pass |
| Colour scan | a letterboxed preview targets the video rectangle, not the view | regression | pass |
| Crypto | keys match Arduino `u_key` / `d_key` byte-for-byte | unit | pass |
| Crypto | golden vectors vs. compiled Arduino reference (4 vectors) | golden | pass |
| Crypto | ECB determinism; equal tails ⇒ equal block 6 | unit | pass |
| Crypto | payload round-trip; wrong lengths rejected | unit | pass |
| Codec | record encode/decode round-trip; all field validations | unit | pass |
| Codec | spec correction — block 6 is not invariant across serials | regression | pass |
| Material DB | real-fixture decode; misspelled `meterialType` preserved | unit | pass |
| Material DB | string-vs-number fields (`diameter`/`density`) both ways | unit | pass |
| Material DB | loss-free round-trip of unmodelled fields | unit | pass |
| Material DB | duplicate-id rejected (Windows defect a) | regression | pass |
| Material DB | edit replaces in place (Windows defect b) | regression | pass |
| Material DB | unknown id throws, no mutate-while-enumerating (defect c) | regression | pass |
| Material DB | empty list still persists (Windows defect d) | regression | pass |
| Material DB | version comparison numeric not lexicographic | unit | pass |
| Material DB | malformed JSON leaves state untouched | unit | pass |
| Colour | 31,861 records load; header/payload checksum agree | unit | pass |
| Colour | exact and nearest matches; black/white/edges | unit | pass |
| Colour | tie-breaks by CSV row order (5 verified vectors) | regression | pass |
| Colour | 7-char field with non-zero leading nibble rejected | unit | pass |
| Colour | 600/600 identical vs. independent reimplementation | cross-check | pass |

## Hardware-in-the-loop (executed on the user's ACS ACR1552)

| Scenario | Method | Result |
|---|---|---|
| Reader enumeration | `spooldiag readers` | pass — 2 contactless slots |
| Card type via ATR | `spooldiag watch` | pass — MIFARE Classic 1K |
| UID read | `FF CA 00 00 00` | pass — 4 tags read |
| Blank tag, factory key | fresh-session probe | pass — key B opens 15/16 sectors |
| Full 16-sector dump | `spooldiag dump` | pass |
| Tag `F0A77939`, all known keys | fresh-session probe, 6 keys × 2 types | locked — see D-009 |
| Tags `40C97A39` / `A0E67A39` "locked" | earlier probe | **WITHDRAWN** — contaminated by the session-poisoning bug; `40C97A39` later read AND written fine |
| **Write → verify → read back** | `spooldiag write --confirm` then `spooldiag read` | **PASS** — wrote `#FF0000` / serial `000042` to `40C97A39`, verified, fresh-session read returned exactly those bytes |
| `SCARD_SHARE_DIRECT` | probe | unsupported on macOS (D-005) |
| Write to a physical tag | — | **NOT YET RUN — needs user consent** |
| Read back a tag we wrote | — | **NOT YET RUN — blocked on the above** |

## Hardware-in-the-loop (executed against a real Creality K2 Plus, 192.168.10.198)

Read-only. Nothing was written to the printer and it was not rebooted.

| Scenario | Result |
|---|---|
| Reachability, port 22 | pass |
| SSH server identity | Dropbear on `K2Plus-E1DB`, Linux 5.4.61 armv7l |
| Algorithm negotiation | `curve25519-sha256` / `ssh-ed25519` / `chacha20-poly1305` — **modern; no legacy relaxation needed** |
| Password auth via askpass FIFO | pass — our credential mechanism works against real Dropbear |
| K2 database path `/mnt/UDISK/creality/userdata/box/` | **confirmed** |
| K1 path `/usr/data/creality/userdata/box/` | absent, as expected on a K2 |
| **`sftp-server` present?** | **NO — `cat`-based transfer was essential, `scp` would fail** |
| Upload deps (`wc -c`, `mv`, `chmod`) | all present; `printf test \| wc -c` → 4 |
| `/bin/sh` | busybox |
| Live database retrieved | 478,873 bytes, 98 records, version `1784284303` |
| Our parser vs. the real database | pass — decodes, and round-trips **20** base keys + ~90 kvParam keys per record with zero loss |
| Upload / reboot | **NOT RUN — would modify the printer** |

## UI scenarios — confirmed on hardware by the user

| Flow | Result |
|---|---|
| Read mode auto-reads a presented tag | **pass** |
| Read result stays after the tag is lifted | **pass** |
| Write mode auto-writes on presentation | **pass** |
| Post-write re-read shows the new contents | **pass** |
| Shared read/write layout | **pass** |
| Colour palette + Custom… wheel | **pass** |
| Reader screen shows one device, two slots | **pass** |
| Materials catalogue (66 filaments, seeded) | **pass** |

User confirmation: "works as designed."

## UI scenarios (detail, from the build-out)

| Flow | Scenario | Status |
|---|---|---|
| Reader status | no reader; reader present, no tag; unplug mid-session | pending |
| Tag read | blank tag; tag we wrote; OEM/locked tag; unsupported card type | pending |
| Tag write | confirmation shown; backup surfaced; success; failure mid-write | pending |
| Tag write | a blank tag authorises its own trailer write; a programmed one does not | `Tag arrivals` |
| Materials | empty DB; browse; add; edit; delete-with-confirm; validation errors | pending |
| Materials | id formats the shipped data actually uses (`E1001`, `P1001`) accepted | pending |
| Printers | none configured; add; upload with progress + cancel; upload failure | pending |
| Printers | password never rendered in plain text | pending |
| Settings | persistence across launches | pending |
| Cross-cutting | full keyboard navigation; VoiceOver on icon-only controls | pending |
| Cross-cutting | light and dark mode | pending |

## Known gaps

- ~~No end-to-end write has been performed on physical hardware.~~ **DONE.** A write was
  performed, verified against the tag, and confirmed by an independent fresh-session read. The
  core read/write path is proven on real hardware.
- **The UI displayed a stale record after writing**, which made three successful writes look like
  failures. Cause: the retained-read feature plus per-UID auto-read suppression. Being fixed.
- **No upload has been performed to the printer.** Connectivity, auth, paths, shell
  capabilities and the database format are all now verified against real hardware, but the
  write path itself (upload + reboot) has not been exercised and needs user consent.
- **Printer-side acceptance of a written tag** remains unverified — that needs a written tag
  and a print job.
