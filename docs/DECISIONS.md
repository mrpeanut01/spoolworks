# DECISIONS

Format: decision · context · alternatives · chosen · why · impact

---

## D-001 — Language & UI framework: Swift + SwiftUI
**Context:** Port a WinForms/.NET 4.8 app to macOS with native feel.
**Alternatives:** (a) .NET MAUI / Avalonia to reuse C# logic; (b) Catalyst; (c) Electron; (d) Swift+SwiftUI.
**Chosen:** Swift + SwiftUI (AppKit where needed).
**Why:** No runtime dependency to ship; direct access to PCSC.framework, CoreGraphics, Keychain;
native macOS look/feel; avoids dragging a .NET runtime into a self-contained `.app`. The C# logic
is small enough (~6.7k LOC, much of it Designer boilerplate) that reuse is not worth the runtime cost.
**Impact:** Full rewrite of UI; business logic translated, not reused. Test vectors become the
parity mechanism against the Windows original.

## D-002 — Build system: Swift Package Manager, not Xcode
**Context:** Probed the machine — only Command Line Tools installed; `xcodebuild` unavailable.
**Alternatives:** (a) require user to install Xcode; (b) SwiftPM + hand-assembled `.app`.
**Chosen:** SwiftPM, with a `make-app.sh` that assembles `Spoolworks.app` (Info.plist, icon, ad-hoc codesign).
**Why:** Works on the machine as-is; no multi-GB install gate; reproducible from CLI; still produces
a real double-clickable app bundle.
**Impact:** No Interface Builder, no Xcode test runner. Tests run via `swift test`. Distribution
signing/notarization is out of scope unless requested.

## D-003 — PC/SC access via an isolated C shim
**Context:** `import PCSC` from Swift fails: the framework's modulemap declares `requires !swift`.
Including `<PCSC/winscard.h>` from a C target still fails, because the module is implicitly imported
into Swift through the header chain.
**Alternatives:** (a) CryptoTokenKit `TKSmartCard`; (b) redeclare winscard prototypes in Swift;
(c) C shim exposing a narrow `k2_*` API, with PCSC headers included only in the `.c` file.
**Chosen:** (c) — validated working end to end.
**Why:** Keeps the incompatible module entirely out of Swift's view; gives full winscard capability
(status-change monitoring, control codes) that `TKSmartCard` does not expose; the narrow surface is
easy to mock and audit.
**Impact:** One small C target (`Sources/CPCSC`). `SCARD_CTL_CODE` must be defined manually
(`0x42000000 + code`) as macOS's pcsclite headers omit it.

## D-004 — Reader support is generic PC/SC, not device-specific
**Context:** Windows app targets the ACR122U; the user's device is an ACR1552.
**Chosen:** Implement the ACS pseudo-APDU set (`FF CA` UID, `FF 82` load key, `FF 86` auth,
`FF B0` read, `FF D6` write) against any PC/SC reader; treat reader-specific escapes (buzzer,
firmware string) as **optional, best-effort, non-fatal**.
**Why:** The MIFARE command set is common across ACS readers; hard-coding a model would break the
user's primary device. Optional-escape handling means an unsupported buzzer command degrades
gracefully instead of failing a write.
**Impact:** Broader hardware support than the Windows original. Reader-specific niceties may be
unavailable on some models — surfaced in UI as disabled, not broken.

## D-005 — `SCARD_SHARE_DIRECT` is unavailable on macOS
**Context:** Probe returned `0x80100011` (SCARD_E_UNSUPPORTED_FEATURE) for direct connect on both
ACR1552 slots.
**Chosen:** Route all reader commands through a normal shared card session; require a card present
for firmware/buzzer queries; never make app startup depend on a direct connection.
**Why:** Platform limitation, not a bug we can fix.
**Impact:** "Reader firmware" and buzzer toggle behave differently from Windows — documented as an
accepted divergence rather than a defect.

## D-007 — Tests are a plain executable, not a `testTarget`
**Context:** `swift test` needs XCTest, which ships with Xcode and is absent here. The toolchain's
bundled `Testing.framework` links but fails at runtime — dyld cannot resolve `lib_TestingInterop.dylib`,
which does not exist anywhere on the system. Both were tried and both are dead ends on this machine.
**Alternatives:** (a) require Xcode; (b) vendor swift-testing as a package dependency; (c) a small
in-repo harness compiled as an executable target.
**Chosen:** (c) — `Sources/SpoolworksTests` with `Harness.swift`, run via `swift run SpoolworksTests`.
**Why:** Runs anywhere Swift runs, including CI, with zero toolchain assumptions and no network
dependency. Exit code 0/1 drops straight into a pipeline. The harness is ~120 lines.
**Impact:** No Xcode test UI and no parallel test execution. Assertions are functions
(`t.equal`, `t.throwsError`) rather than macros. Migrating to swift-testing later is mechanical.

## D-008 — Golden vectors come from compiling the reference implementation, never from hand calculation
**Context:** The extracted codec spec supplied a hand-computed invariant: "block 6 is always
`FAC8F07509292DF943D4CDF64CBA06A1`, because payload bytes 32–47 are always ASCII zeros."
Verification against the compiled reference showed the *ciphertext* is correct but the *reasoning*
is not, and the "always" is false:
- Bytes 32–47 are `"0100000000000000"`, not all zeros — `serialNumber` spans 28–33, so the trailing
  `'1'` of `"000001"` lands at offset 33.
- The value therefore holds only while the serial ends in `01`. The Arduino randomises the serial
  and Android substitutes a Spoolman id, so **real tags from either implementation have a different
  block 6**. Any check asserting a constant block 6 would wrongly reject valid tags.
- Separately, `AES(all zeros)` under the payload key is `C3B98E0E7A3D248A5D7813C0E26B581A` — a
  different quantity that is easy to conflate with the above.
An earlier revision of this entry claimed the spec's constant was simply wrong; that was itself
imprecise and is corrected here.
**Chosen:** All crypto golden vectors are generated by `Tools/aes-reference-check.sh`, which
compiles the in-repo Arduino AES and prints its output. Vectors are pinned as tests.
**Why:** The port must be byte-identical to the firmware that programs real tags. A wrong constant
in a test is worse than no test — it manufactures false confidence. The reference implementation is
sitting in the repository; there is no reason to guess.
**Impact:** The Swift AES layer is now proven byte-identical to the reference for key derivation,
payload encryption, and decryption. Any future spec claim about tag bytes must be validated the
same way before it is trusted.

## D-009 — Scope: the app programs blank tags; it does not read Creality OEM tags
**Context:** Hardware testing across four physical tags. **This entry was originally stated far
more confidently than the evidence supported, and is corrected here.**

| Tag UID | Result | Evidence quality |
|---|---|---|
| `80A67939` | opens with key B / `FFFFFFFFFFFF`; blank | sound |
| `40C97A39` | **opens with its derived key** — a programmed tag, NOT locked | earlier "locked" reading was WRONG |
| `A0E67A39` | unknown | tested before the session-reset fix; result unreliable |
| `F0A77939` | locked against all six keys tried, both key types | sound — fresh PC/SC session per attempt |

**What went wrong in the original conclusion.** Three of the four tags were probed while
`authenticateAny` still had the session-poisoning bug (see `MifareClassicCard.authenticateAny`):
a single wrong-key attempt poisoned the card session, so every subsequent key reported failure
regardless of correctness. That made programmed tags look permanently locked. Only `F0A77939` was
retested with a brand-new PC/SC session per attempt, which is the sound test.

`40C97A39` was later read and written successfully using its UID-derived key, proving it is an
ordinary programmed tag. The generalisation "these are OEM tags nothing can read" was drawn from
contaminated data and is withdrawn for two of the three.

**What still stands:** `F0A77939` genuinely rejects `FFFFFFFFFFFF`, the UID-derived key, the
reversed-UID variant, all-zeros, the MAD key and the NFC Forum key, on both key types, on every
sector — tested cleanly. And the source-level fact is unchanged and decisive on its own: the
Windows app knows exactly two keys (`KEY_DEFAULT` at `Utils.cs:25`, `CreateKey(uid)` at
`MainForm.cs:235`), a grep finds no other 6-byte key literal in the tree, and Arduino and Android
use the same two. So a tag whose sector 1 uses neither is out of reach of this toolchain.

Verified at the source that the Windows app knows exactly two keys and no others:
`KEY_DEFAULT = FFFFFFFFFFFF` (`Utils.cs:25`) and `encKey = CreateKey(uid)` (`MainForm.cs:235`).
A grep for any other 6-byte key literal across the whole Windows tree returns only `KEY_DEFAULT`.
The Arduino and Android implementations use the same two. **No implementation in this project can
read an OEM tag**, so this is a property of the upstream project, not a gap in the port.

**Chosen:** The macOS app targets the same workflow as the original — write spool records to blank
MIFARE Classic 1K cards, and read back tags this toolchain wrote. OEM tags are out of scope.
**Why:** It is what the reference implementations do, and it is a complete, self-consistent
workflow: the printer accepts a correctly-written blank card as a valid spool.
**Impact:** The UI must handle "this tag is locked and not one of ours" as a first-class, clearly
explained state rather than an error — users will present OEM tags and deserve a real explanation.
Key recovery was explicitly considered and rejected as out of scope; it is a separate project, and
the ACR1552's PC/SC pseudo-APDU interface most likely cannot issue the low-level nested-auth
commands such attacks require.

## D-010 — Camera colour scanning measures the *dominant, best-lit* colour, not the average
**Context:** Intake Method B (enter and tag) needs a colour for a third-party spool, and typing a
hex code means guessing. A camera can read it — but filament is a 1.75 mm cylinder wound in a
spiral, so a close-up of a wrap is a corrugated surface, not a flat patch. Every frame contains a
specular highlight along each strand, deep shadow in every valley between them, and whatever shows
through the gaps. Measured on a synthetic wrap with a known albedo: a plain mean of the pixels is
ΔE 7.6 off with shading alone and **ΔE 21 off** once a quarter of the target is spool core; a plain
median is ΔE 4.1 and ΔE 9.7 respectively.

**Alternatives:** (a) average the target area; (b) median of the target area; (c) sample one pixel
under a crosshair; (d) k-means over the patch; (e) mode seek for the dominant colour, then average
its best-lit slice.

**Chosen:** (e). Sample a 20 × 20 grid of patch means across a small centred target, discard clipped
and crushed patches, find the densest cluster, keep everything sharing its colour at any lightness
below a specular ceiling, and average the brightest 30% of that.

**Why:**
- *Dominant, not average* — a contaminant has to out-**cover** the filament before it can affect the
  answer, rather than diluting it in proportion to its area. This is what takes the ΔE 21
  contamination case to ΔE 1.4.
- *Best-lit, not median* — within one material shading only ever makes a sample **darker**, so the
  unshadowed samples are the honest ones and the bulk of the distribution is not. A median
  deliberately reports a shadow. For a cylinder lit by a distant source the brightest 30% of the
  projected area is illuminated at ≥90% of peak whatever angle the light comes from, which is where
  the fraction comes from.
- *k-means was rejected* on determinism. Its initialisation makes the winner of a tie arbitrary, and
  an arbitrary winner shows up as a readout that flips between two colours while nothing in front of
  the camera moves. The mode seek breaks ties on the lowest index with a strict `>`, the same rule
  and the same reasoning as `ColorMatcher` (SPEC-05 §2.3).

**The load-bearing detail — the metric.** Cluster membership is the **angle between linear-RGB
vectors**, not distance in CIELAB's a*/b* plane. Lambertian shading multiplies all three linear
channels by one scalar, so the vector's *direction* is exactly shading-invariant: a lit red and its
own deep shadow are **1.8°** apart, while red and blue are 86°. The obvious alternative fails badly
and quietly — those same two reds are **35 units** apart in a*/b*, further than many pairs of
genuinely different colours, because CIELAB chroma falls with lightness. An early draft used a*/b*
and could not hold one material together across its own shading; the numbers are pinned as a test.
CIELAB is still used, for the L* axis and the final average, where it is the right tool.

**What this does not fix:** the camera's own white balance, which is now the largest source of
error. A spool under a warm lamp reads warm, and auto white balance will actively try to neutralise
a large field of one colour. Keeping the target at 22% of the frame's shorter side is a partial
defence — the camera balances on the whole scene — and the rest of the answer is that this is a good
way to *pick a swatch*, not a colorimeter. The reading is offered for confirmation into an editable
field, never applied silently.

**Impact:** ~340 lines of new domain code in `SpoolworksCore/Color/`, testable without a camera and
tested against synthetic wraps with known albedo (shading, specular, contamination, noise, black,
white, underexposure). 1.4 ms per frame in a release build, so the live readout is free. The app
bundle now carries `NSCameraUsageDescription`, and `make-app.sh` **verifies** it: AVFoundation does
not return an error when that key is missing, it terminates the process — so `CameraColorScanner`
also checks for the key before touching a capture API, which is what keeps `swift run` working.

## D-012 — The printer password moves out of the Keychain and into a file the app owns
**Context:** User-entered root passwords went into the login Keychain (D-001-era design, documented
in `Credentials.swift`). A Keychain item records which application may read it **by code
signature**, and this app has no Apple Developer ID: ad-hoc signed, its identity changes on every
build, so macOS asks the user to authorise it again each time. Even with the local self-signed
certificate the README describes, a freshly downloaded unsigned app raising a system password prompt
at launch is, to a user, indistinguishable from malware.

**Alternatives:** (a) keep the Keychain and document the certificate workaround; (b) keep the
Keychain but defer the first read until the user actually connects, so the prompt is at least
attributable; (c) `UserDefaults`; (d) a file the app owns, `0600`.

**Chosen:** (d), at the tool owner's explicit request, with (b)'s reasoning noted as the thing that
would have been tried had the Keychain stayed.

**Why:** The security control was costing more trust than it bought. `UserDefaults` was rejected as
strictly worse than a file — a plist is world-readable within the account, is copied around by
backup and sync tooling more casually, and gives no place to set permissions. The file is `0600` in
a `0700` directory and excluded from Time Machine, so the plaintext does not fan out into backups.

**What it costs, stated rather than buried:** the password is plaintext at rest and any process
running as this user can read it. That is defensible *only* because of what the secret is — the root
password of a 3D printer on a home LAN, which for most units is the vendor default printed on the
printer's own touchscreen (`VendorDefaultPassword`). It would not be defensible for anything else,
and `FileCredentialStore` should not be reused for anything else.

**No migration.** Reading the old Keychain items would raise exactly the prompt this change removes,
so a user who had saved a password enters it once more. Old items are left where they are rather
than deleted — deleting them would also require the prompt.

**Impact:** `KeychainCredentialStore` is gone and `FileCredentialStore` takes its place behind the
same `CredentialStore` protocol, so the adapter, its host-keying and its failure reporting are
unchanged. The README section explaining how to stop the Keychain prompt is replaced by one saying
where the password now lives and what that means. `import Security` leaves the package.

## D-006 — Hardware safety: writes are explicit and reversible where possible
**Context:** Writing a wrong payload to a real spool tag can brick a customer's spool data, and
sector-trailer writes can permanently lock a tag.
**Chosen:** Read-before-write with a full pre-write diff shown to the user; explicit confirmation
for any destructive operation; automatic backup dump of all readable sectors before any write;
key/trailer modification gated behind an explicit advanced toggle.
**Why:** The Windows app is comparatively unguarded; on a rewrite we can be safer at no UX cost.
**Impact:** Slightly more confirmation UI than Windows. Considered a deliberate improvement.

**Amended (tool owner, on the bench):** the advanced toggle is gone, and programming a blank tag
needs no opt-in. The clause assumed every trailer write is destructive. The only trailer write this
app performs is on a tag whose sector 1 is still on the factory key and holds no record — i.e.
tagging a new spool, the most ordinary thing the app does — and there is nothing on such a tag to
lose. Gating it behind a preference worded like a hazard put two clicks and a hunt in front of the
main workflow and taught the user to tick the scary box by reflex, which is worse than not asking.

Everything else in the clause stands. The write is still authorised per-tag rather than by
preference: `WritePlan.isBlankTagProgramming` is a claim about the card that was just read, and
`TagService.writeTag` re-derives the same condition from its own authentication and refuses if the
two disagree.

**Amended again (code review):** the condition is "sector 1 is still on the factory key", full
stop — not "and holds no record". Those two are not the same bit. `TagService.writeTag` writes
blocks 4–6 before block 7, so a tag lifted between the two is left holding a record under the
factory key; this app produces that tag itself. Core's own gate (`wasProgrammed = auth.key ==
derivedKey`) never looked at the record, but the UI's did, so it showed such a tag as "already
programmed", offered a write, and every attempt failed with "this tag is blank". The UI now
authorises on Core's condition exactly, and the confirmation sheet names the case: the tag holds
a record, its keys were never written, and programming it overwrites that record and writes the
keys. That is a completion of the interrupted write, not a loss. So a stale UI decision cannot rewrite the keys of a tag that turned out to be
programmed — which a persisted `true` preference could. The diff, the backup, the access-bit
preservation and the read-back verification are untouched, and the sheet still states plainly that
the key is being written.

**Amended again (tool owner, 2026-09-11): the printer is never restarted during a print, and never
without asking.** `reboot` in a root shell takes a printer down at once, and a print in progress goes
with it. Both upstream clients reboot straight after every upload and reset. This app had inherited
that for resets, and for uploads whenever database updates were allowed; commit 692a44c tied the
upload reboot to that setting, which no longer applies.
- Core has one way to send `reboot`: `PrinterService.restartIfIdle`. Immediately before the command
  it reads `print_stats` and `idle_timeout` from Moonraker, and refuses when a job is printing or
  paused, when Klipper is executing anything, or when the state cannot be read. There is no override,
  and a missing or unknown state is an error, never "idle".
- Uploads and resets no longer restart the printer. Once one is done, the Upload sheet asks. An idle
  printer gets "Restart the printer?" Yes/No. A printer that is printing, paused or busy gets
  "Automatically restart when the print finishes" or "Restart manually". A printer whose state
  cannot be read is not restarted.
- An automatic restart polls Moonraker, waits until the printer has been idle for two minutes (a
  print starting resets the wait), then goes through the same guard. It lives in memory, so quitting
  the app drops it rather than restarting the printer on some later launch, and it can be cancelled
  from the Printers window.
- The per-printer "Reboot after uploading" preference is gone; the question replaces it.

## D-011 — Location is a user-configurable list of places, and the CFS poll still owns its slots
**Context:** The Inventory screen showed Location and % remaining as read-only text. The tool owner
wanted both editable in place, and wanted the shelf-style locations to be a list the user
maintains, seeded `Unplaced, Shelf, CFS, Ext…`.

`SpoolLocation` already splits four ways by *who owns the fact*: `.cfs(box:slot:)` and
`.externalHolder` are **observed** — `material_box_info.json` reports them and
`SpoolInventory.reconcile` rewrites them every 30 s — while `.shelf(String)` and `.unknown` are
**asserted** by the user and no poll touches them. Making location editable therefore runs straight
into a conflict the app has not had before: a spool the user hand-places into CFS slot `T1A` that
the printer then reports empty, or vice versa.

**Alternatives considered.**
(a) *Let the picker set any location, including a CFS slot.* Rejected: it invites the user to state
something false about their own hardware, which the next poll silently reverses. `CFSViewModel`
already rejects exactly this for the design's "CFS units attached" picker, for the same reason.
(b) *Let a manual CFS assignment win until the user clears it — a sticky override.* Rejected: it
makes the inventory disagree with the machine indefinitely and adds a third, invisible state
(overridden) to a field whose value people trust because it is measured.
(c) *Freeze the picker entirely while the printer holds the spool.* Rejected: "I have just taken
this out" is a true and useful thing to say in the ~30 s before the poll notices, and blocking it
teaches the user the field is unreliable.
(d) *Refuse to remove a place that spools still reference.* Rejected: nothing is lost by moving them
— the spool, its history and its figure are untouched, only a label goes — and a list you cannot
tidy without first hunting every spool that mentions a name is a list people stop using.
(e) *Give places UUIDs so a rename touches nothing.* Rejected: `SpoolLocation.shelf` stores a
string, so a rename must walk the inventory either way; an id would only add a second thing that
can disagree with the first. The accepted cost is that the reserved `Unplaced` entry cannot be
renamed.

**Chosen.**
1. `SpoolPlaces` (Core) is an ordered, case-insensitively unique list of names, seeded with the
   four the tool owner asked for and persisted in `UserDefaults` under `SpoolworksSpoolPlaces` —
   the same pattern as `AppSettings` and `PrinterSettings`, not the inventory file, which the
   printer part-owns. `Unplaced` is reserved: always present, always first, never renamed or
   removed, and the only name mapping to `.unknown`. Every other name maps to `.shelf(name)`.
2. **The picker asserts only where the printer cannot see.** Its rows produce `.unknown` or
   `.shelf` and nothing else; `.cfs` and `.externalHolder` remain settable only by `reconcile`. A
   loaded spool's real position is shown as the selected row, labelled `"CFS T1 · A · reported by
   the printer"`, and applying it is a no-op. So a hand edit can move a spool **off** the printer,
   never **onto** it.
3. A hand edit that moves a loaded spool to a place is allowed and provisional. The poll settles
   it, and the existing reconcile logic already does the right thing in both directions: if the
   spool really was removed the unload pass skips it (it only touches locations that
   `isOnPrinter`), so the user's place **survives**; if it is still in the slot, pass 2 rebinds it
   by identity, restores `.cfs` and writes `"Loaded into T1A"`, so the assertion is **overruled by
   measurement, in writing**. Both are pinned by tests. The move also rewrites `remainingSource` to
   `"Last reading from CFS T1 · A"` — the same wording reconcile uses when the printer notices
   first, so the rail does not read differently depending on who spotted it.
4. Renaming or removing a place re-points its spools in the same operation
   (`SpoolInventory.reassign(place:to:detail:)`), each with a `.movement` line saying why. **A place
   edit can never leave a spool at a name the picker no longer offers.** Removal cascades to
   `Unplaced`; the button shows the count first and a toast reports it after.
5. `% remaining` is edited through the *existing* weigh-in control, which grows a By weight / By
   percent switch rather than gaining a rival "set %" affordance elsewhere. Both units call one
   method, so the `UsageEntry` invariant — every change to `remainingPercent` appends a line
   explaining it — is enforced once. Out-of-range figures are refused, not clamped, for the reason
   the weigh-in already refuses a gross weight; re-typing the figure already on record writes
   nothing, because a "0 g" adjustment explains nothing.
6. The list editor sits under the picker it configures, not in a preferences window. The app has no
   preferences window on purpose (see `AppSettings`): a setting is rendered next to what it affects,
   and places are only ever wanted while looking at a spool's location.

**Why:** It keeps the one line the whole inventory rests on — a measurement is a measurement and an
assertion is an assertion — while giving the user the vocabulary they asked for. Nothing the user
can click produces a claim the printer will contradict without saying so.

**Impact:** `CFS` and `Ext…` are seeded as ordinary shelf names with no special power; they are
*not* `.cfs` / `.externalHolder`, which is why the printer's own row names its source. There is
still a window of up to 30 s in which a hand edit and the printer disagree; it closes on the next
poll and both outcomes are logged. Re-selecting a CFS slot after moving a spool off it by hand is
not possible — the poll is the only way back, which is the point.

## D-013 — A tagged spool's filament is added to the printer one record at a time, on demand
**Context:** A tag stores a filament id, and the CFS rejects a tag whose id its printer's database
does not list. On 2026-09-11 a K2 Plus read a PolyTerra PLA tag correctly and logged
`{"code":"key843", "msg":"rfid is error"}`, because `P1023` is a vendor-catalogue id. The only
remedy the app had was Upload Database, which replaces the printer's file with the Mac's catalogue.
That same day the printer's database was newer than the Mac's: five ids the bundle lacks, different
content for all 96 shared records, and three slicer-synced `userMaterial` records under id `00004`.
An upload would have rolled all of that back and pushed 194 vendor filaments nobody had tagged.
Downloading first would not have helped either: the local catalogue merges by id, so the three
`00004` records would have been folded into one.

**Alternatives:** (a) keep the whole-catalogue upload and document its caveats; (b) re-encode the
printer's file with the record added; (c) set the CFS slot directly over the printer's websocket
(`set modifyMaterial`), as the touchscreen and Creality Print do; (d) splice one record into the
printer's own bytes, offered after a verified write.

**Chosen:** (d).
- After a verified write, an id from the bundled factory catalogue is not checked. Any other id is
  looked up in the printer's live list over its websocket — `get reqMaterials`, port 9999, no
  password. If it is missing, Write tag and Intake offer **Add to printer**.
- Adding reads `material_database.json` over SSH, appends the record in the file's own layout
  (provenance keys dropped, `base.alias` added) and raises `result.count`. It writes the file back
  with a guarded replace: the printer's `md5sum` must still match the file that was read (exit 3
  otherwise), the old file is kept as `material_database.json.spoolworks-bak`, and the new one goes
  through `upload`'s staging, size check and rename. The file is then read back and compared byte
  for byte.
- No version stamp and no reboot.

**Why:**
- (b) would reorder every key and reformat every number in a file the firmware wrote. That is
  harmless to a parser, but the only thing proven on hardware is the printer's file byte for byte
  plus one record (pushed by hand on 2026-09-11, md5-guarded), and the splice reproduces that.
- (c) works per slot, not per filament. It has to be redone whenever a spool moves, it happens at
  load time rather than when the tag is written, and a slot edit to an id the CFS cannot resolve did
  not stick (see Evidence).
- The websocket is used only to read. Its `set` requests are never sent.

**Evidence, and what is still open:**
- After the push, `reqMaterials` listed `P1023` at once, and the touchscreen's filament picker
  offered PolyTerra PLA without a restart.
- Setting slot 1A to it on the touchscreen, mid-print, made klippy log
  `Tn_data[T1][material_type][0]: 0P1023`. The slot still reported a blank name and the touchscreen
  reset to Unknown. The CFS side appears to resolve ids from a copy of the database loaded at startup.
- **Not yet confirmed:** whether the tag is accepted after a re-read with no restart, after a Klipper
  restart, or only after a full reboot. So the notice says the CFS *may* need a restart, and does
  not offer one.

**Impact:**
- New code: `PrinterMaterialDocument` (the splice), `CrealityPrinterSocket` (read-only),
  `PrinterService.addFilament`, `PrinterTransport.replace` with
  `PrinterTransportError.remoteFileChanged`, and `FilamentPushModel` and `FilamentPushNotice` in
  the UI.
- A Creality database update can replace the file and drop an added record. The next verified write
  for that filament notices and offers again.
- MD5 is used only because busybox ships `md5sum`. It detects a changed file; it is not a security
  control.

## D-014 — A factory tag identifies a filament, not a spool: untagged spools are matched by resemblance, and the user is asked
**Context:** The tool owner counted a Creality Hyper PLA White onto the shelf still sealed, so it
went into stock untagged, while another spool of the same filament was already loaded in the CFS.
Once the bag was open there was no way to give the shelf record its tag:
- Read / identify matched the tag to the **loaded** spool, and the attach was refused with "That tag
  already belongs to…". The request banner stayed up, so it looked as though the app was still
  trying.
- Intake refused it as a duplicate of the loaded spool, with no way to continue.
- Loading it into the CFS would have been "discovered" as a second record beside the shelf one.

All three have one cause. Every factory spool of one filament and colour carries the **same**
payload, serial `000001` included (see `SpoolIdentity`), so "this record is already in stock" says
nothing about which spool is on the reader. `SpoolInventory.reconcile` has always accepted twins,
and tells them apart by slot. The attach and Intake refusals were written as though payloads were
unique.

**Alternatives:**
(a) *Record each tag's UID on its spool, and identify by UID.* Rejected for now. The CFS never
reports a UID, so it would not help the poll, and no spool already in stock has one recorded. It
remains the only way a desk reader could ever tell two factory twins apart.
(b) *Bind automatically when exactly one untagged spool resembles the tag.* Rejected. Resemblance
is a guess: colours are picked by eye or by camera. A wrong silent bind rewrites a record's colour,
identity and remaining figure, and is invisible until the figures stop making sense.
(c) *Keep refusing, and tell the user to retire the shelf record and re-intake.* Rejected: it
throws away the history and the location the user entered.

**Chosen:**
1. The twin refusal in `InventoryViewModel.attachTag(record:)` applies only to a tag whose serial
   is its own. A `000001` tag may identify several spools; a Spoolworks-written serial may not.
2. **Resemblance** (`Spool.looksLike` / `couldBe`, `SpoolInventory.untaggedLookalikes`): the same
   filament (by filament id where the spool has one, otherwise by brand and name) and a colour
   within ΔE 25. Only untagged spools that are off the printer are offered. Resemblance is only
   ever used to **ask**.
3. **Inventory rail:** "Attach RFID spool" (was "Read its tag") opens Read / identify for that
   spool. The first tag attaches; a `TagPairing` then asks for the other side of the hub and checks
   it carries the same record. "One side is enough" stops waiting. A tag that is evidently another
   filament or colour is questioned ("Attach anyway / Not this tag") rather than silently
   rewriting the record.
4. **Read / identify, unasked:** a read that resembles an untagged spool offers "Attach to this
   spool / Not this time". The offer names the tagged twin, when there is one, and says why the tag
   cannot settle it.
5. **Intake:** the same offer. A duplicate that shares only a factory payload gets "Continue as a
   new spool" beside "Open the spool in stock". The notice says when the matched spool is loaded in
   the printer, since that makes it unlikely to be the one on the reader. A unique-serial duplicate
   is still refused.
6. **CFS:** `reconcile(holdingLookalikes:declined:)` holds a slot that resembles an untagged spool
   instead of discovering it, and reports it as a `LookalikeSlot`. A banner above every screen asks
   "Is it that spool?". Yes gives the spool the slot's identity and re-runs the poll on the same
   snapshot, so the spool lands in its slot with the CFS's figure at once. No discovers it and
   remembers the answer for that slot and payload. No scan is needed: the printer read the tag, and
   both sides carry the same record.
7. The Printer & CFS slot cells now look their spool up by slot position, not identity. Looking up
   by identity showed the same record in both slots of a twin pair.

**Why:** The app cannot know which of two identical spools is in hand, and the user always can.
Asking costs one click. Guessing costs a corrupted record, and refusing (the old behaviour) cost the
user their record.

**Impact:**
- While a CFS question is unanswered the slot has no spool, so job consumption from it is held by
  `CFSViewModel.pendingGrams` and charged on the next poll after the answer.
- Declined answers live in memory only. The discovered spool becomes the slot's incumbent, so the
  question does not come back while it stays loaded.
- Factory twins remain indistinguishable to a desk reader. The hero on Read / identify says "One of
  N spools with this tag" rather than claiming a single match.
