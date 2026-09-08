import Foundation
import SwiftUI
import Combine
import SpoolworksCore

/// The Printer & CFS screen's state: poll the printer, hold the last snapshot, fold it into the
/// inventory.
///
/// ## The design's "CFS units attached" picker is not built as a picker
///
/// The prototype offers a None/1/2/3/4 segmented control that switches the mock between layouts.
/// That is a mockup device: how many CFS units are attached is a fact the printer reports in
/// `material_box_info.json`, not a setting. Building it as a control would let the user assert
/// something false about their own hardware and would then have to be ignored. The strip keeps its
/// designed position and typography and shows the **measured** figure instead — box count, slot
/// count, how many are loaded — beside the Poll now action. Every layout the picker was there to
/// demonstrate (no CFS, one box, several) still renders; it renders when the printer says so.
@MainActor
final class CFSViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case polling
        case loaded(Date)
        case failed(String)

        var isPolling: Bool { self == .polling }
    }

    @Published private(set) var info: MaterialBoxInfo?
    @Published private(set) var state: State = .idle
    /// Poll on a timer while the screen is showing. The design's kicker says "every 30 s".
    @Published var autoPoll = true

    /// The last reconciliation, so the screen can say what a poll changed.
    @Published private(set) var lastReport: SpoolInventory.ReconcileReport?

    /// The printer's current job, if any.
    @Published private(set) var job: PrintJobSnapshot?
    /// Grams charged to spools since the screen opened, for the job banner.
    @Published private(set) var chargedThisSession: Double = 0
    /// Grams drawn from a slot that has no spool in stock **yet**, held per slot.
    ///
    /// The job poll runs every 5 s and the CFS poll every 30 s, so on a cold start the printer is
    /// seen drawing filament before the inventory knows which spool is in the slot. Dropping that
    /// would lose real consumption; reporting it forever would be noise. It is held and flushed
    /// the moment the spool appears.
    @Published private(set) var pendingGrams: [String: Double] = [:]

    var unattributedGrams: Double { pendingGrams.values.reduce(0, +) }

    static let pollInterval: TimeInterval = 30
    /// Jobs are polled far more often than the CFS: it is a plain HTTP GET rather than an `ssh`
    /// process, and `filament_used` moves continuously where `remainLen` moves in 1 % steps —
    /// 10 g at a time on a 1 kg spool.
    static let jobPollInterval: TimeInterval = 5
    /// How long to wait before looking again when there is nothing to poll yet.
    static let retryInterval: TimeInterval = 5

    private let transport: PrinterTransporting
    private let jobReader: PrintJobReading
    /// Turns the stream of job snapshots into chargeable consumption. See ``PrintJobTracker`` for
    /// the three things that make this harder than subtracting two numbers.
    private var tracker = PrintJobTracker()
    private var jobTimer: Task<Void, Never>?
    // Strong for the same reason as IntakeViewModel's collaborators: no cycle exists, and
    // `unowned` only made short-lived callers crash.
    private let printers: PrinterViewModel
    private let inventory: InventoryViewModel
    private var timer: Task<Void, Never>?

    init(transport: PrinterTransporting,
         printers: PrinterViewModel,
         inventory: InventoryViewModel,
         jobReader: PrintJobReading = MoonrakerClient()) {
        self.transport = transport
        self.printers = printers
        self.inventory = inventory
        self.jobReader = jobReader
    }

    deinit {
        timer?.cancel()
        jobTimer?.cancel()
    }

    // MARK: Target

    /// The printer to poll: the selected one, else the only configured one.
    ///
    /// Deliberately does not guess when several are configured and none is selected — polling the
    /// wrong printer would silently reconcile the inventory against another machine's slots.
    var target: PrinterConfiguration? {
        if let selection = printers.selection,
           let match = printers.printers.first(where: { $0.family == selection }) {
            return match
        }
        return printers.printers.count == 1 ? printers.printers.first : nil
    }

    var canPoll: Bool {
        guard let target else { return false }
        return target.isReachableOnPaper && target.hasStoredPassword
    }

    /// Why the screen cannot poll, in the user's terms. `nil` when it can.
    var blockedReason: String? {
        guard let target else {
            return printers.printers.isEmpty
                ? "No printer is configured yet. Add one in Manage ▸ Printers (⇧⌘2) and Spoolworks can read its CFS."
                : "Several printers are configured. Choose one in Manage ▸ Printers (⇧⌘2) to poll."
        }
        if !target.isReachableOnPaper {
            return "\(target.displayName) has no address. Add one in Manage ▸ Printers (⇧⌘2)."
        }
        if !target.hasStoredPassword {
            return "\(target.displayName) has no saved password. Add one in Manage ▸ Printers (⇧⌘2)."
        }
        return nil
    }

    // MARK: Polling

    func poll() async {
        guard let target, canPoll else { return }
        let password = printers.password(for: target.family)
        guard !password.isEmpty else {
            state = .failed("No saved password for \(target.displayName).")
            return
        }
        state = .polling
        do {
            let credentials = printers.makeCredentials(host: target.host, password: password)
            let snapshot = try await transport.downloadBoxInfo(credentials, family: target.family)
            info = snapshot
            state = .loaded(.now)
            lastReport = inventory.reconcile(with: snapshot)
            // Reconciliation is what puts a spool in a slot, so anything the job poll had to hold
            // can be placed now.
            if !pendingGrams.isEmpty {
                flushPending(jobName: job?.filename ?? "an earlier job")
            }
        } catch {
            // The previous snapshot is kept: a dropped poll should not blank a screen the user is
            // reading. The state carries the failure so the header can say the data is stale.
            state = .failed(error.localizedDescription)
        }
    }

    func startAutoPoll() {
        startJobPoll()
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ready = await self.canPoll
                if await self.autoPoll, ready { await self.poll() }
                // Retry sooner while there is nothing to poll, so adding a printer or its password
                // takes effect in seconds rather than at the end of a full interval.
                let delay = ready ? Self.pollInterval : Self.retryInterval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stopAutoPoll() {
        timer?.cancel()
        timer = nil
        jobTimer?.cancel()
        jobTimer = nil
    }

    // MARK: Job consumption

    /// Reads the printer's job state and charges what it drew to the spool that gave it up.
    ///
    /// Needs no password: Moonraker is plain HTTP on the LAN. It only needs an address, so this
    /// runs even when the CFS poll cannot (no stored SSH password) — the job is still worth
    /// tracking for a spool on the external holder.
    func pollJob() async {
        guard let target, target.isReachableOnPaper else { return }
        do {
            let snapshot = try await jobReader.snapshot(host: target.host)
            job = snapshot
            guard let charge = tracker.accept(snapshot) else { return }
            apply(charge)
        } catch {
            // Deliberately quiet. A printer that is off, or one with no Moonraker, must not raise
            // an error every five seconds behind a screen the user is reading. The CFS poll is the
            // one that reports connectivity.
            job = nil
        }
    }

    /// Charges one slot's draw to the spool sitting in it.
    private func apply(_ charge: PrintJobTracker.Charge) {
        guard let (boxID, slotID) = Self.splitSlotLabel(charge.slot) else { return }

        // Diameter and density come from the slot the printer reports, not from a constant: a
        // 2.85 mm spool would be out by a factor of 2.65 on cross-section alone.
        let slot = info?.boxes.first { $0.boxID == boxID }?.list.first { $0.materialId == slotID }
        let grams = FilamentGeometry.grams(
            forMillimetres: charge.millimetres,
            diameterMillimetres: Double(slot?.diameter ?? "") ?? FilamentGeometry.defaultDiameter,
            densityGramsPerCubicCentimetre: (slot?.density ?? 0) > 0
                ? slot!.density : FilamentGeometry.defaultDensity)
        guard grams > 0 else { return }

        applyCharge(grams: grams, toSlot: charge.slot, boxID: boxID, slotID: slotID,
                    jobName: charge.jobName)
    }

    /// Charges grams to the spool in a slot, or holds them until one is known.
    private func applyCharge(grams: Double, toSlot label: String,
                             boxID: String, slotID: String, jobName: String) {
        let location = SpoolLocation.cfs(box: boxID, slot: slotID)
        guard let spool = inventory.inventory.active.first(where: { $0.location == location })
        else {
            pendingGrams[label, default: 0] += grams
            return
        }
        let held = pendingGrams.removeValue(forKey: label) ?? 0
        let total = grams + held
        chargedThisSession += total
        inventory.consume(spool, grams: total, detail: "job \(jobName)")
    }

    /// Tries to place consumption held while a slot had no spool in stock. Called after a CFS poll,
    /// which is what puts the spool there.
    private func flushPending(jobName: String) {
        for (label, grams) in pendingGrams {
            guard let (boxID, slotID) = Self.splitSlotLabel(label) else {
                pendingGrams.removeValue(forKey: label)
                continue
            }
            _ = grams   // the held amount is read back inside applyCharge
            applyCharge(grams: 0, toSlot: label, boxID: boxID, slotID: slotID, jobName: jobName)
        }
    }

    /// `"T1A"` -> `("T1", "A")`. The slot is always the final character.
    static func splitSlotLabel(_ label: String) -> (box: String, slot: String)? {
        guard label.count >= 2, let last = label.last else { return nil }
        return (String(label.dropLast()), String(last))
    }

    /// `"Printing lid.stl — 42 g from T1A"`, or nil when nothing is running.
    var jobSummary: String? {
        guard let job, job.state.isActive else { return nil }
        let name = job.filename.isEmpty ? "a job" : job.filename
        var parts = ["\(job.state == .paused ? "Paused" : "Printing") \(name)"]
        if let slot = job.feedingSlot { parts.append("feeding from \(slot)") }
        if chargedThisSession > 0 {
            parts.append(String(format: "%.1f g charged", chargedThisSession))
        }
        if unattributedGrams > 0 {
            parts.append(String(format: "%.1f g held — no spool in stock for that slot yet",
                                unattributedGrams))
        }
        return parts.joined(separator: " · ")
    }

    private func startJobPoll() {
        guard jobTimer == nil else { return }
        jobTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollJob()
                try? await Task.sleep(nanoseconds: UInt64(Self.jobPollInterval * 1_000_000_000))
            }
        }
    }

    // MARK: Derived display

    /// `"2 boxes · 8 slots · 5 loaded"`, or the external-holder case.
    var slotSummary: String {
        guard let info else { return "no reading yet" }
        if info.hasNoCFS { return "external spool only" }
        let boxes = info.boxes.count
        return "\(boxes) box\(boxes == 1 ? "" : "es") · \(info.slotCount) slots · \(info.loadedSlotCount) loaded"
    }

    /// The sentence under the slot summary, matching the design's `cfs.note`.
    var note: String {
        guard let info else { return "Poll the printer to read its CFS." }
        if info.hasNoCFS { return "External spool holder only." }
        let n = info.boxes.count
        if n == 1 { return "One box, four slots." }
        return "\(n) boxes daisy-chained as T1–T\(n)."
    }

    /// `"2×"` for the sidebar badge, `"rack"` with no CFS, blank before the first poll.
    var navBadge: String {
        guard let info else { return "" }
        return info.hasNoCFS ? "rack" : "\(info.boxes.count)×"
    }

    /// `"polled 12 s ago"` for the header status strip.
    var freshness: String {
        switch state {
        case .idle: return "not polled"
        case .polling: return "polling…"
        case let .loaded(at):
            let seconds = Int(Date.now.timeIntervalSince(at))
            if seconds < 5 { return "polled just now" }
            if seconds < 90 { return "polled \(seconds) s ago" }
            return "polled \(seconds / 60) min ago"
        case .failed: return "poll failed"
        }
    }

    var isConnected: Bool {
        if case .loaded = state { return true }
        return false
    }
}
