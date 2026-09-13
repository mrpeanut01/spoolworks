// UI state-machine regression tests for the code-review fixes.
//
// These run for real: `K2App` was split into the `SpoolworksUI` library plus a two-line `Spoolworks`
// executable, because SwiftPM will not let a test target depend on a target containing `@main`.
// Without that split these tests could not be compiled at all, and the fixes below would have no
// regression cover.
//
import Foundation
import SwiftUI
import AppKit
@testable import SpoolworksUI
@testable import SpoolworksCore

// MARK: - Bridging async, main-actor code into a synchronous harness

/// `TestCase.run` is synchronous and `TagViewModel` is `@MainActor`, so the async work has to be
/// pumped rather than awaited: blocking the main thread on a semaphore would starve the very
/// executor the work needs.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private func runOnMain(timeout: TimeInterval = 20,
                       _ body: @escaping @MainActor () async -> Void) {
    let done = Box(false)
    Task { @MainActor in
        await body()
        done.value = true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !done.value && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

// MARK: - Fixtures

@MainActor
private struct Harnessed {
    let monitor: ReaderMonitor
    let toasts: ToastCenter
    let settings: AppSettings
    let model: TagViewModel
}

@MainActor
private func makeHarness() -> Harnessed {
    let suite = "SpoolworksUIStateTests"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    let monitor = ReaderMonitor()          // never started: no polling, no PC/SC context
    let toasts = ToastCenter()
    let settings = AppSettings(defaults: defaults)
    return Harnessed(monitor: monitor,
                     toasts: toasts,
                     settings: settings,
                     model: TagViewModel(monitor: monitor,
                                         toasts: toasts,
                                         settings: settings,
                                         defaults: defaults))
}

private func identity(_ uid: [UInt8], type: CardType = .mifareClassic1K) -> CardIdentity {
    CardIdentity(readerName: "Mock Reader (1)",
                 atr: [],
                 type: type,
                 uid: uid,
                 uidFailure: nil,
                 firmware: nil)
}

private let tagA = identity([0x70, 0x4E, 0x7C, 0x39])
private let tagB = identity([0x3A, 0x63, 0x33, 0x03])
/// A 4-byte UID on a card type the Creality layout cannot live on.
private let unsupportedTag = identity([0x01, 0x02, 0x03, 0x04], type: .mifareUltralight)

/// A real `TagReadResult` off the in-memory card simulator, so a real `WritePlan` can be built
/// without a reader.
private func blankTagRead() throws -> TagReadResult {
    let service = TagService(card: MifareClassicCard(transport: MockTransport()),
                             cardType: .mifareClassic1K)
    return try service.readTag()
}

/// A read of a tag that already holds a record, for the prefill rules.
///
/// `isProgrammed: false` with a record is the half-programmed tag: blocks 4–6 written, lifted
/// before block 7, so sector 1 still opens with the factory key and yet a record decodes.
private func programmedRead(uid: [UInt8], serial: String, materialId: String = "12345",
                            colour: String = "1188ff",
                            isProgrammed: Bool = true) throws -> TagReadResult {
    let record = try SpoolRecord(materialId: materialId,
                                 colorRGB: colour,
                                 filamentLength: .kg1,
                                 serialNumber: serial)
    return TagReadResult(uid: uid,
                         derivedKey: .default,
                         isProgrammed: isProgrammed,
                         sector1Key: .default,
                         sector1KeyType: .keyA,
                         decryptedSector1: [UInt8](repeating: 0, count: 48),
                         record: record,
                         recordError: nil,
                         sector2: nil,
                         printerType: nil)
}

@MainActor
private func samplePlan() throws -> WritePlan {
    let current = try blankTagRead()
    let record = try SpoolRecord(materialId: "12345",
                                 colorRGB: "0000ff",
                                 filamentLength: .kg1,
                                 serialNumber: "000001")
    return TagViewModel.makePlan(current: current,
                                 record: record,
                                 materialLabel: "Creality · Hyper PLA",
                                 printerTypeString: "K2")
}

/// A key that is not the factory key, standing in for a UID-derived one.
private let derivedKeyFixture = MifareKey(bytes: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])!

/// A sector-1 dump whose `key` says which state the tag was in when it was taken, and whose block
/// 4 is filled with `marker` so a rendered dump can be told apart from another.
private func sector1Dump(key: MifareKey, marker: UInt8) -> MifareClassicCard.SectorDump {
    MifareClassicCard.SectorDump(sector: TagService.recordSector,
                                 blocks: [4: [UInt8](repeating: marker, count: 16)],
                                 key: key,
                                 keyType: .keyA,
                                 failure: nil)
}

/// A write result as Core returns it from one attempt, for the summary rules that only matter
/// once `ReaderMonitor.withCard` has retried.
private func writeResult(uid: [UInt8],
                         backup: [MifareClassicCard.SectorDump],
                         wasAlreadyProgrammed: Bool,
                         wroteTrailer: Bool) -> TagWriteResult {
    var written: [Int: [UInt8]] = [4: [], 5: [], 6: [], 8: [], 9: [], 10: []]
    if wroteTrailer { written[7] = [] }
    return TagWriteResult(uid: uid,
                          derivedKey: derivedKeyFixture,
                          backup: backup,
                          wasAlreadyProgrammed: wasAlreadyProgrammed,
                          wroteTrailer: wroteTrailer,
                          wroteSector2: true,
                          writtenBlocks: written)
}

/// The form in a state that can produce a record, so `autoWriteState` gets past `.blocked`.
///
/// A colour is now part of that: the draft no longer defaults to the Windows blue, because a
/// pre-filled swatch on a screen that has read nothing looks like a value that came off a tag.
@MainActor
private func makeDraftWritable(_ model: TagViewModel) {
    model.draft.materialID = "12345"
    model.draft.color = Color(nsColor: NSColor(rgbHex: 0xC12E1F))
}

/// The form in a state that cannot, which is also how these tests keep a retried auto-write away
/// from the (absent) hardware: `autoWriteIfNeeded` spends the arming and then stops on validation,
/// which is the observable outcome without ever opening a card session.
@MainActor
private func makeDraftUnwritable(_ model: TagViewModel) {
    model.draft.materialID = ""
}

// MARK: - SpoolDraft

let spoolDraftTests = TestSuite(name: "Write form draft", cases: [

    test("the material label participates in value equality") {
        // Regression: `hasSameValues` compared everything except the label, so a cascade that
        // swapped the label out from under an id counted as "the user has not touched this" and
        // the next read silently overwrote the form.
        var a = SpoolDraft()
        a.materialID = "12345"
        a.materialLabel = "Creality · Hyper PLA"
        var b = a
        b.materialLabel = "Polymaker · PolyTerra"
        $0.expect(!a.hasSameValues(as: b),
                  "two drafts naming different materials must not compare equal")
        $0.expect(a.hasSameValues(as: a), "a draft equals itself")
    },

    test("a label change alone marks the form as edited") { t in
        runOnMain {
            let h = makeHarness()
            t.expect(!h.model.draftIsEdited, "a freshly built form is not edited")
            h.model.draft.materialLabel = "Someone Else · Something Else"
            t.expect(h.model.draftIsEdited,
                      "a form whose label no longer matches the baseline has been edited")
        }
    },

    test("an empty material id is not writable and says so") {
        let draft = SpoolDraft()
        $0.expect(!draft.isValid)
        $0.equal(draft.validationIssues.first, "Enter a material ID.")
    },

    test("a five-digit material id with a colour is writable") {
        var draft = SpoolDraft()
        draft.materialID = "12345"
        draft.color = Color(nsColor: NSColor(rgbHex: 0xC12E1F))
        $0.equal(draft.validationIssues, [])
        $0.expect(draft.isValid)
    },

    // Colour has no default any more, so a form that has never been touched cannot be written —
    // which is the point: a spool's colour is not something to guess.
    test("a draft with no colour chosen is not writable, and says so") {
        var draft = SpoolDraft()
        draft.materialID = "12345"
        $0.expect(!draft.isValid, "no colour yet")
        $0.expect(draft.validationIssues.contains("Choose a colour."),
                  "and the reason is named")
    },

    // `Character.isNumber` is true of `²`, and `123²` is five UTF-8 bytes, so it passed the length
    // check as well and reached Core — which rejected it with a raw error the form had not
    // warned about. Both fields are ASCII on the wire.
    test("non-ASCII numerals are not accepted") {
        var draft = SpoolDraft()
        draft.materialID = "123²"
        draft.color = Color(nsColor: NSColor(rgbHex: 0xC12E1F))
        draft.serialNumber = "1234²"
        $0.expect(draft.validationIssues.contains("Material ID may contain only capital letters A-Z and the digits 0-9."),
                  "the material id must be caught by the form, not by Core")
        $0.expect(draft.validationIssues.contains("Serial number must be exactly 6 digits."),
                  "and so must the serial")
    },

    // The bug this was filed as: picking Polymaker Panchroma PLA Matte on the Write screen was
    // refused with "Material ID must be digits only" — for `P1003`, an id that came out of the
    // app's own catalogue. Every third-party filament in the shipped K2 database is P- or
    // E-prefixed, so all 31 of them were untaggable.
    test("a lettered catalogue id is writable") {
        for id in ["P1003", "P1001", "P7005", "E1001", "01001"] {
            var draft = SpoolDraft()
            draft.materialID = id
            draft.color = Color(nsColor: NSColor(rgbHex: 0xC12E1F))
            $0.expect(draft.isValid, "\(id) is a real catalogue id and must be writable")
            $0.equal(try? draft.makeRecord().materialId, id, "\(id) survives into the record")
        }
    },

    // The alphabet is wider, not absent. A five-byte id is still five bytes, and punctuation is
    // still not an id — Core would take it (it only measures the width), so the form is the
    // only thing standing between a typo and a tag.
    test("the wider alphabet is still an alphabet") {
        var draft = SpoolDraft()
        draft.color = Color(nsColor: NSColor(rgbHex: 0xC12E1F))
        draft.materialID = "P100-"
        $0.expect(draft.validationIssues.contains("Material ID may contain only capital letters A-Z and the digits 0-9."),
                  "punctuation is refused")
        draft.materialID = "P100"
        $0.expect(draft.validationIssues.contains("Material ID must be exactly 5 characters (it is 4)."),
                  "and the width still holds")
    },
])

// MARK: - Write form prefill

/// What the write form remembers, and from which tag.
///
/// The tool owner's rule, in their words: the form opens blank, "however, pre-fill it with the
/// last tag that was read (not written) if there was one". Both halves are load-bearing — a form
/// that fills itself from thin air looks like a tag that was scanned, and a form that fills itself
/// from the app's own last write hands the next spool the serial of the one just tagged.
let writeFormPrefillTests = TestSuite(name: "Write form prefill", cases: [

    test("a form nobody has read a tag into stays blank") { t in
        runOnMain {
            let h = makeHarness()
            t.equal(h.model.prefill, nil)
            t.equal(h.model.draft.materialID, "", "no material out of thin air")
            t.expect(h.model.draft.color == nil, "and no colour: blue read as a tag that was read")
        }
    },

    test("a read fills the untouched form with the tag's values") { t in
        runOnMain {
            let h = makeHarness()
            guard let read = try? programmedRead(uid: tagA.uid, serial: "004212") else {
                t.expect(false, "fixture"); return
            }
            await h.model.adoptForTesting(read)
            t.equal(h.model.draft.materialID, "12345")
            t.equal(h.model.draftSourceUID, tagA.uid)
            t.expect(h.model.draft.color != nil, "the tag's colour comes across")
        }
    },

    // The serial is the one field that must NOT come across on its own. It is hidden, so this is
    // invisible on screen — which is exactly why it is pinned here.
    test("an automatic prefill takes everything except the serial") { t in
        runOnMain {
            let h = makeHarness()
            guard let read = try? programmedRead(uid: tagA.uid, serial: "004212") else {
                t.expect(false, "fixture"); return
            }
            await h.model.adoptForTesting(read)
            t.expect(h.model.draft.serialNumber != "004212",
                     "the next spool is a different spool; two spools must not share a serial")
            t.expect(h.model.draftCarriesFreshSerial, "and the form says so")
        }
    },

    // Asking for the tag's values by name is the "duplicate this tag" gesture — the spool's other
    // side, or a replacement for a damaged tag. Both have to carry the same serial.
    test("asking for the tag's values by name does take the serial") { t in
        runOnMain {
            let h = makeHarness()
            guard let read = try? programmedRead(uid: tagA.uid, serial: "004212") else {
                t.expect(false, "fixture"); return
            }
            await h.model.adoptForTesting(read)
            await h.model.applyPrefill()          // the "Use Tag Values" button
            t.equal(h.model.draft.serialNumber, "004212")
            t.expect(!h.model.draftCarriesFreshSerial)
        }
    },

    // The read-back a write takes of its own handiwork is a confirmation, not a scan.
    test("the tag this app just wrote does not become the form's memory") { t in
        runOnMain {
            let h = makeHarness()
            guard let scanned = try? programmedRead(uid: tagA.uid, serial: "004212"),
                  let written = try? programmedRead(uid: tagB.uid, serial: "008888",
                                                    materialId: "54321") else {
                t.expect(false, "fixture"); return
            }
            await h.model.adoptForTesting(scanned)
            // `prefillingDraft: false` is what `commitWrite` passes for its read-back.
            await h.model.adoptForTesting(written, prefillingDraft: false)

            t.equal(h.model.lastRead?.uid, tagB.uid, "the panel still shows what was read back")
            t.equal(h.model.prefill?.uid, tagA.uid,
                    "but the form remembers the tag the *user* read")
            t.equal(h.model.draft.materialID, "12345",
                    "and holds that tag's values, not the written one's")
        }
    },

    // Unchanged by any of the above, and the reason the rule is "untouched form" rather than
    // "always": Write → Read → Write has to come back to what the user composed.
    test("a form the user has edited is never overwritten by a read") { t in
        runOnMain {
            let h = makeHarness()
            h.model.draft.materialID = "99999"
            guard let read = try? programmedRead(uid: tagA.uid, serial: "004212") else {
                t.expect(false, "fixture"); return
            }
            await h.model.adoptForTesting(read)
            t.equal(h.model.draft.materialID, "99999")
            t.expect(h.model.prefill != nil, "the read is still offered as a button")
        }
    },

    // After a write the form gets a fresh serial for the next spool. That is the app changing the
    // form, not the user, and it must not count as an edit: it used to, so the provenance line
    // read "Edited — started from tag X" after every write and no later read was adopted until
    // Reset.
    test("the serial a write rotates in does not count as the user's edit") { t in
        runOnMain {
            let h = makeHarness()
            guard let read = try? programmedRead(uid: tagA.uid, serial: "004212"),
                  let next = try? programmedRead(uid: tagB.uid, serial: "008888",
                                                 materialId: "54321") else {
                t.expect(false, "fixture"); return
            }
            await h.model.adoptForTesting(read)
            t.expect(!h.model.draftIsEdited, "a form filled from a read is untouched")
            let before = h.model.draft.serialNumber
            h.model.rotateSerialAfterWriteForTesting()
            t.expect(h.model.draft.serialNumber != before, "the next spool gets its own serial")
            t.expect(!h.model.draftIsEdited, "and the form is still untouched")
            await h.model.adoptForTesting(next)
            t.equal(h.model.draft.materialID, "54321", "so the next read is still adopted")
        }
    },
])

// MARK: - Material cascade

let tagCascadeTests = TestSuite(name: "Tag screen material cascade", cases: [

    test("a brand with no materials clears the id, not just the label") { t in
        runOnMain {
            let h = makeHarness()
            h.model.draft.materialID = "00001"
            h.model.draft.materialLabel = "Creality · Hyper PLA"
            // The catalogue is never loaded in these tests, so every brand is empty — which is
            // exactly the case the cascade used to mishandle.
            h.model.selectVendor("Polymaker")
            t.equal(h.model.draft.materialLabel, "",
                     "the label must not survive the material it named")
            t.equal(h.model.draft.materialID, "",
                     "nor may the id keep pointing at the previous brand's material")
        }
    },

    test("an id the catalogue cannot name keeps the id and loses the label") { t in
        runOnMain {
            let h = makeHarness()
            h.model.draft.materialID = "99999"
            h.model.draft.materialLabel = "Creality · Hyper PLA"
            h.model.selectMaterial(id: "99999")
            t.equal(h.model.draft.materialID, "99999",
                     "a valid-looking id the catalogue does not carry is still the user's id")
            t.equal(h.model.draft.materialLabel, "",
                     "but nothing may claim to name it")
            t.expect(h.model.manualMaterialEntry,
                      "and the form falls back to manual entry rather than a dead picker")
        }
    },

    test("selecting nothing clears both halves of the material") { t in
        runOnMain {
            let h = makeHarness()
            h.model.draft.materialID = "00001"
            h.model.draft.materialLabel = "Creality · Hyper PLA"
            h.model.selectMaterial(nil)
            t.equal(h.model.draft.materialID, "")
            t.equal(h.model.draft.materialLabel, "")
        }
    },
])

// MARK: - autoWriteState

let tagAutoWriteStateTests = TestSuite(name: "Auto-write indicator", cases: [

    test("Read mode is always off") { t in
        runOnMain {
            let h = makeHarness()
            makeDraftWritable(h.model)
            t.equal(h.model.mode, .read)
            t.equal(h.model.autoWriteState, .off)
        }
    },

    test("the toggle being off is off") { t in
        runOnMain {
            let h = makeHarness()
            makeDraftWritable(h.model)
            h.model.autoWriteEnabled = false
            h.model.mode = .write
            t.equal(h.model.autoWriteState, .off)
        }
    },

    test("a form that cannot make a record is blocked, and names the problem") { t in
        runOnMain {
            let h = makeHarness()
            h.model.mode = .write
            t.equal(h.model.autoWriteState, .blocked("Enter a material ID."))
        }
    },

    test("a writable form with an empty reader is armed") { t in
        runOnMain {
            let h = makeHarness()
            h.model.mode = .write
            makeDraftWritable(h.model)
            t.equal(h.model.autoWriteState, .armed)
        }
    },

    test("a tag this app cannot write is not reported as armed") { t in
        runOnMain {
            let h = makeHarness()
            // Regression: `guard let card = …, card.isUsable else { return .armed }` folded
            // "no tag" and "a tag we can never write" into the same answer, so the panel said
            // "Ready — writing the tag on the reader" about a tag it would never touch.
            h.monitor.injectStateForTesting(.cardPresent(unsupportedTag))
            await h.model.settle()
            h.model.mode = .write
            makeDraftWritable(h.model)
            await h.model.settle()
            t.equal(h.model.autoWriteState, .unsupportedTag)
        }
    },

    test("a tag whose arming has been spent is handled") { t in
        runOnMain {
            let h = makeHarness()
            h.model.mode = .write
            makeDraftUnwritable(h.model)      // keeps the arrival away from a card session
            h.monitor.injectStateForTesting(.cardPresent(tagA))
            await h.model.settle()
            makeDraftWritable(h.model)
            t.equal(h.model.autoWriteState, .handled)
        }
    },

    test("an operation in flight is reported as busy, not as armed") { t in
        runOnMain {
            let h = makeHarness()
            h.model.mode = .write
            makeDraftWritable(h.model)
            await h.model.withActivityForTesting(.reading) {
                t.equal(h.model.autoWriteState, .busy("Reading tag…"))
            }
            t.equal(h.model.autoWriteState, .armed)
        }
    },

    // The "Write & verify" panel beside the form. Its rows used to key off `writeOutcome != nil`,
    // which is also true of a failure, so all five went green beside a red "Write Failed" card.
    test("the verify panel marks steps done only for a write that succeeded") { t in
        runOnMain {
            let failed = WriteVerifyStep.steps(outcome: .failed("card reset"),
                                               readback: nil, hasCard: true, canWrite: true)
            t.expect(!failed.contains { $0.state == "done" },
                     "a failed write completed nothing the panel can vouch for")

            guard let plan = try? samplePlan() else { t.expect(false, "fixture"); return }
            let box = SectorDumpBox()
            box.set([sector1Dump(key: .default, marker: 0xAA)])
            let summary = WriteSummary(writeResult(uid: plan.uid, backup: box.value,
                                                   wasAlreadyProgrammed: false, wroteTrailer: true),
                                       plan: plan, backup: box)
            let confirmed = WriteVerifyStep.steps(outcome: .succeeded(summary), readback: .confirmed,
                                                  hasCard: true, canWrite: true)
            t.expect(confirmed.allSatisfy { $0.state == "done" },
                     "a verified write completed every step")

            let unread = WriteVerifyStep.steps(outcome: .succeeded(summary),
                                               readback: .unavailable("the tag was lifted"),
                                               hasCard: true, canWrite: true)
            t.equal(unread[2].state, "done", "the write itself landed")
            t.equal(unread[3].state, "unconfirmed",
                    "but a read-back the app could not take is not reported as done")
        }
    },
])

// MARK: - Arrivals: arming, deferral, retry

// Read / identify is a *loop*: present a spool, check it, present the next, check that one again.
// Every other screen wants the opposite — one tag, one read — so the model's dedup is right there
// and wrong here, and `beginIdentification()` is what reconciles the two.
let identifyLoopTests = TestSuite(name: "Identify loop", cases: [

    test("beginning an identification forgets the last tag and its arming") { t in
        runOnMain {
            let h = makeHarness()
            await h.model.autoReadIfNeeded(card: tagA)
            await h.model.settle()
            // The reader is a stub here, so the read fails and releases its own arming; what
            // matters is that a retained record and a spent arming are both cleared, whichever
            // way they got set.
            guard let read = try? blankTagRead() else {
                t.expect(false, "could not build a fixture read"); return
            }
            await h.model.adoptForTesting(read)
            t.expect(h.model.lastRead != nil, "something is retained")
            t.expect(h.model.autoReadArmingForTesting != nil, "and the arming is spent")

            h.model.beginIdentification()
            t.equal(h.model.lastRead, nil, "the screen starts blank")
            t.equal(h.model.autoReadArmingForTesting, nil,
                    "and the same tag put back is read again rather than ignored")
            t.equal(h.model.mode, .read, "in read mode")
        }
    },

    test("the same tag re-presented is read again, which one read per tag would refuse") { t in
        runOnMain {
            let h = makeHarness()
            guard let read = try? blankTagRead() else {
                t.expect(false, "could not build a fixture read"); return
            }
            await h.model.adoptForTesting(read)
            guard let uid = t.unwrap(h.model.lastRead?.uid, "a retained uid") else { return }

            // This is the exact guard that made the screen look broken: `autoReadIfNeeded` skips a
            // card whose UID it already holds, so presenting the tag you had just written did
            // nothing at all.
            await h.model.autoReadIfNeeded(card: identity(uid))
            t.equal(h.model.activity, .idle, "refused, as designed everywhere else")

            h.model.beginIdentification()
            t.equal(h.model.lastRead, nil, "the loop clears first")
            t.equal(h.model.autoReadArmingForTesting, nil, "so the next presentation is not a repeat")
        }
    },

    test("clearing puts the screen back without needing a tag to do it") { t in
        runOnMain {
            let h = makeHarness()
            guard let read = try? blankTagRead() else {
                t.expect(false, "could not build a fixture read"); return
            }
            await h.model.adoptForTesting(read)
            t.expect(h.model.lastRead != nil, "something on screen")
            h.model.clearRetainedRead()
            t.equal(h.model.lastRead, nil, "and gone")
            t.equal(h.model.readFailure, nil, "along with any failure beside it")
        }
    },

    // ⌘R with a tag on the reader, then the identify screen re-appearing mid-read: the arrival is
    // deferred behind the read, the read itself then lands that tag, and the retry finds it
    // already read. The deferral has been overtaken and must not outlive that — it used to, and
    // in Write mode the Auto-Write card then said "Queued … will be written as soon as the read
    // finishes" about a tag nothing was going to write.
    test("a deferral the read itself satisfied does not outlive it") { t in
        runOnMain {
            let h = makeHarness()
            guard let read = try? programmedRead(uid: tagA.uid, serial: "004212") else {
                t.expect(false, "fixture"); return
            }
            await h.model.withActivityForTesting(.reading) {
                h.monitor.injectStateForTesting(.cardPresent(tagA))
                await h.model.settle()
                t.equal(h.model.deferredArrival?.uid, tagA.uid, "deferred behind the read")
                // The read in flight lands, the way `read()` lands it.
                await h.model.adoptForTesting(read)
            }
            await h.model.settle()
            t.equal(h.model.deferredArrival, nil,
                    "the retry found the tag already read; nothing is waiting any more")

            h.model.mode = .write
            makeDraftWritable(h.model)
            await h.model.settle()
            t.equal(h.model.autoWriteState, .handled,
                    "and the indicator does not promise a write that will never come")
        }
    },
])

let tagArrivalTests = TestSuite(name: "Tag arrivals", cases: [

    test("an auto-read that cannot run keeps its arming") { t in
        runOnMain {
            let h = makeHarness()
            t.equal(h.model.mode, .read)
            await h.model.withActivityForTesting(.writing) {
                await h.model.autoReadIfNeeded(card: tagA)
                // Regression: `autoReadUID = card.uid` was assigned *before* `read()`, whose first
                // line is the same busy guard. The arming was spent on a read that never
                // happened, and because the arming is keyed on the UID that tag was then never
                // read at all.
                t.equal(h.model.autoReadArmingForTesting, nil,
                         "the arming must not be spent by a read that did not happen")
                t.equal(h.model.deferredArrival?.uid, tagA.uid,
                         "and the arrival must be remembered rather than dropped")
            }
            // The reader is empty in this test, so the retry finds nothing and touches nothing.
            await h.model.settle()
        }
    },

    test("an auto-write that arrives mid-read is deferred, then written when the read ends") { t in
        runOnMain {
            let h = makeHarness()
            h.model.mode = .write
            makeDraftWritable(h.model)

            await h.model.withActivityForTesting(.reading) {
                h.monitor.injectStateForTesting(.cardPresent(tagA))
                await h.model.settle()
                t.equal(h.model.deferredArrival?.uid, tagA.uid,
                         "the arrival is recorded, not discarded")
                t.equal(h.model.autoWriteArmingForTesting, nil,
                         "and its arming is untouched, because nothing was written")
                t.equal(h.model.autoWriteState, .busy("Reading tag…"))
            }

            // Synchronous point: `activity` has fallen back to `.idle` and queued the retry, but
            // the retry is a task and this actor has not suspended, so it has not run yet. This
            // is the state the indicator used to render as "Ready — writing the tag on the
            // reader" for ever.
            t.equal(h.model.autoWriteState, .deferred("the read in progress finishes"))

            // Stop the retry short of a card session; spending the arming and reporting a
            // validation problem is the same observable "the retry ran".
            makeDraftUnwritable(h.model)
            await h.model.settle()

            t.equal(h.model.autoWriteArmingForTesting, tagA.uid,
                     "the deferred arrival was re-driven and its arming spent")
            t.equal(h.model.deferredArrival, nil, "and the deferral was consumed")
            t.expect(h.model.autoWriteSkipped != nil,
                      "the retry got far enough to report why it stopped")
        }
    },

    test("an open confirmation sheet defers an arrival instead of dropping it") { t in
        runOnMain {
            let h = makeHarness()
            h.model.mode = .write
            makeDraftWritable(h.model)
            guard let plan = try? samplePlan() else {
                t.expect(false, "could not build a plan from the card simulator")
                return
            }
            h.model.pendingPlan = plan
            await h.model.respondToCard(tagA)
            t.equal(h.model.deferredArrival?.uid, tagA.uid)
            t.equal(h.model.autoWriteArmingForTesting, nil,
                     "an arrival the sheet blocked has not been dealt with")
        }
    },

    test("card bookkeeping survives with no view on screen at all") { t in
        runOnMain {
            // The whole of finding 3: there is no `TagView` in this test and there never was, so
            // the only thing that can be keeping the model's card bookkeeping straight is the
            // model's own subscription. Selecting Materials in the real app is the same situation.
            let h = makeHarness()
            h.model.mode = .write
            makeDraftUnwritable(h.model)

            h.monitor.injectStateForTesting(.cardPresent(tagA))
            await h.model.settle()
            t.equal(h.model.autoWriteArmingForTesting, tagA.uid, "the arrival was seen")

            h.monitor.injectStateForTesting(.idle(devices: ["Mock Reader"], note: nil))
            await h.model.settle()
            t.equal(h.model.autoWriteArmingForTesting, nil, "the removal was seen")

            h.monitor.injectStateForTesting(.cardPresent(tagB))
            await h.model.settle()
            t.equal(h.model.autoWriteArmingForTesting, tagB.uid,
                     "and the next tag got an arming of its own rather than inheriting a stale one")
        }
    },

    test("a swap straight from one tag to another re-arms") { t in
        runOnMain {
            let h = makeHarness()
            h.model.mode = .write
            makeDraftUnwritable(h.model)
            h.monitor.injectStateForTesting(.cardPresent(tagA))
            await h.model.settle()
            h.monitor.injectStateForTesting(.cardPresent(tagB))   // no empty state in between
            await h.model.settle()
            t.equal(h.model.autoWriteArmingForTesting, tagB.uid)
        }
    },

    test("committing a write while the reader is held reports instead of doing nothing") { t in
        runOnMain {
            let h = makeHarness()
            guard let plan = try? samplePlan() else {
                t.expect(false, "could not build a plan from the card simulator")
                return
            }
            await h.model.withActivityForTesting(.reading) {
                await h.model.commitWrite(plan, allowTrailerWrite: false)
            }
            t.expect(h.toasts.current != nil,
                      "a swallowed click is what made the sheet look dead; it must say something")
            t.equal(h.model.writeOutcome, nil, "and it must not claim a write happened")
        }
    },

    // The user's instruction: "Blank tags do not need the confirmation."
    //
    // Programming a blank tag used to stop auto-write dead and raise the sheet unless an
    // "Allow writing sector keys (advanced)" preference had been found and ticked — two extra
    // clicks in front of tagging a new spool, which is the most ordinary thing this app does.
    // The authorisation now comes from the plan's own reading of the tag.
    test("a blank tag carries its own authorisation to be programmed") { t in
        runOnMain {
            guard let plan = try? samplePlan() else {
                t.expect(false, "could not build a plan from the card simulator")
                return
            }
            t.expect(plan.requiresTrailerWrite, "the simulator's card starts blank")
            t.equal(plan.currentCondition, .blank)
            t.expect(plan.isBlankTagProgramming,
                     "a blank tag has nothing to lose and needs no opt-in")
        }
    },

    // The narrow claim, so this cannot quietly become "always true". A tag that already holds a
    // record needs no trailer write at all, and must not be reported as if it authorised one.
    test("a programmed tag authorises no trailer write") { t in
        runOnMain {
            guard let current = try? programmedRead(uid: tagA.uid, serial: "004212"),
                  let record = try? SpoolRecord(materialId: "12345",
                                                colorRGB: "c12e1f",
                                                filamentLength: .kg1,
                                                serialNumber: "009999") else {
                t.expect(false, "fixture")
                return
            }
            let plan = TagViewModel.makePlan(current: current,
                                             record: record,
                                             materialLabel: "Creality · Hyper PLA",
                                             printerTypeString: "K2")
            t.expect(!plan.requiresTrailerWrite)
            t.expect(!plan.isBlankTagProgramming)
        }
    },

    // The state between those two: blocks 4–6 written, the tag lifted before block 7. Sector 1
    // still opens with the factory key *and* a record decodes. Core authorises the trailer write
    // on the key alone, so the UI must too — gating on `.blank` as well made this tag a permanent
    // dead end: "Program Tag" on the sheet, and "this tag is blank…" from Core on every press.
    test("a half-programmed tag is authorised, and the sheet says what it is") { t in
        runOnMain {
            guard let current = try? programmedRead(uid: tagA.uid, serial: "004212",
                                                    isProgrammed: false),
                  let record = try? SpoolRecord(materialId: "12345",
                                                colorRGB: "c12e1f",
                                                filamentLength: .kg1,
                                                serialNumber: "009999") else {
                t.expect(false, "fixture")
                return
            }
            let plan = TagViewModel.makePlan(current: current,
                                             record: record,
                                             materialLabel: "Creality · Hyper PLA",
                                             printerTypeString: "K2")
            t.expect(plan.requiresTrailerWrite, "sector 1 is still on the factory key")
            t.expect(plan.currentCondition.record != nil, "and yet a record decoded")
            t.expect(plan.isBlankTagProgramming,
                     "authorised on the condition Core checks — the key, not the record")
            t.expect(plan.isInterruptedProgramming)
            let subtitle = WriteConfirmationSheet.subtitle(for: plan)
            t.expect(subtitle.contains("keys were never written"),
                     "the sheet must call this tag neither blank nor programmed: \(subtitle)")
            t.expect(subtitle.contains("overwrites that record"),
                     "and must say the record on it goes: \(subtitle)")
        }
    },

    // `ReaderMonitor.withCard` re-runs the whole write closure on a stale card handle, so the
    // backup callback can fire twice — the second time against a tag the first attempt may
    // already have written to. The box is what keeps the first, genuine, pre-write dump.
    test("the backup box keeps the first attempt's dump, not the retry's") { t in
        let box = SectorDumpBox()
        t.equal(box.attempts, 0)
        t.expect(!box.firstAttemptFoundFactoryKey, "nothing known yet")
        box.set([sector1Dump(key: .default, marker: 0xAA)])
        box.set([sector1Dump(key: derivedKeyFixture, marker: 0xBB)])   // the retry, mid-write
        t.equal(box.attempts, 2)
        t.equal(box.value.first?.blocks[4]?.first, 0xAA, "the first dump is the pre-write state")
        t.expect(box.firstAttemptFoundFactoryKey)
    },

    test("a retry that found the keys already written still reports the trailer write") { t in
        runOnMain {
            guard let plan = try? samplePlan() else { t.expect(false, "fixture"); return }
            let box = SectorDumpBox()
            box.set([sector1Dump(key: .default, marker: 0xAA)])
            let retryDump = [sector1Dump(key: derivedKeyFixture, marker: 0xBB)]
            box.set(retryDump)
            // What Core returns from the *second* attempt: it authenticated with the derived key
            // the first attempt wrote, so as far as it knows nothing rewrote the trailer.
            let result = writeResult(uid: plan.uid, backup: retryDump,
                                     wasAlreadyProgrammed: true, wroteTrailer: false)
            let summary = WriteSummary(result, plan: plan, backup: box)
            t.expect(summary.wroteTrailer,
                     "the keys were written by this commit, whichever attempt did it")
            t.expect(!summary.wasAlreadyProgrammed)
            t.expect(summary.blocksWritten.contains(7), "and the trailer block is listed")
            t.expect(summary.backupDump.contains("AA AA"),
                     "the dump offered to the user is the pre-write one")
            t.expect(!summary.backupDump.contains("BB BB"), "not the half-written tag's")
        }
    },

    // The flake Core documents: the dump saw the factory key and the authentication a moment
    // later saw the derived key. With no retry, nothing this commit did changed the keys, and
    // Core's own answer stands.
    test("a single attempt trusts Core's own answer about the trailer") { t in
        runOnMain {
            guard let plan = try? samplePlan() else { t.expect(false, "fixture"); return }
            let box = SectorDumpBox()
            box.set([sector1Dump(key: .default, marker: 0xAA)])
            let result = writeResult(uid: plan.uid, backup: box.value,
                                     wasAlreadyProgrammed: true, wroteTrailer: false)
            let summary = WriteSummary(result, plan: plan, backup: box)
            t.expect(!summary.wroteTrailer)
            t.expect(summary.wasAlreadyProgrammed)
            t.expect(!summary.blocksWritten.contains(7))
        }
    },

    test("⇧⌘W with an unwritable form shows the form and says why, without a card session") { t in
        runOnMain {
            let h = makeHarness()
            t.equal(h.model.mode, .read)
            await h.model.prepareWrite()
            t.equal(h.model.mode, .write, "the form the complaint is about has to be visible")
            t.equal(h.model.pendingPlan, nil)
            t.expect(h.toasts.current != nil)
        }
    },
])

// MARK: - ReaderMonitor

let readerMonitorBusyTests = TestSuite(name: "Reader monitor", cases: [

    test("overlapping card operations keep the reader claimed until the last one ends") { t in
        runOnMain {
            let monitor = ReaderMonitor()
            t.equal(monitor.busyDepth, 0)
            await monitor.withReaderClaimed {
                t.equal(monitor.busyDepth, 1)
                t.expect(monitor.isBusy)
                await monitor.withReaderClaimed {
                    t.equal(monitor.busyDepth, 2, "a second claim nests, it does not replace")
                }
                // Regression: `isBusy` was a plain `Bool`, so the inner operation finishing
                // cleared it and let presence polling resume underneath the outer one.
                t.equal(monitor.busyDepth, 1)
                t.expect(monitor.isBusy, "the outer operation still holds the reader")
            }
            t.equal(monitor.busyDepth, 0)
            t.expect(!monitor.isBusy)
        }
    },

    test("an arrival raises the insertion count once, and a swap raises it again") { t in
        runOnMain {
            let monitor = ReaderMonitor()
            let before = monitor.insertionCount
            monitor.injectStateForTesting(.cardPresent(tagA))
            t.equal(monitor.insertionCount, before + 1)
            monitor.injectStateForTesting(.cardPresent(tagA))   // republished, same tag
            t.equal(monitor.insertionCount, before + 1)
            monitor.injectStateForTesting(.cardPresent(tagB))
            t.equal(monitor.insertionCount, before + 2)
        }
    },

    test("stopping releases the context synchronously and is safe to repeat") { t in
        runOnMain {
            // `stop()` used to end in `Task { await engine.shutdown() }`, which never runs when
            // the caller is `applicationWillTerminate`. If the synchronous replacement could
            // deadlock, this case would hang rather than fail — which is the point.
            let monitor = ReaderMonitor()
            monitor.stop()
            monitor.stop()
            t.expect(true, "stop() returned")
        }
    },
])

// The "—" row both write-form pickers start on.
let writeFormPlaceholderTests = TestSuite(name: "Write form placeholder rows", cases: [

    test("choosing “no material” clears rather than switching to manual entry") { t in
        runOnMain {
            let h = makeHarness()
            await h.model.prepareCatalog()
            h.model.selectMaterial(id: "")
            // The empty id is the picker's own placeholder, not an id the catalogue failed to
            // recognise. Treating the two alike would make "no material yet" silently change how
            // the whole field behaves.
            t.expect(!h.model.manualMaterialEntry,
                     "the form stays on the picker, not in manual entry")
            t.equal(h.model.draft.materialID, "", "and nothing is selected")
            t.equal(h.model.draft.materialLabel, "", "nor named")
        }
    },

    test("choosing “no brand” clears the material with it") { t in
        runOnMain {
            let h = makeHarness()
            await h.model.prepareCatalog()
            h.model.selectVendor("")
            t.equal(h.model.selectedVendor, "", "no brand")
            t.equal(h.model.draft.materialID, "",
                    "and no material — reaching for the first of an unset brand would be a guess")
            t.expect(!h.model.manualMaterialEntry, "still on the picker")
        }
    },

    test("an id the catalogue really does not know still means manual entry") { t in
        runOnMain {
            let h = makeHarness()
            await h.model.prepareCatalog()
            h.model.selectMaterial(id: "99999")
            // The distinction the placeholder row must not blur: this one *is* a typed id.
            t.expect(h.model.manualMaterialEntry, "unknown id keeps the manual path")
        }
    },

    // Creality's list by default - the brand, and only the brand. The alphabetical first brand is
    // now Anycubic, which is not what a Creality tag writer should open on; but a material chosen
    // for you is a material a hasty or automatic write puts on the tag, so that stays unset.
    test("the Write tab opens on Creality, with no material chosen") { t in
        runOnMain {
            let h = makeHarness()
            await h.model.prepareCatalog()
            guard h.model.catalog.isReady else {
                t.record("no K2 catalogue to open on", file: #file, line: #line); return
            }
            t.equal(h.model.selectedVendor, "Creality", "Creality's list, by default")
            t.equal(h.model.draft.materialID, "",
                    "but no material - a default one could be written to a tag unseen")
            t.expect(!h.model.manualMaterialEntry, "on the picker, not manual entry")
        }
    },
])
