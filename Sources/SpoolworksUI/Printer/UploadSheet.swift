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
///
/// And one behaviour changed on purpose: it never restarts the printer by itself. Windows reboots
/// straight after every upload and reset, print or no print. Here, once the database is on the
/// printer, the sheet asks — and a printer that is printing is only ever offered a restart once the
/// print has finished (docs/DECISIONS.md D-006).
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

    /// After the database has gone over: whether the printer is being checked, which question is
    /// up, and what came of it.
    enum RestartStage: Equatable {
        case notStarted
        case checking
        case asking(PrinterRestartPrompt)
        case restarting
        case restarted
        case scheduled
        case manual
        case failed(String)
    }

    @State private var phase: Phase = .form
    @State private var restart: RestartStage = .notStarted
    @State private var host = ""
    @State private var password = ""
    @State private var prevent = true
    @State private var isResetMode = false
    @State private var resetLocalDatabaseToo = false
    @State private var didAttemptRun = false
    @State private var work: Task<Void, Never>?
    @State private var didPrepare = false
    /// Kept from the run, for the restart that may follow it.
    @State private var restartCredentials: PrinterCredentials?

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

    /// While the printer is being checked or restarted, the sheet stays up: closing it then would
    /// leave the question unasked, or the answer unreported.
    private var isRestartInFlight: Bool {
        switch restart {
        case .checking, .restarting: return true
        default: return false
        }
    }

    private var restartPrompt: PrinterRestartPrompt? {
        if case let .asking(prompt) = restart { return prompt }
        return nil
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
        }
        .onDisappear { work?.cancel() }
        .interactiveDismissDisabled(isRunning || isRestartInFlight)
        // Every answer sets `restart`, which is what dismisses the alert, so the binding's setter has
        // nothing to do — and must not guess an answer on the user's behalf.
        .alert(restartPrompt?.title ?? "",
               isPresented: Binding(get: { restartPrompt != nil }, set: { _ in }),
               presenting: restartPrompt) { prompt in
            restartActions(prompt)
        } message: { prompt in
            Text(prompt.message(printerName: printer.displayName))
        }
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
                        Text("Once the printer has been reset, replaces the local \(printer.displayName) catalogue with the bundled factory copy. Any filaments you added are lost.")
                    }
                } else {
                    Toggle(isOn: Binding(get: { !prevent }, set: { prevent = !$0 })) {
                        Text("Allow printer database updates")
                        Text("Off stamps the upload with version \(MaterialVersion.preventUpdateSentinel), so the printer's own updater never replaces it.")
                    }
                }
                // In place of the Windows "Reboot printer?" switch, and of a reset's unconditional
                // reboot: the question is asked once the database is on the printer.
                Label("Once it is sent, Spoolworks asks before restarting the printer, and never restarts it while it is printing.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text(message).font(.headline)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            restartStatus
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var restartStatus: some View {
        switch restart {
        case .notStarted, .checking:
            progressLine("Checking whether \(printer.displayName) is printing…")
        case .asking:
            EmptyView()
        case .restarting:
            progressLine("Restarting \(printer.displayName)…")
        case .restarted:
            Text("\(printer.displayName) is restarting and will be unreachable for a minute or so. It uses the new database once it is back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .scheduled:
            Label("Spoolworks will restart \(printer.displayName) once the print has finished and the printer has been idle for \(PrinterRestartScheduler.describe(model.restarts.quietPeriod)). Keep Spoolworks open; the Printers window shows the pending restart and can cancel it.",
                  systemImage: "clock.arrow.circlepath")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .manual:
            reminder("\(printer.displayName) keeps using its current database until it restarts. Restart it yourself once it isn't printing.")
        case let .failed(message):
            reminder("The restart didn't go through: \(message) Restart \(printer.displayName) yourself once it isn't printing.")
        }
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

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func reminder(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.callout)
            .foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
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
                    .disabled(isRestartInFlight)
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

    // MARK: - Restart questions

    @ViewBuilder
    private func restartActions(_ prompt: PrinterRestartPrompt) -> some View {
        switch prompt {
        case .confirmRestart:
            Button("Yes, Restart") { restartNow() }
            Button("No", role: .cancel) { restartManually() }
        case .printInProgress, .printerBusy:
            Button(prompt.automaticRestartLabel) { restartWhenFinished() }
            Button("Restart Manually", role: .cancel) { restartManually() }
        case .cannotConfirm:
            Button("Check Again") { checkPrinter() }
            Button("Restart Manually", role: .cancel) { restartManually() }
        }
    }

    /// Asks the printer what it is doing, then asks the matching question. Restarts nothing.
    private func checkPrinter() {
        guard let credentials = restartCredentials else { return }
        restart = .checking
        let transport = model.transport
        work = Task { @MainActor in
            do {
                let activity = try await transport.activity(host: credentials.host)
                restart = .asking(PrinterRestartPrompt(activity: activity))
            } catch is CancellationError {
                return
            } catch {
                restart = .asking(.cannotConfirm(MaterialsViewModel.message(for: error)))
            }
        }
    }

    /// "Yes, restart." The service reads the printer's state again immediately before sending, so a
    /// print started while the question was up is caught there, and the question changes with it.
    private func restartNow() {
        guard let credentials = restartCredentials else { return }
        // This answer supersedes an automatic restart left pending by an earlier upload.
        model.restarts.cancel(family: printer.family)
        restart = .restarting
        let transport = model.transport
        let family = printer.family
        work = Task { @MainActor in
            do {
                try await transport.restartIfIdle(credentials, family: family)
                restart = .restarted
            } catch let refusal as RestartRefusal {
                restart = .asking(PrinterRestartPrompt(refusal: refusal))
            } catch is CancellationError {
                restart = .manual
            } catch {
                restart = .failed(MaterialsViewModel.message(for: error))
            }
        }
    }

    private func restartWhenFinished() {
        model.restarts.schedule(family: printer.family,
                                printerName: printer.displayName,
                                host: restartCredentials?.host ?? printer.host)
        restart = .scheduled
    }

    private func restartManually() {
        model.restarts.cancel(family: printer.family)
        restart = .manual
    }

    // MARK: - Work

    private func run() {
        didAttemptRun = true
        guard canRun else { return }

        // Persist the non-secret settings the way the Windows dialog does (`UploadForm.cs:137`).
        // The password goes to the credential file through the store, never to defaults.
        model.setHost(host, for: printer.family)
        model.setPassword(password, for: printer.family)
        if !isResetMode {
            // `prevent` is the sheet's own local sense; the stored preference is its inverse.
            model.setAllowDatabaseUpdates(!prevent, for: printer.family)
        }

        let credentials = model.makeCredentials(host: host, password: password)
        restartCredentials = credentials
        restart = .notStarted
        let family = printer.family
        let transport = model.transport
        let reset = isResetMode
        let alsoResetLocal = resetLocalDatabaseToo
        // Everything the service needs to know, decided here and handed over once. The service
        // stamps the version (reading the printer's own when updates are allowed — Windows
        // swallows a failed read there and stamps "0", `Utils.cs:678-681`; here the failure stops
        // the upload) and writes the K1 side-car. It does not restart the printer: once it is done,
        // `checkPrinter()` asks.
        let options = UploadOptions(preventDatabaseUpdates: prevent)

        phase = .running(step: reset ? "Resetting…" : "Preparing…", fraction: nil)

        work = Task { @MainActor in
            let report: @Sendable (PrinterProgress) -> Void = { progress in
                Task { @MainActor in
                    phase = .running(step: Self.step(for: progress.stage, reset: reset),
                                     fraction: progress.fractionCompleted)
                }
            }
            do {
                var note = ""
                if reset {
                    // Windows fetches a fresh catalogue from Creality Cloud (`Utils.cs:454`).
                    // SpoolworksCore ships the factory catalogues in the bundle, so this works offline.
                    let payload = try BundledMaterialSeed().seedData(for: family)
                    try await transport.resetDatabase(payload,
                                                      credentials: credentials,
                                                      family: family,
                                                      progress: report)
                    // Only once the printer has it. Writing the local file first meant a cancelled
                    // or failed reset had already thrown away this Mac's catalogue.
                    if alsoResetLocal {
                        try payload.write(to: model.storage.url(for: family), options: .atomic)
                    }
                } else {
                    let payload = try model.localDatabaseData(for: family)
                    let version = try await transport.uploadDatabase(payload,
                                                                     credentials: credentials,
                                                                     family: family,
                                                                     options: options,
                                                                     progress: report)
                    // Mirror on the local file what was stamped on the wire, so the Printers
                    // screen's "Locked" reading and the Download sheet's comparison describe the
                    // database the printer actually has. The printer has it either way, so a
                    // failure here is a footnote on a success, not a failed upload.
                    do {
                        try model.setLocalVersion(version, for: family)
                    } catch {
                        note = "\nThe local copy's version could not be updated: "
                            + MaterialsViewModel.message(for: error)
                    }
                }

                await model.refresh()
                model.onDatabaseChanged?(family)

                phase = .succeeded((reset ? "Reset complete" : "Upload complete") + note)
                checkPrinter()
            } catch is CancellationError {
                phase = .failed(PrinterUIError.cancelled.localizedDescription)
            } catch {
                phase = .failed(MaterialsViewModel.message(for: error))
            }
        }
    }

    /// The service's stages in the user's words, and the sheet's own earlier step names.
    private static func step(for stage: PrinterProgress.Stage, reset: Bool) -> String {
        switch stage {
        case .preparing:
            return reset ? "Resetting…" : "Preparing…"
        case .readingPrinterVersion:
            return "Reading the printer's database version…"
        case .uploadingDatabase:
            return reset ? "Sending the factory catalogue…" : "Uploading…"
        case .uploadingMaterialOption:
            return "Writing material_option.json…"
        case .downloadingDatabase, .finished:
            return "Finishing…"
        }
    }
}
