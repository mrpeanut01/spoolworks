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

    static let pollInterval: TimeInterval = 30

    private let transport: PrinterTransporting
    private unowned let printers: PrinterViewModel
    private unowned let inventory: InventoryViewModel
    private var timer: Task<Void, Never>?

    init(transport: PrinterTransporting,
         printers: PrinterViewModel,
         inventory: InventoryViewModel) {
        self.transport = transport
        self.printers = printers
        self.inventory = inventory
    }

    deinit { timer?.cancel() }

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
        } catch {
            // The previous snapshot is kept: a dropped poll should not blank a screen the user is
            // reading. The state carries the failure so the header can say the data is stale.
            state = .failed(error.localizedDescription)
        }
    }

    func startAutoPoll() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.autoPoll, await self.canPoll { await self.poll() }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stopAutoPoll() {
        timer?.cancel()
        timer = nil
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
