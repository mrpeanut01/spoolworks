import SwiftUI
import SpoolworksCore

/// Pulls a filament database **into** the app — from the printer over SSH, or from the bundled
/// factory catalogue.
///
/// Port of the Windows `UpdateForm` (SPEC/03-ui.md §5.4, SPEC/04-printer-net.md §3.2). Naming trap
/// preserved from the original: the sidebar calls this *Download Database* while the window was
/// titled *Update*. This sheet says **Download** throughout, because that is the direction of
/// travel and the Upload sheet already owns the word "Update".
///
/// Fixes carried over from the spec:
/// - `Avaliable Version:` → `Available Version:` (the one sanctioned typo fix, SPEC/03 §8.6).
/// - The version comparison was `long.Parse`, so a non-numeric version threw into a generic
///   "Error checking version" (`UpdateForm.cs:112`). `MaterialVersion.number` returns nil instead
///   and this sheet reports *which* version it could not read.
/// - Everything ran on the UI thread with no cancel.
struct UpdateSheet: View {
    @ObservedObject var model: PrinterViewModel
    let printer: PrinterConfiguration

    @Environment(\.dismiss) private var dismiss

    /// Where the catalogue comes from.
    ///
    /// Windows offers "Creality Cloud" and "the printer" (`chkFromPrinter`). SpoolworksCore has no cloud
    /// client, so the cloud option is replaced by the bundled factory catalogue, which is what the
    /// seeding path already uses and which works with no network at all.
    // TODO(wire): add a `.cloud` case once a Creality catalogue client exists in SpoolworksCore
    // (SPEC/04 §5.1). The merge logic below is source-agnostic and will not need to change.
    enum Source: String, CaseIterable, Identifiable {
        case bundled
        case printer

        var id: String { rawValue }
        var title: String {
            switch self {
            case .bundled: return "Bundled factory catalogue"
            case .printer: return "The printer, over SSH"
            }
        }
    }

    enum Phase: Equatable {
        case form
        case checking
        /// A version was read and compared. `isNewer == false` is the version-conflict state.
        case checked(available: String, isNewer: Bool, unreadable: Bool)
        case downloading(String)
        case succeeded(String)
        case failed(String)
    }

    @State private var phase: Phase = .form
    @State private var source: Source = .printer
    @State private var host = ""
    @State private var password = ""
    @State private var didAttemptRun = false
    @State private var didPrepare = false
    @State private var availableVersion: String?
    @State private var work: Task<Void, Never>?

    // MARK: - Validation

    private var needsCredentials: Bool { source == .printer }

    private var hostError: String? {
        guard needsCredentials else { return nil }
        return host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter the printer's hostname or IP address."
            : nil
    }

    private var passwordError: String? {
        guard needsCredentials else { return nil }
        return password.isEmpty ? "Enter the printer's SSH root password." : nil
    }

    private var canRun: Bool { hostError == nil && passwordError == nil }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 500, idealHeight: 580)
        .onAppear {
            guard !didPrepare else { return }
            didPrepare = true
            host = printer.host
            password = model.password(for: printer.family)
        }
        .onDisappear { work?.cancel() }
        .interactiveDismissDisabled(isBusy)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("Download ") + Text(printer.displayName).foregroundColor(Theme.accent) + Text(" Database"))
                .font(.title2.bold())
            (Text("Enter the address and SSH password of your ")
                + Text(printer.displayName).foregroundColor(Theme.accent)
                + Text(" printer to download the filament database from the printer. This requires root access to be enabled on the printer to work."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .form, .checked:
            formBody
        case .checking:
            busyBody("Reading the printer's database version…")
        case let .downloading(step):
            busyBody(step)
        case let .succeeded(message):
            resultBody(title: message, isError: false, detail: nil)
        case let .failed(message):
            resultBody(title: "Download failed", isError: true, detail: message)
        }
    }

    private var formBody: some View {
        Form {
            Section("Versions") {
                LabeledContent("Installed Version") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MaterialsViewModel.describe(version: printer.databaseVersion))
                        Text(printer.databaseVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                // Typo fixed: Windows reads "Avaliable Version:" (`UpdateForm.Designer.cs:175`).
                LabeledContent("Available Version") {
                    if let availableVersion {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(MaterialsViewModel.describe(version: availableVersion))
                            Text(availableVersion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        Text("Not checked yet")
                            .foregroundStyle(.secondary)
                    }
                }
                versionVerdict
            }

            Section("Source") {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: source) { _, _ in
                    availableVersion = nil
                    phase = .form
                }
            }

            if needsCredentials {
                Section("Connection") {
                    LabeledContent("Printer address") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Hostname or IP", text: $host)
                                .labelsHidden()
                                .frame(maxWidth: 260)
                                .accessibilityLabel("Printer hostname or IP address")
                            inlineError(didAttemptRun ? hostError : nil)
                        }
                    }
                    LabeledContent("Password") {
                        VStack(alignment: .leading, spacing: 4) {
                            // SecureField, never a visible field — see UploadSheet.
                            SecureField("root password", text: $password)
                                .labelsHidden()
                                .frame(maxWidth: 260)
                                .accessibilityLabel("SSH root password")
                            Button("Use Factory Default") {
                                password = PrinterSettings.factoryPassword(for: printer.family)
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                            inlineError(didAttemptRun ? passwordError : nil)
                        }
                    }
                    LabeledContent("Source file") {
                        Text(printer.remotePath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Label("""
                Downloading merges the incoming records into the local database by filament ID: \
                existing IDs are overwritten, new ones are added. Filaments you added that the \
                source does not know about are kept.
                """, systemImage: "arrow.triangle.merge")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// The version-conflict state, spelled out. Windows shows a bare `lblMsg = "No update
    /// available"` (`UpdateForm.cs:118`) and hides the Update button, so there is no way to install
    /// an older-but-different catalogue on purpose. Here the verdict is explained and the action
    /// stays available behind an explicit acknowledgement.
    @ViewBuilder
    private var versionVerdict: some View {
        if case let .checked(available, isNewer, unreadable) = phase {
            if unreadable {
                Label("""
                One of the versions is not a number, so they cannot be compared. \
                Installed: “\(printer.databaseVersion)”, available: “\(available)”. \
                You can still download; it will replace matching filaments.
                """, systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isNewer {
                Label("A newer database is available.", systemImage: "arrow.down.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if printer.databaseVersion == MaterialVersion.preventUpdateSentinel {
                Label("""
                The local database is stamped with the “prevent updates” version, which is higher \
                than any real one by design. Downloading will replace that stamp.
                """, systemImage: "lock.open")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Windows string preserved.
                Label("No update available. The local database is the same age or newer.",
                      systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func busyBody(_ step: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step).font(.headline)
            ProgressView().progressViewStyle(.linear)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func resultBody(title: String, isError: Bool, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Theme.danger : .green)
            }
            if let detail {
                Text(detail)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .form, .checked:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if source == .printer, availableVersion == nil {
                    // Windows only shows Update after a successful Check in printer mode
                    // (`UpdateForm.cs:102-125`). Keeping Check as a distinct, cheap step is right;
                    // forcing it is not, so Download stays enabled beside it.
                    Button("Check") { check() }
                        .disabled(isBusy)
                }
                Button("Download") { download() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(isBusy)
            case .checking, .downloading:
                Button("Cancel", role: .cancel) { work?.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .succeeded:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            case .failed:
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { phase = .form }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func inlineError(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Error: \(message)")
        }
    }

    // MARK: - Work

    private func check() {
        didAttemptRun = true
        guard canRun else { return }
        persistConnection()

        let credentials = model.makeCredentials(host: host, password: password)
        let family = printer.family
        let transport = model.transport
        let installed = printer.databaseVersion

        phase = .checking
        work = Task { @MainActor in
            do {
                let remote = try await transport.remoteDatabaseVersion(credentials, family: family)
                availableVersion = remote
                let unreadable = MaterialVersion.number(remote) == nil
                    || MaterialVersion.number(installed) == nil
                phase = .checked(available: remote,
                                 isNewer: MaterialVersion.isNewer(remote, than: installed),
                                 unreadable: unreadable)
            } catch is CancellationError {
                phase = .failed(PrinterTransportError.cancelled.localizedDescription)
            } catch {
                // Windows collapses every failure here into "Error checking version".
                phase = .failed("Error checking version: \(MaterialsViewModel.message(for: error))")
            }
        }
    }

    private func download() {
        didAttemptRun = true
        guard canRun else { return }
        persistConnection()

        let credentials = model.makeCredentials(host: host, password: password)
        let family = printer.family
        let transport = model.transport
        let chosen = source

        phase = .downloading(chosen == .printer ? "Downloading from the printer…" : "Reading the bundled catalogue…")

        work = Task { @MainActor in
            do {
                let payload: Data
                switch chosen {
                case .printer:
                    payload = try await transport.downloadDatabase(credentials, family: family)
                case .bundled:
                    payload = try BundledMaterialSeed().seedData(for: family)
                }

                guard !payload.isEmpty else {
                    // Windows string preserved.
                    phase = .failed("Database not found. The source returned an empty file.")
                    return
                }

                try Task.checkCancellation()
                phase = .downloading("Merging into the local database…")

                let result = try model.mergeDownloadedDatabase(payload, into: family)
                await model.refresh()
                model.onDatabaseChanged?(family)

                // Windows string preserved, with the counts the original never reported.
                phase = .succeeded("Database Updated — \(result.added) added, \(result.updated) updated")
            } catch is CancellationError {
                phase = .failed(PrinterTransportError.cancelled.localizedDescription)
            } catch {
                phase = .failed("Error updating database: \(MaterialsViewModel.message(for: error))")
            }
        }
    }

    private func persistConnection() {
        guard needsCredentials else { return }
        model.setHost(host, for: printer.family)
        model.setPassword(password, for: printer.family)
    }
}
