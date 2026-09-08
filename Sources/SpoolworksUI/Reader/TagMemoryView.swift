import SwiftUI
import SpoolworksCore

/// The full 16 × 4 × 16 hex dump of a MIFARE Classic 1K.
///
/// Replaces `TagMemoryForm` (`SPEC/03-ui.md` §5.7). Kept: the block titles
/// (`MANUFACTURER (UID)` / `Keys A/B + Access Bits` / `USER DATA`), the per-sector
/// `FAILED AUTHENTICATION` row, and the monospace hex.
///
/// Changed:
/// * It is a **real window**, not a modal sheet — it is a reference view you want open beside the
///   main window, and the Windows author already gave it a taskbar entry, which is the same
///   instinct.
/// * There is a **progress indicator**. The Windows version streams cards into a panel with no
///   feedback at all (`TagMemoryForm.cs:39-104`).
/// * A card inserted while the window is open is picked up automatically. Windows hands the form
///   a new `Reader` but never refreshes the list (`TagMemoryForm.cs:26-29`).
/// * Sector-trailer **key bytes are redacted** unless "Show key material" is on in Settings.
///   Nothing here can write, so trailer bytes are shown read-only and never editable.
struct TagMemoryView: View {

    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var settings: AppSettings
    @StateObject private var model: MemoryDumpModel

    init(monitor: ReaderMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings
        _model = StateObject(wrappedValue: MemoryDumpModel(monitor: monitor))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Theme.background)
        .navigationTitle("Tag Memory")
        .toolbar {
            ToolbarItem(placement: .status) {
                if model.isLoading {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(model.progressLabel)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                } else if let uid = model.dumpedUID {
                    Text(uid.hexStringSpaced)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Read Tag", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading || monitor.state.card?.isUsable != true)
                .help("Re-read every sector (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task(id: monitor.insertionCount) {
            guard monitor.state.card?.isUsable == true else { return }
            if model.dumpedUID != monitor.state.card?.uid { await model.reload() }
        }
        .onChange(of: monitor.state.card) { _, card in
            if card == nil { model.clear() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if monitor.state.card == nil {
            ContentUnavailableView {
                Label(monitor.state.hasReader ? "No Tag on the Reader" : "No Reader Found",
                      systemImage: monitor.state.hasReader
                          ? "dot.radiowaves.left.and.right" : "wave.3.right.circle")
            } description: {
                Text(monitor.state.hasReader
                     ? "Place a tag on the reader to dump its memory."
                     : "Connect a PC/SC reader to dump a tag's memory.")
            }
        } else if monitor.state.card?.isUsable != true {
            ContentUnavailableView("Unsupported Tag",
                                   systemImage: "questionmark.circle",
                                   description: Text("Memory layout is only defined for "
                                                     + "MIFARE Classic 1K tags."))
        } else if let failure = model.failure {
            ContentUnavailableView {
                Label("Could Not Read Tag Memory", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.sectors.isEmpty {
            ContentUnavailableView {
                Label("Nothing Read Yet", systemImage: "memorychip")
            } description: {
                Text("Press Read Tag to dump all 16 sectors.")
            } actions: {
                Button("Read Tag") { Task { await model.reload() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoading)
            }
        } else {
            dumpList
        }
    }

    private var dumpList: some View {
        List {
            ForEach(model.sectors) { sector in
                Section {
                    if sector.authFailed {
                        // `Sector <s> | FAILED AUTHENTICATION` / `Key Required`
                        HStack(spacing: Theme.Spacing.m) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("FAILED AUTHENTICATION")
                                    .font(.callout.weight(.semibold))
                                Text("Key Required")
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.secondaryLabel)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Sector \(sector.sector) failed authentication. "
                                            + "Key required.")
                    } else {
                        ForEach(sector.blocks) { block in
                            BlockRow(block: block, redactKeys: !settings.showKeyMaterial)
                        }
                    }
                } header: {
                    HStack {
                        Text("Sector \(sector.sector)")
                        Spacer()
                        if let key = sector.keyLabel {
                            Text(key)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.tertiaryLabel)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .font(Theme.mono)
    }
}

// MARK: - Rows

private struct BlockRow: View {
    let block: MemoryDumpModel.Block
    let redactKeys: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: block.symbol)
                .foregroundStyle(block.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Block \(block.index)  |  \(block.definition)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryLabel)
                Text(displayHex)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                Text(block.ascii)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.tertiaryLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Block \(block.index), \(block.definition)")
        .accessibilityValue(displayHex)
    }

    /// Trailer key bytes (0..5 = key A, 10..15 = key B) are masked unless the user has asked to
    /// see key material. Access bits (6..9) are always shown — they are the part that matters for
    /// judging whether a sector is safe.
    private var displayHex: String {
        guard redactKeys, block.isTrailer else { return block.hex }
        let bytes = block.bytes
        guard bytes.count == 16 else { return block.hex }
        let keyA = "•• •• •• •• •• ••"
        let access = Array(bytes[6...9]).hexStringSpaced
        let keyB = "•• •• •• •• •• ••"
        return "\(keyA) \(access) \(keyB)"
    }
}

// MARK: - Model

@MainActor
final class MemoryDumpModel: ObservableObject {

    struct Block: Identifiable {
        let index: Int
        let bytes: [UInt8]

        var id: Int { index }
        var hex: String { bytes.hexStringSpaced }
        var ascii: String { bytes.asciiDump }
        var isTrailer: Bool { MifareClassicCard.isTrailer(block: index) }

        /// `GetMifareBlockDefinition` (`TagMemoryForm.cs:135-140`), verbatim.
        var definition: String {
            if MifareClassicCard.isManufacturer(block: index) { return "MANUFACTURER (UID)" }
            if isTrailer { return "Keys A/B + Access Bits" }
            return "USER DATA"
        }

        /// `GetIconForBlock` (`TagMemoryForm.cs:122-133`), mapped to SF Symbols per §8.2.
        var symbol: String {
            if MifareClassicCard.isManufacturer(block: index) { return "lock.fill" }
            if isTrailer { return "gearshape.fill" }
            return "square.and.pencil"
        }

        var tint: Color {
            if MifareClassicCard.isManufacturer(block: index) { return Theme.secondaryLabel }
            if isTrailer { return Theme.warning }
            return Theme.accent
        }
    }

    struct Sector: Identifiable {
        let sector: Int
        let blocks: [Block]
        let authFailed: Bool
        let keyLabel: String?
        var id: Int { sector }
    }

    @Published private(set) var sectors: [Sector] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    @Published private(set) var dumpedUID: [UInt8]?
    @Published private(set) var progressLabel = ""

    private unowned let monitor: ReaderMonitor

    init(monitor: ReaderMonitor) {
        self.monitor = monitor
    }

    func clear() {
        sectors = []
        dumpedUID = nil
        failure = nil
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        progressLabel = "all sectors…"
        defer { isLoading = false; progressLabel = "" }

        do {
            let dump = try await monitor.withCard { session, identity -> (uid: [UInt8], dumps: [MifareClassicCard.SectorDump]) in
                guard identity.isUsable else { throw TagError.unsupportedCard(identity.type) }
                let card = MifareClassicCard(transport: session)
                // Both keys, so a half-programmed tag still dumps completely — the same key set
                // `TagService.writeTag` uses for its safety backup.
                var keys: [MifareKey] = [.default]
                if let derived = try? CrealityCrypto.deriveSectorKey(uid: identity.uid) {
                    keys.insert(derived, at: 0)
                }
                return (identity.uid, try card.dumpAll(keys: keys))
            }
            dumpedUID = dump.uid
            sectors = dump.dumps.map { dump in
                Sector(sector: dump.sector,
                       blocks: dump.blocks.keys.sorted().map {
                           Block(index: $0, bytes: dump.blocks[$0] ?? [])
                       },
                       authFailed: dump.authFailed,
                       keyLabel: dump.key.map { "\($0.description) key\(dump.keyType?.description ?? "?")" })
            }
        } catch {
            sectors = []
            dumpedUID = nil
            failure = error.localizedDescription
        }
    }
}
