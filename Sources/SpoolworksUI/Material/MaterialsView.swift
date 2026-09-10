import AppKit
import SwiftUI
import SpoolworksCore

/// The material-database browser: a sortable `Table` of every filament in the selected printer
/// family's catalogue, with add / edit / delete.
///
/// Replaces the four unlabelled Windows combo boxes (`MainForm` printer → vendor → material →
/// weight, SPEC/03-ui.md §5.1). Those cascaded because the only way to reach a filament was to
/// narrow three dropdowns; a table shows the whole catalogue at once, sorts on any column and
/// supports multi-select, which the original could not do at all.
///
/// This is a plain `View` — the shell (UI-01) hosts it in the detail column and supplies the
/// window, the sidebar and the menu bar.
struct MaterialsView: View {
    @ObservedObject var model: MaterialsViewModel
    // The scene that hosts this view attaches `.toast(env.toasts)` at its root (the Materials
    // window in `App.swift`), so this view forwards its view-model's messages into that shared
    // centre rather than presenting its own overlay.
    @EnvironmentObject private var toasts: ToastCenter

    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            saveFailureBanner
            seedAdditionsBanner
            vendorCatalogueBanner
            content
        }
        .navigationTitle("Material Database")
        .toolbar { toolbarContent }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search filaments")
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await model.load()
        }
        .sheet(item: $model.editor) { mode in
            FilamentEditorView(mode: mode, model: model)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { !model.pendingDeletion.isEmpty },
                set: { if !$0 { model.pendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            // Destructive role + Cancel as the default button preserves the deliberate
            // `MessageBox.DefaultButton.Button2` choice at `MainForm.cs:802`.
            Button("Delete", role: .destructive) {
                Task { await model.confirmDeletion() }
            }
            Button("Cancel", role: .cancel) { model.pendingDeletion = [] }
        } message: {
            Text(deletionMessage)
        }
        .onChange(of: model.toast) { _, message in
            guard let message else { return }
            toasts.show(message)
            model.toast = nil
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            loadingState
        case let .failed(message):
            failureState(message)
        case .loaded:
            if model.rows.isEmpty {
                emptyDatabaseState
            } else if model.filteredRows.isEmpty {
                noSearchResultsState
            } else {
                table
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading \(model.printerType.displayName) database…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func failureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Database Could Not Be Read", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await model.load() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Button("Reveal in Finder") { revealStorage() }
        }
    }

    /// The Windows equivalent is a toast reading "Add a printer to get started" followed by a
    /// dialog that opens itself one second later (`MainForm.cs:93-103`). A message that vanishes on
    /// a timer plus a window that appears unbidden is two bad ideas; this is one durable state with
    /// the action attached to it.
    private var emptyDatabaseState: some View {
        ContentUnavailableView {
            Label("No Filaments", systemImage: "tray")
        } description: {
            Text("The \(model.printerType.displayName) database is empty. Add a filament, or download a catalogue from your printer.")
        } actions: {
            Button("Add Filament…") { model.editor = .add(template: nil) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    private var noSearchResultsState: some View {
        ContentUnavailableView {
            Label("No Matches", systemImage: "magnifyingglass")
        } description: {
            Text("No filament matches “\(model.searchText)”.")
        } actions: {
            Button("Clear Search") { model.searchText = "" }
        }
    }

    /// Offers the filaments a newer bundled catalogue has and this one does not.
    ///
    /// An offer, not a merge: the catalogue on disk is the user's, and an app update that poured
    /// records into it unasked would be indistinguishable from the app losing their edits. It is
    /// how a shipped refresh reaches an install that already has a catalogue at all — the seed is
    /// otherwise written once, on the run that had no file.
    @ViewBuilder
    private var seedAdditionsBanner: some View {
        if model.seedAdditions > 0, model.saveFailure == nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.seedAdditions) new filament\(model.seedAdditions == 1 ? "" : "s") "
                         + "in the bundled catalogue")
                        .font(.headline)
                    Text("Adding them leaves every filament already listed exactly as it is, including any you have edited.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Add Them") { Task { await model.applySeedAdditions() } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.accent.opacity(0.35))
            )
            .padding([.horizontal, .top], 12)
            .accessibilityElement(children: .contain)
        }
    }

    /// Offers the assembled third-party catalogue.
    ///
    /// Its own banner rather than a line in the seed one, because it is a different decision. The
    /// seed's records were captured from a printer and their ids already resolve there; these were
    /// assembled from vendor profiles and their ids are ours, so a tag written against one is
    /// ignored until the catalogue reaches the printer. Saying that here is the difference between
    /// a feature and a support question.
    @ViewBuilder
    private var vendorCatalogueBanner: some View {
        if model.vendorAdditions > 0, model.saveFailure == nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.vendorAdditions) third-party filaments available")
                        .font(.headline)
                    Text("Bambu Lab, Elegoo, Overture, SUNLU and Polymaker's consumer line, built from each maker's published print profile. Their IDs are not Creality's, so upload the catalogue to the printer (Printers ▸ Upload) before writing tags for them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Add Them") { Task { await model.applyVendorCatalogue() } }
            }
            .padding(12)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.accent.opacity(0.35))
            )
            .padding([.horizontal, .top], 12)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var saveFailureBanner: some View {
        if let failure = model.saveFailure {
            // Persistent, dismissible, actionable — deliberately *not* a toast. A failed write is
            // the one message the user must not miss on a 2-second timer.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes are not saved to disk")
                        .font(.headline)
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if model.diskChangedWhileUnsaved {
                        // Both sides have something the other lacks, so the choice is the user's.
                        Text("The database on disk was also changed from the Printers window while these edits were unsaved. Retry writes your edits over that change; Reload discards your edits and shows what is on disk.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if model.diskChangedWhileUnsaved {
                    Button("Reload") { Task { await model.load() } }
                }
                Button("Retry") { Task { await model.retrySave() } }
                Button {
                    model.saveFailure = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
            .padding(12)
            .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.danger.opacity(0.4))
            )
            .padding([.horizontal, .top], 12)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(model.filteredRows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Colour") { row in
                swatch(for: row)
            }
            .width(min: 34, ideal: 34, max: 40)

            TableColumn("ID", value: \.materialID) { row in
                Text(row.materialID)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, ideal: 70)

            TableColumn("Brand", value: \.brand) { row in
                Text(row.brand)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Name", value: \.name) { row in
                Text(row.name)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Type", value: \.materialType) { row in
                Text(row.materialType)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Min °C", value: \.minTemp) { row in
                Text(row.minTemp, format: .number)
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 60)

            TableColumn("Max °C", value: \.maxTemp) { row in
                Text(row.maxTemp, format: .number)
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 60)

            TableColumn("Colour Name", value: \.colorName) { row in
                Text(row.colorName.isEmpty ? row.colorHex : row.colorName)
                    .foregroundStyle(row.colorName.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            .width(min: 90, ideal: 130)

            TableColumn("Traits", value: \.traits) { row in
                // Text, not an icon or a tint: soluble/support must not be colour-only encoding.
                Text(row.traits.isEmpty ? "—" : row.traits)
                    .foregroundStyle(row.traits.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .width(min: 70, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: FilamentRow.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let row = model.rows.first(where: { $0.id == id }) {
                model.editor = .edit(row.filament)
            }
        }
        // Plain Delete/Backspace, scoped to the table's focus — safe next to the search field,
        // unlike a bare `.keyboardShortcut(.delete)` on a button, which would fire while typing.
        .onDeleteCommand {
            model.requestDeletionOfSelection()
        }
        .accessibilityLabel("Filaments in the \(model.printerType.displayName) database")
    }

    private func swatch(for row: FilamentRow) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(row.swatch ?? Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.25))
            )
            .overlay {
                if row.swatch == nil {
                    // Unparseable hex: say so instead of rendering a plausible-looking blank.
                    Image(systemName: "questionmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            // The swatch is decorative; the value is carried by the Colour Name column too, so a
            // VoiceOver user never depends on the colour itself.
            .accessibilityLabel(row.colorName.isEmpty ? "Colour \(row.colorHex)" : "Colour \(row.colorName)")
            .help(row.colorName.isEmpty ? row.colorHex : "\(row.colorName) (\(row.colorHex))")
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<FilamentRow.ID>) -> some View {
        let selected = model.rows.filter { ids.contains($0.id) }
        if selected.count == 1, let only = selected.first {
            Button("Edit Filament…") { model.editor = .edit(only.filament) }
            Button("Duplicate as New…") { model.editor = .add(template: only.filament) }
            Divider()
            Button("Copy Colour Hex") { copy(only.colorHex) }
            Button("Copy Filament ID") { copy(only.materialID) }
            Divider()
        }
        if !selected.isEmpty {
            Button("Delete…", role: .destructive) { model.requestDeletion(of: selected) }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Printer", selection: $model.printerType) {
                ForEach(PrinterType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 150)
            .accessibilityLabel("Printer family")
            .help("Which printer family's material database to browse")
        }

        ToolbarItemGroup {
            Button {
                model.editor = .add(template: model.addTemplate)
            } label: {
                Label("Add Filament", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("Add filament")
            .help("Add a new filament (⌘N)")
            .disabled(model.loadState != .loaded)

            Button {
                if let filament = model.singleSelection {
                    model.editor = .edit(filament)
                }
            } label: {
                Label("Edit Filament", systemImage: "pencil")
            }
            .keyboardShortcut("e", modifiers: .command)
            .accessibilityLabel("Edit filament")
            .help("Edit the selected filament (⌘E)")
            .disabled(model.singleSelection == nil)

            Button(role: .destructive) {
                model.requestDeletionOfSelection()
            } label: {
                Label("Delete Filament", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityLabel("Delete filament")
            .help("Delete the selected filaments (⌘⌫)")
            .disabled(model.selection.isEmpty)
        }

        ToolbarItem(placement: .status) {
            statusSummary
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(model.rows.count == 1 ? "1 filament" : "\(model.rows.count) filaments")
                .font(.caption)
            Text("Version: \(model.versionDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .help("Database version \(model.version)")
    }

    // MARK: - Helpers

    private var deletionTitle: String {
        model.pendingDeletion.count == 1 ? "Delete Filament" : "Delete \(model.pendingDeletion.count) Filaments"
    }

    /// Keeps the Windows body text (`MainForm.cs:796-802`) but names the records instead of relying
    /// on whatever happened to be selected in two dropdowns.
    private var deletionMessage: String {
        let names = model.pendingDeletion.prefix(6).map { "\($0.brand) \($0.name) (\($0.id))" }
        let more = model.pendingDeletion.count - names.count
        var body = "Do you want to delete?\n\n" + names.joined(separator: "\n")
        if more > 0 { body += "\nand \(more) more" }
        return body + "\n\nThis cannot be undone."
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        model.toast = ToastMessage("Copied to clipboard")
    }

    private func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([model.storage.directory])
    }
}
