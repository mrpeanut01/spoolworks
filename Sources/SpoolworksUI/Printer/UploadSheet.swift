import SwiftUI
import SpoolworksCore

/// Pushes this Mac's material database **to** the printer over SSH, or resets the printer back to
/// the factory catalogue.
///
/// Port of the Windows `UploadForm` (SPEC/03-ui.md §5.5, SPEC/04-printer-net.md §3.1) with its three
/// worst properties removed:
///
/// 1. The whole SSH transfer ran **synchronously on the UI thread** (`UploadForm.cs:141-169`), so
///    the window froze — and showed "not responding" against a dead host — for the entire operation.
///    Here it is an async `Task` with a real progress indicator.
/// 2. There was **no cancel**: `btnCancel` only worked before the operation started, and once it had
///    started the UI thread was blocked so the button could not be clicked at all (SPEC/04 §7).
///    Here Cancel is live for the whole transfer.
/// 3. The password was a plain `TextBox` with no `PasswordChar` (SPEC/04 §1.4). Here it is a
///    `SecureField`.
struct UploadSheet: View {
    @ObservedObject var model: PrinterViewModel
    let printer: PrinterConfiguration

    @Environment(\.dismiss) private var dismiss

    /// Every state this flow can be in, so none of them is an accident.
    enum Phase: Equatable {
        case form
        /// `fraction` is nil while the transport cannot report progress (SCP over an exec channel
        /// often cannot until the byte count is known).
        case running(step: String, fraction: Double?)
        case succeeded(String)
        case failed(String)
    }

    @State private var phase: Phase = .form
    @State private var host = ""
    @State private var password = ""
    @State private var prevent = true
    @State private var reboot = true
    @State private var isResetMode = false
    @State private var resetLocalDatabaseToo = false
    @State private var didAttemptRun = false
    @State private var work: Task<Void, Never>?
    @State private var didPrepare = false

    // MARK: - Validation

    private var hostError: String? {
        // The only validation Windows performs is non-empty, and it applies it to both fields at
        // once as a single toast (`UploadForm.cs:206`). Splitting it per-field means the user is
        // told which one is missing.
        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter the printer's hostname or IP address."
            : nil
    }

    private var passwordError: String? {
        password.isEmpty ? "Enter the printer's SSH root password." : nil
    }

    private var canRun: Bool {
        hostError == nil && passwordError == nil
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
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
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 600)
        .onAppear {
            guard !didPrepare else { return }
            didPrepare = true
            host = printer.host
            password = model.password(for: printer.family)
            prevent = !printer.allowDatabaseUpdates
            reboot = printer.rebootAfterUpload
        }
        .onDisappear { work?.cancel() }
        .interactiveDismissDisabled(isRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Windows: "Update <printer> Database" / "Reset <printer> Database"
            // (`UploadForm.cs:38`), rendered by hand-searching a RichTextBox for the substrings and
            // recolouring them. Composed Text does the same job without the Find-and-select code.
            (Text(isResetMode ? "Reset " : "Update ").foregroundColor(isResetMode ? Theme.warning : .primary)
                + Text(printer.displayName).foregroundColor(Theme.accent)
                + Text(" Database"))
                .font(.title2.bold())

            description
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var description: Text {
        Text("Enter the address and SSH password of your ")
            + Text(printer.displayName).foregroundColor(Theme.accent)
            + Text(" printer to ")
            + Text(isResetMode ? "Reset" : "Update").foregroundColor(Theme.warning).bold()
            + Text(" the filament database on the printer. This requires root access to be enabled on the printer to work.")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .form:
            formBody
        case let .running(step, fraction):
            runningBody(step: step, fraction: fraction)
        case let .succeeded(message):
            succeededBody(message)
        case let .failed(message):
            failedBody(message)
        }
    }

    private var formBody: some View {
        Form {
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
            }

            Section("What to send") {
                Picker("Mode", selection: $isResetMode) {
                    Text("Upload my database").tag(false)
                    Text("Reset to factory database").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                // Windows stacked `chkReset`, `chkReboot` and a hidden `chkResetApp` in overlapping
                // rectangles and swapped visibility (`UploadForm.cs:105-127`). It is one mode with
                // two values, so it is one picker.

                if isResetMode {
                    Toggle(isOn: $resetLocalDatabaseToo) {
                        Text("Also reset this Mac's database")
                        Text("Replaces the local \(printer.displayName) catalogue with the bundled factory copy. Any filaments you added are lost.")
                    }
                    Label("The printer always reboots after a reset.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(isOn: Binding(get: { !prevent }, set: { prevent = !$0 })) {
                        Text("Allow printer database updates")
                        Text("Off stamps the upload with version \(MaterialVersion.preventUpdateSentinel), so the printer's own updater never replaces it.")
                    }
                    Toggle(isOn: $reboot) {
                        Text("Reboot the printer afterwards")
                        Text(prevent
                             ? "Unavailable while updates are blocked — a restart is when the printer's updater runs."
                             : "The printer only reads the database at start-up.")
                    }
                    .disabled(prevent)
                }
            }

            Section {
                LabeledContent("Destination") {
                    Text(printer.remotePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Sending") {
                    Text(isResetMode
                         ? "Bundled factory catalogue"
                         : "\(printer.filamentCount) filaments · \(MaterialsViewModel.describe(version: printer.databaseVersion))")
                }
            } header: {
                Text("Summary")
            } footer: {
                if isResetMode {
                    Label("This overwrites the filament database on the printer with the factory catalogue.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func runningBody(step: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step)
                .font(.headline)
            if let fraction {
                ProgressView(value: fraction) {
                    Text("Transferring")
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text("Cancelling is safe up to the point the transfer starts. If the connection drops mid-transfer the printer can be left with a partial database — re-run the upload to fix it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func succeededBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                // Preserves the Windows completion strings verbatim, including the two-line
                // "…\nRebooting printer" form (`UploadForm.cs:174-183`).
                Text(message).font(.headline)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if reboot || isResetMode {
                Text("The printer will be unreachable for a minute or so while it restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func failedBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Upload failed").font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            }
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing on the printer was changed unless the transfer had already started. Check the address, the password, and that root access is enabled on the printer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            case .form:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isResetMode ? "Reset Printer Database" : "Upload") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(isResetMode ? Theme.warning : Theme.accent)
            case .running:
                Button("Cancel Transfer", role: .cancel) {
                    work?.cancel()
                }
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

    private func run() {
        didAttemptRun = true
        guard canRun else { return }

        // Persist the non-secret settings the way the Windows dialog does (`UploadForm.cs:137`).
        // The password goes to the Keychain-backed credential store, never to defaults.
        model.setHost(host, for: printer.family)
        model.setPassword(password, for: printer.family)
        if !isResetMode {
            // `prevent` is the sheet's own local sense; the stored preference is its inverse.
            // Reboot is written *after*, and only when updates are allowed — otherwise
            // setAllowDatabaseUpdates's own clearing of it would be undone on the next line.
            model.setAllowDatabaseUpdates(!prevent, for: printer.family)
            if !prevent { model.setRebootAfterUpload(reboot, for: printer.family) }
        }

        let credentials = model.makeCredentials(host: host, password: password)
        let family = printer.family
        let transport = model.transport
        let reset = isResetMode
        let alsoResetLocal = resetLocalDatabaseToo
        let preventUpdates = prevent
        let shouldReboot = reboot

        phase = .running(step: reset ? "Resetting…" : "Preparing…", fraction: nil)

        work = Task { @MainActor in
            do {
                let payload: Data
                if reset {
                    // Windows fetches a fresh catalogue from Creality Cloud (`Utils.cs:454`).
                    // SpoolworksCore ships the factory catalogues in the bundle, so this works offline.
                    payload = try BundledMaterialSeed().seedData(for: family)
                    if alsoResetLocal {
                        try payload.write(to: model.storage.url(for: family), options: .atomic)
                        model.onDatabaseChanged?(family)
                    }
                } else {
                    if preventUpdates {
                        try model.setLocalVersion(MaterialVersion.preventUpdateSentinel, for: family)
                    } else {
                        // Windows swallows a failed version read and stamps "0"
                        // (`Utils.cs:678-681`), silently making the local database look ancient.
                        // Here the failure stops the upload and says so.
                        phase = .running(step: "Reading the printer's database version…", fraction: nil)
                        let remote = try await transport.remoteDatabaseVersion(credentials, family: family)
                        try model.setLocalVersion(remote, for: family)
                    }
                    payload = try model.localDatabaseData(for: family)
                }

                try Task.checkCancellation()
                phase = .running(step: reset ? "Resetting…" : "Uploading…", fraction: nil)

                try await transport.uploadDatabase(payload,
                                                   credentials: credentials,
                                                   family: family) { fraction in
                    Task { @MainActor in
                        if case .running(let step, _) = phase {
                            phase = .running(step: step, fraction: fraction)
                        }
                    }
                }

                // TODO(wire): K1 also expects a `material_option.json` side-car next to the database
                // (SPEC/04 §2, `PrinterType.usesMaterialOptionSidecar`). Building and pushing it
                // belongs in SpoolworksCore's PrinterService, not in a view — wire it here once that exists.

                try Task.checkCancellation()

                // A reset always reboots — the Windows reboot switch is hidden and ignored in reset
                // mode (`Utils.cs:470`).
                let willReboot = reset || shouldReboot
                if willReboot {
                    phase = .running(step: "Rebooting the printer…", fraction: nil)
                    try await transport.reboot(credentials, family: family)
                }

                await model.refresh()
                if reset { model.onDatabaseChanged?(family) }

                if reset {
                    phase = .succeeded("Reset complete\nRebooting printer")
                } else if willReboot {
                    phase = .succeeded("Upload complete\nRebooting printer")
                } else {
                    phase = .succeeded("Upload complete")
                }
            } catch is CancellationError {
                phase = .failed(PrinterTransportError.cancelled.localizedDescription)
            } catch {
                phase = .failed(MaterialsViewModel.message(for: error))
            }
        }
    }
}
