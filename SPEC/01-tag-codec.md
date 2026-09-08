# SPEC-01 — Creality CFS/K2/K1/Hi RFID Tag Codec

Reverse-engineered from the Windows C# app (`Windows/CFS-RFID/`), cross-checked against
the Android app (`Android/SpoolID/`) and the Arduino firmware (`Arduino/*/Spool_ID/`).

Target: a Swift reimplementation that is **byte-for-byte identical** on the wire and on the tag.

All line references are `file:line` into this repository at commit `7101bac` (v57).

---

## 0. KEYS AND AUTHENTICATION — priority answers

*Added in response to hardware-in-the-loop probing of the ACS ACR1552 + a real MIFARE
Classic 1K (UID `80A67939`). Full detail in §2; this section answers the five questions
directly.*

### Q1. What key bytes, for which sectors? Is there a non-default key or a KDF?

**YES — there is a key derivation function, and it is the reason sector 1 rejects
`FFFFFFFFFFFF`.** `KEY_DEFAULT` is *not* the only key.

`Utils.CreateKey` derives a **per-tag Key A from the UID via AES-128-ECB**
(`Windows/CFS-RFID/Utils.cs:195-223`):

```csharp
public static byte[] CreateKey(byte[] tagId)
{
    using (AesCryptoServiceProvider aesAlg = new AesCryptoServiceProvider())
    {
        aesAlg.Mode = CipherMode.ECB;
        aesAlg.Padding = PaddingMode.None;
        aesAlg.Key = new byte[]
        {113, 51, 98, 117, 94, 116, 49, 110, 113, 102, 90, 40, 112, 102, 36, 49};
        ICryptoTransform encryptor = aesAlg.CreateEncryptor(aesAlg.Key, null);
        int x = 0;
        byte[] encB = new byte[16];
        for (int i = 0; i < 16; i++)
        {
            if (x >= 4) x = 0;
            encB[i] = tagId[x];
            x++;
        }
        byte[] encryptedBytes = encryptor.TransformFinalBlock(encB, 0, encB.Length);
        return encryptedBytes.Take(6).ToArray();
    }
}
```

- **AES key** `71 33 62 75 5E 74 31 6E 71 66 5A 28 70 66 24 31` = ASCII **`q3bu^t1nqfZ(pf$1`**
  (`Utils.cs:203-204`)
- **Plaintext** = the 4-byte UID repeated 4× (`Utils.cs:206-213`)
- **AES-128-ECB, `PaddingMode.None`, null IV** (`Utils.cs:201-202,205`)
- **`encKey` = first 6 bytes of the ciphertext** (`Utils.cs:216`)
- Fallback on exception: `KEY_DEFAULT` (`Utils.cs:221`)

There is a **second, unrelated** AES key used for payload confidentiality, not for MIFARE
auth — `Utils.CipherData` (`Utils.cs:233-234`):
`48 40 43 46 6B 52 6E 7A 40 4B 41 74 42 4A 70 32` = ASCII **`H@CFkRnz@KAtBJp2`**.

Exhaustive key inventory for the whole codebase — these are the only three:

| Constant | Bytes | Purpose | Reference |
|---|---|---|---|
| `KEY_DEFAULT` | `FF FF FF FF FF FF` | MIFARE Key A for **sector 2** (and pre-programming sector 1) | `Utils.cs:25` |
| `encKey` (derived, per-tag) | `AES-ECB(q3bu^t1nqfZ(pf$1, UID×4)[0..6]` | MIFARE Key A **and** Key B for **sector 1** | `Utils.cs:195-223` |
| payload AES key | `H@CFkRnz@KAtBJp2` | AES-ECB of the sector-1 *data* — **not** a MIFARE key | `Utils.cs:233-234` |

No other byte-array or hex-string key literal exists. Same KDF, byte for byte, in
`Android/.../Utils.java:364-381` and `Arduino/ESP32/Spool_ID/Spool_ID.ino:174-189`.

**→ Directly testable prediction for the probed tag.** UID `80 A6 79 39`:

| UID byte order | derived `encKey` |
|---|---|
| **as-read `80A67939`** | **`E0 5E 87 25 9A 4F`** |
| reversed `3979A680` (in case the stack hands the UID back-to-front) | `89 D2 13 EA 55 C3` |

Load `E05E87259A4F` and authenticate **sector 1 / block 4**. If it succeeds, that tag has
already been programmed by this app family and everything below applies. Try the reversed
variant only if the first fails — see §11.2 pitfall 2. This single experiment settles the
question outright.

### Q2. Key type — 0x60 (A) or 0x61 (B)?

**The Windows app uses `0x60` = Key A, exclusively and everywhere.** Every call site passes
the literal `96` (decimal) = `0x60`. Traced exhaustively — there are eleven call sites and
`96` is the second argument in all eleven:

| Call site | Block | `keyType` | Key slot | Reference |
|---|---|---|---|---|
| `ReadTag` sector 1 | 4 | `96` = 0x60 **A** | 1 (`encKey`) | `Utils.cs:256` |
| `ReadTag` sector 2 | 8 | `96` = 0x60 **A** | 0 (default) | `Utils.cs:273` |
| `FormatTag` sector 1 | 4 | `96` = 0x60 **A** | 1 | `Utils.cs:286` |
| `FormatTag` sector 2 | 8 | `96` = 0x60 **A** | 0 | `Utils.cs:300` |
| padlock indicator | 7 | `96` = 0x60 **A** | 0 | `MainForm.cs:255` |
| "empty tag?" gate | 7 | `96` = 0x60 **A** | 0 | `MainForm.cs:395` |
| `WriteSpoolData` probe | 4 | `96` = 0x60 **A** | 1 | `MainForm.cs:464` |
| `WriteSpoolData` sector 1 | 4 | `96` = 0x60 **A** | `keyS1` (0 or 1) | `MainForm.cs:470` |
| `WriteSpoolData` sector 2 | 8 | `96` = 0x60 **A** | 0 | `MainForm.cs:501` |
| `TagMemoryForm` probe | 4 | `96` = 0x60 **A** | 1 | `TagMemoryForm.cs:48` |
| `TagMemoryForm` per-sector | `s*4` | `96` = 0x60 **A** | 1 if (s==1 && encrypted) else 0 | `TagMemoryForm.cs:56-63` |

Representative quote (`Utils.cs:256`):
```csharp
if (reader.Authentication10byte(4, 96, 1) || reader.Authentication6byte(4, 96, 1))
```
Signature is `Authentication10byte(byte block, byte keyType, byte keyNumber)`
(`Reader.cs:37`), so `96` is unambiguously `keyType`.

**`0x61` (Key B) is never passed anywhere in the codebase.** However the app *writes* Key B:
on first programming it sets sector 1's Key A **and** Key B both to `encKey`
(`MainForm.cs:486-487`), so on a programmed tag Key B = Key A = `encKey` for sector 1.

⚠️ **This directly conflicts with the hardware probe** (Key A fails `69 82` on every sector
with `FFFFFFFFFFFF`, Key B succeeds). Under those conditions the Windows app's **sector-2**
read/write would fail outright, since it authenticates block 8 with Key A + default key
(`Utils.cs:273`, `MainForm.cs:501`). See OPEN QUESTION 8 — this needs resolving before the
Swift transport layer is finalised, and my recommendation is that the port try Key A first
and fall back to Key B.

### Q3. Which sector/blocks hold the payload? And how do the README's four rows map?

**Sector 1 = blocks 4, 5, 6 (AES-encrypted) and sector 2 = blocks 8, 9, 10 (plaintext).**
Confirmed by the read path (`Utils.cs:259-261`, `:275-277`) and the write path
(`MainForm.cs:475-480`, `:503-510`). Sectors 0 and 3..15 are never used for payload.

**The README's four rows are NOT four blocks — they are four independent example tags.**
Reconciliation:

- Each README row is **40 ASCII characters**, i.e. **40 bytes**, not 40 nibbles. They are
  ASCII digits/letters, not hex — `"AB1240276A2..."` is the literal on-tag text.
- 40 bytes does not divide into 16-byte blocks, which is exactly why the code pads the
  record to 48: `reserve = "00000000000000"` is **14** characters where the README's
  `reserve` column shows only **6** (`MainForm.cs:452`). The extra 8 ASCII `'0'`s bring the
  record to **48 bytes = 3 × 16 = exactly sector 1's data area**.
  Arduino makes the split explicit: `... + serialNum + reserve + "00000000"` with
  `reserve = "000000"` (`Spool_ID.ino:394-395`).
- So one README row → one tag → bytes 0..39 of a 48-byte sector-1 record:

  | Bytes | Block | Content for README row 1 (`AB1240276A21010010FFFFFF0165000001000000`) |
  |---|---|---|
  | 0..15 | **block 4** | `AB1240276A210100` |
  | 16..31 | **block 5** | `10FFFFFF01650000` |
  | 32..47 | **block 6** | `01000000` + `00000000` filler |

  …then AES-ECB-encrypted as one 48-byte unit before writing (`MainForm.cs:474`).
- The four rows correspond exactly to the four `base_data.T1.vender[]` entries in
  `docs/tn_data.json` — that file is the *printer's* view of four loaded spools (slots
  T1[0..3]), not four blocks of one tag.
- `docs/tn_data.json` also carries per-slot `remain_len` (`"54"`, `"49"`, `"48"`, `"52"`),
  `color_value` and `material_type` — all derived by the printer from the tag text, further
  confirming one row = one spool = one tag.

Verified numerically: encrypting README row 1 padded to 48 chars reproduces block 4 =
`57F25B78076D4C1797B1BE35CA269540` etc. — see the golden vectors in §11.4.

### Q4. Does the app write sector trailers? Exact bytes?

**YES — block 7 (sector 1's trailer) is rewritten, and it changes both keys. This is
permanent and is the tag-bricking risk you flagged.** Block 11 is rewritten only by
*format*. Access bits are **never authored** — they are read-modify-write preserved.

**On first programming** (`MainForm.cs:481-494`), only when the tag is not already keyed:
```csharp
if (!encrypted)
{
    byte[] trailer = reader.ReadBinaryBlocks(7, 16);
    if (trailer != null)
    {
        Array.Copy(encKey, 0, trailer, 0, 6);
        Array.Copy(encKey, 0, trailer, 10, 6);
        reader.UpdateBinaryBlocks(7, 16, trailer);
```

Resulting block 7, given the probed tag reads `00 00 00 00 00 00 FF 07 80 69 FF FF FF FF FF FF`
and UID `80A67939` → `encKey = E0 5E 87 25 9A 4F`:

| Bytes 0..5 (Key A) | Bytes 6..9 (access + GPB) | Bytes 10..15 (Key B) |
|---|---|---|
| `E0 5E 87 25 9A 4F` | `FF 07 80 69` ← **preserved verbatim** | `E0 5E 87 25 9A 4F` |

Full 16 bytes: `E0 5E 87 25 9A 4F FF 07 80 69 E0 5E 87 25 9A 4F`

- Access bits stay at the `FF 07 80 69` transport value → **the sector is never made
  read-only**; it remains fully rewritable *by whoever knows `encKey`*.
- Key A is read-masked to zeros by the chip, so the read-modify-write is safe: bytes 0..5
  come back as zeros and are overwritten anyway; bytes 6..9 are the only ones that must
  survive, and they do.
- **Recoverable**: `FormatTag` puts `FFFFFFFFFFFF` back (§6). Not a one-way operation *as
  long as you still know the UID → `encKey`*.
- **Sector 2's trailer (block 11) is NOT touched by the write path** — sector 2 stays on the
  default key permanently (see OPEN QUESTION 7).
- On format, blocks 7 **and** 11 both get `FFFFFFFFFFFF` spliced into bytes 0..5 and 10..15
  with bytes 6..9 preserved (`Utils.cs:292-298`, `:306-312`).

The one genuine bricking hazard is OPEN QUESTION 4: `ReadBinaryBlocks` never checks SW, so a
failed trailer read yields 16 zeros and the app would write access bytes `00 00 00` + GPB
`00`. Unreachable on a compliant reader, but the Swift port should check SW and abort.

### Q5. What happens when auth fails — is there a fallback key sequence?

**There is a fallback on the APDU *variant* and on the key-loading *structure*, but almost
none on the key *value*, and none at all on key type.**

1. **APDU variant fallback** — every call site tries one authenticate form, then the other:
   `Authentication10byte(...) || Authentication6byte(...)` (`Utils.cs:256`), i.e.
   `FF 86 00 00 05 01 00 <blk> 60 <slot>` then `FF 88 00 <blk> 60 <slot>`.
   `WriteSpoolData` and `TagMemoryForm` use the reverse order (`MainForm.cs:464`,
   `TagMemoryForm.cs:48`). See §2.5 for the per-site table.
2. **Key-load structure fallback** — volatile then non-volatile (`MainForm.cs:231-245`):
   `FF 82 00 <slot> 06 <key>`, and if that is not `90 00`, `FF 82 20 <slot> 06 <key>`.
   Slot 0 ← `KEY_DEFAULT`, slot 1 ← `encKey`.
3. **Key value fallback — only in the write path.** `WriteSpoolData` probes with slot 1 and
   picks `keyS1 = encrypted ? 1 : 0` (`MainForm.cs:464-470`), so it tries `encKey` then
   falls back to the default key. That is the *only* place a second key value is attempted.
4. **The read path has NO key fallback.** `ReadTag` authenticates sector 1 with slot 1
   (`encKey`) only, and on failure throws (`Utils.cs:256,271`):
   ```csharp
   else { throw new Exception("Failed to authenticate"); }
   ```
   It never retries with `KEY_DEFAULT`. (Android *does* — `MainActivity.java:545` uses
   `encrypted ? encKey : KEY_DEFAULT`. See §10.)
5. **No key-type fallback anywhere.** Key A only; Key B is never tried after a failure.
6. **Sector 2 failures are silent.** `WriteSpoolData` skips blocks 8..10 with no error if
   block 8 fails to authenticate (`MainForm.cs:501-511`); `ReadTag` returns a 48-char string
   which then makes the caller's `Substring(48)` throw into a generic catch
   (`MainForm.cs:429-433`).
7. **UI-level "is it ours" probes** are auth-failure-driven rather than fallbacks: if block 7
   authenticates with the *default* key the tag is declared **"Empty tag"**
   (`MainForm.cs:395-397`); if it fails, the tag is declared programmed and the padlock
   appears (`MainForm.cs:261-265`).

### 0.6 Reconciling the hardware probe with the source

| Probe observation | Explanation from the source | Confidence |
|---|---|---|
| Sector 1 rejects `FFFFFFFFFFFF` on **both** Key A and Key B; **it is the only such sector** | Exactly what `MainForm.cs:486-487` produces: it sets sector 1's Key **A** *and* Key **B** to `encKey`, and touches no other sector's trailer. **This tag has already been programmed by this app family.** | **High** — the A-and-B-both-changed, sector-1-only signature is a fingerprint of this specific code path |
| Sector 1 data blocks read as zeros | Not "blank" — unreadable. Blocks cannot be read without a successful auth, and `ReadBinaryBlocks` returns a zeroed buffer on failure without checking SW (`Reader.cs:55-61`). See OPEN QUESTION 4. | **High** |
| Sectors 0, 2..15 trailers read `000000000000 FF 07 80 69 FFFFFFFFFFFF` | Untouched factory transport config. The app only ever rewrites blocks 7 and 11. Key A always reads back as zeros — that is chip behaviour, not a blank key. | **High** |
| Key **A** fails `69 82` on every sector with `FFFFFFFFFFFF`, Key **B** succeeds | **Not explained by the source.** With transport access bits `FF 07 80 69`, Key A must work. Fifteen sectors all having a changed Key A but an untouched Key B is not something this app does. Most likely a reader/driver quirk (ACR1552 key-slot or key-type handling) rather than tag state. | **Low — unresolved.** See OPEN QUESTION 8 |

**Actionable next probe, in priority order:**
1. Load `E0 5E 87 25 9A 4F` (UID `80A67939`) into a key slot, authenticate **block 4**,
   **Key A** (`0x60`). Expected: success. Then read blocks 4,5,6 and AES-ECB-decrypt the
   48 bytes with `H@CFkRnz@KAtBJp2` — expect printable ASCII beginning with a
   `<char><2 chars>24 0276 A2 1xxxxx` pattern (§3.2).
2. If step 1 fails with Key A, repeat with **Key B** (`0x61`) — same key value. Success there
   confirms the reader's key-type handling is inverted/quirky and tells us the port needs
   the A→B fallback.
3. If both fail, retry with the reversed-UID key `89 D2 13 EA 55 C3`.
4. Independently: authenticate **sector 2 / block 8** with `FFFFFFFFFFFF` and **Key A**. The
   Windows app depends on this working (`Utils.cs:273`). If it only works with Key B, the
   Swift port must diverge from the C# here.

---

## 0.7 Summary of the whole pipeline

```
                 ┌──────────────── 96-byte ASCII payload ────────────────┐
UI fields  ──►   │ bytes 0..47: 48-char record (40-char logical record   │
                 │              + "00000000" filler)                     │
                 │ bytes 48..95: printer-type string, space-padded       │
                 └───────────────────────────────────────────────────────┘
                            │                          │
             AES-128-ECB encrypt (fixed key)      (left plaintext)
                            │                          │
                            ▼                          ▼
              MIFARE 1K sector 1                MIFARE 1K sector 2
              blocks 4,5,6                      blocks 8,9,10
              Key A = Key B = AES(UID)          Key A = FF FF FF FF FF FF
```

There is **no checksum, CRC, signature, MAC or length field anywhere.** See §4.

---

## 1. MIFARE Classic 1K sector / block layout

Tag: MIFARE Classic 1K — 16 sectors × 4 blocks × 16 bytes (`README.md:4`).
Only **4-byte UID** tags are accepted (`Reader.cs:20-25`, see §2.1).

| Sector | Blocks | Role | Key A used | Content |
|---|---|---|---|---|
| 0 | 0 | Manufacturer / UID | (not touched) | read-only, dump only |
| 0 | 1,2 | unused | — | not touched |
| 0 | 3 | trailer | — | not touched |
| **1** | **4, 5, 6** | **payload bytes 0..47** | **`encKey` = AES(UID)** | **AES-ECB ciphertext** |
| **1** | **7** | trailer | `encKey` (or default when converting) | Key A **and** Key B set to `encKey` |
| **2** | **8, 9, 10** | **payload bytes 48..95** | **`FF FF FF FF FF FF`** | **plaintext ASCII** |
| **2** | **11** | trailer | default | untouched on write; reset on format |
| 3..15 | 12..63 | unused by the app | default | dump-only |

### 1.1 Read order — `Utils.ReadTag`

`Windows/CFS-RFID/Utils.cs:253-280`

1. Authenticate block **4**, Key A, key slot **1** (`encKey`) — `Utils.cs:256`
   ```csharp
   if (reader.Authentication10byte(4, 96, 1) || reader.Authentication6byte(4, 96, 1))
   ```
   If this fails → `throw new Exception("Failed to authenticate")` (`Utils.cs:271`).
   **The Windows read path only ever authenticates sector 1 with `encKey`** — it never
   falls back to the default key. (Android differs; see §10.)
2. Read blocks **4**, then **5**, then **6**, 16 bytes each (`Utils.cs:259-261`).
3. Concatenate into a 48-byte buffer in that order (`Utils.cs:263-265`).
4. `CipherData(0, s1Data)` → AES-128-ECB **decrypt** all 48 bytes (`Utils.cs:266`).
   Decryption is **unconditional** — there is no "plaintext sector 1" read path in Windows.
5. Authenticate block **8**, Key A, key slot **0** (default key) — `Utils.cs:273`.
6. Read blocks **8**, **9**, **10**, appended verbatim, no decryption (`Utils.cs:275-277`).
7. `Encoding.UTF8.GetString(buff.ToArray()).Trim()` (`Utils.cs:279`).

   Note: if step 5 fails, the returned string is only 48 chars and the caller's
   `Substring(48)` will throw (caught at `MainForm.cs:430`).

### 1.2 Write order — `MainForm.WriteSpoolData`

`Windows/CFS-RFID/MainForm.cs:445-518`

1. Build the 96-byte payload (§3), `Encoding.UTF8.GetBytes` (`MainForm.cs:453-455`).
2. Probe: authenticate block 4, Key A, key slot **1** → sets `encrypted` (`MainForm.cs:464-467`).
3. `keyS1 = encrypted ? 1 : 0`; authenticate block 4 with that slot (`MainForm.cs:469-470`).
   On failure → toast "Failed to authenticate" and **return** (`MainForm.cs:496-500`).
4. `CipherData(1, payload[0..48])` → AES-128-ECB **encrypt** (`MainForm.cs:474`).
5. Write blocks **4, 5, 6** in ascending order, 16 bytes each (`MainForm.cs:475-480`).
6. **Only if the tag was not already encrypted**: read block **7**, splice `encKey` into
   bytes 0..5 and 10..15, write block 7 back (`MainForm.cs:481-494`). See §5.
7. Authenticate block **8**, Key A, key slot **0** (`MainForm.cs:501`).
8. Write blocks **8, 9, 10** with `payload[48..96]` **in plaintext** (`MainForm.cs:503-510`).
   No error is reported if this authentication fails — the code silently skips sector 2.

### 1.3 Format order — `Utils.FormatTag`

See §6.

---

## 2. Authentication

### 2.1 Getting the UID

`Reader.cs:17-26`
```csharp
byte[] response = new byte[10];
if (reader.Transmit(new byte[] { 0xFF, 0xCA, 0x00, 0x00, 0x00 }, response) > 6)
{
    return null;
}
Array.Resize(ref response, 4);
```
APDU: `FF CA 00 00 00` (PC/SC "Get Data" / UID).
A response longer than 6 bytes (4 UID + SW1 SW2) means a 7-byte or 10-byte UID →
returns `null` → the app rejects the tag ("Tag not compatible", `MainForm.cs:222-230`).
Cross-check: Android rejects `currentTag.getId().length > 4` (`MainActivity.java:426`).

**Only the first 4 bytes are used, and they are the key-derivation input.**

### 2.2 Key derivation — `Utils.CreateKey`

`Windows/CFS-RFID/Utils.cs:195-223`
```csharp
aesAlg.Mode = CipherMode.ECB;
aesAlg.Padding = PaddingMode.None;
aesAlg.Key = new byte[]
{113, 51, 98, 117, 94, 116, 49, 110, 113, 102, 90, 40, 112, 102, 36, 49};
ICryptoTransform encryptor = aesAlg.CreateEncryptor(aesAlg.Key, null);
int x = 0;
byte[] encB = new byte[16];
for (int i = 0; i < 16; i++)
{
    if (x >= 4) x = 0;
    encB[i] = tagId[x];
    x++;
}
byte[] encryptedBytes = encryptor.TransformFinalBlock(encB, 0, encB.Length);
return encryptedBytes.Take(6).ToArray();
```

- AES key (16 bytes): `71 33 62 75 5E 74 31 6E 71 66 5A 28 70 66 24 31` = ASCII **`q3bu^t1nqfZ(pf$1`**
- Plaintext block: the 4-byte UID repeated 4× (UID‖UID‖UID‖UID).
- AES-128-**ECB**, **no padding**, IV is `null` (irrelevant for ECB).
- `encKey` = **first 6 bytes** of the 16-byte ciphertext.
- On any exception → `KEY_DEFAULT` = `FF FF FF FF FF FF` (`Utils.cs:25`, `Utils.cs:221`).

Identical in Android (`Android/SpoolID/app/src/main/java/dngsoftware/spoolid/Utils.java:364-381`)
and Arduino (`Arduino/ESP32/Spool_ID/Spool_ID.ino:174-189`).

### 2.3 Key loading — `Reader.LoadAuthenticationKeys`

`Reader.cs:28-35`
```csharp
List<byte> command = new byte[] { 0xFF, 0x82, keyStructure, keyNumber, 0x06 }.ToList();
command.AddRange(key);
```
APDU: `FF 82 <keyStructure> <keyNumber> 06 <6 key bytes>`; success = SW `90 00`.

Loading sequence on card insertion (`MainForm.cs:231-245`):

| Order | keyStructure | keyNumber | key | Source |
|---|---|---|---|---|
| 1 | `0x00` (volatile) | **0** | `KEY_DEFAULT` = FF×6 | `MainForm.cs:231` |
| 2 (fallback if #1 ≠ 90 00) | `0x20` (non-volatile) | **0** | `KEY_DEFAULT` | `MainForm.cs:233` |
| 3 | `0x00` | **1** | `encKey` | `MainForm.cs:236` |
| 4 (fallback) | `0x20` | **1** | `encKey` | `MainForm.cs:238` |

So throughout the app: **key slot 0 = default key, key slot 1 = derived key.**

### 2.4 Authenticate APDUs — two variants

`Reader.cs:37-53`

**"10byte" — PC/SC v2.01 General Authenticate** (`Reader.cs:37-44`)
```csharp
List<byte> command = new byte[] { 0xFF, 0x86, 0x00, 0x00, 0x05 }.ToList();
command.AddRange(new byte[] { 0x01, 0x00, block, keyType, keyNumber });
```
→ `FF 86 00 00 05 01 00 <block> <keyType> <keyNumber>`

**"6byte" — obsolete/legacy authenticate** (`Reader.cs:46-53`)
```csharp
List<byte> command = new byte[] { 0xFF, 0x88, 0x00, block, keyType }.ToList();
command.AddRange(new byte[] { keyNumber });
```
→ `FF 88 00 <block> <keyType> <keyNumber>`

Both return success only on SW `90 00`.

`keyType` is **always `96` decimal = `0x60` = Key A**. Every call site passes `96`.
**Key B (`0x61`) is never used for authentication anywhere in the codebase.**

### 2.5 Which variant is tried first, per call site

| Call site | Block | Key slot | Order | Reference |
|---|---|---|---|---|
| `ReadTag` sector 1 | 4 | 1 | **10byte → 6byte** | `Utils.cs:256` |
| `ReadTag` sector 2 | 8 | 0 | **10byte → 6byte** | `Utils.cs:273` |
| `FormatTag` sector 1 | 4 | 1 | **10byte → 6byte** | `Utils.cs:286` |
| `FormatTag` sector 2 | 8 | 0 | **10byte → 6byte** | `Utils.cs:300` |
| "is tag encrypted?" indicator | 7 | 0 | **10byte → 6byte** | `MainForm.cs:255` |
| "empty tag?" gate before read | 7 | 0 | **10byte → 6byte** | `MainForm.cs:395` |
| `WriteSpoolData` probe | 4 | 1 | **6byte → 10byte** | `MainForm.cs:464` |
| `WriteSpoolData` sector 1 | 4 | `keyS1` | **6byte → 10byte** | `MainForm.cs:470` |
| `WriteSpoolData` sector 2 | 8 | 0 | **6byte → 10byte** | `MainForm.cs:501` |
| `TagMemoryForm` probe | 4 | 1 | **6byte → 10byte** | `TagMemoryForm.cs:48` |
| `TagMemoryForm` per-sector | `s*4` | 1 if (s==1 && encrypted) else 0 | **6byte only** | `TagMemoryForm.cs:56-63` |

The mixed ordering is almost certainly incidental, but a byte-identical port should
reproduce it — with an ACR122-class reader both variants succeed, so the *second*
APDU is never emitted in practice; on other readers the emitted APDU differs.

### 2.6 Read / write block APDUs

`Reader.cs:55-70`
```csharp
// Read
reader.Transmit(new byte[] { 0xFF, 0xB0, 0x00, (byte)block, (byte)len }, response);
// Write
List<byte> command = new byte[] { 0xFF, 0xD6, 0x00, (byte)block, (byte)len }.ToList();
command.AddRange(blockData);
```
- Read: `FF B0 00 <block> 10` (len is always 16). **`ReadBinaryBlocks` never checks SW** —
  it blindly `Array.Resize`s to `len`, so a failed read yields a 16-byte buffer whose
  content is whatever was in the freshly-allocated (zeroed) array. See OPEN QUESTION 4.
- Write: `FF D6 00 <block> 10 <16 data bytes>`; success = SW `90 00` (return value ignored
  by all callers).
- Firmware version: `FF 00 48 00 00`, first 10 bytes of the response, ASCII (`Reader.cs:72-78`).
- Buzzer: `FF 00 52 <FF|00> 00` (`Reader.cs:80-85`) — cosmetic, not part of the codec.

---

## 3. Payload encoding

### 3.1 Construction — the single source of truth

`Windows/CFS-RFID/MainForm.cs:445-455`
```csharp
void WriteSpoolData(string MaterialID, string Color, string Length)
{
    bool encrypted = false;
    string filamentId = "1" + MaterialID;
    string vendorId = "0276";
    string color = "0" + Color;
    string serialNum = "000001";
    string reserve = "00000000000000";
    string tagData = "AB124" + vendorId + "A2" + filamentId + color + Length + serialNum + reserve + printerModel.Text;
    string paddedData = tagData.PadRight(96, ' ');
    byte[] fullDataBytes = Encoding.UTF8.GetBytes(paddedData);
```

Identical shape in Android (`MainActivity.java:743-754`) and Arduino
(`Arduino/ESP32/Spool_ID/Spool_ID.ino:386-395`, which uses
`reserve = "000000"` + a literal `"00000000"` — same 14 zeros).

### 3.2 Field table

Everything is **printable ASCII**. There is **no packed BCD, no binary integers,
no endianness** in the payload. Numbers are ASCII decimal, colors are ASCII uppercase hex.

Offsets are **character offsets into the decoded 96-char string** (== byte offsets, ASCII).

| # | Field | Offset | Len | Written value (Windows) | Encoding | Notes |
|---|---|---|---|---|---|---|
| 1 | `month` | 0 | 1 | `'A'` (hard-coded) | 1 ASCII char, `[0-9A-Z]` | scheme **unknown**, see OPEN QUESTION 1 |
| 2 | `day` | 1 | 2 | `"B1"` (hard-coded) | 2 ASCII chars | scheme **unknown**, see OPEN QUESTION 1 |
| 3 | `year` | 3 | 2 | `"24"` (hard-coded) | 2 ASCII digits | 2-digit year, 2024 |
| 4 | `vendorId` | 5 | 4 | `"0276"` | 4 ASCII digits | `0276` = Creality (`MainForm.cs:449`, comment in `MainActivity.java:745`) |
| 5 | `batch` | 9 | 2 | `"A2"` | 2 ASCII chars | hard-coded `MainForm.cs:453`; Android has it as a variable `batch = "A2"` (`MainActivity.java:753`) |
| 6 | `filamentId` | 11 | 6 | `"1" + MaterialID` | `'1'` + 5 ASCII digits | `MaterialID` is `base.id` from `material_database.json`, validated as exactly 5 numeric chars (`FilamentForm.cs:251,256`) |
| 7 | `color` | 17 | 7 | `"0" + RRGGBB` | `'0'` + 6 uppercase hex | leading nibble always `'0'`; see OPEN QUESTION 2 |
| 8 | `filamentLen` | 24 | 4 | e.g. `"0330"` | 4 ASCII digits | metres of filament, from the weight table (§3.4) |
| 9 | `serialNum` | 28 | 6 | `"000001"` | 6 ASCII digits | hard-coded in Windows; see §3.5 |
| 10 | `reserve` | 34 | 6 | `"000000"` | 6 ASCII chars | README calls this `reserve`; part of the 14-zero run |
| — | *filler* | 40 | 8 | `"00000000"` | 8 ASCII `'0'` | remainder of the 14-zero `reserve` string; pads the record out to exactly 48 bytes = sector 1 |
| 11 | `printerType` | 48 | ≤48 | e.g. `"K2"`, `"K1C"`, `"Hi"` | ASCII, **space**-padded to offset 96 | `printerModel.Text`; see §8 |

Cross-verification of every boundary against the Android "manual tag data" dialog,
which is the only place all ten logical fields are individually parsed
(`Android/SpoolID/app/src/main/java/dngsoftware/spoolid/MainActivity.java:917-926`, Java
`substring(begin, end)`):
```java
manual.txtmonth   .setText(tagData.substring(0, 1) .toUpperCase());
manual.txtday     .setText(tagData.substring(1, 3) .toUpperCase());
manual.txtyear    .setText(tagData.substring(3, 5) .toUpperCase());
manual.txtvendor  .setText(tagData.substring(5, 9) .toUpperCase());
manual.txtbatch   .setText(tagData.substring(9, 11).toUpperCase());
manual.txtmaterial.setText(tagData.substring(11, 17).toUpperCase());
manual.txtcolor   .setText(tagData.substring(17, 24).toUpperCase());
manual.txtlength  .setText(tagData.substring(24, 28).toUpperCase());
manual.txtserial  .setText(tagData.substring(28, 34).toUpperCase());
manual.txtreserve .setText(tagData.substring(34, 40).toUpperCase());
```
and the field-length validation at `MainActivity.java:937-940`
(1, 2, 2, 4, 2, 6, 7, 4, 6, 6 — sums to 40).

### 3.3 Parsing — `MainForm.ReadSpoolData`

`Windows/CFS-RFID/MainForm.cs:401-422`. **C# `Substring(startIndex, length)`**, not
`(begin, end)` — a classic porting trap:

```csharp
string materialId  = tagData.Substring(12, 5);   // chars 12..16  (filamentId minus the leading '1')
string printerType = tagData.Substring(48).Trim();
MaterialColor      = tagData.Substring(18, 6);   // chars 18..23  (color minus the leading '0')
string length      = tagData.Substring(24, 4);   // chars 24..27
```

Notes:
- The Windows read path **discards** the leading `'1'` of `filamentId` and the leading
  `'0'` of `color`. It never validates them.
- The gate is `tagData != null && tagData.Length >= 40` (`MainForm.cs:402`) — but the
  code then indexes offset 48, so a 40..48-char string throws (caught at `MainForm.cs:430`).
- `date`, `vendorId`, `batch`, `serialNum` and `reserve` are **never read back** by the
  Windows app. Only Android's manual dialog reads them.

### 3.4 `filamentLen` ↔ spool weight table

`Windows/CFS-RFID/Utils.cs:136-170` (`GetMaterialLength` / `GetMaterialWeight`, exact inverses):

| UI weight | `filamentLen` | grams (`Utils.cs:172-188`) |
|---|---|---|
| `1 KG`  | `0330` | 1000 |
| `750 G` | `0247` | 750 |
| `600 G` | `0198` | 600 |
| `500 G` | `0165` | 500 |
| `250 G` | `0082` | 250 |
| *(default / unknown)* | `0330` | 1000 |

`GetMaterialWeight` defaults to `"1 KG"` for any unrecognised length (`Utils.cs:169`).
Units are metres of 1.75 mm filament. Same table in Arduino
(`Arduino/ESP32/Spool_ID/Spool_ID.ino:399+`).

### 3.5 `serialNum`

- Windows always writes the literal `"000001"` (`MainForm.cs:451`).
- `Utils.RandomSerial()` (`Utils.cs:326-336`) exists — `RNGCryptoServiceProvider`, 4 random
  bytes → `Int32` → `Math.Abs(x % 900000)` → `"D6"` — but **it is dead code: no call site
  anywhere in `Windows/`** (verified by grep).
- Android substitutes the Spoolman spool id when Spoolman integration is enabled
  (`MainActivity.java:748-751`).
- Arduino uses `String(random(100000, 999999))` (`Spool_ID.ino:393`).

### 3.6 Color source

`MainForm.cs:698-712` — from a `ColorDialog`:
```csharp
MaterialColor = (dlg.Color.ToArgb() & 0x00FFFFFF).ToString("X6");
```
Alpha stripped, **uppercase** 6-hex-digit `RRGGBB`. Default at startup is `"0000FF"`
(`MainForm.cs:60`). The written field is `'0' + RRGGBB`.

### 3.7 Padding and encoding details

- `tagData.PadRight(96, ' ')` — pads with **U+0020 space**, not NUL (`MainForm.cs:454`).
- If `tagData` were ever longer than 96 chars, `PadRight` is a no-op and
  `Array.Copy(fullDataBytes, 48, s2ToDisk, 0, 48)` would still copy exactly 48 bytes;
  anything past 96 is silently dropped. Not reachable with real printer names.
- `Encoding.UTF8.GetBytes` — every character produced is ASCII, so UTF-8 == ASCII == 1 byte.
  A non-ASCII printer name would shift all subsequent bytes; not reachable in practice.

---

## 4. Checksum / CRC / signature / derived values

**There is none.** No CRC, no checksum byte, no HMAC, no signature, no length prefix,
no parity field appears anywhere in `Utils.cs`, `MainForm.cs`, the Android app, or the
Arduino firmware. Integrity rests entirely on:

1. the MIFARE per-block CRC/parity handled by the reader hardware, and
2. the fact that sector 1 is AES-encrypted, so garbage decrypts to non-ASCII.

The **only derived value** in the whole system is the sector-1 Key A,
`encKey = AES-ECB(q3bu^t1nqfZ(pf$1, UID×4)[0..6]` (§2.2). It is written to the tag
(into the trailer) but it is a *key*, not an integrity check.

---

## 5. Trailer, keys, access bits, and the "lock" resources

### 5.1 Trailer write on `WriteSpoolData`

`Windows/CFS-RFID/MainForm.cs:481-494`
```csharp
if (!encrypted)
{
    byte[] trailer = reader.ReadBinaryBlocks(7, 16);
    if (trailer != null)
    {
        Array.Copy(encKey, 0, trailer, 0, 6);
        Array.Copy(encKey, 0, trailer, 10, 6);
        reader.UpdateBinaryBlocks(7, 16, trailer);
        encrypted = true;
        ...
    }
}
```

Sector-1 trailer (block 7) layout after the write:

| Bytes | Content |
|---|---|
| 0..5 | **Key A ← `encKey`** |
| 6..9 | **access bits + GPB — read-modify-write, PRESERVED verbatim** |
| 10..15 | **Key B ← `encKey`** |

- Access bits are **never authored**. They are whatever `ReadBinaryBlocks(7,16)` returned.
  On a factory-blank MIFARE 1K, reading the trailer with Key A returns
  `00 00 00 00 00 00 | FF 07 80 69 | FF FF FF FF FF FF` (Key A is masked to zeros by the
  chip), so bytes 6..9 come back as the standard `FF 07 80 69` transport configuration and
  are re-written unchanged. **Sector 1 is therefore never made read-only.**
- Key A and Key B are set to the **same** value. Since the app only ever authenticates
  with Key A (`keyType = 96`), Key B is effectively cosmetic.
- This trailer write happens **exactly once**, on the transition unencrypted → encrypted.
  Re-writing an already-`encKey`'d tag leaves block 7 untouched.
- **Sector 2's trailer (block 11) is never written by `WriteSpoolData`.** Sector 2 stays on
  the default key forever.

Identical logic in Android (`MainActivity.java:600-606`) and Arduino
(`Spool_ID.ino:149-166`, note the Arduino writes bytes 10..15 first, then 0..5 — same result).

### 5.2 "Is this tag ours?" detection

`MainForm.cs:255` and `MainForm.cs:395`:
```csharp
if ((reader.Authentication10byte(7, 96, 0) || reader.Authentication6byte(7, 96, 0)))
```
i.e. **if block 7 still authenticates with the DEFAULT key, the tag is considered blank /
unprogrammed** ("Empty tag", `MainForm.cs:397`) and the padlock indicator is hidden.
If that authentication *fails*, the tag is treated as programmed/encrypted.

`WriteSpoolData` and `TagMemoryForm` use the inverse probe — authenticate block **4** with
slot **1** (`encKey`) — to decide `encrypted` (`MainForm.cs:464`, `TagMemoryForm.cs:48`).

### 5.3 What drives the lock icons — no MIFARE read-only behaviour is involved

| Resource | Where used | Meaning |
|---|---|---|
| `lock.png` → `Resources._lock` | `MainForm.Designer.cs:254` — the `imgEnc` PictureBox | **"this tag carries a derived key"** indicator. Shown when block 7 does *not* auth with the default key (`MainForm.cs:261-265`) or right after a first write (`MainForm.cs:490`). Clicking it copies `UID` + `Key` to the clipboard (`MainForm.cs:866-875`). Tooltip: `"Key: " + hex(encKey)` (`MainForm.cs:263`). |
| `locked.png` → `Resources.locked` | `TagMemoryForm.cs:126` | Icon for **sector 0 / block 0** only — the manufacturer block, which is genuinely read-only on the chip (`TagMemoryForm.cs:124-127`, label `"MANUFACTURER (UID)"` at `:137`). |
| `internal.png` → `Resources._internal` | `TagMemoryForm.cs:130` | Icon for **block 3 of every sector** (the sector trailer), label `"Keys A/B + Access Bits"` (`:138`). |
| `writable.png` → `Resources.writable` | `TagMemoryForm.cs:132` | Icon for every other block, label `"USER DATA"` (`:139`). |
| `failed.png` → `Resources.failed` | `TagMemoryForm.cs:97` | Sector-level authentication failure card. |

**Conclusion: the app has no "lock the tag" / "make read-only" feature.** The icons are
purely presentational, driven by `(sector, blockInSector)` position and by whether the
sector-1 key is the default key. No code ever writes non-default access bits.

---

## 6. The `format` operation

Menu entry: `AddMenuItem("nav_format", "Format Tag", Properties.Resources.format)`
(`MainForm.cs:120`) → `OpenFormat()` (`MainForm.cs:649-677`), confirmation dialog
*"This will erase the tag and set the default MIFARE key"* → `Utils.FormatTag(reader)`.

`Windows/CFS-RFID/Utils.cs:283-314`
```csharp
public static void FormatTag(Reader reader)
{
    byte[] emptyData = new byte[16];
    if (reader.Authentication10byte(4, 96, 1) || reader.Authentication6byte(4, 96, 1))
    {
        for (byte i = 4; i <= 6; i++) reader.UpdateBinaryBlocks(i, 16, emptyData);
        byte[] trailer = reader.ReadBinaryBlocks(7, 16);
        if (trailer != null)
        {
            Array.Copy(KEY_DEFAULT, 0, trailer, 0, 6);
            Array.Copy(KEY_DEFAULT, 0, trailer, 10, 6);
            reader.UpdateBinaryBlocks(7, 16, trailer);
        }
    }
    if (reader.Authentication10byte(8, 96, 0) || reader.Authentication6byte(8, 96, 0))
    {
        for (byte i = 8; i <= 10; i++) reader.UpdateBinaryBlocks(i, 16, emptyData);
        byte[] trailerS2 = reader.ReadBinaryBlocks(11, 16);
        if (trailerS2 != null)
        {
            Array.Copy(KEY_DEFAULT, 0, trailerS2, 0, 6);
            Array.Copy(KEY_DEFAULT, 0, trailerS2, 10, 6);
            reader.UpdateBinaryBlocks(11, 16, trailerS2);
        }
    }
}
```

Exactly:
1. Auth block 4 with **slot 1 (`encKey`)** — a format only works on an already-programmed tag.
2. Blocks **4, 5, 6** ← sixteen `0x00` bytes each.
3. Block **7**: read, splice `FF FF FF FF FF FF` into bytes 0..5 and 10..15,
   **preserve bytes 6..9 (access bits/GPB)**, write back.
4. Auth block 8 with **slot 0 (default)**.
5. Blocks **8, 9, 10** ← sixteen `0x00` bytes each.
6. Block **11**: same default-key splice as step 3.

Sectors 0 and 3..15 are untouched. The blocks are **zero-filled, not space-filled** —
so a formatted tag read back yields 96 NUL characters, which `String.Trim()` does *not*
strip (`\0` is not Unicode whitespace). Android explicitly tests
`tagData.startsWith("\0")` (`MainActivity.java:915`); the Windows app does not.

**Divergence from Android:** Android's `FormatTag` (`MainActivity.java:636-670`) does **not**
touch block 11, and it only rewrites trailer 7 `if (encrypted)`. The Windows version always
resets both trailers. A Swift port should follow the Windows behaviour (Utils.cs is
authoritative for this port).

---

## 7. Tag memory dump / inspection

`Windows/CFS-RFID/TagMemoryForm.cs:31-140`, rendered by `TagBlockCard.SetData`
(`TagBlockCard.cs:13-19` — title, hex string, icon).

Algorithm (`TagMemoryForm.cs:43-104`):
```csharp
int sectorCount = 16;
if (this.reader.Authentication6byte(4, 96, 1) || this.reader.Authentication10byte(4, 96, 1))
    encrypted = true;
for (int s = 0; s < sectorCount; s++)
{
    int firstBlock = s * 4;
    bool auth;
    if (s == 1 && encrypted) auth = this.reader.Authentication6byte((byte)firstBlock, 96, 1);
    else                     auth = this.reader.Authentication6byte((byte)firstBlock, 96, 0);
    if (auth)
        for (int b = 0; b < 4; b++) { ... reader.ReadBinaryBlocks(firstBlock + b, 16) ... }
    else
        // card: "Sector {s} | FAILED AUTHENTICATION" / "Key Required"
}
```

- Fixed **16 sectors** (1K assumed; a 4K tag would only show its first 1K).
- Only the **6byte** authenticate variant is used inside the loop.
- Sector 1 uses key slot 1 iff the tag is encrypted; **every other sector uses the default key.**
- Blocks are dumped **raw** — sector 1 is shown as **ciphertext**, never decrypted.
- Hex rendering: `BitConverter.ToString(data).Replace("-", " ").Trim()` (`TagMemoryForm.cs:74`)
  → uppercase, space-separated, e.g. `57 F2 5B 78 ...`.
- Titles: `$"Block {currentBlock} | {definition}"` where `definition` comes from
  `GetMifareBlockDefinition` (`TagMemoryForm.cs:135-140`):
  - sector 0, block 0 → `"MANUFACTURER (UID)"`
  - block index 3 → `"Keys A/B + Access Bits"`
  - otherwise → `"USER DATA"`
- On failure the *whole sector* collapses into one error card; individual block failures
  are invisible because `ReadBinaryBlocks` never checks SW.
- The form is refreshed with the live `Reader` on card insert (`MainForm.cs:267-270`,
  `TagMemoryForm.UpdateReader`).

---

## 8. Printer-type differences (k1 / k2 / hi / cfs)

**The tag layout is identical for all printer types.** The only difference is the ASCII
string written at offset 48.

- Written value is `printerModel.Text` (`MainForm.cs:453`), i.e. the selected entry of the
  printer combo box.
- The combo is populated from the **filenames** in `<AppDir>\material_database\*.json`,
  stripped of extension (`Utils.GetPrinterTypes`, `Utils.cs:398-418`; `MainForm.cs:81`).
- Those filenames are the Creality-cloud printer `name` field verbatim
  (`ManageForm.cs:55-58`: `SetDBfile(printerName + ".json", ...)`), filtered by
  `Utils.printerTypes = { "K2", "K1", "HI" }` (`Utils.cs:190-193`, used at `ManageForm.cs:29`
  via substring match, so real values look like `"K2 Plus"`, `"K1C"`, `"Hi"`).
- On read, `printerModel.FindStringExact(printerType)` (`MainForm.cs:408-410`) —
  `FindStringExact` is **case-insensitive** in WinForms, so read-back tolerates case drift,
  but **the bytes written preserve the exact case of the filename.**
- Repo reference DBs are lowercase: `db/k1.json`, `db/k2.json`, `db/hi.json`.
- The reference/Arduino firmware writes `"00000000"` in that region instead of a printer
  name (`Spool_ID.ino:395`) — i.e. bytes 48..55 are `'0'` and the rest are undefined —
  so the printer-type field is evidently optional / ignored by at least some firmware.
- `"cfs"` appears only in the application name (`CFS_RFID`) and never as a tag value in
  this codebase. Only per-printer *material database file paths* differ elsewhere
  (`Utils.cs:488-490`: K1 uses `/usr/data/creality/userdata/box/`, everything else uses
  `/mnt/UDISK/creality/userdata/box/`) — that is SSH/SCP behaviour, not tag encoding.

---

## 9. Cryptography in `Utils.cs`

`using System.Security.Cryptography;` at `Utils.cs:14`. Three uses:

### 9.1 `CreateKey` — MIFARE Key A derivation
`Utils.cs:195-223`. See §2.2. AES-128-ECB, `PaddingMode.None`,
key `q3bu^t1nqfZ(pf$1`, plaintext = UID repeated 4×, output = ciphertext[0..6].

### 9.2 `CipherData` — sector-1 payload confidentiality
`Utils.cs:225-250`
```csharp
aesAlg.Mode = CipherMode.ECB;
aesAlg.Padding = PaddingMode.None;
aesAlg.Key = new byte[]
{72, 64, 67, 70, 107, 82, 110, 122, 64, 75, 65, 116, 66, 74, 112, 50};
cryptoTransform = (mode == 1) ? aesAlg.CreateEncryptor(...) : aesAlg.CreateDecryptor(...);
return cryptoTransform.TransformFinalBlock(tagData, 0, tagData.Length);
```
- AES key: `48 40 43 46 6B 52 6E 7A 40 4B 41 74 42 4A 70 32` = ASCII **`H@CFkRnz@KAtBJp2`**
- **`mode == 1` → encrypt; anything else → decrypt.** Callers: `CipherData(1, …)` on write
  (`MainForm.cs:474`), `CipherData(0, …)` on read (`Utils.cs:266`).
  ⚠️ Android uses the JCE constants: `cipherData(1, …)` = `Cipher.ENCRYPT_MODE`,
  `cipherData(2, …)` = `Cipher.DECRYPT_MODE` (`Utils.java:383-391`, `MainActivity.java:565`).
  Same semantics, different sentinel for "decrypt". Pick one convention in Swift and
  document it — do not blind-port the integer.
- Input is always exactly **48 bytes** = 3 AES blocks, ECB, no padding, no IV.
  Because it is **ECB**, each 16-byte block encrypts independently — this is why block 6
  (`"0000000000000000"` for every standard write) always produces the identical ciphertext
  `FA C8 F0 75 09 29 2D F9 43 D4 CD F6 4C BA 06 A1`. See the test vectors in §11.
- On exception the C# returns **`null`** (`Utils.cs:249`) — the Android version returns the
  *input unchanged* (`Utils.java:390`). A `null` here would NRE at `Utils.cs:267`.
- **Sector 2 (bytes 48..95) is never encrypted** — plaintext on the tag.

### 9.3 `RandomSerial` — dead code
`Utils.cs:326-336`. `RNGCryptoServiceProvider` → 4 bytes → `BitConverter.ToInt32` →
`Math.Abs(x % 900000)` → `.ToString("D6")`. No call sites in `Windows/`. Not needed for
the port, but note `Math.Abs(int.MinValue % 900000)` is safe here
(`int.MinValue % 900000 = -748800`), so no overflow bug.

Nothing else in `Utils.cs` is cryptographic. SSH/SCP (`Renci.SshNet`) is used for pushing
`material_database.json` to the printer (`Utils.cs:420-733`) — unrelated to the tag codec.

---

## 10. Behavioural divergences between the three reference implementations

Flagged because a "byte-identical" port must pick one. **Windows is authoritative for this port.**

| Behaviour | Windows | Android | Arduino |
|---|---|---|---|
| Sector-1 read key | **always `encKey`**, throws if it fails (`Utils.cs:256,271`) | `encrypted ? encKey : KEY_DEFAULT` (`MainActivity.java:545`) | n/a (write-only) |
| Sector-1 decrypt on read | **always** (`Utils.cs:266`) | only `if (encrypted)` (`MainActivity.java:564-570`) | n/a |
| Sector-1 encrypt on write | always (`MainForm.cs:474`) | always (`MainActivity.java:596`) | always (`Spool_ID.ino:141-145`) |
| Format resets block 11 | **yes** (`Utils.cs:306-312`) | no | n/a |
| Format resets block 7 | always (`Utils.cs:292-298`) | only `if (encrypted)` (`MainActivity.java:658-663`) | n/a |
| `serialNum` | `"000001"` const | Spoolman id or `"000001"` | `random(100000, 999999)` |
| `printerType` at offset 48 | combo text | `PrinterType` | literal `"00000000"` |
| decrypt sentinel to `CipherData` | `0` (anything ≠ 1) | `2` | n/a |

Because Windows always decrypts sector 1 on read, and it only reaches `ReadTag` after
confirming block 7 does *not* auth with the default key (`MainForm.cs:395`), the two
behaviours agree in practice. A Swift port that supports reading *foreign* tags should
mirror Android's conditional decrypt — but that would be a **deliberate deviation**, not
a port of `Utils.cs`.

---

## 11. Swift implementation notes

### 11.1 Recommended value types

```swift
struct TagUID: Equatable {           // exactly 4 bytes; reject anything else
    let bytes: (UInt8, UInt8, UInt8, UInt8)
}

typealias MifareKey = [UInt8]        // always count == 6

struct SpoolRecord {                 // the 40-char logical record
    var month:       Character   // 1 char,  default "A"
    var day:         String      // 2 chars, default "B1"
    var year:        String      // 2 chars, default "24"
    var vendorId:    String      // 4 chars, default "0276"
    var batch:       String      // 2 chars, default "A2"
    var filamentId:  String      // 6 chars = "1" + 5-digit material id
    var color:       String      // 7 chars = "0" + RRGGBB uppercase
    var filamentLen: String      // 4 chars, from FilamentLength enum
    var serialNum:   String      // 6 chars
    var reserve:     String      // 6 chars, default "000000"
}

enum FilamentLength: String, CaseIterable {   // Utils.cs:136-170
    case kg1   = "0330", g750 = "0247", g600 = "0198"
    case g500  = "0165", g250 = "0082"
}
```

**Keep every field a `String`, not an `Int`.** Fields like `day = "B1"` and
`batch = "A2"` are not numbers, and `filamentId = "101001"` must not lose leading digits.
Converting `vendorId` to `Int` and back would work today (`0276` → `276` → `"0276"` only
with explicit `%04d`) but is a needless hazard.

### 11.2 Endianness and byte-order pitfalls

1. **The payload has no endianness.** Everything is ASCII. Do not introduce
   `withUnsafeBytes` / `UInt32(bigEndian:)` anywhere in the codec.
2. **The UID is used in transmission order**, not reversed. `FF CA 00 00 00` returns the
   UID MSB-first as printed on the card, and `CreateKey` consumes `tagId[0..3]` in that
   order (`Utils.cs:211`). Some CoreNFC / PC/SC wrappers hand you the UID reversed —
   **verify against the on-screen UID** (`MainForm.cs:248`:
   `BitConverter.ToString(uid).Replace("-", " ")`, i.e. `04 1A 2B 3C`).
   A reversed UID silently produces a completely different — and wrong — Key A.
3. **`encKey` is `ciphertext[0..<6]`**, the *first* six bytes, not the last.
4. **Blocks are written low→high (4,5,6 / 8,9,10)** and the 48-byte buffer maps
   `[0..16) → block 4`, `[16..32) → block 5`, `[32..48) → block 6`. No interleaving.
5. `BitConverter.ToString` in C# is uppercase hex with `-` separators; if you reproduce
   any UI/dump strings, match `String(format: "%02X")`.
6. **`Substring(start, length)` (C#) vs `substring(begin, end)` (Java) vs Swift indices** —
   see the field table in §3.2 for absolute offsets; do not port either language's call
   shape literally.
7. `.NET String.Trim()` strips Unicode whitespace but **not `\0`**. Swift's
   `.trimmingCharacters(in: .whitespaces)` is close but not identical — and a formatted
   (zero-filled) tag will *not* be trimmed by either. Test the all-NUL case explicitly.
8. `PadRight(96, ' ')` pads with `0x20`; `FormatTag` writes `0x00`. Don't conflate them.

### 11.3 Crypto in Swift

`CryptoKit` has no AES-ECB. Use `CommonCrypto`:
```swift
CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
        CCOptions(kCCOptionECBMode),      // NOTE: no kCCOptionPKCS7Padding
        key, kCCKeySizeAES128,
        nil,                               // IV ignored in ECB
        input, input.count, &out, out.count, &moved)
```
Both inputs are exact multiples of 16 (16 bytes for `CreateKey`, 48 for `CipherData`), so
`kCCOptionPKCS7Padding` **must be off** — enabling it changes the output length and breaks
byte-identity.

Constants:
```swift
let KEY_DERIVATION_AES_KEY: [UInt8] = Array("q3bu^t1nqfZ(pf$1".utf8)
    // 71 33 62 75 5E 74 31 6E 71 66 5A 28 70 66 24 31
let PAYLOAD_AES_KEY: [UInt8] = Array("H@CFkRnz@KAtBJp2".utf8)
    // 48 40 43 46 6B 52 6E 7A 40 4B 41 74 42 4A 70 32
let KEY_DEFAULT: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
```

### 11.4 Test vectors (no hardware required)

#### A. `CreateKey` — UID → 6-byte MIFARE Key A
AES-128-ECB, key `q3bu^t1nqfZ(pf$1`, plaintext = UID repeated 4×, take first 6 bytes.

| UID (hex, transmission order) | expected `encKey` |
|---|---|
| `00000000` | `1D0E88EACF60` |
| `041A2B3C` | `D9DB31ACC344` |
| `DEADBEEF` | `9B7996EB4A68` |
| `FFFFFFFF` | `0E9D73EDF813` |

#### B. Record construction — inputs → 40-char record
`WriteSpoolData(MaterialID, Color, Length)` with `vendorId="0276"`, `batch="A2"`,
`date="AB124"`, `serialNum="000001"`, `reserve[6]="000000"`:

| MaterialID | Color | Length | printerType | 40-char record |
|---|---|---|---|---|
| `01001` | `0000FF` | `0330` | `K2` | `AB1240276A210100100000FF0330000001000000` |
| `01001` | `FFFFFF` | `0165` | `K1` | `AB1240276A21010010FFFFFF0165000001000000` |
| `02001` | `C12E1F` | `0247` | `HI` | `AB1240276A21020010C12E1F0247000001000000` |

Row 2 reproduces line 1 of the README table (`README.md:36,44`) and entry 1 of
`docs/tn_data.json` exactly — use it as the primary golden vector.

#### C. Full 48-char sector-1 record (record + 8-char filler)
```
AB1240276A210100100000FF033000000100000000000000   (test A above, MaterialID 01001 / 0000FF / 0330)
AB1240276A21010010FFFFFF016500000100000000000000   (README line 1)
AB1240276A21020010C12E1F024700000100000000000000
```
Plaintext bytes for the README line-1 case:
```
41 42 31 32 34 30 32 37 36 41 32 31 30 31 30 30
31 30 46 46 46 46 46 46 30 31 36 35 30 30 30 30
30 31 30 30 30 30 30 30 30 30 30 30 30 30 30 30
```

#### D. Sector 1 ciphertext (`CipherData(1, …)`, key `H@CFkRnz@KAtBJp2`, AES-128-ECB)

| 48-char record | block 4 | block 5 | block 6 |
|---|---|---|---|
| `AB1240276A210100100000FF033000000100000000000000` | `57F25B78076D4C1797B1BE35CA269540` | `451BBCE6FDE582AB501B41101C3741C0` | `FAC8F07509292DF943D4CDF64CBA06A1` |
| `AB1240276A21010010FFFFFF016500000100000000000000` | `57F25B78076D4C1797B1BE35CA269540` | `D80EE25C0E3EDD25A3C1079BC52DD3AC` | `FAC8F07509292DF943D4CDF64CBA06A1` |
| `AB1240276A21010010C12E1F016500000100000000000000` | `57F25B78076D4C1797B1BE35CA269540` | `D73ED540CAB15038CC6100B05DDD7855` | `FAC8F07509292DF943D4CDF64CBA06A1` |
| `9A2240276A21010010000000016500000100000000000000` | `E42D5E6B37D74897C0AEF48021ADA142` | `00665003DD7923030A93A19D56B0460E` | `FAC8F07509292DF943D4CDF64CBA06A1` |
| `AB1240276A21020010C12E1F024700000100000000000000` | `58CB1E98A91234508C8796F46A73EE2F` | `AF07DFC05C79707E8298D3BB7F2BBE57` | `FAC8F07509292DF943D4CDF64CBA06A1` |

(Rows 2–4 are the three distinct README / `tn_data.json` records.)

**Block 6 is constant** (`FAC8F07509292DF943D4CDF64CBA06A1`) for every standard write —
because ECB, and because bytes 32..47 are always the 16 ASCII zeros
`"0000000000000000"`. This is the single cheapest smoke test for "is my AES wired up
correctly". Block 4 depends only on `date|vendorId|batch|filamentId[0..5]`, so it is also
constant across colors and weights.

#### E. Sector 2 (plaintext, never encrypted)
`printerType = "K2"`, payload bytes 48..95 = `"K2"` + 46 spaces:

| block | hex |
|---|---|
| 8  | `4B322020202020202020202020202020` |
| 9  | `20202020202020202020202020202020` |
| 10 | `20202020202020202020202020202020` |

For `"K1"`: block 8 = `4B312020…`; for `"HI"`: block 8 = `48492020…`.

#### F. Round-trip parse vectors
Given the decoded 96-char string
`"AB1240276A21010010FFFFFF016500000100000000000000K2" + 46 spaces`, after `.Trim()`:

| Expression (C#) | Expected |
|---|---|
| `tagData.Substring(12, 5)` | `"01001"` |
| `tagData.Substring(18, 6)` | `"FFFFFF"` |
| `tagData.Substring(24, 4)` | `"0165"` |
| `tagData.Substring(48).Trim()` | `"K2"` |
| `GetMaterialWeight("0165")` | `"500 G"` |

#### G. Format vectors
After `FormatTag`, blocks 4,5,6,8,9,10 are each
`00000000000000000000000000000000`, and blocks 7 and 11 each have bytes 0..5 and 10..15
equal to `FFFFFFFFFFFF` with bytes 6..9 unchanged from before the format.

### 11.5 Suggested Swift API shape

```swift
protocol TagTransport {                       // one impl over PC/SC, one fake for tests
    func getUID() throws -> [UInt8]           // FF CA 00 00 00
    func loadKey(structure: UInt8, slot: UInt8, key: [UInt8]) throws -> Bool
    func authenticate(block: UInt8, keyType: UInt8, slot: UInt8, legacy: Bool) throws -> Bool
    func readBlock(_ block: UInt8) throws -> [UInt8]
    func writeBlock(_ block: UInt8, _ data: [UInt8]) throws -> Bool
}

enum TagCodec {                               // pure, hardware-free — this is what you unit-test
    static func derivedKey(uid: [UInt8]) -> [UInt8]
    static func encodePayload(_ r: SpoolRecord, printerType: String) -> [UInt8]  // 96 bytes
    static func sector1Blocks(_ payload: [UInt8]) -> [[UInt8]]                   // 3 × 16, encrypted
    static func sector2Blocks(_ payload: [UInt8]) -> [[UInt8]]                   // 3 × 16, plaintext
    static func decodePayload(sector1: [UInt8], sector2: [UInt8]) -> String      // 96 chars
    static func parse(_ decoded: String) -> SpoolRecord?
}
```
Everything in §11.4 tests `TagCodec` alone. `TagTransport` needs only APDU-shape tests
against the byte strings in §2.

---

## OPEN QUESTIONS

**1. The date field encoding (`month` / `day` / `year`) is NOT derivable from this codebase.**
Every implementation hard-codes the literal `"AB124"`:
`MainForm.cs:453`, `MainActivity.java:754`, `Spool_ID.ino:395`. There is no
`DateTime`/`Calendar`/`strftime` call anywhere near the tag codec.
The complete observed corpus is two samples:

| sample | month | day | year | source |
|---|---|---|---|---|
| `AB124…` | `A` | `B1` | `24` | `README.md:44,46,50`, `tn_data.json` entries 1,2,4, `def_mon/def_day/def_yr` in `Android/.../res/values/strings.xml:45-47` |
| `9A224…` | `9` | `A2` | `24` | `README.md:48`, `tn_data.json` entry 3 |

`year` is plainly a 2-digit year (`24` = 2024). `month` as a single hex-ish digit is
consistent with `A` = 10 (October) and `9` = September. But **`day` cannot be plain hex**
(`B1` = 177, `A2` = 162 — both out of range for a day of month), so the 1/2/2 split is
either not month/day/year at all, or `day` uses an encoding not evidenced here.
The field *boundaries* (1, 2, 2) are firm — confirmed by the Android manual dialog's
parse and validation (`MainActivity.java:917-919`, `:937`). **The semantics are not.**
Recommendation: treat `"AB124"` as an opaque 5-char constant in the Swift port
(that is byte-identical to Windows) and expose it as a configurable string.

**2. The leading nibble of the `color` field (offset 17) has unknown meaning.**
It is always written as `'0'` (`MainForm.cs:450`: `string color = "0" + Color;`) and is
discarded on read (`MainForm.cs:416` reads offset 18 for 6 chars). All four
`tn_data.json` `color_value` samples also start with `0` (`0FFFFFF`, `0C12E1F`, `0000000`).
Plausible candidates: an alpha/opacity nibble, a color-space selector, or a multi-color
spool flag — **no evidence in this repo**. Port it as a constant `'0'`.

**3. `batch` (`"A2"`) and `vendorId` (`"0276"`) are constants with only partial documentation.**
`vendorId` is commented `// 0276 creality` (`MainActivity.java:745`,
`Spool_ID.ino:389`) — presumably a Creality vendor code; the value space and whether a
third-party vendor code would be accepted by the printer is unknown. `batch` has no
comment at all in any implementation. Treat both as opaque constants.

**4. `Reader.ReadBinaryBlocks` never inspects SW1/SW2** (`Reader.cs:55-61`).
A failed read silently returns 16 zero bytes, and the `if (trailer != null)` guards at
`MainForm.cs:484`, `Utils.cs:293`, `Utils.cs:307` can therefore never be false.
Consequence: if block 7 could not be read, the app would write
`encKey ‖ 00 00 00 00 ‖ encKey` — clobbering the access bits to `00 00 00` + GPB `00`.
In practice the read always succeeds on a compliant reader, so this path is not exercised.
**Should the Swift port (a) faithfully reproduce this, or (b) check SW and abort?**
Recommendation: check SW and abort — the failure mode is a bricked-ish sector, and the
"faithful" behaviour is unreachable on working hardware. Needs a decision from the owner.

**5. `MainForm.ReadSpoolData`'s length gate is inconsistent with its own indexing.**
`MainForm.cs:402` requires `tagData.Length >= 40`, then `MainForm.cs:407` indexes
`Substring(48)`. Strings of length 40..48 throw and are swallowed by the `catch` at
`MainForm.cs:429-433` ("Error reading tag"). Intended minimum is presumably 48 or 50.
Should the Swift port keep `>= 40` (faithful) or use `>= 48`? Purely a UX difference —
does not affect bytes on the tag.

**6. Whether the printer firmware validates `printerType` at offset 48 is unknown.**
The Arduino firmware writes literal `"00000000"` there instead of a name
(`Spool_ID.ino:395`) and is reported to work, which suggests the field is ignored by
the printer and used only by the app for UI restoration (`MainForm.cs:407-411`).
Unconfirmed against real firmware.

**7. Sector 2's trailer is left on the default key permanently.**
`WriteSpoolData` writes blocks 8–10 but never block 11, so bytes 48..95 of any programmed
tag are readable and rewritable by anyone with a default-key reader. This looks intentional
(the printer must read it without deriving a key) but is not documented anywhere.
Flagging in case it is actually an omission that a newer firmware revision changed.

**8. ⚠️ BLOCKING — the hardware probe says Key A fails where the C# requires Key A.**
On the ACS ACR1552 + the probed 1K tag, authenticating with `FFFFFFFFFFFF` succeeds with
**Key B (`0x61`)** and fails `69 82` with **Key A (`0x60`)** on sectors 0 and 2..15.
The Windows app authenticates **sector 2 / block 8 with Key A + the default key** and has no
key-type fallback (`Utils.cs:273`, `MainForm.cs:501`, §0-Q2, §0-Q5). Under the probed
conditions the Windows app could not read or write sector 2 on this tag at all.

The source offers **no explanation** for this — with the observed transport access bits
`FF 07 80 69`, Key A must be usable. Candidate causes, none confirmed:
- an ACR1552 firmware quirk in key-slot ↔ key-type binding (the ACR1552 is a newer
  CCID/`FF 86` implementation than the ACR122U this code was clearly written against);
- the probe's key-slot number not matching the slot the key was loaded into;
- a genuinely non-default Key A on 15 sectors, which this app never produces.

**This must be resolved before the Swift transport layer is finalised.** Probe steps 2 and 4
in §0.6 discriminate between the causes in two APDU exchanges.
Interim recommendation for the port: make key type a parameter, attempt **Key A first, fall
back to Key B with the same key value**, and log which one succeeded. That is a *deliberate,
documented deviation* from `Utils.cs` — it changes no bytes written to the tag, only which
authenticate APDU is emitted, so it cannot affect payload byte-identity.

**9. Is the probed tag blank or already programmed?** The hardware probe log records
"All data blocks read as zeros (this is a blank/unwritten tag)", but §0.6 argues sector 1 is
*unreadable*, not blank — and that its A-and-B-both-non-default state is the signature of
this app's own first-write path (`MainForm.cs:486-487`). If sector 1 authenticates with
`E05E87259A4F`, the tag is programmed and the "blank" reading was an artefact of
`ReadBinaryBlocks` swallowing the error SW. Resolve with probe step 1 in §0.6 before
drawing any conclusion about what a factory-blank tag looks like.
