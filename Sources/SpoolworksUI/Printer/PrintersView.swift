import SwiftUI
import SpoolworksCore

/// Printer management: which printer families have a local material database, and how to reach each
/// one over SSH.
///
/// Replaces the Windows `ManageForm` (SPEC/03-ui.md §5.3), which was a single combo box, a
/// thumbnail, and one button that silently flipped between **Add** and **Delete** depending on
/// whether a file happened to exist — with no confirmation on the delete. Here the list is the
/// state, the destructive action is confirmed, and the per-printer connection settings that Windows
/// scattered across the Upload and Update dialogs live in one place.
struct PrintersView: View {
    @ObservedObject var model: PrinterViewModel
    // RootView attaches `.toast(env.toasts)` once per scene, so this view forwards its
    // view-model's messages into that shared centre rather than presenting its own overlay.
    @EnvironmentObject private var toasts: ToastCenter

    @State private var hasLoaded = false

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                loadingState
            case .loaded:
                if model.printers.isEmpty {
                    emptyState
                } else {
                    HSplitView {
                        printerList
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                        detail
                            .frame(minWidth: 380)
                    }
                }
            }
        }
        .navigationTitle("Printers")
        .toolbar { toolbarContent }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await model.refresh()
        }
        .sheet(isPresented: $model.addSheetPresented) {
            AddPrinterSheet(model: model)
        }
        .sheet(item: $model.uploadTarget) { printer in
            UploadSheet(model: model, printer: printer)
        }
        .sheet(item: $model.updateTarget) { printer in
            UpdateSheet(model: model, printer: printer)
        }
        .confirmationDialog(
            "Remove \(model.pendingRemoval?.displayName ?? "Printer")?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Printer", role: .destructive) {
                Task { await model.confirmRemoval() }
            }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            if let doomed = model.pendingRemoval {
                Text("""
                This deletes the local material database for \(doomed.displayName) \
                (\(doomed.filamentCount) filaments), including any filaments you added yourself, \
                and forgets the saved address.

                Nothing on the printer is changed. This cannot be undone.
                """)
            }
        }
        .onChange(of: model.toast) { _, message in
            guard let message else { return }
            toasts.show(message)
            model.toast = nil
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Looking for installed databases…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Windows' equivalent of "no printers" is a toast that disappears after 3.5 s followed by a
    /// dialog that opens itself a second later (`MainForm.cs:93-103`). A durable state with the
    /// action on it is both more discoverable and less startling.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Printers Configured", systemImage: "printer")
        } description: {
            Text("Add a printer to get started. Each printer keeps its own material database, which you can then upload to the machine.")
        } actions: {
            Button("Add Printer…") { model.addSheetPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    // MARK: - List

    private var printerList: some View {
        List(selection: $model.selection) {
            ForEach(model.printers) { printer in
                HStack(spacing: 10) {
                    Image(systemName: "printer")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(printer.displayName)
                        Text(subtitle(for: printer))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if printer.loadFailure != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                            .accessibilityLabel("Database could not be read")
                            .help("This printer's local database could not be read")
                    }
                }
                .padding(.vertical, 2)
                .tag(printer.family)
                .contextMenu {
                    Button("Upload Database…") { model.uploadTarget = printer }
                    Button("Download Database…") { model.updateTarget = printer }
                    Divider()
                    Button("Remove Printer…", role: .destructive) { model.requestRemoval(of: printer) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onDeleteCommand {
            if let selected = model.selectedPrinter { model.requestRemoval(of: selected) }
        }
    }

    private func subtitle(for printer: PrinterConfiguration) -> String {
        let where_ = printer.isReachableOnPaper ? printer.host : "No address set"
        return "\(printer.filamentCount) filaments · \(where_)"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let printer = model.selectedPrinter {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure = model.actionFailure {
                        banner(failure, onDismiss: { model.actionFailure = nil })
                    }
                    if let failure = printer.loadFailure {
                        banner("The local database for \(printer.displayName) could not be read: \(failure)",
                               onDismiss: nil)
                    }
                    detailForm(printer)
                }
            }
        } else {
            ContentUnavailableView("No Printer Selected",
                                   systemImage: "sidebar.left",
                                   description: Text("Choose a printer on the left to configure it."))
        }
    }

    private func detailForm(_ printer: PrinterConfiguration) -> some View {
        Form {
            Section {
                LabeledContent("Family") {
                    Text(printer.displayName)
                }
                LabeledContent("Local database") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(printer.filamentCount) filaments")
                        Text(MaterialsViewModel.describe(version: printer.databaseVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if printer.databaseVersion == MaterialVersion.preventUpdateSentinel {
                    Label("""
                    This database is stamped with the “prevent updates” version, so the printer will \
                    consider itself up to date and never replace it from Creality's servers.
                    """, systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Database")
            }

            Section {
                LabeledContent("Address") {
                    TextField("Hostname or IP", text: Binding(
                        get: { printer.host },
                        set: { model.setHost($0, for: printer.family) }
                    ))
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Printer hostname or IP address")
                }

                LabeledContent("Password") {
                    VStack(alignment: .leading, spacing: 6) {
                        // SecureField, always. The Windows dialogs use a plain TextBox with no
                        // PasswordChar (SPEC/04 §1.4), so the printer's root password is rendered
                        // in clear on screen. SPEC/03-ui.md §8.5 lists that as a non-goal.
                        SecureField("root password", text: Binding(
                            get: { model.password(for: printer.family) },
                            set: { model.setPassword($0, for: printer.family) }
                        ))
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        .accessibilityLabel("SSH root password for \(printer.displayName)")

                        HStack(spacing: 8) {
                            Button("Use Factory Default") {
                                model.setPassword(PrinterSettings.factoryPassword(for: printer.family),
                                                  for: printer.family)
                            }
                            .help("Fills in the password Creality prints on this model's touchscreen")
                            if printer.hasStoredPassword {
                                Label("Kept for this session only", systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                // TODO(wire): once SpoolworksCore ships a Keychain-backed credential store, replace the
                // in-memory store in PrinterViewModel and soften this footer to "Stored in your
                // keychain". Until then the honest statement is that it is not stored at all.
                Text("""
                The app connects as **root** on port 22, which is what the printer's SSH service \
                expects. The password is held in memory for this session only — it is never written \
                to disk. Root access must be switched on from the printer's touchscreen first.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { printer.preventDatabaseUpdates },
                    set: { model.setPreventDatabaseUpdates($0, for: printer.family) }
                )) {
                    Text("Prevent database updates on the printer")
                    Text("Stamps the uploaded database with an impossibly high version so the printer's own updater leaves your filaments alone.")
                }

                Toggle(isOn: Binding(
                    get: { printer.rebootAfterUpload },
                    set: { model.setRebootAfterUpload($0, for: printer.family) }
                )) {
                    Text("Reboot the printer after uploading")
                    Text("The printer only reads a new database at start-up, so without this the change takes effect on its next restart.")
                }
            } header: {
                Text("Upload Defaults")
            }

            Section {
                LabeledContent("Remote path") {
                    Text(printer.remotePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    Button {
                        model.updateTarget = printer
                    } label: {
                        Label("Download Database…", systemImage: "square.and.arrow.down")
                    }
                    .help("Pull the filament database from the printer or the bundled catalogue")

                    Button {
                        model.uploadTarget = printer
                    } label: {
                        Label("Upload Database…", systemImage: "square.and.arrow.up")
                    }
                    .help("Push this Mac's filament database to the printer")

                    Spacer()

                    Button(role: .destructive) {
                        model.requestRemoval(of: printer)
                    } label: {
                        Label("Remove Printer…", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Delete the local database for this printer (⌘⌫)")
                }
            } header: {
                Text("Actions")
            }
        }
        .formStyle(.grouped)
    }

    private func banner(_ message: String, onDismiss: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(Theme.danger.opacity(0.4))
        )
        .padding([.horizontal, .top], 12)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.addSheetPresented = true
            } label: {
                Label("Add Printer", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("Add printer")
            .help("Add a printer (⌘N)")
            .disabled(model.configurableFamilies.isEmpty)

            Button(role: .destructive) {
                if let selected = model.selectedPrinter { model.requestRemoval(of: selected) }
            } label: {
                Label("Remove Printer", systemImage: "trash")
            }
            .accessibilityLabel("Remove printer")
            .help("Remove the selected printer")
            .disabled(model.selectedPrinter == nil)
        }
    }
}

// MARK: - Add sheet

/// Picks which printer family to install a database for.
///
/// The Windows dialog lists *cloud* printer names and downloads the catalogue over HTTP
/// (`ManageForm.cs:29,58`), so first run needs a working network and a live Creality API. SpoolworksCore
/// ships all three catalogues in the bundle, so this works offline; the Download sheet is where a
/// fresher copy comes from.
struct AddPrinterSheet: View {
    @ObservedObject var model: PrinterViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var choice: PrinterType?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Printer")
                    .font(.title2.bold())
                Text("Each printer family keeps its own material database.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .accessibilityAddTraits(.isHeader)

            Divider()

            if model.configurableFamilies.isEmpty {
                ContentUnavailableView("All Printers Added",
                                       systemImage: "checkmark.circle",
                                       description: Text("Every supported printer family already has a local database."))
                    .frame(minHeight: 180)
            } else {
                Form {
                    Picker("Printer", selection: $choice) {
                        Text("Choose…").tag(PrinterType?.none)
                        ForEach(model.configurableFamilies, id: \.self) { family in
                            Text(family.displayName).tag(PrinterType?.some(family))
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityLabel("Printer family")
                }
                .formStyle(.grouped)
                .frame(minHeight: 180)
            }

            Divider()

            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Installing catalogue…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let choice else { return }
                    isWorking = true
                    Task {
                        await model.addPrinter(choice)
                        isWorking = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(choice == nil || isWorking)
            }
            .padding(20)
        }
        .frame(minWidth: 420, idealWidth: 460)
    }
}
