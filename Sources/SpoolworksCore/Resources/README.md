# Bundled resources

Everything in this directory ships inside `Spoolworks_SpoolworksCore.bundle` and is reached
through `SpoolworksCoreResources` (see `Support/ResourceBundle.swift`), never `Bundle.module`.

| File | What it is | Where it comes from |
|---|---|---|
| `colors.bin` | 31,861 named colours, a fixed-width binary table with a checksummed header. Read by `Color/ColorTable.swift`. | Generated from `reference/colors.db` by `Tools/build-color-table.sh`; the header layout and checksum are defined once, in that script and the Swift reader. |
| `filament-swatches.json` | 2,258 manufacturer swatches with measured colour and material, grouped by manufacturer. Read by `Color/FilamentSwatchLibrary.swift`. | Derived from `reference/filamentcolors-swatches.json`, an export of the filamentcolors.xyz library; `dbVersion` in the document records which. |
| `k1.json`, `k2.json`, `hi.json` | The factory material catalogue for each printer family, in the printer's own `material_database.json` envelope. Copied to the user's data directory on first run by `MaterialDatabase.seedFromBundle()`. | Captured from the printers; `reference/printer-dumps/` holds the raw K2 Plus dump they were checked against. |

A missing or unreadable file here is a build defect, not a runtime condition: `make-app.sh`
verifies the bundle's contents, and the colour table aborts loudly rather than degrading. The
swatch library is the one exception — it degrades to an empty picker — and logs why.
