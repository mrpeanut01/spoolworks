import Foundation
import SpoolworksCore

/// Offers to add a filament to the printer, right after a tag has been written for one it does not
/// list.
///
/// A tag carries a filament *id*, and the CFS ignores an id its printer's database does not hold —
/// which is every id in the vendor catalogue until something puts it there. Uploading the Mac's
/// whole catalogue does that, and also rolls back everything the printer's database has gained since
/// the Mac last saw it (D-013). This adds one filament at a time, and only one somebody has just
/// tagged a spool with.
///
/// The questions come in an order that makes the common case cost nothing and changes nothing on
/// the printer without a click:
/// 1. An id from the bundled factory catalogue is Creality's own, on every printer of its family:
///    not checked.
/// 2. Anything else is looked up in the printer's live filament list, over its websocket, with no
///    password.
/// 3. Missing: offer. Adding it reads the printer's file, splices the one record in and writes it
///    back, over SSH with the saved password.
@MainActor
final class FilamentPushModel: ObservableObject {

    /// How to reach the printer a tag was written for.
    struct Printer: Equatable {
        let host: String
        let name: String
    }

    /// The filament a notice is about.
    struct Subject: Equatable {
        let filamentID: String
        /// `Polymaker PolyTerra PLA`.
        let label: String
        let family: PrinterType
        let printerName: String
        let host: String
    }

    enum Phase: Equatable {
        case idle
        case checking(Subject)
        case missing(Subject)
        case adding(Subject)
        case added(Subject)
        case failed(Subject, Step, String)

        enum Step: Equatable {
            case check
            case add
        }

        var subject: Subject? {
            switch self {
            case .idle: return nil
            case let .checking(subject), let .missing(subject), let .adding(subject), let .added(subject):
                return subject
            case let .failed(subject, _, _):
                return subject
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    private let transport: PrinterTransporting
    private let filamentList: PrinterFilamentListReading
    private let printer: @MainActor (PrinterType) -> Printer?
    private let credentials: @MainActor (PrinterType) -> PrinterCredentials?
    private let catalogueRecord: @MainActor (String, PrinterType) -> Filament?
    private let isFactoryFilament: @MainActor (String, PrinterType) -> Bool

    /// The filament "Not now" was said to. Kept quiet until a tag for a different one is written, so
    /// neither the other side of the same spool nor the next spool of it asks again.
    private var declinedID: String?
    private var work: Task<Void, Never>?

    init(transport: PrinterTransporting,
         filamentList: PrinterFilamentListReading,
         printer: @escaping @MainActor (PrinterType) -> Printer?,
         credentials: @escaping @MainActor (PrinterType) -> PrinterCredentials?,
         catalogueRecord: @escaping @MainActor (String, PrinterType) -> Filament?,
         isFactoryFilament: @escaping @MainActor (String, PrinterType) -> Bool) {
        self.transport = transport
        self.filamentList = filamentList
        self.printer = printer
        self.credentials = credentials
        self.catalogueRecord = catalogueRecord
        self.isFactoryFilament = isFactoryFilament
    }

    // MARK: Events

    /// Every verified write, from whichever screen made it.
    func noteVerifiedWrite(filamentID: String, printerTypeString: String) {
        if let declined = declinedID, declined != filamentID { declinedID = nil }
        guard declinedID == nil,
              let family = PrinterType(identifying: printerTypeString),
              !isFactoryFilament(filamentID, family),
              let printer = printer(family),
              let filament = catalogueRecord(filamentID, family) else { return }

        // The other side of the same spool, written a moment later: already in hand.
        if let current = phase.subject, current.filamentID == filamentID, current.family == family {
            switch phase {
            case .checking, .missing, .adding, .added: return
            case .idle, .failed: break
            }
        }

        check(Subject(filamentID: filamentID,
                      label: [filament.vendor, filament.name].filter { !$0.isEmpty }.joined(separator: " "),
                      family: family,
                      printerName: printer.name,
                      host: printer.host))
    }

    /// Adds the filament the notice is about to its printer.
    func add() {
        let subject: Subject
        switch phase {
        case let .missing(current), let .failed(current, .add, _):
            subject = current
        default:
            return
        }
        guard let filament = catalogueRecord(subject.filamentID, subject.family) else {
            phase = .failed(subject, .add, "\(subject.filamentID) is no longer in this Mac's catalogue.")
            return
        }
        guard let credentials = credentials(subject.family) else {
            phase = .failed(subject, .add,
                            "\(subject.printerName) has no saved password. Add one in Manage ▸ Printers (⇧⌘2), then try again.")
            return
        }

        phase = .adding(subject)
        let transport = self.transport
        work = Task { [weak self] in
            do {
                _ = try await transport.addFilament(filament, credentials: credentials, family: subject.family)
                guard let self, self.phase == .adding(subject) else { return }
                self.phase = .added(subject)
            } catch {
                guard let self, self.phase == .adding(subject) else { return }
                self.phase = .failed(subject, .add, error.localizedDescription)
            }
        }
    }

    /// Runs the step that failed again.
    func retry() {
        guard case let .failed(subject, step, _) = phase else { return }
        switch step {
        case .check: check(subject)
        case .add: add()
        }
    }

    /// Hides the notice, and stays quiet about this filament until a different one is written.
    func notNow() {
        declinedID = phase.subject?.filamentID
        work?.cancel()
        phase = .idle
    }

    /// Hides a finished notice.
    func dismiss() {
        work?.cancel()
        phase = .idle
    }

    /// Waits for the check or push in flight. For tests.
    func settle() async {
        await work?.value
    }

    // MARK: Steps

    private func check(_ subject: Subject) {
        work?.cancel()
        phase = .checking(subject)
        let filamentList = self.filamentList
        work = Task { [weak self] in
            do {
                let ids = try await filamentList.filamentIDs(host: subject.host)
                guard let self, self.phase == .checking(subject) else { return }
                self.phase = ids.contains(subject.filamentID) ? .idle : .missing(subject)
            } catch {
                guard let self, self.phase == .checking(subject) else { return }
                self.phase = .failed(subject, .check, error.localizedDescription)
            }
        }
    }

    // MARK: Factory catalogue

    /// Whether `id` is in the factory catalogue this build ships for `family`.
    ///
    /// Those are Creality's own ids, and a printer's database holds every one of them — the K2 Plus
    /// checked on 2026-09-11 had all 96 — so a write for one is not worth a network round trip.
    static func isInBundledCatalogue(_ id: String, _ family: PrinterType) -> Bool {
        if let cached = bundledIDs[family] { return cached.contains(id) }
        let ids = (try? BundledMaterialSeed().seedData(for: family))
            .flatMap { try? PrinterMaterialDocument.filamentIDs(in: $0) }
            .map(Set.init) ?? []
        bundledIDs[family] = ids
        return ids.contains(id)
    }

    private static var bundledIDs: [PrinterType: Set<String>] = [:]
}
