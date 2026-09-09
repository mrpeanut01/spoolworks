import Foundation

// MARK: - Errors

public enum InventoryError: Error, Equatable, CustomStringConvertible {
    case storage(String)
    case decoding(String)

    public var description: String {
        switch self {
        case let .storage(detail): return "Inventory storage failed: \(detail)"
        case let .decoding(detail): return "The inventory file could not be read: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Filters

/// The Inventory screen's segmented control.
public enum InventoryFilter: Hashable, Sendable, Identifiable {

    case all
    case onPrinter
    /// One of the user's own locations.
    ///
    /// This replaced a fixed `shelf` case that meant "anywhere but the printer" while being
    /// *labelled* "Shelf". That was true only while Shelf was the one place a spool could be; once
    /// locations became a list the user edits, the button named a location it did not filter on and
    /// kept naming it after the location had been renamed away.
    ///
    /// Carries the ``SpoolLocation`` rather than the place's name so matching stays an equality
    /// check on the value a spool actually holds — a name would have to be resolved back through
    /// the place list, which ``SpoolInventory`` does not have and should not need.
    case at(SpoolLocation)
    case low
    case untagged

    public var id: String {
        switch self {
        case .all: return "all"
        case .onPrinter: return "onPrinter"
        case let .at(location): return "at:\(location.description)"
        case .low: return "low"
        case .untagged: return "untagged"
        }
    }

    public var title: String {
        switch self {
        case .all: return "All"
        case .onPrinter: return "On printer"
        case let .at(location): return location.description
        case .low: return "Low"
        case .untagged: return "Untagged"
        }
    }

    func matches(_ spool: Spool) -> Bool {
        switch self {
        case .all: return true
        case .onPrinter: return spool.location.isOnPrinter
        case let .at(location): return spool.location == location
        case .low: return spool.isLow
        case .untagged: return spool.isUntagged
        }
    }
}

/// What the Inventory table can be ordered by — one case per sortable column.
public enum InventorySort: String, CaseIterable, Sendable, Identifiable {
    case colour, filament, type, location, left, tag

    public var id: String { rawValue }

    /// Which way round "ascending" reads for this column, so the arrow means the same thing
    /// everywhere. Text sorts A→Z; a quantity sorts fullest-first, because a list of spools is
    /// scanned for the ones running out and putting them at the far end is the wrong default.
    public var ascendingIsNaturalFirst: Bool { self != .left }
}

extension Spool {
    /// The value this spool sorts by for one column, plus a tie-break, as one comparable pair.
    ///
    /// The tie-break is always the label, so equal keys never leave rows shuffling between renders
    /// — twelve spools all reading "100%" would otherwise reorder on every reconcile.
    func sortKey(_ sort: InventorySort) -> (primary: Double, text: String) {
        switch sort {
        case .colour:   return (colourOrder, label)
        case .filament: return (0, label)
        case .type:     return (materialType.isEmpty ? 1 : 0, materialType)
        case .location: return (0, location.description)
        case .left:     return (remainingPercent, label)
        case .tag:      return (0, tagSource.description)
        }
    }
}

// MARK: - The inventory

/// Every spool the user owns, and the rules for keeping it in step with the printer.
///
/// A value type on purpose: reconciliation is the one piece of logic here with real consequences —
/// it can move a spool, rewrite what is left of it and invent records — and testing that against a
/// struct with no I/O is far easier than against a class that owns a file. ``InventoryStore`` adds
/// persistence around it.
public struct SpoolInventory: Codable, Hashable, Sendable {

    /// Newest intake first, which is the order the Inventory table shows.
    public private(set) var spools: [Spool]

    public init(spools: [Spool] = []) {
        self.spools = spools
    }

    private enum CodingKeys: String, CodingKey {
        case spools
    }

    /// Property observers do not run inside a synthesized `init(from:)`, so a figure outside
    /// 0…100 in the file — a hand edit, a corrupt write, a client this app has not met — would
    /// arrive unclamped and trap in `Int(...)` the first time its row rendered. Every decoded
    /// spool goes through the same clamp a live write gets.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spools = try container.decode([Spool].self, forKey: .spools).map { spool in
            var clamped = spool
            clamped.remainingPercent = Spool.clamp(spool.remainingPercent)
            return clamped
        }
    }

    // MARK: Reading

    /// Spools that have not been retired.
    public var active: [Spool] { spools.filter { !$0.isRetired } }

    public var lowCount: Int { active.filter(\.isLow).count }
    public var untaggedCount: Int { active.filter(\.isUntagged).count }

    /// `"10 spools · 2 low · 1 untagged"` — the Inventory screen's kicker. Clauses that would read
    /// zero are dropped rather than printed, so a healthy inventory says just `"10 spools"`.
    public var summary: String {
        var parts = ["\(active.count) spool\(active.count == 1 ? "" : "s")"]
        if lowCount > 0 { parts.append("\(lowCount) low") }
        if untaggedCount > 0 { parts.append("\(untaggedCount) untagged") }
        return parts.joined(separator: " · ")
    }

    /// Filtered, then ordered.
    ///
    /// `sort` is optional and defaults to nil, which keeps the intake order the list has always
    /// had — newest first — so a caller that does not care is unchanged.
    public func filtered(by filter: InventoryFilter,
                         sortedBy sort: InventorySort?,
                         ascending: Bool) -> [Spool] {
        let rows = filtered(by: filter)
        guard let sort else { return rows }
        return rows.sorted { a, b in
            let (lhs, rhs) = (a.sortKey(sort), b.sortKey(sort))
            if lhs.primary != rhs.primary {
                return ascending ? lhs.primary < rhs.primary : lhs.primary > rhs.primary
            }
            let order = lhs.text.localizedCaseInsensitiveCompare(rhs.text)
            if order != .orderedSame {
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            // Total, so the sort is stable across renders whatever the column.
            return a.id.uuidString < b.id.uuidString
        }
    }

    public func filtered(by filter: InventoryFilter) -> [Spool] {
        active.filter(filter.matches)
    }

    public func spool(id: UUID) -> Spool? { spools.first { $0.id == id } }

    /// The active spool with this identity. Retired spools are deliberately excluded: presenting a
    /// retired spool's tag should not silently resurrect it into a CFS slot.
    public func spool(identity: SpoolIdentity) -> Spool? {
        spools.first { !$0.isRetired && $0.identity == identity }
    }

    /// What a tag read resolves to, if anything.
    public func spool(matching record: SpoolRecord) -> Spool? {
        spool(identity: SpoolIdentity(record: record))
    }

    // MARK: Writing

    public mutating func add(_ spool: Spool) {
        spools.insert(spool, at: 0)
    }

    /// Replaces a spool by id. A no-op if the id is unknown, so a stale selection cannot resurrect
    /// a deleted row.
    public mutating func update(_ spool: Spool) {
        guard let index = spools.firstIndex(where: { $0.id == spool.id }) else { return }
        spools[index] = spool
    }

    /// Marks a spool retired, keeping it and its history in the file.
    ///
    /// The Retire dialog promises the last reading *"stays on the usage record"*, so this appends
    /// a line rather than deleting anything.
    public mutating func retire(id: UUID, date: Date = .now) {
        guard let index = spools.firstIndex(where: { $0.id == id }) else { return }
        guard !spools[index].isRetired else { return }
        spools[index].note(kind: .retirement,
                           detail: "Retired at \(spools[index].remainingLabel)",
                           date: date)
        spools[index].isRetired = true
        spools[index].location = .unknown
    }

    /// Permanently removes a spool. Nothing in the UI calls this — retirement is the user-facing
    /// operation — but tests and a future "purge retired" need it.
    public mutating func remove(id: UUID) {
        spools.removeAll { $0.id == id }
    }

    // MARK: - Reconciliation

    /// What a poll changed, so the UI can say so without diffing the list itself.
    public struct ReconcileReport: Equatable, Sendable {
        public var discovered: [UUID] = []
        public var updated: [UUID] = []
        public var unloaded: [UUID] = []

        public var isEmpty: Bool { discovered.isEmpty && updated.isEmpty && unloaded.isEmpty }
        public var changeCount: Int { discovered.count + updated.count + unloaded.count }
    }

    /// Brings the inventory into step with a `material_box_info.json` snapshot.
    ///
    /// The CFS is the only source of a *measured* remaining figure, so a poll wins over whatever
    /// the inventory believed.
    ///
    /// ## Matching is two-pass, because identity is not unique
    ///
    /// ``SpoolIdentity`` cannot separate two spools of the same filament and colour — on the K2
    /// Plus dump every slot reports `serialNum 000001`, and `T1B`/`T1D` are the same red. A single
    /// pass taking the first identity match would swap those two spools' histories on every poll,
    /// each stealing the other's consumption.
    ///
    /// So slots are bound in two passes, and **a spool is bound to at most one slot**:
    ///
    /// 1. **Incumbents.** A slot whose current occupant already claims exactly that location keeps
    ///    it. This is what makes the binding stable across polls.
    /// 2. **Newcomers.** Remaining slots take any unbound spool with a matching identity.
    /// 3. **Discovery.** Slots still unmatched become new spools when `addingUnknown` is set — a
    ///    spool physically in the printer that the inventory has never seen is a gap, not something
    ///    to stay quiet about.
    ///
    /// Finally, spools that were on the printer and no longer are lose their location. Their
    /// remaining figure is left alone — it was last measured, and nothing better exists — and the
    /// move is noted so the detail panel can explain why the source line stopped updating.
    ///
    /// A slot with no identity (unoccupied, or configured by hand with no serial) is skipped.
    @discardableResult
    /// `unloadTo` is where a spool goes when the printer stops reporting it.
    ///
    /// A parameter rather than the constant `.unknown` it used to be, because "off the printer" and
    /// "nowhere in particular" are not the same claim. A spool you unload almost always goes back
    /// to the same shelf, and defaulting it there is the difference between an inventory that stays
    /// true on its own and one that needs correcting after every print.
    ///
    /// Still `.unknown` by default: that is the honest answer when nobody has said otherwise, and
    /// it keeps every existing caller — the tests especially — meaning exactly what it did.
    public mutating func reconcile(with info: MaterialBoxInfo,
                                   at date: Date = .now,
                                   addingUnknown: Bool = true,
                                   unloadTo: SpoolLocation = .unknown) -> ReconcileReport {
        var report = ReconcileReport()
        var seen = Set<UUID>()

        struct Pending {
            let identity: SpoolIdentity
            let label: String
            let location: SpoolLocation
            let slot: CFSSlot
        }

        let pending: [Pending] = info.loadedSlots.compactMap { box, slot in
            guard let identity = slot.identity else { return nil }
            return Pending(identity: identity,
                           label: slot.label(in: box),
                           location: .cfs(box: box.boxID, slot: slot.materialId),
                           slot: slot)
        }

        // Bound by **id**, not by index: discovery inserts into `spools` while this array is still
        // in use, which would silently shift every index recorded before it.
        var bound = [UUID?](repeating: nil, count: pending.count)

        // -- pass 1: incumbents ----------------------------------------------------------------
        for (n, entry) in pending.enumerated() {
            guard let match = spools.first(where: {
                !$0.isRetired && $0.identity == entry.identity
                    && $0.location == entry.location && !seen.contains($0.id)
            }) else { continue }
            seen.insert(match.id)
            bound[n] = match.id
        }

        // -- pass 2: newcomers -----------------------------------------------------------------
        for (n, entry) in pending.enumerated() where bound[n] == nil {
            guard let match = spools.first(where: {
                !$0.isRetired && $0.identity == entry.identity && !seen.contains($0.id)
            }) else { continue }
            seen.insert(match.id)
            bound[n] = match.id
        }

        // -- apply -----------------------------------------------------------------------------
        for (n, entry) in pending.enumerated() {
            let source = "CFS remainLen · \(entry.label)"

            if let id = bound[n], let index = spools.firstIndex(where: { $0.id == id }) {
                var changed = false
                if spools[index].location != entry.location {
                    spools[index].location = entry.location
                    spools[index].note(kind: .movement,
                                       detail: "Loaded into \(entry.label)", date: date)
                    changed = true
                }
                // A poll is only news when the **measurement** changed, not when it merely
                // disagrees with our figure. The CFS reports whole percent, so a print smaller
                // than 1 % of the spool leaves it unmoved while job tracking has legitimately
                // deducted grams; treating that as a discrepancy overwrites the finer number with
                // the coarser one, every 30 seconds, forever.
                if let percent = entry.slot.remainingPercent,
                   spools[index].lastCFSPercent.map({ abs(percent - $0) >= 0.5 }) ?? true {
                    spools[index].lastCFSPercent = percent
                    // Only write a line if it actually moves the figure — on first sight the
                    // reading usually equals what we already have.
                    if abs(percent - spools[index].remainingPercent) >= 0.5 {
                        spools[index].record(percent: percent,
                                             kind: .cfsPoll,
                                             detail: "CFS poll · \(entry.label)",
                                             date: date,
                                             source: source)
                        changed = true
                    } else {
                        spools[index].remainingSource = source
                    }
                } else {
                    spools[index].remainingSource = source
                }
                if changed { report.updated.append(spools[index].id) }

            } else if addingUnknown {
                // -- pass 3: discovery -------------------------------------------------------
                var spool = Spool(identity: entry.identity,
                                  brand: entry.slot.brand,
                                  name: entry.slot.name,
                                  materialType: entry.slot.materialType,
                                  colorHex: entry.slot.rgbHex,
                                  netWeightGrams: entry.slot.netWeightGrams,
                                  remainingPercent: entry.slot.remainingPercent ?? 100,
                                  location: entry.location,
                                  remainingSource: source,
                                  tagSource: entry.slot.hasTag ? .crealityFactory : .untagged,
                                  intakeDate: date,
                                  lastCFSPercent: entry.slot.remainingPercent)
                spool.note(kind: .intake, detail: "Discovered in \(entry.label)", date: date)
                spools.insert(spool, at: 0)
                seen.insert(spool.id)
                report.discovered.append(spool.id)
            }
        }

        // -- the external holder ------------------------------------------------------------
        // The same two-pass rule as the slots: the spool already on the holder first, then any
        // twin not yet bound above. A spool bound to a slot is never re-pointed here. Without
        // the exclusion, twin spools of one identity — one in a slot, one on the holder — made
        // the first match the slot's own spool: it was moved to the holder, the real holder
        // spool was "unloaded", and the next poll reversed both. Two movement lines every 30 s
        // and the wrong location for both, forever.
        if let rack = info.rackMaterial, rack.attach, let identity = rack.identity,
           let index = spools.firstIndex(where: {
               !$0.isRetired && $0.identity == identity
                   && $0.location == .externalHolder && !seen.contains($0.id)
           }) ?? spools.firstIndex(where: {
               !$0.isRetired && $0.identity == identity && !seen.contains($0.id)
           }) {
            seen.insert(spools[index].id)
            if spools[index].location != .externalHolder {
                spools[index].location = .externalHolder
                spools[index].note(kind: .movement, detail: "Mounted on the external holder", date: date)
                report.updated.append(spools[index].id)
            }
            // No remainLen on the holder: the last figure stands, and the source says so.
            spools[index].remainingSource = "rackMaterial · attached, no sensor"
        }

        // -- 3: spools the printer no longer reports -------------------------------------------
        for index in spools.indices
        where spools[index].location.isOnPrinter && !seen.contains(spools[index].id)
                && !spools[index].isRetired {
            let previous = spools[index].location.description
            spools[index].location = unloadTo
            spools[index].remainingSource = "Last reading from \(previous)"
            spools[index].note(kind: .movement, detail: "Unloaded from \(previous)", date: date)
            report.unloaded.append(spools[index].id)
        }

        return report
    }
}

// MARK: - Persistence

/// Reads and writes the inventory as one JSON file.
///
/// One file rather than a file per spool: the whole inventory is a few hundred kilobytes at worst,
/// it is always loaded and saved whole, and a single atomic replace is the only way to guarantee a
/// crash mid-save cannot leave half an inventory behind.
public struct InventoryStore: Sendable {

    public let directory: URL
    public let fileName: String

    public init(directory: URL, fileName: String = "inventory.json") {
        self.directory = directory
        self.fileName = fileName
    }

    /// `~/Library/Application Support/Spoolworks/inventory.json`.
    public static func applicationSupport(fileManager: FileManager = .default) throws -> InventoryStore {
        do {
            let base = try fileManager.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: false)
            return InventoryStore(directory: base
                .appendingPathComponent("Spoolworks", isDirectory: true))
        } catch {
            throw InventoryError.storage("locating Application Support: \(error.localizedDescription)")
        }
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    public func exists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    /// Loads the inventory, returning an empty one when the file does not exist yet.
    ///
    /// A missing file is the first-run case and is not an error. A file that exists but will not
    /// decode **is** an error and is reported: silently starting empty would look identical to
    /// "the app lost all my spools".
    public func load(fileManager: FileManager = .default) throws -> SpoolInventory {
        guard exists(fileManager: fileManager) else { return SpoolInventory() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw InventoryError.storage("reading \(fileURL.path): \(error.localizedDescription)")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SpoolInventory.self, from: data)
        } catch {
            throw InventoryError.decoding("\(fileURL.lastPathComponent): \(error)")
        }
    }

    /// Writes atomically, so an interrupted save cannot truncate the inventory.
    public func save(_ inventory: SpoolInventory, fileManager: FileManager = .default) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw InventoryError.storage("creating \(directory.path): \(error.localizedDescription)")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(inventory)
        } catch {
            throw InventoryError.storage("encoding the inventory: \(error.localizedDescription)")
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw InventoryError.storage("writing \(fileURL.path): \(error.localizedDescription)")
        }
    }
}

/// The enum already provided `errorDescription`; what it lacked was the conformance that makes
/// `Error.localizedDescription` — which is what every UI surface shows — read it. Without this
/// the CFS strip showed "The operation couldn't be completed. (SpoolworksCore.InventoryError error 0.)"
/// in place of the sentence the case was written to say.
extension InventoryError: LocalizedError {}
