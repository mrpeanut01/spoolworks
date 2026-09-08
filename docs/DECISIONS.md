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

## D-006 — Hardware safety: writes are explicit and reversible where possible
**Context:** Writing a wrong payload to a real spool tag can brick a customer's spool data, and
sector-trailer writes can permanently lock a tag.
**Chosen:** Read-before-write with a full pre-write diff shown to the user; explicit confirmation
for any destructive operation; automatic backup dump of all readable sectors before any write;
key/trailer modification gated behind an explicit advanced toggle.
**Why:** The Windows app is comparatively unguarded; on a rewrite we can be safer at no UX cost.
**Impact:** Slightly more confirmation UI than Windows. Considered a deliberate improvement.
