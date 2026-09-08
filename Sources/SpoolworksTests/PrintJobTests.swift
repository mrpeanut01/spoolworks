import Foundation
@testable import SpoolworksCore

// The real thing: 63 samples captured off a K2 Plus while a print started from T1A.
private struct CapturedSample: Decodable {
    let wall: String
    let state: String?
    let filename: String?
    let filament_used: Double?
    let slot: String?
}

private struct Capture: Decodable {
    let slotUnderTest: String
    let samples: [CapturedSample]
}

private func loadCapture(_ t: TestContext) -> Capture? {
    guard let url = Bundle.module.url(forResource: "printer-k2plus-print-start",
                                      withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let capture = try? JSONDecoder().decode(Capture.self, from: data) else {
        t.record("print-start fixture missing", file: #file, line: #line)
        return nil
    }
    return capture
}

private func snapshot(_ s: CapturedSample) -> PrintJobSnapshot {
    PrintJobSnapshot(filename: s.filename ?? "",
                     state: PrintJobSnapshot.State(rawValue: s.state ?? "standby") ?? .standby,
                     filamentUsedMillimetres: s.filament_used ?? 0,
                     feedingSlot: (s.slot == nil || s.slot == "None") ? nil : "T1" + s.slot!)
}

// MARK: - Geometry

let filamentGeometryTests = TestSuite(name: "Filament geometry", cases: [

    // filament_used is a length; a spool is bought and weighed by mass.
    test("1.75 mm PLA converts length to mass") { t in
        // π × 0.875² × 1000 mm = 2405.28 mm³ = 2.405 cm³ × 1.24 g/cm³ = 2.983 g
        let grams = FilamentGeometry.grams(forMillimetres: 1000,
                                           diameterMillimetres: 1.75,
                                           densityGramsPerCubicCentimetre: 1.24)
        t.expect(abs(grams - 2.983) < 0.002, "a metre of PLA is about 2.98 g, got \(grams)")
    },

    // The observed print had pulled 293.83 mm when the capture window ended.
    test("the captured print's consumption is about 0.88 g") { t in
        let grams = FilamentGeometry.grams(forMillimetres: 293.83,
                                           diameterMillimetres: 1.75,
                                           densityGramsPerCubicCentimetre: 1.24)
        t.expect(abs(grams - 0.876) < 0.01, "got \(grams)")
    },

    // Diameter is squared, so assuming 1.75 for 2.85 stock is out by 2.65×, not 1.6×.
    test("diameter matters more than it looks") { t in
        let thin = FilamentGeometry.grams(forMillimetres: 1000, diameterMillimetres: 1.75,
                                          densityGramsPerCubicCentimetre: 1.24)
        let thick = FilamentGeometry.grams(forMillimetres: 1000, diameterMillimetres: 2.85,
                                           densityGramsPerCubicCentimetre: 1.24)
        t.expect(abs(thick / thin - 2.652) < 0.01, "ratio is the square of the diameters")
    },

    test("nonsense inputs produce zero rather than a NaN") { t in
        t.equal(FilamentGeometry.grams(forMillimetres: -5, diameterMillimetres: 1.75,
                                       densityGramsPerCubicCentimetre: 1.24), 0, "negative length")
        t.equal(FilamentGeometry.grams(forMillimetres: 100, diameterMillimetres: 0,
                                       densityGramsPerCubicCentimetre: 1.24), 0, "no diameter")
        t.equal(FilamentGeometry.grams(forMillimetres: 100, diameterMillimetres: 1.75,
                                       densityGramsPerCubicCentimetre: 0), 0, "no density")
    },
])

// MARK: - Tracking

let printJobTrackerTests = TestSuite(name: "Print job tracker", cases: [

    // The whole point: replaying the real capture must total the real consumption, no more.
    test("replaying the captured print charges T1A exactly what was extruded") { t in
        guard let capture = loadCapture(t) else { return }
        var tracker = PrintJobTracker()
        var charged: [String: Double] = [:]

        for sample in capture.samples {
            if let charge = tracker.accept(snapshot(sample)) {
                charged[charge.slot, default: 0] += charge.millimetres
            }
        }

        let peak = capture.samples.compactMap(\.filament_used).max() ?? 0
        t.equal(Set(charged.keys), [capture.slotUnderTest], "only the feeding slot was charged")
        let total = charged[capture.slotUnderTest] ?? 0
        // The total must equal the high-water mark: not the sum of raw deltas (which would
        // over-count the un-retractions) and not less (which would drop the purge).
        t.expect(abs(total - peak) < 0.001,
                 "charged \(total) mm against a high-water mark of \(peak) mm")
    },

    // filament_used dips constantly. Differencing consecutive readings records filament flowing
    // back onto the spool.
    test("a retraction is not consumption, and the un-retraction is not counted twice") { t in
        var tracker = PrintJobTracker()
        func step(_ used: Double) -> Double {
            tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                            filamentUsedMillimetres: used,
                                            feedingSlot: "T1A"))?.millimetres ?? 0
        }
        t.equal(step(100), 100, "first reading")
        t.equal(step(104), 4, "advanced")
        t.equal(step(102), 0, "retracted — nothing consumed")
        t.equal(step(104), 0, "back to where it was — still nothing new")
        t.equal(step(110), 6, "only the genuine advance beyond the high-water mark")
    },

    // The slot is nil for the first minute. That filament still left a spool.
    test("consumption before the slot is named is held, then attributed") { t in
        var tracker = PrintJobTracker()
        let early = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                                    filamentUsedMillimetres: 14,
                                                    feedingSlot: nil))
        t.expect(early == nil, "nothing chargeable yet")
        t.equal(tracker.unattributedMillimetres, 14, "but it is held, not dropped")

        let charge = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                                     filamentUsedMillimetres: 50,
                                                     feedingSlot: "T1A"))
        t.equal(charge?.slot, "T1A", "attributed once the slot appears")
        t.equal(charge?.millimetres, 50, "including the 14 mm of purge")
    },

    // filament_used resets to 0 on a new job; differencing across that boundary reports a large
    // negative.
    test("a new job restarts the counter instead of reporting a negative") { t in
        var tracker = PrintJobTracker()
        _ = tracker.accept(PrintJobSnapshot(filename: "first.gcode", state: .printing,
                                            filamentUsedMillimetres: 900, feedingSlot: "T1A"))
        let charge = tracker.accept(PrintJobSnapshot(filename: "second.gcode", state: .printing,
                                                     filamentUsedMillimetres: 12,
                                                     feedingSlot: "T1A"))
        t.equal(charge?.millimetres, 12, "the new job starts from zero")
        t.equal(charge?.jobName, "second.gcode", "and is named correctly")
    },

    test("finishing a job clears the tracker") { t in
        var tracker = PrintJobTracker()
        _ = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                            filamentUsedMillimetres: 500, feedingSlot: "T1A"))
        let done = tracker.accept(PrintJobSnapshot(filename: "", state: .complete,
                                                   filamentUsedMillimetres: 0, feedingSlot: nil))
        t.expect(done == nil, "nothing charged on completion")
        t.equal(tracker.highWaterMillimetres, 0, "counters cleared")
        t.expect(tracker.jobKey == nil, "no job")
    },

    // Auto-refill hands over mid-job. What was drawn before the handover belongs to the old spool.
    test("a slot handover charges the outgoing slot before the new one starts") { t in
        var tracker = PrintJobTracker()
        _ = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                            filamentUsedMillimetres: 100, feedingSlot: "T1B"))
        // Draw more, then hand over to the partner slot in the same reading.
        let charge = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                                     filamentUsedMillimetres: 160,
                                                     feedingSlot: "T1D"))
        t.equal(charge?.slot, "T1B", "the 60 mm drawn before the handover is T1B's")
        t.equal(charge?.millimetres, 60, "amount")

        let next = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                                   filamentUsedMillimetres: 200,
                                                   feedingSlot: "T1D"))
        t.equal(next?.slot, "T1D", "and what follows is T1D's")
        t.equal(next?.millimetres, 40, "amount")
    },

    test("a paused job keeps its counters — it is not over") { t in
        var tracker = PrintJobTracker()
        _ = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                            filamentUsedMillimetres: 300, feedingSlot: "T1A"))
        _ = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .paused,
                                            filamentUsedMillimetres: 300, feedingSlot: "T1A"))
        t.equal(tracker.highWaterMillimetres, 300, "kept across the pause")
        let resumed = tracker.accept(PrintJobSnapshot(filename: "job.gcode", state: .printing,
                                                      filamentUsedMillimetres: 340,
                                                      feedingSlot: "T1A"))
        t.equal(resumed?.millimetres, 40, "and only the new draw is charged")
    },
])

// MARK: - Moonraker parsing

let moonrakerTests = TestSuite(name: "Moonraker parsing", cases: [

    // The shape observed live, including the field that is NOT the answer.
    test("the feeding slot comes from box.T1.filament, not filament_detected") { t in
        let json = """
        {"result": {"status": {
          "print_stats": {"filename": "lid.stl_PLA_29m0s.gcode", "state": "printing",
                          "filament_used": 405.39},
          "box": {"filament": 1, "state": "connect",
                  "T1": {"state": "connect", "filament": "A", "filament_detected": "None", "mode": "2"},
                  "T2": {"state": "None", "filament": "None"}}
        }}}
        """
        let snapshot = try MoonrakerClient.decode(Data(json.utf8))
        t.equal(snapshot.feedingSlot, "T1A", "box key plus the slot letter")
        t.equal(snapshot.state, .printing, "state")
        t.equal(snapshot.filename, "lid.stl_PLA_29m0s.gcode", "filename")
        t.equal(snapshot.filamentUsedMillimetres, 405.39, "length")
        t.equal(snapshot.jobKey, "lid.stl_PLA_29m0s.gcode", "job key")
    },

    test("an idle printer names no slot and no job") { t in
        let json = """
        {"result": {"status": {
          "print_stats": {"filename": "", "state": "standby", "filament_used": 0.0},
          "box": {"T1": {"state": "connect", "filament": "None"}}
        }}}
        """
        let snapshot = try MoonrakerClient.decode(Data(json.utf8))
        t.expect(snapshot.feedingSlot == nil, "no slot feeding")
        t.expect(snapshot.jobKey == nil, "no job")
        t.expect(!snapshot.state.isActive, "not active")
    },

    test("a printer with no box object at all still parses") { t in
        let json = """
        {"result": {"status": {"print_stats": {"filename": "a.gcode", "state": "printing",
                                               "filament_used": 12.0}}}}
        """
        let snapshot = try MoonrakerClient.decode(Data(json.utf8))
        t.expect(snapshot.feedingSlot == nil, "no CFS, so no slot")
        t.equal(snapshot.filamentUsedMillimetres, 12.0, "consumption is still readable")
    },

    test("a response that is not Moonraker's shape is rejected") { t in
        t.throwsError("decoding junk") { _ = try MoonrakerClient.decode(Data("{}".utf8)) }
    },
])

// MARK: - Deducting from a spool

let spoolConsumptionTests = TestSuite(name: "Spool consumption", cases: [

    test("consuming grams deducts and records the job") { t in
        var spool = Spool(brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                          colorHex: "101010", netWeightGrams: 1000, remainingPercent: 99)
        spool.consume(grams: 42, detail: "job lid.stl_PLA_29m0s.gcode")
        t.expect(abs(spool.remainingPercent - 94.8) < 0.001, "99% less 4.2%")
        t.equal(spool.usage.first?.kind, .job, "recorded as a job")
        t.expect(abs((spool.usage.first?.deltaGrams ?? 0) + 42) < 0.001, "the amount consumed")
        t.equal(spool.usage.first?.amountLabel, "−42 g", "label")
    },

    // A spool cannot give up more than it holds, and the log must not claim it did.
    test("consuming past empty clamps, and the line reports only what was there") { t in
        var spool = Spool(brand: "X", name: "Y", materialType: "PLA", colorHex: "FFFFFF",
                          netWeightGrams: 1000, remainingPercent: 3)
        spool.consume(grams: 500, detail: "job big.gcode")
        t.equal(spool.remainingPercent, 0, "empty, not negative")
        t.expect(abs((spool.usage.first?.deltaGrams ?? 0) + 30) < 0.001,
                 "only the 30 g that were actually left")
    },

    // A poll every few seconds would otherwise write hundreds of lines for one print, each
    // rounding to "0 g" — which is exactly what the live run produced before this.
    test("repeated charges for one job coalesce into a single growing line") { t in
        var spool = Spool(brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                          colorHex: "101010", netWeightGrams: 1000, remainingPercent: 99)
        for _ in 0..<40 {
            spool.consume(grams: 0.3, detail: "job lid.stl_PLA_29m0s.gcode")
        }
        t.equal(spool.usage.count, 1, "one line, not forty")
        guard let entry = t.unwrap(spool.usage.first, "entry") else { return }
        t.expect(abs(entry.deltaGrams + 12) < 0.001, "40 × 0.3 g = 12 g, got \(entry.deltaGrams)")
        t.equal(entry.amountLabel, "−12 g", "displayed as whole grams")
        t.expect(abs(spool.remainingPercent - 97.8) < 0.001, "and the figure moved with it")
    },

    // Sub-gram charges are the normal case at a 5 s poll; an Int would round every one to nothing.
    test("a sub-gram charge is recorded rather than rounded away") { t in
        var spool = Spool(brand: "X", name: "Y", materialType: "PLA", colorHex: "FFFFFF",
                          netWeightGrams: 1000, remainingPercent: 100)
        spool.consume(grams: 0.4, detail: "job tiny.gcode")
        guard let entry = t.unwrap(spool.usage.first, "entry") else { return }
        t.expect(abs(entry.deltaGrams + 0.4) < 0.0001, "held at full precision")
        t.equal(entry.amountLabel, "−0.4 g", "and shown with a decimal below 10 g")
    },

    test("a different job starts a new line") { t in
        var spool = Spool(brand: "X", name: "Y", materialType: "PLA", colorHex: "FFFFFF",
                          netWeightGrams: 1000, remainingPercent: 100)
        spool.consume(grams: 5, detail: "job a.gcode")
        spool.consume(grams: 3, detail: "job b.gcode")
        t.equal(spool.usage.count, 2, "two jobs, two lines")
        t.equal(spool.usage[0].detail, "job b.gcode", "newest first")
    },

    test("a zero or negative consumption writes nothing") { t in
        var spool = Spool(brand: "X", name: "Y", materialType: "PLA", colorHex: "FFFFFF",
                          remainingPercent: 50)
        spool.consume(grams: 0, detail: "noop")
        spool.consume(grams: -10, detail: "noop")
        t.equal(spool.usage.count, 0, "no history")
        t.equal(spool.remainingPercent, 50, "unchanged")
    },

    // The CFS is coarse (1% = 10 g) and the job is fine. Both are recorded; the poll corrects.
    test("a CFS poll after a job overwrites the estimate with a measurement") { t in
        var spool = Spool(brand: "X", name: "Y", materialType: "PLA", colorHex: "FFFFFF",
                          netWeightGrams: 1000, remainingPercent: 99)
        spool.consume(grams: 6, detail: "job a.gcode")
        t.expect(abs(spool.remainingPercent - 98.4) < 0.001, "estimated")

        spool.record(percent: 99, kind: .cfsPoll, detail: "CFS poll · T1A")
        t.equal(spool.remainingPercent, 99, "the measurement wins")
        t.expect(abs((spool.usage.first?.deltaGrams ?? 0) - 6) < 0.001,
                 "and the correction is visible, not hidden")
        t.equal(spool.usage.count, 2, "both events on the record")
    },
])


// MARK: - The CFS must not undo job tracking

// Observed live over an hour: a 20 g print moved the app's figure repeatedly, and every 30 s poll
// put it straight back, because remainLen for that slot never left "99". 1 % is 10 g on a 1 kg
// spool, so the CFS cannot see a print this size at all — and comparing its reading against the
// app's finer figure read "unchanged CFS" as "the app has drifted".
let cfsVersusJobTests = TestSuite(name: "CFS versus job tracking", cases: [

    test("an unchanged CFS reading does not undo job consumption") { t in
        let slot = CFSSlot(materialId: "A", remainLen: "99", filamentId: "101001",
                           brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                           venderId: "0276", color: "#0000000", filamentLen: "0330",
                           serialNum: "000001", rfid: 2)
        let info = MaterialBoxInfo(material: MaterialSection(
            state: "connect",
            info: [CFSBox(boxID: "T1", state: "connect", list: [slot])]))

        var inventory = SpoolInventory()
        inventory.reconcile(with: info)
        guard var spool = t.unwrap(inventory.active.first, "discovered spool") else { return }
        t.equal(spool.remainingPercent, 99, "starts at the measured figure")

        // A 20 g print, deducted as the job runs.
        spool.consume(grams: 20.27, detail: "job lid.stl_PLA_29m0s.gcode")
        inventory.update(spool)
        t.expect(abs(inventory.active[0].remainingPercent - 96.973) < 0.01, "job moved the figure")

        // The CFS still says 99 — it cannot resolve 20 g. Three more polls.
        for _ in 0..<3 { inventory.reconcile(with: info) }

        t.expect(abs(inventory.active[0].remainingPercent - 96.973) < 0.01,
                 "the unchanged reading left it alone, got \(inventory.active[0].remainingPercent)")
        t.equal(inventory.active[0].usage.filter { $0.kind == .cfsPoll }.count, 0,
                "and wrote no corrections")
    },

    // The flip side: a reading that genuinely moves is a real measurement and must win.
    test("a CFS reading that actually changes is taken as the truth") { t in
        func info(_ remain: String) -> MaterialBoxInfo {
            MaterialBoxInfo(material: MaterialSection(state: "connect", info: [
                CFSBox(boxID: "T1", state: "connect", list: [
                    CFSSlot(materialId: "A", remainLen: remain, filamentId: "101001",
                            brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                            venderId: "0276", color: "#0000000", filamentLen: "0330",
                            serialNum: "000001", rfid: 2)])]))
        }
        var inventory = SpoolInventory()
        inventory.reconcile(with: info("99"))
        guard var spool = t.unwrap(inventory.active.first, "spool") else { return }
        spool.consume(grams: 20.27, detail: "job a.gcode")
        inventory.update(spool)

        // The spool has drawn enough for the CFS to finally notice. 97 confirms the estimate of
        // 96.973 to within 0.03 %, so there is nothing to correct — and writing "+0.3 g" would be
        // churn, not information. The reading is still remembered.
        inventory.reconcile(with: info("97"))
        t.expect(abs(inventory.active[0].remainingPercent - 96.973) < 0.01,
                 "a measurement that agrees leaves the finer figure alone")
        t.equal(inventory.active[0].usage.filter { $0.kind == .cfsPoll }.count, 0,
                "and writes no line")
        t.equal(inventory.active[0].lastCFSPercent, 97, "but the raw reading is remembered")
    },

    // The case the correction exists for: the spool was swapped, unloaded and refilled, or the
    // estimate simply drifted. A materially different measurement must overwrite it.
    test("a measurement that materially disagrees overwrites the estimate") { t in
        func info(_ remain: String) -> MaterialBoxInfo {
            MaterialBoxInfo(material: MaterialSection(state: "connect", info: [
                CFSBox(boxID: "T1", state: "connect", list: [
                    CFSSlot(materialId: "A", remainLen: remain, filamentId: "101001",
                            brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                            venderId: "0276", color: "#0000000", filamentLen: "0330",
                            serialNum: "000001", rfid: 2)])]))
        }
        var inventory = SpoolInventory()
        inventory.reconcile(with: info("99"))
        guard var spool = t.unwrap(inventory.active.first, "spool") else { return }
        spool.consume(grams: 20.27, detail: "job a.gcode")
        inventory.update(spool)

        // The CFS now reports far less than the estimate — something happened off-book.
        inventory.reconcile(with: info("60"))
        t.equal(inventory.active[0].remainingPercent, 60, "the measurement wins")
        t.equal(inventory.active[0].usage.first?.kind, .cfsPoll, "and the correction is recorded")
        t.expect((inventory.active[0].usage.first?.deltaGrams ?? 0) < 0,
                 "as a loss, since the spool holds less than we thought")
    },

    test("the remembered reading is what a poll is compared against, not our figure") { t in
        let spool = Spool(identity: SpoolIdentity(vendorId: "0276", filamentId: "101001",
                                                  colorHex: "000000", serialNumber: "000001"),
                          brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                          colorHex: "000000", netWeightGrams: 1000,
                          remainingPercent: 90, location: .cfs(box: "T1", slot: "A"),
                          lastCFSPercent: 99)
        var inventory = SpoolInventory(spools: [spool])
        let info = MaterialBoxInfo(material: MaterialSection(state: "connect", info: [
            CFSBox(boxID: "T1", state: "connect", list: [
                CFSSlot(materialId: "A", remainLen: "99", filamentId: "101001",
                        brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                        venderId: "0276", color: "#0000000", filamentLen: "0330",
                        serialNum: "000001", rfid: 2)])]))

        let report = inventory.reconcile(with: info)
        t.equal(inventory.active[0].remainingPercent, 90,
                "a 9-point gap is ignored because the measurement itself did not move")
        t.expect(report.isEmpty, "nothing reported as changed")
    },
])
