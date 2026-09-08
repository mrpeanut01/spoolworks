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
two disagree. So a stale UI decision cannot rewrite the keys of a tag that turned out to be
programmed — which a persisted `true` preference could. The diff, the backup, the access-bit
preservation and the read-back verification are untouched, and the sheet still states plainly that
the key is being written.

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
