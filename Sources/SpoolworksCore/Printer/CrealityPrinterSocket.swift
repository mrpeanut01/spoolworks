import Foundation

// SPEC-04 has no section for this, because neither upstream client uses it. Creality printers
// serve a websocket on port 9999 — the one Creality Print's device page talks to — and it answers
// `{"method":"get","params":{"reqMaterials":1}}` with the printer's filament list, no password
// asked. That makes it the cheap way to answer "does the printer know this filament?" before
// anything needs the root password.
//
// Read-only by design. The same socket accepts `set` requests that change CFS slots, and nothing
// here sends one. See D-013.

/// Reads the ids in a printer's live filament list.
public protocol PrinterFilamentListReading: Sendable {
    func filamentIDs(host: String) async throws -> Set<String>
}

public enum CrealitySocketError: Error, Equatable, CustomStringConvertible {
    case invalidHost(String)
    case connectionFailed(String)
    case timedOut(seconds: Double)

    public var description: String {
        switch self {
        case let .invalidHost(host):
            return "Invalid printer address: \(host)"
        case let .connectionFailed(detail):
            return "Could not reach the printer: \(detail)"
        case let .timedOut(seconds):
            return "The printer did not send its filament list within \(Int(seconds))s."
        }
    }
}

extension CrealitySocketError: LocalizedError {
    public var errorDescription: String? { description }
}

/// The printer's local websocket, used for one read-only question.
public struct CrealityPrinterSocket: PrinterFilamentListReading {

    public static let port = 9999

    /// The request Creality Print sends on connect, less everything else it asks for.
    static let materialListRequest = #"{"method":"get","params":{"reqMaterials":1}}"#

    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func filamentIDs(host: String) async throws -> Set<String> {
        guard let url = Self.url(host: host) else { throw CrealitySocketError.invalidHost(host) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: url)
        // A K2 Plus with 105 filaments sends ~370 KB; the default ceiling is 1 MB.
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        let deadline = timeout

        do {
            try await socket.send(.string(Self.materialListRequest))
            return try await withThrowingTaskGroup(of: Set<String>.self) { group in
                group.addTask {
                    while true {
                        let data: Data
                        switch try await socket.receive() {
                        case let .string(text): data = Data(text.utf8)
                        case let .data(bytes): data = bytes
                        @unknown default: continue
                        }
                        // The printer pushes status on its own schedule; only the reply counts.
                        if let ids = Self.filamentIDs(fromReply: data) { return Set(ids) }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    throw CrealitySocketError.timedOut(seconds: deadline)
                }
                defer {
                    // `receive()` does not observe task cancellation; closing the socket ends it.
                    socket.cancel(with: .normalClosure, reason: nil)
                    group.cancelAll()
                }
                guard let first = try await group.next() else {
                    throw CrealitySocketError.timedOut(seconds: deadline)
                }
                return first
            }
        } catch let error as CrealitySocketError {
            throw error
        } catch {
            socket.cancel(with: .normalClosure, reason: nil)
            throw CrealitySocketError.connectionFailed(error.localizedDescription)
        }
    }

    /// The ids in a `retMaterials` reply, in the printer's order with duplicates kept — or `nil`
    /// for any other message, including the status frames the printer pushes unprompted.
    public static func filamentIDs(fromReply data: Data) -> [String]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = object["retMaterials"] as? [Any] else { return nil }
        return records.compactMap { (($0 as? [String: Any])?["base"] as? [String: Any])?["id"] as? String }
    }

    /// `ws://<host>:9999/`, or `nil` for an address that is not just a host.
    static func url(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !trimmed.contains("/"),
              !trimmed.contains(":") else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = trimmed
        components.port = port
        components.path = "/"
        return components.url
    }
}
