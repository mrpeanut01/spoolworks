# SPEC-04 — Printer Communication & Networking Specification

Reverse-engineered from the Windows C# app (`Windows/CFS-RFID`, .NET Framework 4.8.1),
cross-checked against the Android app (`Android/SpoolID`) where the C# uses a library
that hides the wire protocol.

All file:line references are to files under the repo root
`/Users/nrene/Documents/Development/04-personal-projects/k2-rfid`.

**Scope note:** the app has exactly **three** network surfaces:

1. SSH/SCP to the printer (port 22, root).
2. HTTPS to the Creality Cloud slicer-profile API + the CDN zip it points at.
3. Optional HTTP to a user-run **Spoolman** server (LAN, default port 7912).

There is **no** WebSocket, no JSON-RPC, no Moonraker client, and no LAN discovery. See §6 and §9.

---

## 0. Dependency inventory (relevant to networking)

`Windows/CFS-RFID/packages.config`:

| Package | Version | Line | Used for |
|---|---|---|---|
| `SSH.NET` (`Renci.SshNet`) | `2025.0.0` | packages.config:10 | `SshClient` (exec) + `ScpClient` (file transfer) |
| `Newtonsoft.Json` | `13.0.3` | packages.config:7 | all JSON |
| `BouncyCastle.Cryptography` | `2.6.1` | packages.config:3 | transitive dep of SSH.NET |
| `SixLabors.ImageSharp` | `2.1.11` | packages.config:9 | decoding `.webp` printer thumbnails from the CDN |
| `PCSC` | `7.0.1` | packages.config:8 | smartcard reader (not networking — see `Monitor.cs`) |

Assembly reference confirming the SSH.NET build: `Windows/CFS-RFID/CFS-RFID.csproj:83-84`
(`Renci.SshNet, Version=2025.0.0.1`, `..\packages\SSH.NET.2025.0.0\lib\net462\Renci.SshNet.dll`).
`System.IO.Compression` is a plain framework reference (`CFS-RFID.csproj:103`) used only for
`ZipArchive` on the downloaded profile bundle (`Utils.cs:916`).

**`Monitor.cs` is not networking.** It is a PC/SC smartcard-reader monitor
(`Monitor.cs:1-2` imports `PCSC.Monitoring`, `PCSC`) wrapping `MonitorFactory.Instance.Create(SCardScope.System)`
(`Monitor.cs:18`) and re-raising `CardInserted` / `CardRemoved` / `StatusChanged`
(`Monitor.cs:34-47`). It contains no sockets, no HTTP, no SSH. It is listed in this task
presumably because of the name; it belongs to the RFID-reader spec, not this one.

---

## 1. SSH: host, port, credentials, transfer mechanics

### 1.1 Connection parameters

Every SSH/SCP call in the app is constructed identically:

```csharp
new SshClient(host, 22, "root", psw)   // Utils.cs:422
new ScpClient(host, 22, "root", psw)   // Utils.cs:450, 481, 513, 545, 590, 622, 657
```

* **Host** — free-text from the user (`txtIP.Text`), an IP address *or* a hostname
  (`UploadForm.cs:139`, `UpdateForm.cs:108`). No validation beyond non-empty.
* **Port** — hardcoded `22` at all seven construction sites listed above. Not configurable.
* **Username** — hardcoded `"root"` at all seven sites. Not configurable, not shown in the UI.
* **Auth** — **password only.** No key auth, no agent, no keyboard-interactive fallback
  anywhere in the codebase. The `SshClient(string, int, string, string)` /
  `ScpClient(string, int, string, string)` ctor overload creates a
  `PasswordAuthenticationMethod`.

### 1.2 Default passwords (verbatim from source)

Selected per printer type in `UploadForm.cs:40-51` and `UpdateForm.cs:48-59`, read from
`Windows/CFS-RFID/Properties/Resources.resx`:

| Resource | Value | resx line | Applies to |
|---|---|---|---|
| `hiPsw` | `Creality2024` | Resources.resx:149-151 | printer name containing `hi` |
| `k1Psw` | `creality_2023` | Resources.resx:146-148 | printer name containing `k1` |
| `k2Psw` | `creality_2024` | Resources.resx:161-163 | **everything else** (fallback, incl. K2) |

Note the capitalisation difference: `Creality2024` (Hi) vs `creality_2024` (K2).
`root/README.md` independently documents `Account: root` / `Password: creality_2024`
as what the K2 touchscreen displays after enabling root.

These are per-device factory defaults printed on the printer's own screen; the user can
override the value in the dialog and the override is persisted (§1.4). Root SSH must first
be enabled on the printer via *Settings → Root account information* on the touchscreen
(`root/README.md`).

### 1.3 Host-key verification — NONE

The app never subscribes to `SshClient.HostKeyReceived` / `ScpClient.HostKeyReceived`.
SSH.NET's default when no handler sets `e.CanTrust = false` is to **accept any host key**,
so the Windows app has no host-key pinning, no known_hosts, and no MITM protection.
The Android sibling does this explicitly:
`prop.put("StrictHostKeyChecking", "no")` — `Android/SpoolID/app/src/main/java/dngsoftware/spoolid/Utils.java:526-527, 550-551, 616-617`.
This is a deliberate design choice (printers regenerate host keys on firmware flash), and it
has direct UX consequences for the macOS port — see §10.5.

### 1.4 Credential storage

Both dialogs persist host and password **in cleartext** in the Windows registry under
`HKCU\CFS RFID\Settings` (`Settings.cs:12, 137-139`):

* `host_<PrinterName>` — `UploadForm.cs:53, 137`; `UpdateForm.cs:61, 106`
* `psw_<PrinterName>` — `UploadForm.cs:54, 138`; `UpdateForm.cs:62, 107`
* `prevent_<PrinterName>` (bool, default `true`) — `UploadForm.cs:55, 97`
* `reboot_<PrinterName>` (bool, default `true`) — `UploadForm.cs:56, 102`

The password field is a plain `TextBox` with **no `PasswordChar`** — it is displayed in
clear on screen (`UploadForm.Designer.cs:61-66`, `UpdateForm.Designer.cs:120-127`).

### 1.5 The one and only remote command

```csharp
public static string SendSShCommand(string psw, string host, string command)  // Utils.cs:420
{
    using (var client = new SshClient(host, 22, "root", psw))                 // Utils.cs:422
    {
        client.ConnectionInfo.Timeout = TimeSpan.FromSeconds(5);              // Utils.cs:426
        client.Connect();                                                     // Utils.cs:427
        using (var cmd = client.CreateCommand(command))                       // Utils.cs:428
        {
            cmd.CommandTimeout = TimeSpan.FromSeconds(5);                     // Utils.cs:430
            return cmd.Execute();                                             // Utils.cs:431
        }
    }
}
```

The **only** command string ever passed is `"reboot"` — `UploadForm.cs:167`, `Utils.cs:470`,
`Utils.cs:731`. There is no `chmod`, no `chown`, no `sync`, no service restart
(`systemctl` / `/etc/init.d/… restart` / `killall`), no `mkdir -p`. The printer picks up the
new database purely by rebooting (or, if the user disables reboot, on the next natural restart).

### 1.6 File transfer — SCP, not SFTP

All transfers use `Renci.SshNet.ScpClient` (`ScpClient.Upload(Stream, path)` /
`ScpClient.Download(path, Stream)`), i.e. **the legacy SCP protocol driven over an exec
channel**, not the SFTP subsystem. SSH.NET's `ScpClient` issues:

* upload: `scp -t <remote-directory>` then the SCP control record `C0644 <length> <filename>\n`
  followed by the raw bytes and a trailing `\0`;
* download: `scp -f <remote-path>` then the ack/`C<mode> <size> <name>` handshake.

The Android app hand-rolls the identical protocol over JSch and makes the wire format explicit,
which is the best available confirmation of what the printer sees:

* `channel.setCommand("scp -p -t /usr/data/creality/userdata/box/" + fileName)` — Android `Utils.java:622`
* `channel.setCommand("scp -p -t /mnt/UDISK/creality/userdata/box/" + fileName)` — Android `Utils.java:624`
* `out.write(("C0644 " + dbData.length() + " " + fileName + "\n").getBytes())` — Android `Utils.java:627`
* `channel.setCommand("scp -f /usr/data/creality/userdata/box/" + fileName)` — Android `Utils.java:566`
* `channel.setCommand("scp -f /mnt/UDISK/creality/userdata/box/" + fileName)` — Android `Utils.java:568`

**Permissions: `0644`, owner `root` (the login user).** No explicit `chmod`/`chown` is ever
issued; the mode comes from the SCP `C0644` control record. Because the login is root, the
resulting file is `root:root 0644`.

Each helper opens **its own connection** and closes it in `finally` — e.g. `Utils.cs:485-506`,
`Utils.cs:594-615`. A single "Upload" click therefore opens **2–3 separate SSH sessions**
(version read, file upload, reboot; plus a 4th for `material_option.json` on K1).

---

## 2. Exact remote paths

Base directory, by printer type (the *only* branch in the whole networking layer):

| Printer type | Remote base directory |
|---|---|
| name contains `k1` | `/usr/data/creality/userdata/box/` |
| everything else (K2, Hi, …) | `/mnt/UDISK/creality/userdata/box/` |

Branch sites (identical `pType.ToLower().Contains("k1")` test at every one):
`Utils.cs:487-491`, `Utils.cs:519-523`, `Utils.cs:551-555`, `Utils.cs:596-600`,
`Utils.cs:628-632`, `Utils.cs:663-667`.

Files touched:

| Remote file | Direction | Mode | Written by | Path constant |
|---|---|---|---|---|
| `…/box/material_database.json` | **write** | 0644 | Upload flow | `Utils.cs:487`, `Utils.cs:490` |
| `…/box/material_database.json` | **write** | 0644 | Reset flow (filename param) | `Utils.cs:455` → `Utils.cs:551-555` |
| `…/box/material_database.json` | read | — | version check | `Utils.cs:663`, `Utils.cs:666` |
| `…/box/material_database.json` | read | — | "get update from printer" | `Utils.cs:628`, `Utils.cs:631` |
| `…/box/material_option.json` | **write** | 0644 | K1 only, after DB upload | `Utils.cs:728` |

`README.md` ("Files of interest") lists four files in that directory —
`tn_data.json`, `material_box_info.json`, `material_database.json`, `material_modify_info.json` —
but **only `material_database.json` and `material_option.json` are ever touched by the app**
(verified by grep across `Windows/`). The other two/three are documentation-only captures (§8).

No directories are created remotely; the app assumes `…/creality/userdata/box/` exists.

---

## 3. "Upload" vs "Update" — two different dialogs, opposite directions

The sidebar menu (`MainForm.cs:112-121`) offers, under the header "Printer Database":

| Menu id | Label | Handler | Dialog |
|---|---|---|---|
| `nav_manage` | "Manage Printers" | `OpenManage()` — `MainForm.cs:558` | `ManageForm` (cloud only) |
| `nav_upload` | "Upload Database" | `OpenUpload()` — `MainForm.cs:621` | **`UploadForm`** (PC → printer) |
| `nav_download` | "Download Database" | `OpenUpdate()` — `MainForm.cs:593` | **`UpdateForm`** (cloud/printer → PC) |

**Naming trap for the port:** the menu item is called *Download Database* but the class is
`UpdateForm` and its window title is `"Update"` (`UpdateForm.Designer.cs:298`); the *Upload*
dialog's window title is `"Upload"` (`UploadForm.Designer.cs:269`) but its header label reads
`"Update <printer> Database"` (`UploadForm.cs:38`). Both are reachable at any time from the
sidebar; neither is conditionally offered.

### 3.1 UploadForm — push the local database onto the printer

`UploadForm.SelectedPrinter` is set from `MainForm.PrinterType` (`MainForm.cs:627`), which is
the selected item of the printer combo (`MainForm.cs:727`), which is the set of
`material_database\*.json` filenames in the app directory (`Utils.cs:398-418`).
If `SelectedPrinter == null` the dialog closes immediately with `DialogResult.No`
(`UploadForm.cs:30-35`) and MainForm toasts `"No printer selected"` (`MainForm.cs:642`).

Controls (`UploadForm.Designer.cs`):

| Control | Label | Default | Meaning |
|---|---|---|---|
| `txtIP` | "Printer IP:" | `host_<p>` setting | hostname or IP |
| `txtPass` | "Password:" | `psw_<p>` setting, else type default | root password, shown in clear |
| `chkPrevent` | "Prevent DB updates?" | `true` | write a bogus huge version so the printer/cloud never overwrites the DB |
| `chkReboot` | "Reboot printer?" | `true` | issue `reboot` after upload |
| `chkReset` | "Reset printer database?" | `false` | switch the dialog to Reset mode |
| `chkResetApp` | "Reset app database?" | `false` | (Reset mode only) also overwrite the local file |

**Normal upload path** (`UploadForm.cs:150-168`):

1. `lblMsg = "Uploading..."`.
2. If `chkPrevent` → `SetDatabaseVersion(SelectedPrinter, Resources.verPrevent)` where
   `verPrevent = "9876543210"` (`Resources.resx:168-170`, used at `UploadForm.cs:153`).
   This rewrites the **local** file's `result.version` (`MatDb.cs:78-93`) so that the value
   subsequently uploaded is larger than any real Creality version → the printer's own
   updater will consider itself up to date.
   Else → `GetPrinterVersion(...)` over SCP and stamp that value locally
   (`UploadForm.cs:157-158`).
3. `SetJsonDB(psw, host, pType)` — SCP-upload the local `material_database\<pType>.json`
   to the remote path (`Utils.cs:479-509`).
4. If `pType == "k1"` (exact, `OrdinalIgnoreCase` — `UploadForm.cs:161`) →
   `SaveMatOption(...)`: build `material_option.json` (a `{brand: {materialType: "name\nname"}}`
   index, `Utils.cs:694-728`), SCP it up, then `reboot` if `chkReboot` (`Utils.cs:729-732`).
   Else if `chkReboot` → `SendSShCommand(psw, host, "reboot")` (`UploadForm.cs:167`).

**Reset path** (`chkReset` checked → `UploadForm.cs:143-147` → `Utils.cs:448-477`):

1. Fetch a **fresh database from the Creality cloud** for this printer name at nozzle `0.4`
   (`GetJsonDB(pType, "0.4")` — the 2-arg cloud overload, `Utils.cs:454` → `Utils.cs:903`).
2. SCP it to `…/box/material_database.json` (`Utils.cs:455`).
3. If `chkResetApp` → also overwrite the local `material_database\<pType>.json`
   (`Utils.cs:457-469`).
4. **Unconditionally `reboot`** (`Utils.cs:470`) — the `chkReboot` switch is hidden in Reset
   mode (`UploadForm.cs:111`) and ignored.

Dead code worth not copying: `ResetJsonDB` constructs `new ScpClient(host, 22, "root", psw)`
at `Utils.cs:450` and never connects or uses it; the real transfer happens inside `SetJsonDB`,
which makes its own client.

### 3.2 UpdateForm — pull a database into the app

Two sources, toggled by `chkFromPrinter` ("Get update from printer?", `UpdateForm.Designer.cs:268`):

* **Off (default) — Creality Cloud.** On load, `FindPrinters(SelectedPrinter, "0.4")`
  (`UpdateForm.cs:78`) populates a model combo with cloud printer records and their
  thumbnails (`UpdateForm.cs:229-241`, image fetched by `LoadPrinterImage`, `Utils.cs:949`).
  "Available version" shows the cloud record's `version` field (`UpdateForm.cs:237-238`).
  `BtnUpdate_Click` calls `GetJsonDB(SelectedDatabase, "0.4")` (`UpdateForm.cs:138`) — the
  cloud overload — where `SelectedDatabase` starts as the selected printer type
  (`UpdateForm.cs:46`) and follows the combo selection (`UpdateForm.cs:239`).
* **On — the printer itself.** `panel1`/`btnUpdate` hide, `btnCheck` appears
  (`UpdateForm.cs:245-252`). `btnCheck` → `GetPrinterVersion(psw, host, pType)` over SCP
  (`UpdateForm.cs:108`) and compares `long.Parse(newVersion) > long.Parse(currentVersion)`
  (`UpdateForm.cs:112`); only then is `btnUpdate` shown. `btnUpdate` →
  `GetJsonDB(psw, host, pType)` (`UpdateForm.cs:134` → `Utils.cs:620`), i.e. SCP-download
  `material_database.json` into a string.

Either way, the parsed `result.list[]` is merged into the in-memory material DB — existing
`base.id` → `EditMaterial`, new → `AddMaterial` (`UpdateForm.cs:143-171`) — and then written
to the local app file with the new version (`SaveMaterials`, `UpdateForm.cs:179` →
`MatDb.cs:158-190`).

### 3.3 ManageForm — add/remove a printer profile (cloud only, no SSH)

`ManageForm` lists **all** supported types at once via `FindPrinters(Utils.printerTypes, "0.4")`
(`ManageForm.cs:29`, array `{"K2","K1","HI"}` at `Utils.cs:190-193`), and "Add" writes
`material_database\<CloudPrinterName>.json` from the cloud
(`SetDBfile(printerName + ".json", …GetJsonDB(printerName, "0.4"))` — `ManageForm.cs:58`).
"Delete" removes the local file (`ManageForm.cs:63-69`). No printer contact whatsoever.

---

## 4. Printer type detection

**There is no detection.** The type is a *string the user picked from a combo box*, and that
combo is populated from local filenames, which came from cloud printer names.

Chain: `Utils.GetPrinterTypes()` (`Utils.cs:398-418`) lists `*.json` under
`<AppDir>\material_database\` and returns the filenames without extension →
`MainForm.cs:81, 570, 580` fills `printerModel` → `MainForm.cs:727` sets `PrinterType` →
passed to `UploadForm.SelectedPrinter` / `UpdateForm.SelectedPrinter`
(`MainForm.cs:627`, `MainForm.cs:599`).

Everything downstream is **substring matching on that display name**:

| Test | Where | Effect |
|---|---|---|
| `name.ToLower().Contains("hi")` | `UploadForm.cs:40`, `UpdateForm.cs:48` | default password `Creality2024` |
| `name.ToLower().Contains("k1")` | `UploadForm.cs:44`, `UpdateForm.cs:52` | default password `creality_2023` |
| *(else)* | `UploadForm.cs:48-51`, `UpdateForm.cs:56-59` | default password `creality_2024` |
| `pType.ToLower().Contains("k1")` | `Utils.cs:488, 520, 552, 597, 629, 664` | remote base dir `/usr/data/…` instead of `/mnt/UDISK/…` |
| `pType.Equals("k1", OrdinalIgnoreCase)` | `UploadForm.cs:161` | **exact** match → also write `material_option.json` |

Per-type differences summary:

| | K2 (and default) | K1 | Hi |
|---|---|---|---|
| Default password | `creality_2024` | `creality_2023` | `Creality2024` |
| Remote base dir | `/mnt/UDISK/creality/userdata/box/` | `/usr/data/creality/userdata/box/` | `/mnt/UDISK/creality/userdata/box/` |
| `material_option.json` written | no | **yes** (exact-name match only) | no |
| User/port | `root`/22 | `root`/22 | `root`/22 |
| Payload format | identical | identical | identical |

**Known fragilities to fix rather than port verbatim:**

* The `"hi"` test is checked *first* and is an unanchored substring — any cloud printer name
  containing the letters `hi` (e.g. a hypothetical "…Hi Combo", or any future name) picks the
  Hi password. Conversely a real name like `K1 Max` contains `k1` and works by luck.
* The password branch keys off the *display name*, while the path branch keys off the same
  string — but the `material_option.json` branch uses **exact** equality with `"k1"`, so a
  profile named `K1 Max` or `K1C` **never** gets `material_option.json` even though it uses
  the K1 path. Android has the same split (`Utils.java:474` uses `contains("k1")` there,
  so Android *does* write it for K1 Max). **This is a genuine behavioural divergence between
  the two existing clients** — see OPEN QUESTIONS.

---

## 5. HTTP endpoints

### 5.1 Creality Cloud slicer-profile API

Single helper: `Utils.FetchDataFromApi(string apiUrl)` — `Utils.cs:736-759`.

* **Method:** `POST` (`client.UploadString(apiUrl, "POST", jsonBody)`, `Utils.cs:757`)
* **Transport:** `System.Net.WebClient`, TLS per .NET 4.8 defaults; no proxy config, no
  certificate pinning, no explicit `Accept-Encoding` (so **no gzip** on this call — see §5.3).

**URLs (only two):**

| URL | Called from |
|---|---|
| `https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/printerList` | `Utils.cs:765` (GetZipUrl), `Utils.cs:792` (FindPrinters[]), `Utils.cs:822` (FindPrinters) |
| `https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/materialList` | `Utils.cs:909` |

**Headers** (`Utils.cs:740-753`) — note the `User-Agent` impersonates **Bambu Studio**:

```
User-Agent: BBL-Slicer/v01.09.03.50 (dark) Mozilla/5.0 (Windows NT 10.0; Win64; x64)
            AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.52
Content-Type: application/json
__CXY_BRAND_:     creality
__CXY_UID_:       (empty)
__CXY_OS_LANG_:   0
__CXY_DUID_:      <fresh GUID per request>
__CXY_APP_VER_:   1.0
__CXY_APP_CH_:    CP_Beta
__CXY_OS_VER_:    <same string as User-Agent>
__CXY_TIMEZONE_:  28800
__CXY_APP_ID_:    creality_model
__CXY_REQUESTID_: <fresh GUID per request>
__CXY_PLATFORM_:  11
```

Byte-identical header set in Android `Utils.java:670-682`, confirming these are required by
the server (`__CXY_*` is Creality's app-gateway convention; `28800` = UTC+8 seconds).

**Request body** (`Utils.cs:754-756`):

```json
{"engineVersion":"3.0.0"}
```
and for the `materialList` URL only, `pageSize` is added:
```json
{"engineVersion":"3.0.0","pageSize":500}
```

**Response shapes:**

`printerList` → `root.result.printerList[]`, each element used for:
`name` (`Utils.cs:772, 800, 830`), `nozzleDiameter[]` (string array, matched against the
literal `"0.4"` — `Utils.cs:774-775, 804-805, 833-834`), `zipUrl` (`Utils.cs:777`),
`thumbnail` (image URL — `UpdateForm.cs:234`, `ManageForm.cs:86`), `version`
(`UpdateForm.cs:237`).

`materialList` → `root.result.list[]`, each with a `name` plus base metadata; entries
`createTime`, `status`, `userInfo` are stripped before use (`Utils.cs:867`).

**Nozzle diameter `"0.4"` is hardcoded at every call site** — `UpdateForm.cs:78, 138`,
`ManageForm.cs:29, 58`, `Utils.cs:454`. Non-0.4 printers are simply invisible to the app.

### 5.2 The profile ZIP (CDN)

`Utils.GetJsonDB(string targetPrinterName, string targetNozzle)` — `Utils.cs:903-946`:

1. `GetZipUrl(name, "0.4")` → the printer record's `zipUrl` (`Utils.cs:777`). URL is
   **server-supplied**, host not hardcoded anywhere. Empty/absent → return `null`.
2. `FetchDataFromApi(".../materialList")` (`Utils.cs:909`).
3. `new WebClient().DownloadData(zipUrl)` — plain **GET, no headers at all**
   (`Utils.cs:912-914`).
4. `new ZipArchive(new MemoryStream(zipData))` (`Utils.cs:915-916`) and iterate entries
   (`Utils.cs:918`):
   * entry ending `.json` with **no `/` in its path** (archive root) → parse and take
     `version` (`Utils.cs:927-931`) — this becomes the DB version.
   * entry under `materials/` → collect the whole JSON text (`Utils.cs:932-935`).
5. `ProcessMaterials(materialListJson, filamentJsonList, extractedVersion)` (`Utils.cs:848-901`)
   joins each filament profile (`metadata.name`) to its `materialList` base record and emits
   the printer-format document (§8.3):
   * per item: `engineVersion` ← `engine_version`, `printerIntName` ← **hardcoded `"F008"`**
     (`Utils.cs:874`), `nozzleDiameter` ← `["0.4"]` (`Utils.cs:875`), `kvParam` ←
     `engine_data`, `base` ← cleaned material record.
   * envelope: `{"code":0,"msg":"ok","reqId":"0","result":{list,count,version}}`
     (`Utils.cs:883-896`); if the zip had no version, `DateTimeOffset.UtcNow.ToUnixTimeSeconds()`
     is used (`Utils.cs:887`).

### 5.3 gzip / compression handling

* **No HTTP gzip anywhere.** `WebClient.AutomaticDecompression` is never set and no
  `Accept-Encoding` header is added, so responses are handled as-is. Android likewise
  (`HttpURLConnection` default `Accept-Encoding: gzip` with transparent decode, but nothing
  explicit).
* The only compression is **ZIP (deflate)** of the profile bundle, via
  `System.IO.Compression.ZipArchive` (`Utils.cs:11`, `Utils.cs:916`). Read-only, in memory,
  never written to disk.

### 5.4 Thumbnail fetch

`Utils.LoadPrinterImage(urlString, pictureBox)` — `Utils.cs:949-991`. Raw `WebClient.DownloadData`
on a background `Thread`. If the URL ends in `.webp` it is decoded with ImageSharp and
composited over `#F4F4F4` (`Utils.cs:958-971`); otherwise `System.Drawing.Bitmap`
(`Utils.cs:977-985`). All errors swallowed (`Utils.cs:989`).

**Threading bug to not reproduce:** the `.webp` branch assigns `pictureBox.Image` from the
worker thread *without* `Invoke` (`Utils.cs:969`), while the non-webp branch does use
`Invoke` (`Utils.cs:980`).

### 5.5 Spoolman (optional, LAN, third network surface)

* Base URL: `string.Format("http://{0}:{1}/api/v1", host, port)` — `Utils.cs:1127`.
  Host from setting `SmHost` (empty by default), port from `SmPort`, **default `7912`**
  (`MainForm.cs:911`, `SettingsForm.cs:29-30`). Plain HTTP, no auth.
* Endpoints (`Utils.cs:1135, 1158, 1163, 1205, 1220`):
  * `GET  /api/v1/vendor` — find a vendor by name (case-insensitive, `Utils.cs:1145`)
  * `POST /api/v1/vendor` — `{"name":<vendor>,"comment":"Created by: Cfs RFID"}` (`Utils.cs:1154-1157`)
  * `GET  /api/v1/filament` — find `vendor.id == vendorId && name == "<Name> (<Color>)"` (`Utils.cs:1169-1177`)
  * `POST /api/v1/filament` — `{name, vendor_id, color_hex (no '#'), comment, material,
    diameter, settings_extruder_temp, settings_bed_temp, density}` (`Utils.cs:1181-1204`);
    the last five are copied from the local filament's `base.meterialType`, `base.diameter`,
    `kvParam.nozzle_temperature`, `kvParam.hot_plate_temp`, `kvParam.filament_density`.
  * `POST /api/v1/spool` — `{filament_id, initial_weight, remaining_weight,
    comment:"RFID tagged for <printerType>"}` (`Utils.cs:1212-1220`)
* Transport: `PerformSmRequest` (`Utils.cs:1231-1254`) using a `TimedWebClient`
  (`Utils.cs:1257-1269`) with `Timeout = 5000` ms; headers
  `Content-Type: application/json`, `Accept: application/json`, UTF-8. Any `WebException`
  → `return null` (`Utils.cs:1249-1252`), which the caller turns into a user message.
* Gated by the `EnableSm` setting (`MainForm.cs:340, 530`; `SettingsForm.cs:27, 57-62`).

**Settings type mismatch to watch:** `SmPort` is *written* as a `String` registry value
(`SettingsForm.cs:67`) but *read* as an `int` (`MainForm.cs:911`); `Settings.GetSetting(string,int)`
survives this only because it does `int.TryParse(value.ToString())` (`Settings.cs:71`).

---

## 6. LAN discovery — none

**The user types an IP address or hostname.** There is no mDNS/Bonjour, no SSDP, no UDP
broadcast, no subnet scan, no ARP, no `Dns.` resolution helper, no ping. Verified by grep
across `Windows/**/*.cs` for `websocket|ws://|wss://|jsonrpc|moonraker|mdns|bonjour|broadcast|
UdpClient|Dns\.|Ping\(` — the only hits in the entire tree are the five HTTP URLs listed in §5.

The only "discovery" in the app is **cloud** printer-model discovery
(`FindPrinters`, `Utils.cs:787-845`) — it queries Creality's API for the catalogue of printer
*models*, not devices on the LAN.

Convenience is provided instead by persistence: the last-used host per printer type is
restored into `txtIP` (`UploadForm.cs:53`, `UpdateForm.cs:61`).

---

## 7. Progress, timeouts, retry, cancellation

**Timeouts**

| Operation | Timeout | Site |
|---|---|---|
| SSH connect (exec) | 5 s | `Utils.cs:426` |
| SSH command execute | 5 s | `Utils.cs:430` |
| SCP connect | 5 s | `Utils.cs:485, 517, 549, 594, 626, 661` |
| SCP transfer (`OperationTimeout`) | **never set** → SSH.NET default (infinite) | — |
| Creality API / zip / thumbnail | **never set** → `WebClient` default 100 s | `Utils.cs:738, 912, 955` |
| Spoolman | 5 s | `Utils.cs:1259` |

`ScpClient.OperationTimeout` being unset means a stalled transfer hangs indefinitely with a
frozen UI. The macOS port must set an explicit transfer deadline.

**Progress reporting**

Text-only, no percentage, no bar. `ScpClient` exposes `Uploading`/`Downloading` progress
events — **none are subscribed**. The user sees only:

* `lblMsg = "Uploading..."` (`UploadForm.cs:150`) or `"Resetting..."` (`UploadForm.cs:145`)
* then a completion string, set on a background task after the work has already finished
  (`UploadForm.cs:186-197`), held for `Thread.Sleep(2000)` before the dialog auto-closes.
* `UpdateForm` sets `"Database Updated"` then sleeps 1000 ms (`UpdateForm.cs:173-185`).

**Threading**

`UploadForm.BtnUpload_Click` performs *all* SSH work **synchronously on the UI thread**
(`UploadForm.cs:141-169`); same for `UpdateForm.BtnCheck_Click` (`UpdateForm.cs:108`) and
`BtnUpdate_Click` (`UpdateForm.cs:134`). The window is unresponsive (and shows as "not
responding" on a dead host until the 5 s connect timeout) for the whole operation. The only
async work is the initial cloud printer-list fetch (`UpdateForm.cs:77-80`, `ManageForm.cs:28-30`,
`await Task.Run`) and the Spoolman call (`MainForm.cs:910-916`).

**Retry:** none. Not one retry loop, backoff, or re-auth anywhere.

**Cancellation:** none. No `CancellationToken`, no abort button. `btnCancel` merely closes
the dialog *before* an operation starts (`UploadForm.cs:129-133`, `UpdateForm.cs:198-202`);
once `BtnUpload_Click` is running the button cannot be clicked (UI thread blocked).

**Idempotency / atomicity:** the upload is a direct overwrite of
`material_database.json` with no temp-file-and-rename, no backup, and no checksum
verification. A connection dropped mid-SCP leaves a truncated database on the printer.

---

## 8. Error conditions and user-facing messages

Toasts are rendered by `Toast.Show(form, msg, duration, isError)`; `LENGTH_LONG = 3500` ms,
`LENGTH_SHORT = 2000` ms (`Toast.cs:35-36, 142`).

### 8.1 UploadForm

| Condition | Message | Surface | Site |
|---|---|---|---|
| `SelectedPrinter == null` | *(none — closes with `DialogResult.No`)* | → MainForm toast `"No printer selected"` | `UploadForm.cs:30-35`; `MainForm.cs:642` |
| IP or password empty | `Printer IP and Password cannot be blank` | Toast, error, LONG | `UploadForm.cs:206` |
| Any exception from SSH/SCP | **raw `ex.Message`** (SSH.NET text, e.g. *"Permission denied (password)."*, *"No such file or directory"*, *"Connection failed to establish within 5000 milliseconds."*) | Toast, error, LONG; `lblMsg` cleared | `UploadForm.cs:199-202`, re-thrown from `Utils.cs:436, 474, 499, 531, 561, 608, 643` |
| In progress | `Uploading...` / `Resetting...` | `lblMsg` | `UploadForm.cs:150, 145` |
| Success + reboot | `Upload complete\nRebooting printer` | `lblMsg`, 2 s | `UploadForm.cs:180` |
| Success, no reboot | `Upload complete` | `lblMsg`, 2 s | `UploadForm.cs:183` |
| Reset success | `Reset complete\nRebooting printer` | `lblMsg`, 2 s | `UploadForm.cs:174` |

**Silent failure to be aware of:** `GetPrinterVersion` swallows every exception and returns
the string `"0"` (`Utils.cs:678-681`). With "Prevent DB updates" off, an unreachable printer
silently stamps the local database version as `0`.

### 8.2 UpdateForm

| Condition | Message | Surface | Site |
|---|---|---|---|
| `SelectedPrinter == null` | *(closes, `DialogResult.No`)* → `"No printer selected"` | Toast | `UpdateForm.cs:39-44`; `MainForm.cs:614` |
| Cloud printer list failed | `Failed to retrieve printer data` | `lblMsg` | `UpdateForm.cs:93` |
| Printer version ≤ local | `No update available` | `lblMsg` | `UpdateForm.cs:118` |
| Version check threw (connect fail, parse fail) | `Error checking version` | `lblMsg` | `UpdateForm.cs:123` |
| DB body null/empty | `Database not found` | `lblMsg` | `UpdateForm.cs:189` |
| Any exception while merging | `Error updating database` | `lblMsg` | `UpdateForm.cs:194` |
| Success | `Database Updated` | `lblMsg`, 1 s | `UpdateForm.cs:177` |

### 8.3 Elsewhere

| Message | Site |
|---|---|
| `Error finding printers` (cloud list failed in ManageForm) | `ManageForm.cs:42` |
| `Printer added` / `Printer removed` | `MainForm.cs:575, 585` |
| `MaterialID <id> not found` (Spoolman) | `Utils.cs:1131` |
| `Error adding spool` (vendor GET failed) | `Utils.cs:1139` |
| `Failed to create spool` (spool POST failed) | `Utils.cs:1221` |
| `Spool created for\n<name> (<color>)` | `Utils.cs:1221` |
| `Error <exception message>` (Spoolman, prefix drives the error styling at `MainForm.cs:914`) | `Utils.cs:1226` |

Swallowed-entirely (no user feedback at all): `GetZipUrl` (`Utils.cs:783`), both
`FindPrinters` (`Utils.cs:813, 843`), cloud `GetJsonDB` (`Utils.cs:944`), `ProcessMaterials`
(`Utils.cs:900`), `LoadPrinterImage` (`Utils.cs:989`), every `MatDb` method, and the
`OpenUpload`/`OpenUpdate`/`OpenManage` wrappers (`MainForm.cs:589, 618, 646`).

---

## 9. WebSocket / JSON-RPC — not present

Creality's K-series firmware does expose a WebSocket/JSON-RPC control API (`ws://<ip>:9999`,
plus Moonraker on some models), but **this application does not use it**. Confirmed by:

* grep for `websocket|ws://|wss://|jsonrpc|json-rpc|moonraker` across `Windows/**/*.cs` — zero hits;
* the only `System.Net` types referenced are `WebClient`, `WebRequest`, `WebException`,
  `HttpRequestHeader` (`Utils.cs:13, 738, 1233, 1260-1262`);
* the entire printer-side interaction is "write a JSON file over SCP and reboot".

The JSON documents in `docs/` (§10) are *artifacts of that API / of the printer's own state
files*, captured for reference, not consumed by any code path.

---

## 10. The captured printer payloads in `docs/`

These are on-printer state files from `…/creality/userdata/box/` (see `README.md`
"Files of interest"). **None of `material_box_info.json`, `material_modify_info.json`, or
`tn_data.json` is read or written by the Windows app** (grep-verified); they are the CFS
runtime's own state and are the best available documentation of what the firmware does with
an RFID tag after it is read.

### 10.1 `docs/material_box_info.json` — full CFS state (read-only observation)

Two top-level keys:

* `rackMaterial` — the spool currently on the external rack:
  `{attach:bool, selected:bool, rfid:int, editStatus:int, filamentId:"101001",
  color:"#0C12E1F", brand, name, materialType, minTemp, maxTemp, pressure:"0.04",
  maxVSpeed:"23"}` (lines 2-16).
* `Material` — `{state:"connect", filament:1, auto_refill:1, same_material:[…], enable:1,
  info:[…]}` (lines 17-151).
  * `same_material` (lines 21-47) groups slots that hold identical filament: each entry is
    `[filamentId, colorValue(7 hex digits, no '#'), [slotNames…], materialType]`, e.g.
    `["101001","0C12E1F",["T1B","T1D"],"PLA"]`.
  * `info[]` — one object per connected box: `{boxID:"T1", state:"connect",
    filament:"None", temperature:"27", dry_and_humidity:"39", version:"1.1.2", sn:"0",
    uuid:[], list:[4 slots]}` (lines 50-58).
  * each slot (lines 60-81): `materialId` `"A"`–`"D"`, `state`, `remainLen` (string,
    percent-ish), `filamentId`, `brand`, `name`, `materialType`, `density` (number),
    `diameter` (string `"1.75"`), `minTemp`/`maxTemp` (numbers), `pressure`, `maxVSpeed`,
    `venderId:"0276"`, `color:"#0FFFFFF"` (**`#` + 7 hex digits** — leading digit is the
    alpha/flag nibble from the tag), `filamentLen:"0165"` (the 4-digit length code that
    `Utils.GetMaterialLength` maps to spool weight, `Utils.cs:136-152`), `serialNum:"000001"`,
    `reserve:"000000"`, `rfid` (2 = tag read OK, 0 = no tag), `editStatus`.

Every one of `venderId`, `filamentId`, `color`, `filamentLen`, `serialNum`, `reserve` is a
field of the 40-hex-char tag payload documented in `README.md` ("Tag Format"), so this file is
effectively the decoded tag.

### 10.2 `docs/material_modify_info.json` — the user-override file

Same `rackMaterial` block (lines 2-16), then `Material` as an **array of all four boxes**
`T1`–`T4` (lines 17-250), each `{boxID, state, list:[4]}` with a *reduced* slot schema:
`{rfid, remainLen, editStatus, filamentId, color, brand, name, materialType, minTemp,
maxTemp, pressure}` (lines 22-34). Empty boxes are `state:"None"` with `rfid:0` and all
strings blank (lines 76-132). This is the file that records manual edits made on the printer's
touchscreen — i.e. the override layer over what the RFID tag says.

### 10.3 `docs/material_database.json` — the filament catalogue (the file we upload)

**This is the on-wire format of the file written to
`…/creality/userdata/box/material_database.json`.** Envelope:

```json
{"code":0,"msg":"ok","reqId":"cl602024082916552939795681",
 "result":{"list":[…],"count":56,"version":"1746005657"}}
```

* `result.version` — a **decimal Unix-seconds string** compared numerically
  (`long.Parse`, `UpdateForm.cs:112`) and overwritten with `9876543210`
  by "Prevent DB updates" (`Resources.resx:169`). `9876543210` ≈ year 2282, hence "prevent".
* `result.count` — must equal `list.length` (the app maintains it: `MatDb.cs:179`,
  `Utils.cs:886`).
* `result.list[]` — each item: `{engineVersion:"3.0.0", printerIntName:"F008",
  nozzleDiameter:["0.4"], kvParam:{…~150 slicer keys, all string-valued…}, base:{…}}`.
* `base` keys (exactly): `id`, `brand`, `name`, `meterialType` *(sic — misspelled in the
  firmware format; preserve it)*, `colors`, `density`, `diameter`, `costPerMeter`,
  `weightPerMeter`, `rank`, `minTemp`, `maxTemp`, `isSoluble`, `isSupport`, `shrinkageRate`,
  `softeningTemp`, `dryingTemp`, `dryingTime`.
* `kvParam` is a flat `string → string` map of Orca/Bambu-style slicer keys
  (`filament_density`, `nozzle_temperature`, `hot_plate_temp`, `filament_max_volumetric_speed`,
  `filament_end_gcode`, …). Only three are ever read by the app, and only for Spoolman
  (`Utils.cs:1197-1202`).
* `base.id` is the join key everywhere (`UpdateForm.cs:153`, `MatDb.cs:41`), and the tag's
  `filamentId` field is `"1" + MaterialID` per Android `MainActivity.java:744`.

Bundled reference copies: `db/k2.json` (66 materials), `db/k1.json` (46), `db/hi.json` (21),
all at version `1758907369`.

### 10.4 `docs/tn_data.json` — raw tag data as the CFS stores it

`{"base_data":{"T1":{"vender":[4 × 40-hex-char tag strings], "remain_len":["54",…],
"color_value":["0FFFFFF",…], "material_type":["101001",…]}, "T2".."T4": all "-1"},
"remain_material":{"color":"0000000","type":"000007"}, "enable":1}` (single line).
`-1` denotes an absent box/slot. The `vender[]` strings are byte-for-byte the tag payloads
from `README.md`'s Tag Format table.

### 10.5 `material_option.json` — written, K1 only (no capture in docs/)

Not in `docs/`, but generated by the app (`Utils.cs:694-728`): a two-level index
`{"<brand>": {"<meterialType>": "<name>\n<name>\n…"}}`, serialised `Formatting.Indented`
and SCP'd to `…/box/material_option.json`. It is the K1 UI's brand/type picker source.

---

## 11. Swift implementation notes (SwiftPM app, no Xcode, self-contained `.app`)

### 11.1 What the transport actually has to do

Very little, which shapes the recommendation:

1. `connect(host, 22, user:"root", password:)`
2. `exec("reboot")` — fire-and-forget, connection will die
3. `upload(bytes, to: "<dir>/material_database.json", mode: 0644)`
4. `upload(bytes, to: "<dir>/material_option.json", mode: 0644)` (K1)
5. `download("<dir>/material_database.json") -> Data`

No port forwarding, no interactive shell, no PTY, no subsystems. **Anything that can run one
exec channel can do all five** — because `cat > file` / `cat file` is a complete substitute
for SCP, and is in fact more portable than SCP on a busybox printer.

### 11.2 Option (a) — pure-Swift SSH package

Candidates: `swift-nio-ssh` (Apple, protocol-level, **no SFTP/SCP client**, exec channels only)
and `Citadel` (third-party, builds SFTP + exec on top of NIOSSH).

* **Pros.** Pure SwiftPM — `swift build` from the CLI with no Xcode, no system deps; statically
  linked into the executable so the `.app` stays self-contained and notarisation is trivial;
  full programmatic control of timeouts, cancellation (`Task` cancellation maps onto NIO
  channel close), byte-level progress, and host-key policy; no process spawning, no password
  ever crossing a process boundary.
* **Cons — and one of them is disqualifying-risk-level.** NIOSSH deliberately implements
  **only modern algorithms** (curve25519-sha256 KEX, ed25519/ecdsa host keys, AES-GCM,
  `chacha20-poly1305`). Creality printers run an old busybox/Dropbear; if the printer's SSH
  server only offers `diffie-hellman-group14-sha1` KEX and an `ssh-rsa`/SHA-1 host key,
  **NIOSSH will fail key exchange outright and there is no configuration knob to relax it.**
  Secondary cons: Citadel is a small-maintainer dependency with API churn; NIOSSH's
  password-auth path is fine but keyboard-interactive is not, and some Dropbear builds only
  offer `keyboard-interactive`.
* **Verdict:** best long-term ergonomics, but its viability depends entirely on an empirical
  question we cannot answer from the source tree (see OPEN QUESTIONS #1). Do not commit to it
  before testing against a real K1 *and* K2 *and* Hi.

### 11.3 Option (b) — shell out to `/usr/bin/ssh` and `/usr/bin/scp`

* **Pros.** `/usr/bin/ssh` is part of the macOS base system on every supported release —
  it cannot be uninstalled, so the `.app` remains self-contained in the sense that matters
  (nothing to bundle). Zero binary-size cost, zero dependency-audit surface, zero
  notarisation impact. **Crucially, Apple's OpenSSH speaks legacy algorithms** and, unlike
  NIOSSH, lets you re-enable them per-invocation:
  `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1`.
  It therefore interoperates with whatever the printer runs. Debuggable by pasting the same
  command into Terminal.
* **Cons and the two gotchas that will bite.**
  1. **Password injection.** `ssh` reads the password from `/dev/tty`, never stdin, so you
     cannot just pipe it. `sshpass` is not on macOS. The supported mechanism is
     `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` (OpenSSH ≥ 8.4; macOS ships 9.x), which
     works with no TTY and no `DISPLAY`. Ship a tiny helper executable as a **second SwiftPM
     product** inside `Contents/MacOS/` that prints the password; hand it the secret via an
     inherited file descriptor or a per-invocation UNIX socket path in the environment —
     *not* as a plain env var (same-user processes can read `/proc`-equivalent env via
     `ps -E`) and *not* as an argv argument (world-visible in `ps`). A shell script also
     works but a compiled helper signs and seals more cleanly.
  2. **`scp` changed protocol.** Since OpenSSH 9.0 (macOS 13+), `/usr/bin/scp` uses the
     **SFTP** protocol by default and will fail against a printer with no `sftp-server`.
     You must pass **`-O`** to force the legacy SCP protocol — or sidestep the issue entirely
     by using `ssh … 'cat > /path/file'` for upload and `ssh … 'cat /path/file'` for
     download, which needs only an exec channel (then `chmod 644` explicitly, since `cat >`
     preserves an existing file's mode and creates new files at `umask` default).
  3. Progress requires parsing `scp -v` output or chunking the write yourself; cancellation
     means killing a child process (workable: `Process.terminate()`), and you must reap it.
* **Verdict:** highest interoperability confidence, lowest build complexity, moderate
  plumbing ugliness.

### 11.4 Option (c) — libssh2 via a C shim

* **Pros.** Mature, exactly the feature set needed (`libssh2_channel_exec`,
  `libssh2_scp_send64`/`libssh2_scp_recv2`, plus SFTP if wanted); wide algorithm support
  including legacy KEX/host-key types; C interop from SwiftPM via a `systemLibrary` or a
  vendored `.c` target needs no Xcode.
* **Cons.** libssh2 requires a crypto backend — OpenSSL, mbedTLS, libgcrypt or wolfSSL; there
  is **no Security.framework/CryptoKit backend**, so you must vendor and statically link a
  crypto library, which is the single largest addition to build complexity, binary size,
  licence review, and CVE-tracking burden for this project. You would also be hand-writing a
  Swift concurrency wrapper over a blocking/non-blocking C API, including its notoriously
  fiddly `LIBSSH2_ERROR_EAGAIN` loop, plus manual timeout handling. Universal (arm64 + x86_64)
  builds mean building the C deps twice and `lipo`-ing.
* **Verdict:** only justified if (a) is blocked by algorithms *and* (b) is blocked by policy
  (e.g. a future App Sandbox / Mac App Store requirement that forbids spawning helpers).

### 11.5 Recommendation

**Ship (b) — system `/usr/bin/ssh` — as the default transport, behind a `PrinterTransport`
protocol, and use `ssh … 'cat > …'` + `ssh … 'cat …'` rather than `scp`.**

Rationale, in priority order:

1. **Interop certainty beats elegance here.** The whole feature is worthless if it cannot
   negotiate with an old Dropbear, and only Apple's `ssh` gives us a documented escape hatch
   (`-o KexAlgorithms=+…`) for that. NIOSSH gives us none.
2. **`cat` over an exec channel is more portable than SCP**, and simultaneously dodges the
   OpenSSH-9 `scp`-is-now-SFTP trap and any missing `sftp-server` on the printer. It also
   makes the K1/K2 path difference a pure string substitution.
3. **Self-containment is preserved.** Nothing is bundled except a ~20-line askpass helper we
   build ourselves; `/usr/bin/ssh` is guaranteed present.
4. **Escape hatch.** With the transport behind a protocol, swapping in Citadel later is a
   contained change — and worth doing once someone has verified the printers' algorithm
   support on real hardware.

Concrete invocation sketch (one connection per operation, matching Windows semantics):

```
/usr/bin/ssh
  -p 22
  -l root
  -o BatchMode=no
  -o NumberOfPasswordPrompts=1
  -o PreferredAuthentications=password,keyboard-interactive
  -o PubkeyAuthentication=no                 # skip the user's keys/agent entirely
  -o IdentitiesOnly=yes
  -o UserKnownHostsFile=<AppSupport>/known_hosts   # never the user's ~/.ssh/known_hosts
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=5                         # mirrors ConnectionInfo.Timeout (Utils.cs:426)
  -o HostKeyAlgorithms=+ssh-rsa               # only if probing shows it is needed
  <host> 'cat > /mnt/UDISK/creality/userdata/box/material_database.json && chmod 644 …'
```

with `SSH_ASKPASS=<bundle>/Contents/MacOS/cfsrfid-askpass`, `SSH_ASKPASS_REQUIRE=force`,
`DISPLAY=:0` (harmless, belt-and-braces for older OpenSSH), the JSON piped to the child's
stdin, and an overall `Task` deadline the Windows app lacks (§7).

Port-behaviour deltas to fix rather than replicate:

* Set an explicit **transfer** timeout (Windows leaves it infinite).
* Do the work **off the main actor** with real cancellation (Windows blocks the UI thread).
* Upload to `…/material_database.json.tmp` then `mv` into place, so a dropped connection
  cannot truncate the printer's database.
* Encode/decode as **UTF-8**, not ASCII: `Utils.cs:524` (`Encoding.ASCII.GetBytes`),
  `Utils.cs:639` and `Utils.cs:674` (`Encoding.ASCII.GetString`), and `MatDb.cs:89, 186`
  mangle non-ASCII brand/colour names into `?`.
* Store the root password in the **macOS Keychain**, not a plist, and use a
  `SecureField`; the Windows app writes cleartext to the registry (`Settings.cs:137-139`)
  and shows it on screen (`UploadForm.Designer.cs:61-66`).
* `reboot` will always kill the connection — treat "connection closed by remote host" /
  exit status 255 immediately after issuing `reboot` as **success**, not failure. (The
  Windows app's 5 s `CommandTimeout` at `Utils.cs:430` papers over this by accident.)

### 11.6 Host-key verification UX

Both existing clients trust any host key (§1.3), so users have no mental model of host-key
prompts and any friction here will read as a bug. Recommended behaviour:

* Keep an **app-private `known_hosts`** in `~/Library/Application Support/<app>/known_hosts`.
  Never read or write the user's `~/.ssh/known_hosts` — a 3D-printer utility must not be able
  to corrupt the user's real SSH trust store.
* **First connection: TOFU, silent.** `StrictHostKeyChecking=accept-new` — pin on first use
  with no dialog. Optionally show the fingerprint in a disclosure area of the dialog and, for
  the security-minded, in a "Printer identity" detail row.
* **Changed key: explain, don't alarm-and-block.** A printer firmware update or factory reset
  regenerates the host key, and this will happen to ordinary users. Present a specific,
  non-scary alert — *"This printer's identity has changed. This is normal after a firmware
  update or factory reset, but it can also mean another device is answering at
  `<host>`."* — with buttons **Trust New Identity** (removes the stale entry via
  `ssh-keygen -R -f <our known_hosts>` and re-pins) and **Cancel** (default). Show old and
  new SHA256 fingerprints.
* **Never ship `StrictHostKeyChecking=no`.** It provides the Windows app's behaviour but
  makes the "changed key" case invisible, which is precisely the case worth surfacing.
* Because DHCP reassigns addresses, key the pin on the **hostname/IP string the user typed**
  (as the Windows app keys its saved settings, §1.4) and accept that a re-addressed printer
  will look "new" — which lands in the silent TOFU path, not the scary one.

---

## OPEN QUESTIONS

1. **Which SSH server, and which algorithms, do K1/K2/Hi actually run?** Nothing in the repo
   says. This single fact decides whether §11.2 (pure Swift) is viable at all or whether
   §11.3 (system `ssh`) is mandatory. Needs a `ssh -vv` probe against real hardware.
2. **Does the printer have an `sftp-server`?** Both existing clients use the legacy SCP
   protocol (`scp -t` / `scp -f`, Android `Utils.java:566-568, 622-624`), which *suggests*
   SFTP is unavailable — but that may just be JSch/SSH.NET convenience. Determines whether
   `/usr/bin/scp` works without `-O`, and whether an SFTP-based Swift path is open.
3. **Is `/mnt/UDISK/creality/userdata/box/` correct for the Hi?** The code routes everything
   that is not `k1` to the K2 path (`Utils.cs:488` etc.), so the Hi inherits the K2 path by
   default rather than by verification. Unverified for the Hi specifically.
4. **`material_option.json` for K1 variants.** Windows writes it only on an **exact**
   `"k1"` name match (`UploadForm.cs:161`, `Equals(..., OrdinalIgnoreCase)`), while Android
   writes it for any name **containing** `k1` (Android `Utils.java:474`). So `K1 Max` /
   `K1C` profiles get different treatment depending on which app you use. Which is correct —
   i.e. does K1 Max firmware read `material_option.json`?
5. **Does anything on the printer need a reload short of a full reboot?** The app only ever
   issues `reboot` (§1.5). Whether restarting the CFS/box service alone suffices (much better
   UX) is unknown.
6. **Is `9876543210` sufficient to defeat the printer's DB updater**, and does the firmware
   ever *reject* a version it cannot parse? The value is chosen empirically
   (`Resources.resx:168-170`) with no accompanying rationale.
7. **`printerIntName: "F008"` is hardcoded** in the cloud→printer conversion
   (`Utils.cs:874`) for *every* printer model. Presumably a K2-family internal model code —
   whether K1/Hi need a different value, and whether the firmware even reads it, is unknown.
8. **Nozzle diameter is hardcoded to `"0.4"`** at every call site (§5.1). Whether printers
   with 0.6/0.8 nozzles need a different profile set, or whether the filament database is
   nozzle-independent in practice, is unresolved.
9. **`docs/*.json` provenance and firmware version.** `material_box_info.json` reports
   `"version":"1.1.2"` for box T1 (line 56) but there is no record of which printer firmware
   produced these captures, so schema drift across firmware releases cannot be assessed.
10. **Creality Cloud API stability/auth.** The `__CXY_*` headers and the Bambu-Studio
    `User-Agent` (`Utils.cs:740`) are undocumented and unauthenticated (`__CXY_UID_` is empty,
    `Utils.cs:744`). Whether Creality rate-limits, requires auth in future, or geo-restricts
    `api.crealitycloud.com` is unknown, and the app has no fallback if the API disappears —
    though the bundled `db/*.json` files could serve as one.
11. **`GetJsonDB(psw, host, pType, fileName)` (`Utils.cs:575-618`) — the download-to-local-file
    overload — has no caller in the Windows app** (grep-verified). Android has an equivalent
    that *is* used. Dead code, or a planned "backup from printer" feature? Do not port it
    without deciding.
