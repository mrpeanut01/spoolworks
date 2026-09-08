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
    var hostKeyPolicy: HostKeyPolicy = .acceptNew

    private func service(_ credentials: PrinterCredentials) -> PrinterService {
        let configuration = SSHConfiguration(host: credentials.host,
                                             port: credentials.port,
                                             username: credentials.username,
                                             hostKeyPolicy: hostKeyPolicy)
        return PrinterService(transport: SSHTransport(configuration: configuration,
                                                      password: credentials.password))
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

    func uploadDatabase(_ data: Data,
                        credentials: PrinterCredentials,
                        family: PrinterType,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await service(credentials).upload(database: data,
                                                  to: model(family)) { report in
            progress(report.fractionCompleted)
        }
    }

    func reboot(_ credentials: PrinterCredentials, family _: PrinterType) async throws {
        try await service(credentials).reboot()
    }

    func downloadBoxInfo(_ credentials: PrinterCredentials,
                         family: PrinterType) async throws -> MaterialBoxInfo {
        try await service(credentials).boxInfo(of: model(family))
    }
}
