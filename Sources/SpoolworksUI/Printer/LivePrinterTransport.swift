import Foundation
import SpoolworksCore

/// The real SSH transport, connecting the UI to ``SpoolworksCore/PrinterService``.
///
/// ## Why this file exists
///
/// `PrinterViewModel` was written against a `PrinterTransporting` protocol whose only conformer
/// was ``UnimplementedPrinterTransport`` — a stand-in that throws `notImplemented` from every
/// method — and `AppEnvironment` took the default. So the core shipped a complete, tested
/// `PrinterService` and `SSHTransport`, and the app on screen could not reach either: every upload
/// and every version check failed with "not implemented yet".
///
/// This is the missing wire. It builds one `SSHTransport` per call rather than holding a
/// connection open, which matches how the Windows original behaves (connect, do one thing,
/// disconnect) and means a changed password or address takes effect on the next operation with no
/// invalidation logic.
///
/// The password never lands in ``SSHConfiguration``: it is handed to `SSHTransport`'s convenience
/// initialiser, which passes it to the child process over a private FIFO. Nothing here writes it
/// to defaults, a file or a log.
struct LivePrinterTransport: PrinterTransporting {

    /// Trust on first use. The alternative, `.strict`, would refuse every printer until the user
    /// hand-pinned a host key, which no Creality client has ever asked for; `.acceptNew` still
    /// fails loudly if a pinned key later *changes*, which is the attack worth catching.
    let hostKeyPolicy: HostKeyPolicy

    /// What the printer is doing, from Moonraker. It answers without a password, and every restart
    /// is checked against it. Injectable so tests can script a print.
    private let activityReader: PrinterActivityReading

    /// Builds the session for one call. Injectable so the option plumbing between the sheet and
    /// `PrinterService` can be exercised against `MockPrinterTransport` — that plumbing is exactly
    /// what went wrong once already, when every upload ran with the service's defaults whatever
    /// the sheet said.
    private let makeTransport: @Sendable (PrinterCredentials, HostKeyPolicy) -> PrinterTransport

    init(hostKeyPolicy: HostKeyPolicy = .acceptNew,
         activityReader: PrinterActivityReading = MoonrakerClient(),
         makeTransport: @escaping @Sendable (PrinterCredentials, HostKeyPolicy) -> PrinterTransport
            = { LivePrinterTransport.ssh($0, policy: $1) }) {
        self.hostKeyPolicy = hostKeyPolicy
        self.activityReader = activityReader
        self.makeTransport = makeTransport
    }

    private static func ssh(_ credentials: PrinterCredentials, policy: HostKeyPolicy) -> PrinterTransport {
        let configuration = SSHConfiguration(host: credentials.host,
                                             port: credentials.port,
                                             username: credentials.username,
                                             hostKeyPolicy: policy)
        return SSHTransport(configuration: configuration, password: credentials.password)
    }

    private func service(_ credentials: PrinterCredentials) -> PrinterService {
        PrinterService(transport: makeTransport(credentials, hostKeyPolicy))
    }

    /// The printer family's own idea of itself. `PrinterModel` is constructed with the family the
    /// user chose rather than classified from a name, because the user already told us.
    private func model(_ family: PrinterType) -> PrinterModel {
        PrinterModel(profileName: family.displayName, family: PrinterFamily(family))
    }

    func remoteDatabaseVersion(_ credentials: PrinterCredentials,
                               family: PrinterType) async throws -> String {
        try await service(credentials).printerDatabaseVersion(of: model(family))
    }

    func downloadDatabase(_ credentials: PrinterCredentials,
                          family: PrinterType) async throws -> Data {
        try await service(credentials).downloadDatabaseFromPrinter(model(family))
    }

    /// The sheet's choices go through as given. This used to call `upload` with `UploadOptions()`,
    /// so the "Allow printer database updates" switch changed nothing on the wire. The upload does
    /// not restart the printer; the sheet asks about that separately.
    func uploadDatabase(_ data: Data,
                        credentials: PrinterCredentials,
                        family: PrinterType,
                        options: UploadOptions,
                        progress: @escaping @Sendable (PrinterProgress) -> Void) async throws -> String {
        let result = try await service(credentials).upload(database: data,
                                                           to: model(family),
                                                           options: options,
                                                           progress: progress)
        return result.version
    }

    /// `PrinterService.reset` owns the reset semantics — the document's own version is kept and the
    /// K1 side-car is written — so nothing here second-guesses it. Stamping the prevent sentinel on
    /// a factory catalogue, as the old upload path did, would have blocked the very updates a reset
    /// exists to hand back to the printer. Like an upload, it does not restart the printer.
    func resetDatabase(_ data: Data,
                       credentials: PrinterCredentials,
                       family: PrinterType,
                       progress: @escaping @Sendable (PrinterProgress) -> Void) async throws {
        _ = try await service(credentials).reset(to: model(family),
                                                 withCloudDatabase: data,
                                                 progress: progress)
    }

    func activity(host: String) async throws -> PrinterActivity {
        try await activityReader.activity(host: host.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The service reads the printer's state itself, immediately before the command, so nothing
    /// calling this can restart a printer that is printing.
    func restartIfIdle(_ credentials: PrinterCredentials, family _: PrinterType) async throws {
        try await service(credentials).restartIfIdle(
            host: credentials.host.trimmingCharacters(in: .whitespacesAndNewlines),
            checkingWith: activityReader)
    }

    func downloadBoxInfo(_ credentials: PrinterCredentials,
                         family: PrinterType) async throws -> MaterialBoxInfo {
        try await service(credentials).boxInfo(of: model(family))
    }
}
