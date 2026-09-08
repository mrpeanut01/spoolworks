# SPEC-05 — Color Matching & Image Processing

Reverse-engineered from the Windows C# app (`Windows/CFS-RFID/`), cross-checked against the
Android app (`Android/SpoolID/`) which is a line-for-line port of the same logic.

All file:line references are to the repo at commit `7101bac` (v57).

---

## 0. Executive summary / scope corrections

Three findings up front, because they change the shape of the port:

1. **`colors.db` is NOT SQLite.** It is a **ZIP archive** containing a single UTF-8 CSV file
   (`colornames.csv`). `sqlite3` is not involved anywhere in this codebase.
2. **There is no image → color feature.** The app has **no** image-to-color extraction, no
   resizing for sampling, no averaging, and no dominant-color extraction. The only
   `SixLabors.ImageSharp` usage in the entire Windows project is two lines that flatten a
   downloaded **WebP printer thumbnail** onto a grey background for display in a `PictureBox`.
   See §3.
3. **`FilamentForm.cs` contains no color-picking UI.** Its only `Color` references are static
   chrome (`BackColor`/`ForeColor` theming). The actual color picker lives in
   `MainForm.cs:698-712`, and the named-color display lives in `SmDialog.cs`. See §5.

Color input is therefore **always** a user-chosen RGB triple from the Windows system color
dialog (or a value read back off a tag) — never derived from an image.

---

## 1. `colors.db` — format, schema, semantics

### 1.1 Container format

```
$ file Windows/CFS-RFID/Resources/colors.db
Zip archive data, at least v2.0 to extract, compression method=deflate

$ xxd Windows/CFS-RFID/Resources/colors.db | head -2
00000000: 504b 0304 1400 0800 0800 6669 2a5c 0000  PK........fi*\..
00000010: 0000 0000 0000 0000 0000 0e00 2000 636f  ............ .co
00000020: 6c6f 726e 616d 6573 2e63 7376 7578 0b00  lornames.csvux..
```

Magic bytes `50 4B 03 04` = PKZIP local file header. Not `SQLite format 3\0`.

| Property | Value |
|---|---|
| File | `Windows/CFS-RFID/Resources/colors.db` |
| On-disk size | 297,579 bytes |
| Format | ZIP (deflate) |
| Entries | 1 |
| Entry name | `colornames.csv` |
| Uncompressed size | 704,682 bytes |
| Entry mtime | 2026-01-10 00:11 |
| Encoding | UTF-8, **no BOM** |
| Line endings | **LF only** (`0x0A`), verified by hex dump |
| Final line | **no trailing newline** (`...Zydeco Blue,#2b61a0,<EOF>`) |

The identical file is shipped to Android as `Android/SpoolID/app/src/main/assets/colors.db`
(byte-identical, 297,579 bytes).

The archive entry is opened **by index, not by name** — `ColorMatcher.cs:43`:

```csharp
ZipArchiveEntry entry = archive.Entries.Count > 0 ? archive.Entries[0] : null;
```

so the CSV filename is not load-bearing.

### 1.2 CSV schema

The CSV is the [meodai/color-names](https://github.com/meodai/color-names) dataset. **Line 1 is
not a header row** — it is the literal string `https://github.com/meodai/color-names` (an
attribution line). The loader blindly discards line 1 (`ColorMatcher.cs:48`,
`reader.ReadLine();` with no assignment), so the effect is the same as skipping a header.

Data rows have exactly **3 comma-separated fields**, no exceptions (verified: parts-count
distribution across all 31,861 data rows is `{3: 31861}`):

| # | Column | Type | Semantics | Used by app? |
|---|---|---|---|---|
| 0 | `name` | UTF-8 string | Human-readable color name, e.g. `Cherry Pie`, `5-Masted Preußen`. 739 rows contain non-ASCII characters (`ü`, `’`, `À`, …). All 31,861 names are **unique**. **Zero** names contain a comma or a `"` quote. | **Yes** — returned to caller |
| 1 | `hex` | `#rrggbb` | Lowercase 7-char CSS hex. All 31,861 values are **unique** (no two names share a hex). | **Yes** — parsed to R/G/B |
| 2 | `isGoodName` | `x` or empty | Upstream dataset's "good name" flag: `x` on 4,875 rows, empty on 26,986 rows. | **No — completely ignored.** `ColorMatcher.cs:54` only checks `parts.Length >= 2` and never reads `parts[2]`. |

### 1.3 Record count

| Metric | Count |
|---|---|
| Raw lines in CSV (LF-split, incl. attribution line) | 31,862 |
| Data rows after discarding line 1 | 31,861 |
| Rows passing the `#` + length-7 filter (`ColorMatcher.cs:57`) | **31,861** (100%) |
| **Colors loaded into `colorList` at runtime** | **31,861** |

Every data row survives the filter — the guard is defensive, not selective.

### 1.4 Row order matters

The CSV is **not** in strict ordinal sort order. First inversion is at data row 10:
`'3AM in Shibuya'` > `'3AM Latte'` (the upstream dataset uses a locale/natural sort). Because
the matcher's tie-break is "first row wins" (§2.3), **the port must preserve CSV file order
exactly** and must not re-sort the list.

### 1.5 Loading code

`ColorMatcher.cs:35-68`. Field split at `ColorMatcher.cs:52`:

```csharp
string[] parts = Regex.Split(line, ",(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)");
```

This is a "split on commas outside double quotes" regex. **Since no name in the dataset contains
a comma or a quote, this is behaviourally identical to a plain `split(",")`.** The port may use a
plain split.

Name normalisation at `ColorMatcher.cs:55`: `parts[0].Replace("\"", "").Trim()` — strip *all*
double quotes anywhere in the string, then trim ASCII/Unicode whitespace. Hex at
`ColorMatcher.cs:56`: `parts[1].Trim()`.

Hex → RGB at `ColorMatcher.cs:21-24`:

```csharp
int color = Convert.ToInt32(hex.Replace("#", ""), 16);
this.R = (color >> 16) & 0xFF;
this.G = (color >> 8) & 0xFF;
this.B = (color) & 0xFF;
```

The whole loader is wrapped in `try { … } catch {}` (`ColorMatcher.cs:37,67`) — **any failure
silently yields an empty `colorList`**, and `FindNearestColor` then returns `null`. Note the
asymmetry: the failure path of the *loader* gives `null` (from `closestName` never being
assigned), while the failure path of the *matcher* gives `String.Empty` (`ColorMatcher.cs:97`).

---

## 2. The color-matching algorithm

### 2.1 Entry point

`ColorMatcher.FindNearestColor(string targetHex) -> string` — `ColorMatcher.cs:70-99`.

Input parsing (`ColorMatcher.cs:74-77`):

```csharp
int targetColor = Convert.ToInt32(targetHex.Replace("#", ""), 16);
int r1 = (targetColor >> 16) & 0xFF;
int g1 = (targetColor >> 8) & 0xFF;
int b1 = targetColor & 0xFF;
```

`Replace("#","")` strips `#` from *anywhere*, and `Convert.ToInt32(…, 16)` is length-agnostic —
so `"C12E1F"`, `"#C12E1F"`, and the 7-char tag form `"0C12E1F"` all parse to the same
`0xC12E1F`. That last case works **only because the leading nibble is always `0`** (§4); a
non-zero leading nibble would shift bits and silently corrupt the match.

### 2.2 Distance metric — plain unweighted RGB Euclidean

Quoted verbatim from `ColorMatcher.cs:82-86`:

```csharp
double distance = Math.Sqrt(
    Math.Pow(r1 - entry.R, 2) +
    Math.Pow(g1 - entry.G, 2) +
    Math.Pow(b1 - entry.B, 2)
);
```

That is:

```
d = sqrt( (Δr)² + (Δg)² + (Δb)² )
```

- **No** per-channel weighting (no 2/4/3, no "redmean").
- **No** CIELAB / CIELUV / CIE76 / CIE94 / CIEDE2000.
- **No** HSV/HSL conversion.
- **No** gamma linearisation — operates directly on non-linear sRGB 8-bit codes (see §6).
- The `Math.Sqrt` is monotonic and therefore **mathematically irrelevant** to which entry wins.
  A port may compare squared distances in integer arithmetic and get bit-identical results
  while avoiding all floating-point concerns. Recommended.

The Android port is character-for-character the same formula
(`Android/SpoolID/app/src/main/java/dngsoftware/spoolid/ColorMatcher.java:66`), confirming this
is the intended cross-platform contract.

### 2.3 Search & tie-breaking

`ColorMatcher.cs:78-92` — linear scan over all 31,861 entries, `minDistance` initialised to
`double.MaxValue`, updated on **strictly-less-than**:

```csharp
if (distance < minDistance)
```

Strict `<` means **the first entry in CSV order wins any tie**. Ties are real and reachable —
e.g. `#EAD742` is exactly equidistant (d² = 12) from `Meadowlark` (#e8d940, row 17219) and
`Sandstorm` (#ecd540, row 24631); `Meadowlark` wins purely on row order. Any port that sorts,
hashes, uses a k-d tree with different traversal, or parallelises the reduction **must** break
ties by lowest original row index to stay compatible.

Cost: 31,861 iterations per lookup, and `new ColorMatcher()` re-unzips and re-parses the whole
704 KB CSV on **every** call site invocation (`SmDialog.cs:58` constructs one per dialog). Fine
for a once-per-dialog UI action; the port should cache the parsed table anyway.

### 2.4 Return value

The `Name` string only. The matched hex, the distance, and the row index are all discarded.

---

## 3. Image → color: does not exist

**There is no code path anywhere in the Windows app that derives a color from an image.**

Exhaustive `SixLabors.ImageSharp` inventory for the whole Windows project:

| Location | Content |
|---|---|
| `Windows/CFS-RFID/packages.config:9` | `SixLabors.ImageSharp` version `2.1.11`, `targetFramework="net481"` |
| `Windows/CFS-RFID/CFS-RFID.csproj:86-87` | `Reference Include="SixLabors.ImageSharp, Version=2.0.0.0…"`, HintPath `..\packages\SixLabors.ImageSharp.2.1.11\lib\net472\SixLabors.ImageSharp.dll` |
| `Utils.cs:4` | `using SixLabors.ImageSharp;` |
| `Utils.cs:5` | `using SixLabors.ImageSharp.PixelFormats;` |
| `Utils.cs:6` | `using SixLabors.ImageSharp.Processing;` |
| `Utils.cs:18` | `using ImageSharpImage = SixLabors.ImageSharp.Image;` |
| `Utils.cs:962` | `using (var image = ImageSharpImage.Load<Rgba32>(ms))` |
| `Utils.cs:964` | `image.Mutate(x => x.BackgroundColor(SixLabors.ImageSharp.Color.ParseHex("#F4F4F4")));` |

That is the complete list — **two** call sites, both inside one method.

### 3.1 The only image code: `Utils.LoadPrinterImage`

`Utils.cs:949-991`. Traced call-by-call:

1. `Utils.cs:951` — spawns a raw `new Thread(…)`, fire-and-forget.
2. `Utils.cs:957` — `WebClient.DownloadData(urlString)` → `byte[]`.
3. `Utils.cs:958` — branches on `urlString.ToLower().EndsWith(".webp")`.
4. **WebP branch** (`Utils.cs:960-973`):
   - `Utils.cs:962` — `ImageSharpImage.Load<Rgba32>(ms)`. Decodes to 8-bit-per-channel RGBA.
     No size limit, no `DecoderOptions`, **no resize**.
   - `Utils.cs:964` — `image.Mutate(x => x.BackgroundColor(Color.ParseHex("#F4F4F4")))`.
     This is the **only** alpha handling in the app: it composites the image over an opaque
     `#F4F4F4` (244,244,244) fill using source-over, flattening transparency to match the
     WinForms window background. It is **display flattening, not color extraction.**
   - `Utils.cs:967` — `image.SaveAsBmp(outStream)` (BMP round-trip purely because
     `System.Drawing` on .NET Framework cannot decode WebP).
   - `Utils.cs:969-970` — `pictureBox.Image = System.Drawing.Image.FromStream(outStream)`,
     `SizeMode = PictureBoxSizeMode.Zoom`. **This is the resize** — and it is done by WinForms
     at paint time (aspect-preserving fit-inside), purely visual, never sampled back.
5. **Non-WebP branch** (`Utils.cs:977-985`): `new Bitmap(ms)` straight into the `PictureBox`.
   ImageSharp not involved at all.

Answers to the questions posed:

| Question | Answer |
|---|---|
| Resize dimensions | **None in code.** The only scaling is `PictureBoxSizeMode.Zoom` at paint time. |
| Sampling strategy | **None.** No pixel is ever read back. |
| Averaging | **None.** |
| Alpha/transparency handling | Source-over composite onto opaque `#F4F4F4`, WebP branch only (`Utils.cs:964`). Display-only. |
| Dominant-color extraction | **None.** |

> **Threading bug, noted in passing (do not replicate):** the WebP branch at `Utils.cs:969`
> assigns `pictureBox.Image` **directly from the worker thread**, while the non-WebP branch at
> `Utils.cs:980` correctly marshals via `pictureBox.Invoke`. The whole body is swallowed by
> `catch { }` at `Utils.cs:989`, so the resulting cross-thread exception is invisible. The Swift
> port should hop to `@MainActor` in both paths.

---

## 4. Tag color-field encoding (7 hex chars)

### 4.1 Tag layout

Per `README.md` and confirmed by `MainForm.cs:453`, the tag payload is a fixed-offset ASCII
string, right-padded with spaces to 96 chars (`MainForm.cs:454`) then UTF-8 encoded
(`MainForm.cs:455`):

| Offset | Len | Field | Value in code |
|---|---|---|---|
| 0 | 5 | date | `"AB124"` (hard-coded, `MainForm.cs:453`) |
| 5 | 4 | vendorId | `"0276"` (`MainForm.cs:449`) |
| 9 | 2 | batch | `"A2"` (`MainForm.cs:453`) |
| 11 | 6 | filamentId | `"1" + MaterialID` (`MainForm.cs:448`) |
| **17** | **7** | **color** | **`"0" + Color`** (`MainForm.cs:450`) |
| 24 | 4 | filamentLen | `Length` |
| 28 | 6 | serialNum | `"000001"` (`MainForm.cs:451`) |
| 34 | 14 | reserve | `"00000000000000"` (`MainForm.cs:452`) |
| 48 | … | printerModel | `printerModel.Text` |

### 4.2 The leading nibble

Write path — `MainForm.cs:450`:

```csharp
string color = "0" + Color;
```

Read path — `MainForm.cs:416`:

```csharp
MaterialColor = tagData.Substring(18, 6);
```

**The leading nibble is a hard-coded literal ASCII `'0'`. It carries no color information.**

- On write it is a constant `'0'` prepended to the 6-hex RGB string. There is no code path in
  the Windows app that can emit any other value.
- On read it is **skipped** — the substring starts at offset **18**, not 17, discarding the
  nibble entirely without inspecting or validating it.
- Round-trip is therefore lossy-but-harmless for `'0'`, and a tag written by other software with
  a non-zero nibble would have that nibble silently dropped on read and reset to `'0'` on
  rewrite.

Corroboration:
- Android does the identical thing: `MainActivity.java:746` `String color = "0" + Color;`
- Android's *manual/expert* mode is the one place a full 7-char field is user-editable
  (`MainActivity.java:939` validates `length() == 7`, `:923` reads back `substring(17, 24)`),
  and its default string is `def_col = 00000FF` (`Android/SpoolID/app/src/main/res/values/strings.xml:51`)
  — i.e. `'0'` + `0000FF`, matching the Windows default.
- Every example in `README.md` uses `0` (`0FFFFFF`, `0C12E1F`, `0000000`).
- The printer's own state file uses the same 7-char form:
  `docs/tn_data.json` → `base_data.T1.color_value = ["0FFFFFF","0C12E1F","0000000","0C12E1F"]`,
  and `remain_material.color = "0000000"`. Empty slots are the sentinel `"-1"`
  (`base_data.T2/T3/T4.color_value`).

> **OPEN QUESTION (nibble semantics)** — see §7.

### 4.3 RGB → 6-hex encoding

`MainForm.cs:710`, the sole producer of `MaterialColor` from user input:

```csharp
MaterialColor = (dlg.Color.ToArgb() & 0x00FFFFFF).ToString("X6");
```

- `Color.ToArgb()` yields `0xAARRGGBB`; `& 0x00FFFFFF` **discards alpha** (the Windows
  `ColorDialog` always returns `A = 255` anyway).
- `"X6"` → **uppercase**, zero-padded to 6 chars.
- Default before any pick: `MaterialColor = "0000FF"` (`MainForm.cs:60`).
- Round-trip back to a swatch: `ColorTranslator.FromHtml("#" + MaterialColor)`
  (`MainForm.cs:61`, `:418`, `:705`; `SmDialog.cs:37`).

Note the case asymmetry: values produced by the picker are **uppercase**; values read off a tag
(`MainForm.cs:416`) preserve whatever case the tag holds. `FindNearestColor` is case-insensitive
(`Convert.ToInt32(…,16)` accepts both), so this only affects displayed text, never matching.

---

## 5. Named-color lookup & display in the UI

### 5.1 Color picking — `MainForm.cs`, not `FilamentForm.cs`

`MainForm.BtnColor_Click`, `MainForm.cs:698-712`:

```csharp
ColorDialog dlg = new ColorDialog
{
    AllowFullOpen = true,
    FullOpen = true,
    AnyColor = true,
    Color = ColorTranslator.FromHtml("#" + MaterialColor)
};
if (dlg.ShowDialog() == DialogResult.OK)
{
    btnColor.BackColor = dlg.Color;
    MaterialColor = (dlg.Color.ToArgb() & 0x00FFFFFF).ToString("X6");
}
```

The standard Win32 `ChooseColor` dialog, opened pre-expanded to the full custom-color picker.
Result drives a swatch button (`btnColor`) and the `MaterialColor` string. Visibility of
`btnColor` is toggled per printer type at `MainForm.cs:311, 338, 354, 371`.

**No color name is displayed at this point.** The main form shows a swatch only.

### 5.2 Where the name is shown — `SmDialog.cs` (Spoolman upload)

The *only* consumer of `ColorMatcher` in the Windows app is the "Add Spool to Spoolman" dialog.

`SmDialog.cs:58-69`:

```csharp
ColorMatcher matcher = new ColorMatcher();
string matchedColor = matcher.FindNearestColor(colorHex);
if (TxtColorName.IsHandleCreated)
{
    SendMessage(TxtColorName.Handle, EM_SETCUEBANNER, 1, matchedColor);
}
else
{
    TxtColorName.HandleCreated += (s, e) => {
        SendMessage(TxtColorName.Handle, EM_SETCUEBANNER, 1, matchedColor);
    };
}
```

The matched name is rendered as a **Win32 cue banner / placeholder** (`EM_SETCUEBANNER`,
`0x1501`, `SmDialog.cs:11`) inside an empty text box — greyed-out ghost text, **not** the
control's value. The user is free to type a different name over it.

Commit behaviour, `SmDialog.cs:86-92`:

```csharp
btnOk.Click += (s, e) => {
    if (TxtColorName.Text == "")
    {
        TxtColorName.Text = matchedColor;
    }
    this.ColorNameResult = TxtColorName.Text;
};
```

So the matched name is only *materialised* if the user submits an empty box. This is a
placeholder-with-fallback pattern, not an auto-fill.

Dialog also shows the raw hex as text and a 32×16 swatch panel, `SmDialog.cs:27-39`:

```csharp
AddLabel("Color:", colorHex, 70);
…
try { colorBox.BackColor = ColorTranslator.FromHtml("#" + colorHex); }
catch { colorBox.BackColor = Color.Gray; }
```

Note the hex shown is the **6-char** `MaterialColor` (`MainForm.cs:899` passes `MaterialColor`),
not the 7-char tag form. Invalid hex falls back to `Color.Gray`.

Downstream, `MainForm.cs:899-911`:

```csharp
using (SmDialog dialog = new SmDialog(vendorName.Text, materialName.Text, MaterialColor, GetMaterialIntWeight(MaterialWeight)))
…
    string colorName = dialog.ColorNameResult;
…
        colorName = MaterialColor;      // MainForm.cs:907 — second-level fallback
…
        return SmAddSpool(…, MaterialID, MaterialColor, colorName, …);   // MainForm.cs:911
```

Two-stage fallback chain: **user text → matched name → raw hex string**.

### 5.3 `FilamentForm.cs` — no color logic

For the record, every `Color` token in `FilamentForm.cs` is static UI chrome:

- `FilamentForm.cs:30` `BackColor = ColorTranslator.FromHtml("#F4F4F4");`
- `FilamentForm.cs:31` `tabControl1.BackColor = …("#F4F4F4");`
- `FilamentForm.cs:33-34` `btnCancel/btnSave.BackColor = …("#1976D2");`
- `FilamentForm.cs:35` `lblFilament.ForeColor = …("#1976D2");`
- `FilamentForm.cs:366` `rtbDesc.BackColor = tabControl1.BackColor;`
- `FilamentForm.cs:370, 376` `rtbDesc.SelectionColor = …("#1976D2");`

And one **commented-out** block, `FilamentForm.cs:302-303`:

```csharp
//   JArray colors = (JArray)baseval["colors"];
//   colors[0] = "#ffffff";
```

This is dead code referencing the material database's per-filament `colors` array
(e.g. `db/k2.json` → `result.list[0].base.colors = ["#ffffff"]`; all 66 such values across the
file are `#rrggbb`, unrelated to the tag's 7-char field). **The material DB's suggested colors
are never fed into `ColorMatcher` and never influence the tag.** Do not port this.

### 5.4 App palette constants (for visual parity, not matching)

`#F4F4F4` window background, `#1976D2` accent/primary, `#FFFFFF` panels, `#333333` toast,
`#990000` error toast (`Toast.cs:37,152,156`), `#CD5C5C` error text (`UploadForm.cs:72,77`).

---

## 6. Gamma / color-space conversion

**There is none. Anywhere.**

- `ColorMatcher.cs` performs pure integer bit-masking on 8-bit hex codes and Euclidean distance
  on those raw codes. No linearisation (`c/12.92` / `((c+0.055)/1.055)^2.4`), no XYZ, no LAB, no
  white-point, no chromatic adaptation.
- `MainForm.cs:710` is a bit-mask and a hex format.
- `ImageSharp` `Load<Rgba32>` at `Utils.cs:962` decodes to non-linear sRGB 8-bit and the only
  operation (`BackgroundColor`, `Utils.cs:964`) composites in that same non-linear space. Even
  here nothing is sampled, so it cannot affect matching.
- No ICC profile is read, embedded, assigned, or stripped at any point.

**Implication for the port:** the algorithm operates on **raw device sRGB 8-bit code values**.
The Swift implementation must treat the picked color as an untagged 8-bit sRGB triple and must
**not** let CoreGraphics/AppKit perform any color-space conversion between the picker and the
integer triple. See §8.2 — this is the single highest-risk source of off-by-one divergence.

---

## 7. OPEN QUESTIONS

1. **OPEN QUESTION — semantics of the leading nibble.** The nibble is a hard-coded `'0'` on
   write and discarded on read in *both* the Windows and Android apps, and every observed sample
   (README, `docs/tn_data.json`) is `0`. Its meaning in Creality's firmware is **unknown**. Plausible
   hypotheses, none confirmed by anything in this repo: (a) a color-count / multi-color flag
   (0 = single color, N = N-color filament) — the printer-side field is named `color_value` and is
   a per-slot array, which is suggestive but not evidence; (b) a high alpha/opacity or
   transparency nibble; (c) a special-effect code (silk / matte / glow / marble); (d) simply
   structural padding to align the field to 7 chars. **Recommendation for the port: emit literal
   `'0'` and skip index 17 on read, exactly matching Windows/Android.** Do not expose it in the
   UI until firmware behaviour is observed. If parity with Android's expert mode is later wanted,
   a 7-char manual entry field can be added, but note that `FindNearestColor` would then need an
   explicit "take the low 24 bits" guard (§2.1) which the current code does not have.

2. **OPEN QUESTION — is a named-color feature wanted beyond the Spoolman dialog?** In the Windows
   app the color *name* surfaces in exactly one place (`SmDialog`), as a placeholder. The main
   window shows only a swatch. If the macOS port wants to show "Cherry Pie" next to the picker on
   the main screen, that is a **new feature**, not a port. Flagging so the scope decision is
   explicit.

3. **OPEN QUESTION — is `parts.Length >= 2` vs. the 3-column reality a latent contract?** The
   loader tolerates 2-column rows, and the `isGoodName` column is ignored. If `colors.db` is ever
   regenerated from upstream meodai with a different column count, the Windows app keeps working.
   Should the Swift port replicate that tolerance, or hard-fail on a malformed DB it ships itself?
   Recommend: replicate the tolerance (cheap), but add a **debug-only assertion on the loaded
   count == 31,861** so a bad rebuild is caught in CI rather than silently degrading matches.

4. **OPEN QUESTION — the silent-empty-list failure mode.** `ColorMatcher.cs:67` (`catch {}`)
   means a corrupt/missing resource degrades to "every lookup returns `null`" with no user-visible
   signal, and `SmDialog` then shows an empty placeholder and silently falls back to the raw hex.
   Recommend the Swift port **fail loudly in debug / log in release** rather than replicating the
   total silence — but keep the user-facing fallback chain (name → hex) identical.

5. **OPEN QUESTION — `null` vs `String.Empty` return asymmetry.** `FindNearestColor` returns
   `null` when the list is empty (loop never runs) but `String.Empty` when hex parsing throws
   (`ColorMatcher.cs:97`). `SmDialog` treats both the same (`EM_SETCUEBANNER` with either is a
   no-op-ish empty banner), so it is not observably load-bearing. Recommend a single Swift
   `String?` returning `nil` for both, and confirm no caller distinguishes them.

---

## 8. Swift implementation notes

### 8.1 `colors.db` — recommendation: **convert to a generated Swift resource at build time**

Options weighed:

| Option | Verdict |
|---|---|
| Ship `colors.db` as-is and unzip at runtime | Works (`Foundation` has no unzip; you'd need `Compression` + a hand-rolled ZIP local-header parser, or `libz`). ~300 KB bundle, ~700 KB inflate + full CSV parse on every load. Faithful, but you are writing a ZIP parser to read a file *you* control. |
| Ship `colors.db`, read with system `libsqlite3` | **Not applicable — the file is not SQLite.** Noted because the task premise assumed it was. (`libsqlite3.tbd` is indeed always present on macOS, but there is nothing here to point it at.) |
| Convert to SQLite at build time | Adds a dependency and an index for a problem that is a 31,861-element linear scan over ~5 ms. Overkill. |
| Convert to JSON at build time | Fine, but JSON parsing 31,861 objects is slower and larger than the alternatives. |
| **Convert to a packed binary blob + a generated names table** | **Recommended.** |

**Recommended concrete shape:**

Add a build-time script (SPM plugin or a checked-in generator run manually, with the output
committed so the build stays hermetic) that reads `reference/colors.db` and emits
two artifacts into the macOS app bundle:

1. `colors.rgb` — a flat little-endian `[UInt32]` of 31,861 entries, `0x00RRGGBB`, **in original
   CSV row order**. 127,444 bytes. Loaded with a single `Data(contentsOf:)` +
   `withUnsafeBytes { $0.bindMemory(to: UInt32.self) }` — zero parsing.
2. `colors.names` — the 31,861 names, UTF-8, `\n`-separated, in the same order, plus a
   `colors.names.idx` of `[UInt32]` byte offsets (or just split lazily on first access).
   Names are only needed for the single winning index, so this can be lazily memory-mapped and
   sliced — you never need to materialise 31,861 `String`s.

This preserves row order (critical for tie-breaking, §2.4), removes the ZIP dependency entirely,
and makes the hot loop a tight scan over contiguous `UInt32`s.

**Keep the original `colors.db` in the repo** as the source of truth so Windows/Android/macOS
cannot drift, and have the generator assert the count is 31,861.

### 8.2 The matcher

```swift
/// Byte-exact port of Windows/CFS-RFID/ColorMatcher.cs:70-99.
/// Ties are broken by lowest index, matching the strict `<` at ColorMatcher.cs:87.
func findNearestColorIndex(r: Int32, g: Int32, b: Int32, table: UnsafeBufferPointer<UInt32>) -> Int? {
    var bestIndex = -1
    var bestDist  = Int32.max          // squared distance; max is 3*255^2 = 195_075, fits easily
    for i in 0..<table.count {
        let c  = table[i]
        let dr = r - Int32((c >> 16) & 0xFF)
        let dg = g - Int32((c >>  8) & 0xFF)
        let db = b - Int32( c        & 0xFF)
        let d  = dr*dr + dg*dg + db*db
        if d < bestDist { bestDist = d; bestIndex = i }   // strict <  => first row wins
    }
    return bestIndex >= 0 ? bestIndex : nil
}
```

Notes:
- **Drop the `sqrt`.** `sqrt` is monotonic, so comparing squared distances selects the identical
  winner. This also eliminates the `Math.Pow`/`Double` rounding that C# incurs — and because the
  comparison is now exact integer arithmetic, the Swift result is *provably* identical to C# for
  every one of the 2²⁴ possible inputs, rather than "identical in practice". Max squared distance
  is `3 × 255² = 195,075`, comfortably inside `Int32`.
- Do **not** parallelise with `concurrentPerform` unless the reduction breaks ties by lowest
  index. A naive parallel min will pick a nondeterministic winner on ties (§2.3).
- Do **not** substitute a k-d tree / octree / `vImage` nearest-neighbour without a tie-break
  guarantee — the win is a few milliseconds and the risk is silent divergence.
- Cache the loaded table in a `let` on a singleton / `@MainActor` cached type. Do not rebuild it
  per dialog the way `SmDialog.cs:58` does.

### 8.3 Hex parsing parity

```swift
// Mirrors ColorMatcher.cs:74-77 — accepts "C12E1F", "#C12E1F", and the 7-char "0C12E1F".
func rgbFromHex(_ s: String) -> (Int32, Int32, Int32)? {
    guard let v = UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
    return (Int32((v >> 16) & 0xFF), Int32((v >> 8) & 0xFF), Int32(v & 0xFF))
}
```

`UInt32(_:radix:)` is length-agnostic like `Convert.ToInt32(…, 16)`. Note it is stricter than C#
about leading/trailing whitespace — call `.trimmingCharacters(in: .whitespaces)` first if the
input can come from a text field.

### 8.4 Color picking on macOS — the sRGB trap

Replace `ColorDialog` (`MainForm.cs:700-706`) with `NSColorPanel` / SwiftUI `ColorPicker`.

**Critical:** `NSColor` from the picker may be in `deviceRGB`, `displayP3`, or a
calibrated space depending on the user's display and the picker tab. Reading `.redComponent`
directly will give you **display-P3 or calibrated-RGB** components, which are *not* the sRGB code
values the Windows app produced. Always convert explicitly before quantising:

```swift
// Mirrors MainForm.cs:710 — (ToArgb() & 0x00FFFFFF).ToString("X6")
func materialColorHex(from nsColor: NSColor) -> String {
    let c = nsColor.usingColorSpace(.sRGB) ?? nsColor   // MUST pin to sRGB — see SPEC §6
    let r = UInt8((c.redComponent   * 255).rounded())
    let g = UInt8((c.greenComponent * 255).rounded())
    let b = UInt8((c.blueComponent  * 255).rounded())
    return String(format: "%02X%02X%02X", r, g, b)      // uppercase, matching "X6"
}
```

- `.usingColorSpace(.sRGB)` is the whole ballgame. Omit it and every color the user picks is
  silently off by several code values, and matches drift to neighbouring names.
- Alpha is dropped, matching the `& 0x00FFFFFF` mask.
- Rounding: `(x * 255).rounded()` (round-half-away-from-zero) matches what the Win32 picker
  effectively yields. The Win32 `ChooseColor` dialog is natively 8-bit integer, so on Windows
  there is no rounding at all — pin the macOS picker to 8-bit sRGB and the two agree exactly.
- Default `MaterialColor` is `"0000FF"` (`MainForm.cs:60`).
- Swatch round-trip: build `NSColor(srgbRed:green:blue:alpha: 1.0)` from the parsed bytes —
  again explicitly sRGB — mirroring `ColorTranslator.FromHtml` (`MainForm.cs:61`, `SmDialog.cs:37`),
  with a `.gray` fallback on parse failure (`SmDialog.cs:38`).

### 8.5 Tag field encoding

```swift
let colorField = "0" + materialColor          // MainForm.cs:450 — literal '0', 7 chars total
```

Read back (`MainForm.cs:416`):

```swift
let materialColor = String(tagData[tagData.index(tagData.startIndex, offsetBy: 18) ..<
                                   tagData.index(tagData.startIndex, offsetBy: 24)])
```

Offset **18**, length **6** — deliberately skipping the nibble at 17. Because `tagData` is
guaranteed ASCII here, prefer working on `Array(tagData.utf8)` and slicing by integer offsets;
using `String.Index` arithmetic on arbitrary input risks grapheme-cluster surprises if a
malformed tag ever decodes to non-ASCII.

### 8.6 Image handling (`Utils.LoadPrinterImage` equivalent)

Only relevant to the printer-thumbnail feature; **it has nothing to do with color matching**, so
resampling fidelity is a non-issue for correctness.

- WebP decoding: macOS 11+ `ImageIO` decodes WebP natively (`CGImageSourceCreateWithData`), so
  no third-party decoder is needed and the whole ImageSharp → BMP → `System.Drawing` round-trip
  (`Utils.cs:962-969`) collapses to a single `NSImage(data:)` / `CGImageSourceCreateImageAtIndex`.
- Alpha flattening (`Utils.cs:964`): draw the image into a `CGContext` pre-filled with
  `#F4F4F4`, or simply set the hosting `NSImageView`'s background to `#F4F4F4` and let AppKit
  composite. The latter is closer to intent and avoids a redundant blit.
- `PictureBoxSizeMode.Zoom` (`Utils.cs:970`) ≡ `NSImageView.imageScaling = .scaleProportionallyUpOrDown`
  with `imageAlignment = .alignCenter`.
- Do the network fetch with `URLSession` and hop to `@MainActor` before touching the view —
  fixing the cross-thread bug noted in §3.1.

**On resampling parity:** ImageSharp's default resampler (bicubic) and CoreGraphics'
interpolation are different algorithms with different kernels and different edge handling.
**Pixel-for-pixel parity is not achievable and should not be attempted.** In this app it also
does not matter, since no resampled pixel is ever read back — the scaling is purely for display.
If a future feature *does* sample pixels, budget a tolerance of **±2 per 8-bit channel** for
resampled/interpolated pixels (and require **exact** equality for un-resampled 1:1 reads).
For any *color-matching* comparison, require **exact** equality — that path involves no
resampling and no floating point, so there is no reason to accept drift.

### 8.7 Test vectors

Derived by re-implementing `ColorMatcher.cs:70-99` against the extracted `colornames.csv`
(31,861 entries, original row order, strict-`<` tie-break). `Row` is the 0-based index into the
data rows (i.e. CSV line number − 2), included so the port can assert tie-break behaviour, not
just the name.

| Input RGB (6-hex) | Tag field (7-hex) | Expected name | Matched hex | Distance | Row | Note |
|---|---|---|---|---|---|---|
| `0000FF` | `00000FF` | `Blue` | `#0000ff` | 0.0000 | 3001 | default `MaterialColor` (`MainForm.cs:60`) |
| `FFFFFF` | `0FFFFFF` | `White` | `#ffffff` | 0.0000 | 30854 | README example |
| `000000` | `0000000` | `Black` | `#000000` | 0.0000 | 2674 | README example |
| `C12E1F` | `0C12E1F` | `Cherry Pie` | `#bd2c22` | 5.3852 | 5497 | README example — **inexact match** |
| `1976D2` | `01976D2` | `Bright Navy Blue` | `#1974d2` | 2.0000 | 3866 | app accent colour |
| `808080` | `0808080` | `Grey` | `#808080` | 0.0000 | 12463 | mid grey |
| `FF0000` | `0FF0000` | `Red` | `#ff0000` | 0.0000 | 23129 | pure red |
| `00FF00` | `000FF00` | `Green` | `#00ff00` | 0.0000 | 12174 | pure green |
| `010203` | `0010203` | `Black Hole` | `#010203` | 0.0000 | 2711 | near-black exact hit |
| `A59344` | `0A59344` | `18th Century Green` | `#a59344` | 0.0000 | 1 | **first** data row |
| `2B61A0` | `02B61A0` | `Zydeco Blue` | `#2b61a0` | 0.0000 | 31860 | **last** data row (no trailing `\n`) |
| `EAD742` | `0EAD742` | `Meadowlark` | `#e8d940` | 3.4641 | 17219 | **TIE-BREAK** — exactly equidistant (d²=12) from `Sandstorm` `#ecd540` (row 24631). Must return `Meadowlark`. |
| `2D49CC` | `02D49CC` | `Blue Blue` | `#2242c7` | 13.9642 | 3036 | **TIE-BREAK** — ties `Kikorangi Blue` `#2e4ebf` (row 14837), d²=195 |
| `FCC327` | `0FCC327` | `Golden Banner` | `#fcc62a` | 4.2426 | 11708 | **TIE-BREAK** — ties `Ripe Mango` `#ffc324` (row 23629), d²=18 |

Additional assertions worth encoding as tests:

- `loadedColorCount == 31_861`
- `entry(at: 0).name == "100 Mph"` and `entry(at: 0).hex == "#c93f38"` (the *attribution* line
  `https://github.com/meodai/color-names` must have been discarded, `ColorMatcher.cs:48`)
- `entry(at: 31_860).name == "Zydeco Blue"` (last row parsed despite missing trailing newline)
- A UTF-8 round-trip: some row's name must equal `"5-Masted Preußen"` and another
  `"Zürich Blue"` (739 rows contain non-ASCII; a Latin-1 misread would corrupt these)
- `rgbFromHex("0C12E1F") == rgbFromHex("C12E1F") == rgbFromHex("#C12E1F")` (§2.1)
- `materialColorHex(from: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) == "0000FF"`
  (uppercase, alpha stripped — `MainForm.cs:710`)
- Empty-table behaviour returns `nil` and the UI falls back to the raw hex string
  (`MainForm.cs:907`)
