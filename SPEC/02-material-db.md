# SPEC-02 — Material / Filament Database

Reverse-engineered from the Windows C# app (`Windows/CFS-RFID/`), the shipped
reference databases (`db/*.json`) and the printer-side captures (`docs/*.json`).

All line references are `file:line` against the repo as of commit `7101bac (v57)`.
Anything I could not establish from the source is marked **OPEN QUESTION** rather
than guessed.

---

## 1. The `Filament` model

`Windows/CFS-RFID/Filament.cs:1-8` — the entire in-memory model is five strings:

| C# property | Type | Source JSON key | Semantics |
|---|---|---|---|
| `FilamentName` | `string` | `base.name` | Marketing name, e.g. `"Hyper PLA"`, `"Generic PLA"` |
| `FilamentId` | `string` | `base.id` | 5-character material id, e.g. `"01001"`, `"00001"`, `"E1001"` |
| `FilamentVendor` | `string` | `base.brand` | Brand, e.g. `"Creality"`, `"Generic"`, `"eSUN"`, `"Polymaker"` |
| `FilamentType` | `string` | `base.meterialType` | Polymer family, e.g. `"PLA"`, `"PETG-CF"`. Note the **misspelling** `meterialType` in the wire format |
| `FilamentParam` | `string` | *the entire list item* | The whole `list[i]` object re-serialised to a compact JSON **string** |

Population happens in `MatDb.cs:39-46`; every field is `.Trim()`ed on load
(`MatDb.cs:41-44`).

**Critical design fact:** `FilamentParam` is the *complete* list element
(`engineVersion`, `printerIntName`, `nozzleDiameter`, `kvParam`, `base`) stored as
an opaque JSON string (`MatDb.cs:45` uses `item.ToString(Formatting.None)`). The four
scalar properties are a *denormalised cache* of four keys inside that blob. Writes
must update **both** (see §7). The Windows model deliberately does not type any of
the numeric/boolean base fields — temperatures, density, diameter etc. are only ever
touched through `FilamentParam`.

### 1.1 Fields inside `base` (the real material record)

Established from `db/k1.json`, `db/k2.json`, `db/hi.json` — all 133 records across the
three files have all 18 keys present, with consistent JSON types:

| Key | JSON type | Units / semantics | Observed values |
|---|---|---|---|
| `id` | string | 5 chars. Prefix encodes family (`01`=Hyper PLA, `02`=PLA-CF, `03`=ABS, `06`=PETG, `10`/`16`=TPU, `00`=Generic…). Not always numeric | `"00001"`…`"29001"`, plus `"E1001"` (eSUN) and `"P1001"`–`"P1003"` (Polymaker) in `k2.json` |
| `brand` | string | Vendor | `Creality`, `Generic`, `Polymaker`, `eSUN` |
| `name` | string | Product name | |
| `meterialType` | string | Polymer type (sic — misspelled) | 26 distinct values in k2, 20 in k1, 7 in hi |
| `colors` | array of string | Hex RGB with `#` prefix, **lowercase**. Always exactly 1 element in shipped data | only `#ffffff` (93×) and `#000000` (40×) |
| `density` | number (double) | g/cm³ | 1.03 – 1.31 |
| `diameter` | **string** | mm | always `"1.75"` |
| `costPerMeter` | number (int) | currency/m — unused | always `0` |
| `weightPerMeter` | number (int) | g/m — unused | always `0` |
| `rank` | number (int) | UI sort weight, descending | 10000 down to 4830; **not unique** — `4910` appears twice in each of k1/k2/hi |
| `minTemp` | number (int) | °C, nozzle minimum | 190–330 |
| `maxTemp` | number (int) | °C, nozzle maximum | 230–350 |
| `isSoluble` | bool | support material dissolves (PVA/BVOH) | |
| `isSupport` | bool | is a support-interface material | |
| `shrinkageRate` | number (int) | unitless ×0.1 %? only `0` and `40` seen | **OPEN QUESTION** — no code reads it |
| `softeningTemp` | number (int) | °C (glass transition); only `0` and `53` seen | |
| `dryingTemp` | number (int) | °C; only `0` and `50` seen | |
| `dryingTime` | number (int) | hours; only `0` and `6` seen | |

Length is **not** in `base`. Spool length lives on the RFID tag and is derived from a
weight picker: `Utils.cs:136-152` (`GetMaterialLength`) maps `"1 KG"→"0330"`,
`"750 G"→"0247"`, `"600 G"→"0198"`, `"500 G"→"0165"`, `"250 G"→"0082"` — i.e. a
4-digit **decimetre** count (0330 dm = 330 m for 1 kg of 1.75 mm PLA). Inverse:
`Utils.cs:154-170`. Grams: `Utils.cs:172-188`.

Colour is also *not* taken from `base.colors` at write time — the user picks an
arbitrary colour in a `ColorDialog` and it is stored as a 6-hex-digit uppercase string
(`MainForm.cs:705-711`, `MaterialColor = (dlg.Color.ToArgb() & 0x00FFFFFF).ToString("X6")`).

### 1.2 `kvParam` — the slicer profile

`kvParam` is a **flat map of string → string** (verified: all 12 082 values across
k1+k2+hi are JSON strings; there are no nested objects, numbers or booleans). Key
count per record is 90 (71 records), 91 (31), 92 (19), 93 (11) and 100 (1 —
`k1.json` id `01002` "Hyper L-W PLA", which adds `customized_plate_temp`,
`filament_long_retractions_when_cut`, `idle_temperature`, `pellet_flow_coefficient`
and 6 others). **Key sets are therefore NOT uniform** — never model `kvParam` as a
fixed struct.

Representative keys: `nozzle_temperature`, `nozzle_temperature_initial_layer`,
`nozzle_temperature_range_low/high`, `hot_plate_temp`, `filament_density`,
`filament_diameter`, `filament_type`, `filament_vendor`, `filament_cost`,
`filament_flow_ratio`, `filament_max_volumetric_speed`, `pressure_advance`,
`filament_start_gcode`/`filament_end_gcode` (multi-line G-code with `\n`),
`compatible_printers`, `inherits`. Values that are logically numeric are still
strings (`"190"`, `"1.24"`), booleans are `"0"`/`"1"`, and unset values are the
literal string `"nil"`.

Two `kvParam` keys are treated as *derived* by the app: on add, `filament_vendor` and
`filament_type` are overwritten from the brand/type comboboxes
(`FilamentForm.cs:279-286`).

`Windows/CFS-RFID/JsonItem.cs:1-5` is a trivial `{Key, Value}` string pair used only
to back the `kvParam` editing `ListView` (`FilamentForm.cs:99-114`).

---

## 2. On-disk JSON schema

Exact envelope (both the shipped `db/*.json` and everything the app writes):

```jsonc
{
  "code":   0,          // int,     always 0            (MatDb.cs:181, Utils.cs:892)
  "msg":    "ok",       // string,  always "ok"         (MatDb.cs:182, Utils.cs:893)
  "reqId":  "0",        // string,  "0" when written by this app (MatDb.cs:183, Utils.cs:894)
                        //   real printer captures carry e.g.
                        //   "cl602024082916552939795681" (docs/material_database.json)
  "result": {
    "list":    [ /* array of list-items, see below */ ],  // MatDb.cs:178
    "count":   66,      // int, == list.Length            // MatDb.cs:179
    "version": "1758907369"  // STRING, unix epoch seconds // MatDb.cs:180
  }
}
```

Each element of `result.list`:

```jsonc
{
  "engineVersion":   "3.0.0",          // string
  "printerIntName":  "F008",           // string, internal printer model code
  "nozzleDiameter":  ["0.4"],          // array of string (mm)
  "kvParam":         { "<key>": "<string value>", ... },   // 90–100 keys
  "base":            { ...18 keys, see §1.1... }
}
```

`printerIntName` observed values: `"F008"` (k2.json, docs/material_database.json),
`"CR-K1 Max"` (k1.json), `"F018"` (hi.json). `engineVersion` is `"3.0.0"` and
`nozzleDiameter` is `["0.4"]` in 100 % of shipped records.

Only `result`, `result.list`, `result.version`, `list[i].base` and the four `base`
keys `id`/`name`/`brand`/`meterialType` are ever *read* by the C# code
(`MatDb.cs:29-49`, `MatDb.cs:68-72`). Everything else is round-tripped verbatim.

### Record counts (as shipped)

| File | `result.count` | actual `list` length | `result.version` | `printerIntName` | brands |
|---|---|---|---|---|---|
| `db/k1.json` | 46 | 46 | `"1758907369"` | `CR-K1 Max` | Creality 25, Generic 21 |
| `db/k2.json` | 66 | 66 | `"1758907369"` | `F008` | Generic 31, Creality 30, Polymaker 3, eSUN 2 |
| `db/hi.json` | 21 | 21 | `"1758907369"` | `F018` | Creality 15, Generic 6 |
| `docs/material_database.json` | 56 | 56 | `"1746005657"` | `F008` | Generic 31, Creality 24, eSUN 1 |

All four files are pure 7-bit ASCII (0 bytes > 0x7F), consistent with the app's use of
`Encoding.ASCII` on both read (`MatDb.cs:23,62,83`) and write (`MatDb.cs:89,186`).
Note `ManageForm.cs:58` writes with `Encoding.UTF8` instead — harmless while content
stays ASCII, but an inconsistency.

### Related printer-side files (not the material DB itself)

`docs/material_box_info.json` and `docs/material_modify_info.json` describe the CFS
*runtime slot state*, not the catalogue. Shapes:

- `material_box_info.json`: `{ rackMaterial:{attach,selected,rfid,editStatus,filamentId,color,brand,name,materialType,minTemp,maxTemp,pressure,maxVSpeed}, Material:{state,filament,auto_refill,same_material,enable,info:[{boxID,state,filament,temperature,dry_and_humidity,version,sn,uuid,list:[…4 slots…]}]} }`. Each slot: `{materialId:"A".."D", state, remainLen, filamentId, brand, name, materialType, density, diameter, minTemp, maxTemp, pressure, maxVSpeed, venderId, color, filamentLen, serialNum, reserve, rfid, editStatus}`.
- `material_modify_info.json`: `{ rackMaterial:{…same…}, Material:[ {boxID:"T1".."T4", state, list:[ {rfid,remainLen,editStatus,filamentId,color,brand,name,materialType,minTemp,maxTemp,pressure} ×4 ] } ] }`.

**Important id relationship:** these files use a **6-digit** `filamentId` (`"101001"`)
while `base.id` is **5 chars** (`"01001"`). The app prepends a literal `"1"`:
`MainForm.cs:448` — `string filamentId = "1" + MaterialID;`. Reading back,
`MainForm.cs:405` takes `tagData.Substring(12, 5)` (i.e. drops the leading `1`) and
looks that up in the DB. Colours on the printer side likewise carry a leading `0`
(`MainForm.cs:450`, `string color = "0" + Color;` → `"#0FFFFFF"`).

**OPEN QUESTION** — what the leading `"1"` denotes (batch/namespace/checksum). It is
hard-coded and never varied, and neither `docs/` nor the C# explains it. The
`venderId` `"0276"` and batch `"A2"` are likewise hard-coded at `MainForm.cs:449,452-453`.

---

## 3. Where the DB lives on Windows, and `CheckDBfile`

Single canonical path expression, repeated verbatim in seven places:

```
AppDomain.CurrentDomain.BaseDirectory + "\\material_database\\" + pType + ".json"
```

`Utils.cs:340` (CheckDBfile), `Utils.cs:350` (GetDBfile), `Utils.cs:364` (SetDBfile),
`Utils.cs:402` (GetPrinterTypes, folder only), `Utils.cs:458`, `Utils.cs:577`,
`MatDb.cs:82`, `MatDb.cs:160`, `ManageForm.cs:63,88`.

`AppDomain.CurrentDomain.BaseDirectory` is the directory containing the `.exe`, so the
DB lives **next to the binary** (e.g. `C:\Program Files\CFS-RFID\material_database\K2.json`).
There is no use of `%APPDATA%`, `Environment.SpecialFolder`, or any per-user location.
User settings, by contrast, go to the registry under `HKCU\CFS RFID\Settings`
(`Settings.cs:12,24,51,63,94,106,137,152`).

`CheckDBfile` (`Utils.cs:338-346`) is *only* a `File.Exists` test:

```csharp
public static bool CheckDBfile(string pType)
{
    string filePath = AppDomain.CurrentDomain.BaseDirectory + "\\material_database\\" + pType + ".json";
    if (File.Exists(filePath)) { return true; }
    return false;
}
```

It **never fetches or creates** anything. If it returns false, `LoadFilaments` returns
with an empty `mdb` (`MatDb.cs:21-28`) and `GetVersion` returns `"0"` (`MatDb.cs:60-67`).
Population is entirely user-driven:

1. `MainForm` populates the printer dropdown from `GetPrinterTypes()`
   (`Utils.cs:398-418`) = `Directory.GetFiles(folder, "*.json")` → filenames without
   extension, sorted alphabetically (`MainForm.cs:81`).
2. If the list is empty, a toast "Add a printer to get started" fires and `ManageForm`
   auto-opens after 1 s (`MainForm.cs:92-103`).
3. `ManageForm` downloads a profile from Creality Cloud and calls
   `SetDBfile(printerName + ".json", …)` (`ManageForm.cs:58`).
4. `SetDBfile` (`Utils.cs:362-396`) **refuses to overwrite**: `if (File.Exists(filePath)) return;`
   (`Utils.cs:365-368`). It creates the `material_database` directory if missing
   (`Utils.cs:369-380`) and no-ops on empty data (`Utils.cs:381-384`).
5. Delete is `File.Delete` from `ManageForm.cs:64-69`.

Consequence: the printer *type* string is the **file base name**, which is whatever
`name` the cloud API returned (e.g. `"K2 Plus"`), not the short codes in
`Utils.printerTypes`. See §6.

### Recommended macOS layout

```
~/Library/Application Support/CFS-RFID/material_database/<PrinterName>.json
```

i.e. `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, …)`
appending the bundle-id or product name, then `material_database/`.
Rationale: the Windows location is only "next to the exe" because WinForms apps are
often xcopy-deployed; on macOS the app bundle is read-only/signed and writing inside it
would break the signature. Do **not** use `~/Library/Caches` — the DB holds
user-authored filaments that must survive cache eviction. Ship `db/k1.json`,
`db/k2.json`, `db/hi.json` inside the app bundle as seed resources and copy-on-first-run
(this is a **new** behaviour; the Windows app has no such seeding — see §8).

---

## 4. Remote fetch

### 4.1 Transport

`FetchDataFromApi` (`Utils.cs:736-759`) — `System.Net.WebClient`, method **POST**,
body `{"engineVersion":"3.0.0"}` (`Utils.cs:754`), plus `"pageSize":500` when the URL
contains `materialList` (`Utils.cs:755`). Headers (`Utils.cs:740-753`):

| Header | Value |
|---|---|
| `User-Agent` | `BBL-Slicer/v01.09.03.50 (dark) Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.52` |
| `Content-Type` | `application/json` |
| `__CXY_BRAND_` | `creality` |
| `__CXY_UID_` | `` (empty) |
| `__CXY_OS_LANG_` | `0` |
| `__CXY_DUID_` | fresh `Guid.NewGuid().ToString()` per call |
| `__CXY_APP_VER_` | `1.0` |
| `__CXY_APP_CH_` | `CP_Beta` |
| `__CXY_OS_VER_` | (same string as User-Agent) |
| `__CXY_TIMEZONE_` | `28800` |
| `__CXY_APP_ID_` | `creality_model` |
| `__CXY_REQUESTID_` | fresh `Guid.NewGuid().ToString()` per call |
| `__CXY_PLATFORM_` | `11` |

**No authentication** — `__CXY_UID_` is deliberately empty; there is no token, cookie
or signature. Note the spoofed Bambu-Studio User-Agent.

### 4.2 Exact URLs

```
https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/printerList
```
`Utils.cs:765` (GetZipUrl), `Utils.cs:792` (FindPrinters[]), `Utils.cs:822` (FindPrinters).

```
https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/materialList
```
`Utils.cs:909` (GetJsonDB).

A third URL is dynamic: `result.printerList[i].zipUrl` from the printerList response,
downloaded with a plain `client.DownloadData(zipUrl)` (`Utils.cs:914`) — **GET, no
custom headers, no auth**. Thumbnails come from `printerList[i].thumbnail`
(`ManageForm.cs:86`, `UpdateForm.cs:234`) via `LoadPrinterImage` (`Utils.cs:949-…`),
which handles `.webp` through ImageSharp.

There is also a local Spoolman integration at `http://{host}:{port}/api/v1`
(`Utils.cs:1127`) with `GET /vendor`, `POST /vendor`, `GET /filament`, `POST /filament`,
`POST /spool` (`Utils.cs:1135,1158,1163,1205,1220`) — unrelated to the material DB.

### 4.3 Compression

`Utils.cs:11` imports `System.IO.Compression`. **There is no GZip anywhere in the
repo** — I grepped `Windows/`, `Android/` and `Arduino/` for `GZip` and got zero hits.
The only compression is **ZIP (`ZipArchive`)**, in two places:

- `Utils.cs:915-939` — the cloud `zipUrl` bundle. Entries ending `.json` are read; a
  `.json` at the archive **root** (no `/` in `FullName`) is the manifest and yields
  `version` (`Utils.cs:927-931`); entries under `materials/` are individual filament
  profiles (`Utils.cs:932-935`).
- `ColorMatcher.cs:39-65` — `Properties.Resources.colors` (`Resources/colors.db`) is a
  ZIP whose first entry is a CSV of `name,#rrggbb`. See §8.

### 4.4 Assembly: `GetJsonDB(printerName, nozzle)` → a DB file

`Utils.cs:903-946` orchestrates: resolve `zipUrl` → fetch `materialList` → download and
unzip → `ProcessMaterials` (`Utils.cs:848-901`). `ProcessMaterials` joins each zip
`materials/*.json` (keyed on `metadata.name`) to the `materialList` entry with the same
`name` (`Utils.cs:859-861`), strips `createTime`, `status`, `userInfo` from the base
object (`Utils.cs:867`), and emits the list item with:

- `engineVersion` ← `sourceObj["engine_version"]` (`Utils.cs:873`)
- `printerIntName` ← **hard-coded `"F008"`** (`Utils.cs:874`)
- `nozzleDiameter` ← **hard-coded `["0.4"]`** (`Utils.cs:875`)
- `kvParam` ← `sourceObj["engine_data"]` (`Utils.cs:876`)
- `base` ← the cleaned `materialList` entry (`Utils.cs:877`)

⚠️ **Known defect worth preserving-or-fixing in the port:** `printerIntName` is
hard-coded to the K2 code `F008` even when building a K1 (`CR-K1 Max`) or Hi (`F018`)
database. Every DB produced through the cloud path is therefore mislabelled for
non-K2 printers. Likewise the nozzle is always `0.4` (also hard-coded at every call
site: `ManageForm.cs:29,58`, `UpdateForm.cs:78,138`, `Utils.cs:454`).

**OPEN QUESTION** — whether the printer firmware actually reads `printerIntName`. Not
determinable from this repo.

### 4.5 Version check

Two independent comparisons exist:

1. **Printer vs local (SSH path).** `UpdateForm.cs:108-119`:
   `newVersion = GetPrinterVersion(...)` (SCP-downloads `material_database.json` from
   the printer and reads `result.version`, `Utils.cs:655-690`; returns `"0"` on any
   failure, `Utils.cs:680`), then
   `if (long.Parse(newVersion) > long.Parse(currentVersion))` enable Update.
   → **`version` must parse as `long`.** Non-numeric versions throw and are swallowed
   into "Error checking version" (`UpdateForm.cs:121-124`).
2. **Cloud vs local.** `UpdateForm.cs:237` reads `version` off the selected printerList
   entry and just *displays* it — there is **no** comparison; the Update button is
   always enabled on that path (`UpdateForm.cs:68-72`).

---

## 5. Versioning

- **Storage.** `result.version` is a **string** holding unix epoch seconds
  (`"1758907369"` = 2025-09-26; `"1746005657"` = 2025-04-30).
- **Read.** `MatDB.GetVersion` (`MatDb.cs:55-76`) → `result["version"].ToString()`;
  returns `"0"` if the file is absent (`MatDb.cs:66`) or on any exception
  (`MatDb.cs:75`). Surfaced via `Utils.GetDatabaseVersion` (`Utils.cs:57-60`).
- **Write, whole file.** `MatDB.SaveFilaments(pType, version)` (`MatDb.cs:158-190`)
  **does not compute** a version — it writes whatever the caller passes. Callers pass
  `MainForm.DbVersion` (`MainForm.cs:751,778,806`), which was last read from the file
  itself. So local add/edit/delete **preserves** the existing version.
- **Write, version only.** `MatDB.SetVersion(pType, version)` (`MatDb.cs:78-93`)
  re-parses the file, sets `result["version"]`, rewrites it.
- **Version generation** happens in exactly one place:
  `Utils.cs:887` — `zipVersion ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString()`,
  i.e. the manifest version from the cloud zip, falling back to "now" in epoch seconds.
- **The sentinel `"9876543210"`.** `Resources.verPrevent` = `9876543210`
  (`Properties/Resources.resx`, key `verPrevent`). When "prevent" is checked, the local
  DB's version is stamped to this value **before** upload (`UploadForm.cs:151-154`), so
  the DB pushed to the printer carries an artificially huge version and the printer will
  not replace it with a cloud update. Unchecked, the printer's own version is copied
  first (`UploadForm.cs:156-159`).
- Serialisation is always `Formatting.Indented` with
  `new JsonSerializerSettings { MaxDepth = 2 }` (`MatDb.cs:88-89`, `MatDb.cs:185-186`).
  `MaxDepth` on *serialisation* has no effect in Newtonsoft — it is a read-side guard.
  Treat it as vestigial.

---

## 6. `k1` / `k2` / `hi`, and what "CFS" means

**CFS = Creality Filament System** — Creality's 4-slot multi-material unit (the
"box"). Confirmed contextually: the app is named `CFS-RFID` / window title `"CFS RFID"`
(`MainForm.Designer.cs:398`), and every printer-side path is under
`.../creality/userdata/**box**/` (`Utils.cs:487,519,596,628,663`). The Spoolman comment
string is `"Created by: Cfs RFID"` (`Utils.cs:1156,1185`). The README frames it as
"K2/K1/HI/CFS RFID Programming". So "CFS" = the filament box whose slot state lives in
`material_box_info.json` / `material_modify_info.json` (`docs/`), and this app writes
the MIFARE Classic 1K tags that the CFS reads.

**The three printer families:**

| Token | Printer family | `printerIntName` | SSH default password | Printer-side DB path |
|---|---|---|---|---|
| `K2` | K2 Plus / K2 series | `F008` | `creality_2024` (`Resources.k2Psw`) | `/mnt/UDISK/creality/userdata/box/material_database.json` |
| `K1` | K1 / K1 Max | `CR-K1 Max` | `creality_2023` (`Resources.k1Psw`) | `/usr/data/creality/userdata/box/material_database.json` |
| `HI` | Hi / Hi Combo | `F018` | `Creality2024` (`Resources.hiPsw`) | `/mnt/UDISK/creality/userdata/box/material_database.json` |

**Selection logic — there are three different mechanisms, and they disagree:**

1. **The candidate list** is a hard-coded array
   `Utils.printerTypes = { "K2", "K1", "HI" }` (`Utils.cs:190-193`), used only as
   substring filters against cloud printer names in
   `FindPrinters(string[], nozzle)` (`Utils.cs:787-815`, called from `ManageForm.cs:29`).
2. **The active printer type** is the *filename* of the selected DB:
   `PrinterType = printerModel.Items[printerModel.SelectedIndex].ToString()`
   (`MainForm.cs:727`), where the items come from `GetPrinterTypes()` =
   directory listing (`Utils.cs:398-418`, `MainForm.cs:81`). Since `ManageForm.cs:58`
   names the file after the cloud `name`, `PrinterType` can be e.g. `"K2 Plus"`, not `"K2"`.
   The selected index (not the name) is persisted to the registry as `printerType`
   (`MainForm.cs:935`, `MainForm.cs:86`).
3. **Behavioural branching** is by **substring, case-insensitively**, and the order
   matters — `hi` is tested first, then `k1`, else K2 is the fallback:
   ```csharp
   if (SelectedPrinter.ToLower().Contains("hi"))  sshDefault = Resources.hiPsw;
   else if (SelectedPrinter.ToLower().Contains("k1")) sshDefault = Resources.k1Psw;
   else sshDefault = Resources.k2Psw;
   ```
   `UpdateForm.cs:48-59`, duplicated at `UploadForm.cs:40-51`.
   Separately, the printer-side path branches on `pType.ToLower().Contains("k1")`
   (`Utils.cs:488-491, 520-523, 552-555, 597-600, 629-632, 664-667`), and
   `SaveMatOption` (the `material_option.json` side-car) is invoked **only** for an
   exact `"k1"` match: `if (SelectedPrinter.Equals("k1", StringComparison.OrdinalIgnoreCase))`
   (`UploadForm.cs:161-164`).

⚠️ Two portability landmines here:
- `Contains("hi")` matches any name containing the letters "hi" — e.g. a hypothetical
  `"Ender Chi"`. And `"K1"` inside `"K1 Max"` is fine, but a K2 file named
  `"K2 Plus"` correctly falls through to the else-branch only by luck of ordering.
- `UploadForm.cs:161` requires the file to be named exactly `k1`/`K1` for the
  `material_option.json` generation to run, yet `ManageForm` will have named it
  `"K1 Max.json"`. **OPEN QUESTION** — is this an actual bug, or do users hand-rename
  files to `k1.json`/`k2.json`/`hi.json` (which is exactly what the `db/` folder in this
  repo provides)? The presence of `db/k1.json`, `db/k2.json`, `db/hi.json` with those
  bare names strongly suggests hand-placement is the intended workflow, and that the
  ManageForm/cloud path is the newer, less-exercised one.

`SaveMatOption` (`Utils.cs:692-733`) builds a K1-only `material_option.json`:
`{ "<brand>": { "<meterialType>": "name1\nname2\n…" } }` — names joined by `\n`
(`Utils.cs:719`), uploaded to the box directory (`Utils.cs:728`).

---

## 7. CRUD semantics

All CRUD operates on the static `List<Filament> MatDB.mdb` (`MatDb.cs:13`).
`Utils.AddMaterial/EditMaterial/RemoveMaterial/LoadMaterials/SaveMaterials`
(`Utils.cs:27-55`) are thin pass-throughs.

### Load
`MatDB.LoadFilaments(pType)` (`MatDb.cs:15-53`): resets `mdb` to a new list
(`MatDb.cs:18`), reads the file as ASCII, iterates `result.list`, projects to
`Filament`. The whole body is wrapped in `catch { }` (`MatDb.cs:52`) — a malformed file
silently yields a partially-filled list. `pType` is lower-cased at every call
(`MatDb.cs:21,23`), so on a case-sensitive filesystem (macOS can be either) the
filename must be lower-case, but `GetPrinterTypes()` returns the on-disk casing.
⚠️ **This is a real cross-platform hazard**: on NTFS `K2.json` and `k2.json` are the
same file; on a case-sensitive APFS volume they are not.

### Add — `MatDB.AddFilament` (`MatDb.cs:192-207`)
1. Parse `filament.FilamentParam`.
2. Write the four denormalised fields **back into** `jobject["base"]`
   (`MatDb.cs:198-201`) — this is how the cache and blob are kept consistent.
3. Re-serialise into `FilamentParam` (`MatDb.cs:203`).
4. `mdb.Add(filament)` (`MatDb.cs:204`) — **appends unconditionally, no duplicate check.**

Duplicate protection lives in the UI, not the model: `FilamentForm.cs:271` guards with
`if (GetMaterialByID(txtId.Text.Trim()) == null)` and otherwise toasts
"Filament ID Exists / Duplicate IDs are not allowed" (`FilamentForm.cs:358`).
The `UpdateForm` merge path (`UpdateForm.cs:153-170`) also checks `GetMaterialByID`
first: found → `EditMaterial`, not found → `AddMaterial`. **Any port that exposes
`AddFilament` directly must re-implement the uniqueness check.**

New-record validation (`FilamentForm.cs:240-270`): all of id/brand/name/type/minTemp/
maxTemp non-empty; **id must be exactly 5 chars AND `int.TryParse`-able**
(`FilamentForm.cs:251-260`); min/max temp must parse as int. The new id is seeded from
`string.Format("{0:D5}", random.Next(99999))` (`FilamentForm.cs:81`).
⚠️ The numeric-id rule contradicts the shipped data: `k2.json` contains `E1001`,
`P1001`, `P1002`, `P1003`. Existing non-numeric ids load fine but cannot be re-created.

Add clones the *currently selected* filament as its template — `FilamentForm.cs:74`
parses `GetMaterialByID(SelkectedFilament).FilamentParam`, so the new record inherits
that record's `kvParam`, `engineVersion`, `printerIntName`, `nozzleDiameter`, colours,
density, diameter, rank, drying params etc. Only id/brand/name/type/minTemp/maxTemp/
isSoluble/isSupport are overwritten (`FilamentForm.cs:297-330`). The commented-out
block at `FilamentForm.cs:302-309,332-335` shows the author considered resetting
colours/density/rank and chose not to.

### Edit — `MatDB.EditFilament` (`MatDb.cs:209-223`)
```csharp
foreach (Filament item in mdb)
{
    if (item.FilamentId.Trim() == filament.FilamentId.Trim())
    {
        mdb.Remove(item);
        mdb.Add(filament);
    }
}
```
Matching is by **trimmed `FilamentId` only** (brand/name ignored). This is
remove-then-append, so **edited records move to the end of the list** and the on-disk
order changes on every save. It also **mutates the collection while enumerating it**,
which throws `InvalidOperationException` in .NET — swallowed by `catch { }`
(`MatDb.cs:221`). It happens to work because the exception is thrown on the *next*
`MoveNext()`, after the swap has already been applied; a second matching id would never
be reached. **Do not reproduce this pattern in Swift** — implement it as
`if let i = firstIndex(where:) { remove; append }` and decide deliberately whether to
preserve position (recommended: replace in place, `mdb[i] = filament`).

⚠️ Also note edit does **not** re-sync `FilamentParam.base` from the four scalar fields
the way Add does. `FilamentForm.SaveJsonEdit` (`FilamentForm.cs:215-236`) only replaces
`kvParam` and never touches `base`, and the base-editing tab is removed in edit mode
(`FilamentForm.cs:96`, `tabControl1.TabPages.Remove(basePage)`) — so in practice
`base` can't drift on this path. But `UpdateForm.cs:156` sets
`filament.FilamentParam = item.ToString()` from the *incoming* record while leaving the
four cached properties at their **old** values, so a cloud update that renames a
material leaves `Filament.FilamentName` stale until the next `LoadFilaments`.

### Remove — `MatDB.RemoveFilament` (`MatDb.cs:225-238`)
Same trimmed-id match, `mdb.Remove(item)` inside a `foreach` — same
mutate-during-enumeration issue, same `catch { }`. `Utils.RemoveMaterial(string materialId)`
(`Utils.cs:47-50`) resolves via `GetFilamentById` and will pass `null` if not found
(`GetFilamentById` returns `null` at `MatDb.cs:106`), whereupon
`filament.FilamentId` NREs and is swallowed.

### Persistence timing
CRUD is **purely in-memory**. Nothing touches disk until `SaveMaterials(pType, version)`
→ `MatDB.SaveFilaments` (`MatDb.cs:158-190`). The UI calls it immediately after each
dialog returns `DialogResult.OK`, then reloads: `MainForm.cs:751-755` (add),
`MainForm.cs:778-782` (edit), `MainForm.cs:805-810` (delete),
`UpdateForm.cs:179` (cloud/printer merge).

`SaveFilaments` **early-returns when `mdb` is null or empty** (`MatDb.cs:161-164`) — so
**deleting the last filament silently fails to persist**; the file keeps the old
content and the deletion is undone on the next `LoadMaterials`. Reproduce or fix
deliberately; I recommend fixing and noting it.

`SaveFilaments` rebuilds the envelope from scratch: it re-parses each
`FilamentParam` into the `list` array (`MatDb.cs:169-174`) and re-emits
`code`/`msg`/`reqId`/`result` (`MatDb.cs:176-184`). Any `reqId` from a printer capture
is therefore **lost and replaced with `"0"`** on the first local save. `count` is
recomputed from the actual list length (`MatDb.cs:179`) — so `count` is authoritative
after a save even if the input file's `count` disagreed.

---

## 8. `Resources/colors.db` and how `MatDb` relates to it

`Windows/CFS-RFID/Resources/colors.db` (297 579 bytes) is a **ZIP archive** whose first
entry is a CSV with a header row followed by `"<colour name>",#rrggbb` lines
(`ColorMatcher.cs:39-65`). It is embedded as `Properties.Resources.colors` and read
only by `ColorMatcher`, which does a nearest-neighbour lookup in RGB Euclidean space
(`ColorMatcher.cs:70-99`).

**Relationship to `MatDb`: none, directly.** `MatDb.cs` never references it, and
`base.colors` (which only ever contains `#ffffff` / `#000000`) is never read by any
code path. The two meet only in `MainForm.cs:911`, where the *user-picked* colour is
converted to a human name for the Spoolman `SmAddSpool` call. Full treatment of
`colors.db` is covered by [`05-color.md`](05-color.md) — this spec only asserts that the material
DB has no dependency on it and that a macOS port can implement the DB layer without it.

**There are no other embedded/bundled DB resources.** I grepped `CFS-RFID.csproj` for
`material_database` and `.json` and found nothing: the repo's `db/k1.json`,
`db/k2.json`, `db/hi.json` are **not** build artifacts, not embedded resources, and not
copied to output. They are reference files a user manually drops into
`<exe dir>\material_database\`. (The Android sibling app takes a different route
entirely — Room/SQLite, `Android/SpoolID/app/src/main/java/dngsoftware/spoolid/filamentDB.java:16-21`,
database name `"material_database_" + pType`.)

---

## 9. Swift implementation notes

### 9.1 Recommended Codable model

The safest port keeps the Windows split: typed envelope + typed `base` + **untyped,
order-preserving passthrough** for `kvParam` and unknown keys.

```swift
// MARK: Envelope
struct MaterialDatabase: Codable {
    var code: Int = 0
    var msg: String = "ok"
    var reqId: String = "0"
    var result: MaterialResult
}

struct MaterialResult: Codable {
    var list: [MaterialEntry]
    var count: Int
    var version: String          // unix epoch seconds, as a STRING
}

struct MaterialEntry: Codable {
    var engineVersion: String
    var printerIntName: String
    var nozzleDiameter: [String]
    var kvParam: [String: String]   // flat, keys vary per record
    var base: MaterialBase
}

struct MaterialBase: Codable {
    var id: String
    var brand: String
    var name: String
    var meterialType: String        // sic — keep the wire spelling
    var colors: [String]
    var density: Double
    var diameter: String            // "1.75" — a STRING, not a number
    var costPerMeter: Int
    var weightPerMeter: Int
    var rank: Int
    var minTemp: Int
    var maxTemp: Int
    var isSoluble: Bool
    var isSupport: Bool
    var shrinkageRate: Int
    var softeningTemp: Int
    var dryingTemp: Int
    var dryingTime: Int
}
```

If you prefer Swift-idiomatic naming, use explicit `CodingKeys`
(`case materialType = "meterialType"`) rather than a key-decoding strategy — the
misspelling must survive the round trip byte-for-byte or the printer will reject it.

The `Filament` façade, if you keep it:

```swift
struct Filament: Identifiable, Hashable {
    var id: String          // FilamentId   <- base.id
    var name: String        // FilamentName <- base.name
    var vendor: String      // FilamentVendor <- base.brand
    var type: String        // FilamentType <- base.meterialType
    var entry: MaterialEntry  // replaces the FilamentParam JSON string
}
```
Prefer holding the decoded `MaterialEntry` over a JSON `String`. The Windows code only
uses a string because it round-trips through `JObject`; a typed value removes an entire
class of parse-failure paths. **But** see the passthrough warning in 9.2.

### 9.2 Decoding pitfalls

1. **`kvParam` values are always strings, never numbers.** `"190"`, `"1.24"`, `"0"`,
   `"1"`, `"nil"`, `"100%"`. Never `Int`/`Double`/`Bool`. Verified across all
   12 082 values in `db/*.json`. `[String: String]` is correct — but a
   `[String: JSONValue]` decoder is more defensive against future firmware.
2. **`kvParam` key sets vary per record** (90/91/92/93/100 keys observed). Never a
   fixed struct. Also: `[String: String]` **loses key order**; the shipped files are
   alphabetically ordered and `MatDb.SaveFilaments` preserves whatever
   `JObject` order it read. If byte-identical round-tripping matters (it might for a
   printer-side diff), use an ordered container or re-sort keys alphabetically on
   encode — which matches the observed on-disk order.
3. **`base.diameter` is a `String` (`"1.75"`), while `base.density` is a `Double`
   (`1.24`).** Easy to get backwards. Same trap in the box files: `pressure`,
   `maxVSpeed`, `remainLen`, `filamentLen` are all strings while `density`, `minTemp`,
   `maxTemp`, `rfid`, `state` are numbers.
4. **`result.version` is a String that must parse as `Int64`** for
   `UpdateForm.cs:112`'s comparison. Decode as `String`, compare via
   `Int64(a) ?? 0 > Int64(b) ?? 0` — do **not** decode as a number (the printer writes
   it quoted and a numeric encode would break the format).
5. **`reqId` is a String** but its value varies: `"0"` from this app,
   `"cl602024082916552939795681"` from a real printer. Never decode it as a number.
6. **The C# never validates `code`/`msg`.** Don't fail decoding on unexpected values.
7. **Newtonsoft `JObject` is order-preserving and loss-free; `Codable` is not.**
   Any key present in a printer-generated file that is missing from `MaterialEntry` or
   `MaterialBase` is **silently dropped** on re-encode. The Windows app cannot lose data
   this way because it stores the raw blob. If you decode into structs, either (a) add
   an `additionalProperties: [String: JSONValue]` catch-all, or (b) keep the original
   `Data` alongside and only splice the four mutated `base` keys. I recommend (b) for
   the upload path (fidelity to what the printer expects) and (a) for the editor.
8. **Encoding.** Read/write as ASCII-safe UTF-8. The C# uses `Encoding.ASCII` on read
   (`MatDb.cs:23`), which **mangles any byte > 0x7F into `?`**. Shipped files are pure
   ASCII so this never bit anyone, but a cloud-fetched profile with a non-ASCII vendor
   name would be silently corrupted on Windows. On macOS use UTF-8 and do **not**
   replicate the corruption; flag it if fidelity to Windows output is required.
9. **Output formatting.** `Formatting.Indented` = 2-space indent **with** a space after
   `:` (`"code": 0`). The shipped `db/*.json` use 2-space indent **without** the space
   (`"code":0`), i.e. they were *not* produced by this app's writer. Use
   `JSONEncoder.OutputFormatting = [.prettyPrinted]` and accept the difference, or
   post-process if byte-parity with `db/*.json` is a test requirement.
   `JSONEncoder` also escapes `/` differently and sorts keys only with `.sortedKeys`.
10. **`base.id` is not always numeric** (`E1001`, `P1001`…). Never `Int`. And it is
    zero-padded — `"00001"` must not become `1`.
11. **Case sensitivity.** `MatDb` lower-cases `pType` before building the filename
    (`MatDb.cs:21,23,60,62,82,83`) but `GetPrinterTypes` returns on-disk casing
    (`Utils.cs:410`). On a case-sensitive volume this breaks. Normalise once, in one
    place, in the Swift port.
12. **The `nil` sentinel.** `kvParam` values of the literal string `"nil"` mean "unset /
    inherit". Do not map to Swift `nil` on decode — round-trip the literal.

### 9.3 Concrete test fixtures

Use these verbatim; they are lifted from `db/k2.json`.

**Fixture A — minimal valid envelope (round-trip / empty-DB test).**
```json
{"code":0,"msg":"ok","reqId":"0","result":{"list":[],"count":0,"version":"0"}}
```
Assert: decodes; `GetVersion` → `"0"`; `LoadFilaments` → empty; `SaveFilaments` on an
empty list **must early-return without writing** if you are matching Windows
(`MatDb.cs:161-164`), or must write `count:0` if you are fixing the bug — pick one and
pin it with this test.

**Fixture B — one Creality record (the canonical happy path).**
`base` exactly as in `db/k2.json`, id `01001`:
```json
{
  "engineVersion": "3.0.0",
  "printerIntName": "F008",
  "nozzleDiameter": ["0.4"],
  "kvParam": {
    "filament_type": "PLA",
    "filament_vendor": "Creality",
    "filament_density": "1.24",
    "filament_diameter": "1.75",
    "filament_retraction_speed": "nil",
    "filament_shrink": "100%",
    "nozzle_temperature": "220",
    "filament_notes": "\"\"",
    "filament_end_gcode": ";filament end gcode \n"
  },
  "base": {
    "id": "01001", "brand": "Creality", "name": "Hyper PLA", "meterialType": "PLA",
    "colors": ["#ffffff"], "density": 1.24, "diameter": "1.75",
    "costPerMeter": 0, "weightPerMeter": 0, "rank": 10000,
    "minTemp": 190, "maxTemp": 240,
    "isSoluble": false, "isSupport": false,
    "shrinkageRate": 0, "softeningTemp": 0, "dryingTemp": 0, "dryingTime": 0
  }
}
```
Covers: string-vs-number split (`diameter` string / `density` double), the `"nil"`
sentinel, `"100%"`, an escaped empty-string value `"\"\""`, and an embedded newline in
G-code.

**Fixture C — Generic record, id `00001`.** Same shape, `brand:"Generic"`,
`name:"Generic PLA"`, `rank:9100`. Asserts leading-zero id preservation.

**Fixture D — non-numeric id.** `base.id = "E1001"`, `brand:"eSUN"`, `name:"PLA+"`.
Asserts the id is never coerced to `Int`, and pins the FilamentForm validation
divergence (§7) as a *known* deviation.

**Fixture E — the 100-key outlier.** `db/k1.json` id `01002` "Hyper L-W PLA" carries 10
extra `kvParam` keys (`customized_plate_temp`, `customized_plate_temp_initial_layer`,
`dont_slow_down_outer_wall`, `filament_long_retractions_when_cut`,
`filament_retraction_distances_when_cut`, `filament_shrinkage_compensation_z`,
`filament_stamping_distance`, `filament_stamping_loading_speed`, `idle_temperature`,
`pellet_flow_coefficient`). Asserts heterogeneous key sets survive.

**Fixture F — full-file golden tests.** Decode + re-encode `db/k1.json` (46 records),
`db/k2.json` (66), `db/hi.json` (21), `docs/material_database.json` (56, `reqId` =
`"cl602024082916552939795681"`, version `"1746005657"`). Assert `result.count ==
result.list.count` for all four, and assert **no key loss** by diffing
`JSONSerialization` dictionaries rather than raw bytes.

**Fixture G — CRUD semantics.**
- add duplicate id → must be rejected at the service layer (Windows rejects only in the UI);
- edit → assert whether your implementation preserves index or appends (Windows appends);
- delete the only record → assert the chosen behaviour (Windows silently no-ops);
- `remove(id:)` for an unknown id → must not crash (Windows NREs into `catch {}`).

**Fixture H — tag id bridging.** `base.id "01001"` → tag `filamentId "101001"`
(`MainForm.cs:448`), and back via `substring(12,5)` (`MainForm.cs:405`). Colour
`"C12E1F"` → `"0C12E1F"` (`MainForm.cs:450`). Weight `"500 G"` ↔ `"0165"`
(`Utils.cs:147,164`).

---

## OPEN QUESTIONS

1. **`shrinkageRate` units.** Values are only `0` and `40`. If it is 0.1 % units, 40 =
   4 %? No code reads it and no doc explains it.
2. **The leading `"1"` on `filamentId`.** `MainForm.cs:448` hard-codes `"1" + MaterialID`.
   Namespace? Vendor class? Checksum? Not derivable from this repo. Same for the
   hard-coded `venderId "0276"` and batch `"A2"` (`MainForm.cs:449,452`).
3. **Does the printer firmware read `printerIntName`?** `Utils.cs:874` hard-codes
   `"F008"` for every cloud-built DB regardless of target printer, which would be a
   serious bug if the field is load-bearing — and dead weight if it is not.
4. **Are DB files expected to be named `k1/k2/hi` or the full cloud printer name?**
   `db/` ships bare names; `ManageForm.cs:58` writes cloud names; `UploadForm.cs:161`
   requires an exact `"k1"` match for `material_option.json`. These cannot all be right.
   This decides the macOS filename scheme, so it needs an answer before implementation.
5. **Is the empty-`mdb` early return in `SaveFilaments` (`MatDb.cs:161-164`) intentional?**
   It makes "delete the last filament" a silent no-op. Port as-is or fix?
6. **Is `rank` meant to be unique?** `4910` is duplicated in all three shipped files.
   If the printer sorts on it, ties are undefined.
7. **`SmDialog`/Spoolman `port 7912` default** (`MainForm.cs:911`) — out of scope here
   but it consumes `MaterialID`; confirm whether SPEC coverage is needed elsewhere.
8. **Version comparison on the cloud path.** `UpdateForm.cs:237` displays the cloud
   version but never compares it — is "always allow update" the intended UX, or a
   missing guard?
9. **`nozzleDiameter` is always `["0.4"]`** and `0.4` is hard-coded at every call site.
   Is multi-nozzle support expected in the macOS port, or is 0.4 a permanent assumption?
