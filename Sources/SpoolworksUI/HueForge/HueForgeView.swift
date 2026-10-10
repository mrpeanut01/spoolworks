import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SpoolworksCore

/// Send the inventory to HueForge as a filament library — `Manage ▸ HueForge…` (⇧⌘4).
///
/// ## What goes where
///
/// HueForge takes filaments in three ways, and this window offers each rather than picking one:
///
/// 1. **A file, imported by hand** — *Filaments ▸ Import* reads JSON or CSV. Every entry carries
///    an id derived from the filament, so importing a second export updates the first one.
/// 2. **A library file in its folder** — what its own importer does when told the file is a vendor
///    library. Spoolworks owns one file there and rewrites it; that is *Sync*.
/// 3. **A community source** — a folder on a Git host that HueForge downloads by itself.
///
/// A window for the reason Locations is one: it is a list you sit down and edit. The one thing
/// here that needs editing is the transmission distance, which Spoolworks has no way to know.
struct HueForgeView: View {
    @ObservedObject var model: HueForgeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: model.summary, title: "HueForge") {
                    Button("Export…", action: export)
                        .buttonStyle(.sw(.primary))
                        .disabled(model.included.isEmpty)
                        .accessibilityHint("Saves a JSON or CSV file HueForge can import.")
                }
                .padding(.bottom, 18)
                Rule().padding(.bottom, 20)

                if let problem = model.problem {
                    InlineFailure(text: problem).padding(.bottom, 18)
                }

                filaments.padding(.bottom, 18)
                sync.padding(.bottom, 18)
                communitySource.padding(.bottom, 18)
                explanation
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(Theme.background)
        .frame(minWidth: 640, minHeight: 480)
        .task { await model.loadReference() }
    }

    // MARK: The list

    private var filaments: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Filaments in stock").kicker()
                Spacer()
                Button("Import TDs…", action: importTransmissivities)
                    .buttonStyle(.sw(.ghost, size: 11, h: 8, v: 4))
                    .disabled(model.entries.isEmpty)
                    .accessibilityHint("Reads transmission distances from a HueForge export.")
            }
            .padding(.bottom, 12)

            if model.entries.isEmpty {
                Text("Spools you take into stock appear here, one row per filament.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            ForEach(model.entries) { entry in
                HueForgeRow(entry: entry,
                            setIncluded: { model.setIncluded($0, for: entry.id) },
                            setTD: { model.setTransmissivity($0, for: entry.id) },
                            clearTD: { model.clearTransmissivity(for: entry.id) })
                    // Keyed by the TD as well, so a value arriving from an import or a library
                    // rebuilds the row instead of leaving the field on its old draft.
                    .id("\(entry.id)|\(entry.filament.transmissivity)")
            }

            if model.estimatedCount > 0 {
                Hairline().padding(.vertical, 12)
                Text("\(model.estimatedCount) transmission distance\(model.estimatedCount == 1 ? " is an estimate" : "s are estimates") "
                     + "taken from similar colours. HueForge will print from them as given — "
                     + "measure the filament and type the figure in before relying on one.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
    }

    // MARK: Sync

    private var sync: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Sync to HueForge's folder").kicker()
            HStack(spacing: Theme.Spacing.s) {
                ReadOnlyValue(model.syncFolder?.path ?? "No folder chosen")
                Button(model.syncFolder == nil ? "Choose…" : "Change…", action: chooseSyncFolder)
                    .buttonStyle(.sw(.secondary, size: 12, h: 14, v: 7))
                Button("Sync now") { model.syncNow() }
                    .buttonStyle(.sw(.primary, size: 12, h: 14, v: 7))
                    .disabled(model.syncFolder == nil || model.included.isEmpty)
            }
            Text("Writes Filaments/Vendor Libraries/\(HueForgeInstall.syncFileName) and nothing "
                 + "else. Your personal library is never touched.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
    }

    // MARK: Community source

    private var communitySource: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Publish as a community source").kicker()
            TextField("Source name", text: $model.sourceName)
                .textFieldStyle(.plain)
                .swInput()
                .accessibilityLabel("Name HueForge shows for this source")
            HStack(spacing: Theme.Spacing.s) {
                TextField("https://raw.githubusercontent.com/you/repo/main/libraries",
                          text: $model.sourceBaseURL)
                    .textFieldStyle(.plain)
                    .swInput()
                    .accessibilityLabel("Raw URL the libraries folder will be served from")
                Button("Write folder…", action: writeCommunitySource)
                    .buttonStyle(.sw(.secondary, size: 12, h: 14, v: 7))
                    .disabled(model.included.isEmpty
                              || !model.sourceBaseURL.lowercased().hasPrefix("https://")
                              || model.sourceName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Writes manifest.json and libraries/\(HueForgeInstall.syncFileName) for a Git "
                 + "repository. HueForge downloads updates to a source by itself.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this lines up with HueForge").kicker()
            Text("HueForge lists filaments, not spools, so three spools of one filament are one "
                 + "row. Its Brand is the product line — “Creality Hyper” — and its Name is the "
                 + "colour, so that is how each row is written.")
                .fixedSize(horizontal: false, vertical: true)
            Text(model.reference.isEmpty
                 ? "HueForge's own libraries were not found on this Mac, so every transmission "
                   + "distance you have not typed is an estimate."
                 : "Transmission distances were looked up among the \(model.reference.count) "
                   + "filaments in HueForge's libraries on this Mac. One you type always wins.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Exporting again does not duplicate anything: each filament keeps the same id, "
                 + "so HueForge's import offers to update the entries it already has.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.secondaryLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 18)
    }

    // MARK: Panels

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export for HueForge"
        panel.nameFieldStringValue = "spoolworks_filaments.json"
        // The extension chosen is the format written, as in HueForge's own export dialog.
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
    }

    private func importTransmissivities() {
        let panel = NSOpenPanel()
        panel.title = "Read transmission distances"
        panel.message = "Choose a file from HueForge's Filaments ▸ Export."
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importTransmissivities(from: url)
    }

    private func chooseSyncFolder() {
        guard let url = chooseFolder(title: "Choose HueForge's folder",
                                     message: "The folder that has HueForge's Filaments folder in it. "
                                        + "macOS may ask whether Spoolworks can use another app's data.",
                                     startingAt: model.syncFolder
                                        ?? HueForgeInstall.dataFolder()) else { return }
        model.chooseSyncFolder(url)
    }

    private func writeCommunitySource() {
        guard let url = chooseFolder(title: "Write the community source",
                                     message: "Choose the root of the Git repository.",
                                     startingAt: nil) else { return }
        model.writeCommunitySource(to: url)
    }

    private func chooseFolder(title: String, message: String, startingAt: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One filament: whether it goes, what it is, and its transmission distance.
///
/// The TD is a field committed with Return, as a location's name is, and for the same reason — the
/// row is already a field. What differs is the tag beside it: an estimate and a measurement are
/// the same number in the file, so the row is the only place the difference can be seen.
private struct HueForgeRow: View {
    let entry: HueForgeExportEntry
    let setIncluded: (Bool) -> Void
    let setTD: (String) -> Bool
    let clearTD: () -> Void

    @State private var draft = ""

    private var filament: HueForgeFilament { entry.filament }
    private var current: String { HueForgeRow.format(filament.transmissivity) }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: Binding(get: { entry.isIncluded }, set: setIncluded))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Send \(filament.brand) \(filament.name) to HueForge")
            Swatch(hex: filament.colorHex)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(filament.brand) · \(filament.name)")
                    .font(Theme.rowTitle)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text("\(filament.type) · \(entry.spoolIDs.count) spool\(entry.spoolIDs.count == 1 ? "" : "s")")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Spacer(minLength: Theme.Spacing.s)
            SWTag(text: entry.tdSource.label, style: entry.tdSource == .estimated ? .accent : .neutral)
                .help(tagHelp)
            if entry.tdSource == .user {
                Button("Reset", action: clearTD)
                    .buttonStyle(.sw(.ghost, size: 11, h: 8, v: 4))
                    .accessibilityLabel("Forget the transmission distance you set")
            }
            TextField("TD", text: $draft)
                .textFieldStyle(.plain)
                .swInput()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onSubmit { if !setTD(draft) { draft = current } }
                .accessibilityLabel("Transmission distance of \(filament.brand) \(filament.name), in millimetres")
                .accessibilityHint("Press Return to set it.")
            Text("mm").font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
        }
        .padding(.vertical, 4)
        .opacity(entry.isIncluded ? 1 : 0.5)
        .onAppear { draft = current }
    }

    private var tagHelp: String {
        switch entry.tdSource {
        case .user: return "You set this transmission distance."
        case let .library(match): return "From “\(match)” in HueForge's libraries."
        case .estimated: return "Estimated from similar colours of the same material."
        }
    }

    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
