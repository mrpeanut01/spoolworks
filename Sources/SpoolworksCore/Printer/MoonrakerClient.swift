import Foundation

/// Reads the printer's job state from Moonraker.
///
/// Klipper-based Creality printers expose Moonraker over plain HTTP on port 7125 — no
/// authentication, no SSH. That makes the job poll far cheaper than the CFS poll, which spawns an
/// `ssh` process per read, so the two run at different rates.
///
/// Only `/printer/objects/query` is used, and only to read. Moonraker will happily accept gcode
/// over the same interface; nothing here does, and nothing here should.
public protocol PrintJobReading: Sendable {
    func snapshot(host: String) async throws -> PrintJobSnapshot
}

public enum MoonrakerError: Error, CustomStringConvertible {
    case badResponse(status: Int)
    case malformed(String)

    public var description: String {
        switch self {
        case let .badResponse(status): return "The printer's API returned HTTP \(status)."
        case let .malformed(detail): return "The printer's API returned something unexpected: \(detail)."
        }
    }

    public var errorDescription: String? { description }
}

public struct MoonrakerClient: PrintJobReading, PrinterActivityReading {

    public var port: Int
    public var timeout: TimeInterval
    private let session: URLSession

    public init(port: Int = 7125, timeout: TimeInterval = 6, session: URLSession = .shared) {
        self.port = port
        self.timeout = timeout
        self.session = session
    }

    public func snapshot(host: String) async throws -> PrintJobSnapshot {
        // `box` is Creality's own object, not stock Klipper — it is what names the feeding slot.
        try Self.decode(try await query(host: host, objects: ["print_stats", "box"]))
    }

    /// What the printer is doing, for deciding whether it may be restarted. See
    /// ``decodeActivity(_:)``.
    public func activity(host: String) async throws -> PrinterActivity {
        try Self.decodeActivity(try await query(host: host, objects: ["print_stats", "idle_timeout"]))
    }

    private func query(host: String, objects: [String]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/printer/objects/query"
        components.queryItems = objects.map { URLQueryItem(name: $0, value: nil) }
        guard let url = components.url else {
            throw MoonrakerError.malformed("could not build a URL for \(host)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw MoonrakerError.badResponse(status: http.statusCode)
        }
        return data
    }

    /// Split out from the transport so the parsing can be tested against captured payloads.
    public static func decode(_ data: Data) throws -> PrintJobSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let status = result["status"] as? [String: Any] else {
            throw MoonrakerError.malformed("no result.status object")
        }
        let stats = status["print_stats"] as? [String: Any] ?? [:]
        let filename = stats["filename"] as? String ?? ""
        let used = stats["filament_used"] as? Double ?? 0
        let state = PrintJobSnapshot.State(rawValue: (stats["state"] as? String) ?? "standby")
            ?? .standby

        // box.T<n>.filament is the slot letter — "A" — and the box key supplies the "T1".
        // Deliberately not box.T<n>.filament_detected, which reads "None" throughout a print.
        var feeding: String?
        if let box = status["box"] as? [String: Any] {
            for (key, value) in box.sorted(by: { $0.key < $1.key }) {
                guard key.hasPrefix("T"), let unit = value as? [String: Any],
                      let letter = unit["filament"] as? String,
                      letter != "None", !letter.isEmpty else { continue }
                feeding = key + letter
                break
            }
        }

        return PrintJobSnapshot(filename: filename,
                                state: state,
                                filamentUsedMillimetres: used,
                                feedingSlot: feeding)
    }

    /// Reads ``PrinterActivity`` from a `print_stats` + `idle_timeout` query.
    ///
    /// Strict where ``decode(_:)`` is lenient. A job snapshot can default a missing state to
    /// `standby`; here that default would read as "idle" and let a restart through, so a missing or
    /// unrecognised `print_stats.state` is an error, which
    /// ``PrinterService/restartIfIdle(host:checkingWith:)`` turns into a refusal. `idle_timeout` is
    /// Klipper's own "is anything executing", and only ever adds caution: absent, it is not read as
    /// idle or busy, and the job state decides.
    public static func decodeActivity(_ data: Data) throws -> PrinterActivity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let status = result["status"] as? [String: Any] else {
            throw MoonrakerError.malformed("no result.status object")
        }
        guard let stats = status["print_stats"] as? [String: Any],
              let raw = stats["state"] as? String,
              let state = PrintJobSnapshot.State(rawValue: raw) else {
            throw MoonrakerError.malformed("no recognisable print_stats.state")
        }
        switch state {
        case .printing:
            return .printing(paused: false)
        case .paused:
            return .printing(paused: true)
        case .standby, .complete, .cancelled, .error:
            break
        }
        if let idle = status["idle_timeout"] as? [String: Any], idle["state"] as? String == "Printing" {
            return .busy
        }
        return .idle
    }
}

/// The enum already provided `errorDescription`; what it lacked was the conformance that makes
/// `Error.localizedDescription` — which is what every UI surface shows — read it. Without this
/// the CFS strip showed "The operation couldn't be completed. (SpoolworksCore.MoonrakerError error 0.)"
/// in place of the sentence the case was written to say.
extension MoonrakerError: LocalizedError {}
