# Bundled resources

Everything in this directory ships inside `Spoolworks_SpoolworksCore.bundle` and is reached
through `SpoolworksCoreResources` (see `Support/ResourceBundle.swift`), never `Bundle.module`.

| File | What it is | Where it comes from |
|---|---|---|
| `colors.bin` | 31,861 named colours, a fixed-width binary table with a checksummed header. Read by `Color/ColorTable.swift`. | Generated from `reference/colors.db` by `Tools/build-color-table.sh`; the header layout and checksum are defined once, in that script and the Swift reader. |
| `filament-swatches.json` | 2,258 manufacturer swatches with measured colour and material, grouped by manufacturer. Read by `Color/FilamentSwatchLibrary.swift`. | Derived from `reference/filamentcolors-swatches.json`, an export of the filamentcolors.xyz library; `dbVersion` in the document records which. |
| `k1.json`, `k2.json`, `hi.json` | The factory material catalogue for each printer family, in the printer's own `material_database.json` envelope. Copied to the user's data directory on first run by `MaterialDatabase.seedFromBundle()`, and offered to an existing catalogue by `MaterialDatabase.topUpFromSeed()`. | Captured from the printers. `k2.json` is the 2026-07-17 K2 Plus capture (`result.version` `1784284303`), 96 records: `Sources/SpoolworksTests/Fixtures/printer-k2plus-material_database.json` verbatim, less its two `userMaterial` records — a slicer profile the printer had synced from the machine it was captured on, which duplicated id `00004` and carried that machine's filesystem path. `k1.json` and `hi.json` are still the 2025-09-26 captures. `reference/printer-dumps/` holds an older (2025-04-30) K2 Plus dump. |

| `vendor-k2.json` | The third-party catalogue: 194 filaments across Flashforge (46), Bambu Lab (41), Elegoo (30), Anycubic (27), Polymaker's consumer line (24), Overture (11), Prusament (8) and SUNLU (7). Offered separately in the Materials window, never merged into `k2.json`. | Assembled by `Tools/build-vendor-catalogue.py` from each maker's published OrcaSlicer profile, with the Creality generic record for the same polymer supplying everything the printer owns. **These ids are ours, not Creality's** — a tag written against one is ignored until the catalogue is uploaded to the printer. Each record carries `sourceProfile` (the resolved inheritance chain) and `sourceTemplate` (the Creality record it was built on); the 58 assembled from disagreeing per-printer profiles also carry `sourceConflicts`. |

| `refresh-k2.json` | For every record in `k2.json` and `vendor-k2.json`, its content fingerprint and the fingerprints of every earlier version of it this repository has committed. Read by `MaterialDatabase.refreshUntouchedRecords()`, which replaces a local record matching an earlier version with today's and leaves anything else alone. | Built by `Tools/build-refresh-index.py` from git history — rerun it whenever either catalogue changes. The fingerprint is defined in `Material/Fingerprint.swift` and mirrored in the script; a test recomputes every entry in Swift, so the two cannot silently disagree. |

A missing or unreadable file here is a build defect, not a runtime condition: `make-app.sh`
verifies the bundle's contents, and the colour table aborts loudly rather than degrading. The
swatch library is the one exception — it degrades to an empty picker — and logs why.
