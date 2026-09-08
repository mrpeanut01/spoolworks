import Foundation

// SPEC-04 §5.1 / §5.2 — the Creality Cloud slicer-profile API.
//
// Three requests exist in the whole application:
//
//   POST https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/printerList
//   POST https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/materialList
//   GET  <printerList[].zipUrl>            — server-supplied CDN URL, no headers at all
//
// The API is undocumented and unauthenticated (`__CXY_UID_` is empty). The header set below is
// byte-identical between the Windows app (Utils.cs:740-753) and Android (Utils.java:670-682),
// which is the strongest available evidence that the server requires it. Note that the
// `User-Agent` impersonates Bambu Studio — that is what both existing clients send, and
// changing it is an untested behavioural risk, so it is preserved verbatim and flagged here.

// MARK: - HTTP seam

/// The one and only place this module can touch the network.
///
/// Everything above is written against this protocol so tests exercise request *construction*
/// without ever opening a socket. `MockHTTPClient` is the test double; `URLSessionHTTPClient`
/// is the only implementation that performs I/O and is never constructed in tests.
public protocol HTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPFetching {
    private let session: URLSession

    /// Defaults mirror the intent of SPEC-04 §7: the Windows app never sets a timeout on its
    /// `WebClient`, inheriting the 100 s default. 30 s is long enough for the profile zip on a
    /// slow link and short enough not to look hung.
    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CrealityCloudError.transport("the server returned a non-HTTP response")
        }
        return (data, http)
    }
}

/// Scripted HTTP for tests. Refuses to answer anything it was not explicitly given, so a test
/// that forgets to stub a URL fails loudly rather than reaching the real API.
public final class MockHTTPClient: HTTPFetching, @unchecked Sendable {
    public struct Response {
        public let statusCode: Int
        public let body: Data
        public init(statusCode: Int = 200, body: Data) {
            self.statusCode = statusCode
            self.body = body
        }
    }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var _requests: [URLRequest] = []

    public init() {}

    /// Every request that was made, in order — including the ones that were not stubbed.
    public var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    public func stub(_ url: URL, with response: Response) {
        lock.lock(); responses[url.absoluteString] = response; lock.unlock()
    }

    public func stub(_ url: URL, json: String, statusCode: Int = 200) {
        stub(url, with: Response(statusCode: statusCode, body: Data(json.utf8)))
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let stubbed = lock.withLock { () -> Response? in
            _requests.append(request)
            return request.url.flatMap { responses[$0.absoluteString] }
        }
        guard let stubbed, let url = request.url else {
            throw CrealityCloudError.transport(
                "MockHTTPClient has no stub for \(request.url?.absoluteString ?? "<nil>")")
        }
        let response = HTTPURLResponse(url: url, statusCode: stubbed.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (stubbed.body, response)
    }
}

// MARK: - Errors

public enum CrealityCloudError: Error, Equatable, CustomStringConvertible {
    case transport(String)
    case httpStatus(Int)
    case malformedResponse(String)
    case apiError(code: Int, message: String)
    /// The printer model exists but has no profile bundle for the requested nozzle.
    case noProfileForNozzle(printer: String, nozzle: String)
    case printerNotFound(String)
    /// The server supplied a `zipUrl` that is not an https URL on an allow-listed host.
    /// See ``CrealityCloudRequest/validatedZipURL(_:)``.
    case untrustedProfileURL(String)

    public var description: String {
        switch self {
        case .transport(let detail):        return "Could not reach Creality Cloud: \(detail)"
        case .httpStatus(let code):         return "Creality Cloud returned HTTP \(code)."
        case .malformedResponse(let detail): return "Unexpected response from Creality Cloud: \(detail)"
        case .apiError(let code, let message): return "Creality Cloud error \(code): \(message)"
        case .noProfileForNozzle(let printer, let nozzle):
            return "Creality Cloud has no \(nozzle) mm profile for \(printer)."
        case .printerNotFound(let name):    return "Creality Cloud does not list a printer called \(name)."
        case .untrustedProfileURL(let url):
            return "Creality Cloud pointed the profile download at \(url), which is not an "
                 + "https address on a recognised Creality host. The download was refused."
        }
    }
}

// MARK: - Requests

/// Pure request construction. Separated from the client so the exact URL, method, headers, and
/// body can be asserted in tests with nothing on the wire.
public enum CrealityCloudRequest {

    public static let printerListURL =
        URL(string: "https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/printerList")!
    public static let materialListURL =
        URL(string: "https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/materialList")!

    /// Verbatim from Windows `Utils.cs:740` / Android `Utils.java` `api_useragent`. It claims to
    /// be Bambu Studio; both existing clients send exactly this and the server may key off it.
    public static let userAgent =
        "BBL-Slicer/v01.09.03.50 (dark) Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.52"

    /// The engine version both clients pin in the request body.
    public static let engineVersion = "3.0.0"

    /// `materialList` only. Windows `Utils.cs:755`, Android `Utils.java:685`.
    public static let materialPageSize = 500

    /// The nozzle diameter hardcoded at every call site in both existing clients
    /// (SPEC-04 §5.1). Non-0.4 printers are invisible to them; kept as a parameter here so the
    /// limitation is at least visible, but 0.4 stays the default.
    public static let defaultNozzle = "0.4"

    /// Builds one API request.
    ///
    /// `duid` and `requestID` are fresh GUIDs per request in both clients; they are parameters
    /// so tests get a deterministic result.
    public static func apiRequest(url: URL, duid: String, requestID: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("creality", forHTTPHeaderField: "__CXY_BRAND_")
        request.setValue("", forHTTPHeaderField: "__CXY_UID_")
        request.setValue("0", forHTTPHeaderField: "__CXY_OS_LANG_")
        request.setValue(duid, forHTTPHeaderField: "__CXY_DUID_")
        request.setValue("1.0", forHTTPHeaderField: "__CXY_APP_VER_")
        request.setValue("CP_Beta", forHTTPHeaderField: "__CXY_APP_CH_")
        request.setValue(userAgent, forHTTPHeaderField: "__CXY_OS_VER_")
        request.setValue("28800", forHTTPHeaderField: "__CXY_TIMEZONE_")   // UTC+8, in seconds
        request.setValue("creality_model", forHTTPHeaderField: "__CXY_APP_ID_")
        request.setValue(requestID, forHTTPHeaderField: "__CXY_REQUESTID_")
        request.setValue("11", forHTTPHeaderField: "__CXY_PLATFORM_")
        request.httpBody = body(for: url)
        return request
    }

    /// `{"engineVersion":"3.0.0"}`, plus `pageSize` for `materialList`.
    /// Built by hand rather than through `JSONSerialization` so key order is deterministic and
    /// matches what both existing clients send byte for byte.
    public static func body(for url: URL) -> Data {
        if url == materialListURL {
            return Data("{\"engineVersion\":\"\(engineVersion)\",\"pageSize\":\(materialPageSize)}".utf8)
        }
        return Data("{\"engineVersion\":\"\(engineVersion)\"}".utf8)
    }

    /// The profile zip: a plain GET with **no headers at all** (Windows `Utils.cs:912-914`).
    public static func zipRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }

    // MARK: zipUrl validation

    /// Hosts a profile bundle may be fetched from.
    ///
    /// A record matches when its host equals one of these or ends with `"." + entry`, so CDN
    /// subdomains resolve without the list becoming a wildcard.
    ///
    /// SPEC-04 §5.2 step 1 notes the zip URL is "server-supplied, host not hardcoded anywhere",
    /// and the API it comes from is unauthenticated and undocumented. Both existing clients
    /// hand that string straight to a downloader. Add the domains a future CDN move needs; do
    /// not replace this with "anything https".
    public static let allowedZipHosts: Set<String> = [
        "crealitycloud.com",
        "crealitycloud.cn",
        "creality.com",
        "creality3d.com",
        "crealitygroup.com",
        // Creality's cloud is fronted by Alibaba object storage / CDN.
        "aliyuncs.com",
        "alicdn.com",
    ]

    /// Validates a server-supplied `zipUrl` before it is fetched.
    ///
    /// Two checks, both of which the existing clients skip:
    ///
    /// * **scheme must be https.** `URL(string:)` happily produces `file:///etc/passwd`, and
    ///   `URLSession` honours `file://` — so a hostile or MITM'd `printerList` response could
    ///   make the app read a local file and treat it as a profile bundle. `http://` is refused
    ///   for the same reason it is refused everywhere else: the response is unauthenticated
    ///   already, and plaintext would let any on-path device choose the bytes.
    /// * **host must be allow-listed** (``allowedZipHosts``), so a valid-looking https URL
    ///   cannot redirect the fetch to an attacker's server.
    public static func validatedZipURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        return allowedZipHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) ? url : nil
    }
}

// MARK: - Models

/// One entry of `result.printerList[]`.
public struct CloudPrinter: Equatable, Sendable, Decodable {
    public let name: String
    public let nozzleDiameter: [String]
    public let zipUrl: String?
    public let thumbnail: String?
    public let version: String?

    public init(name: String, nozzleDiameter: [String],
                zipUrl: String? = nil, thumbnail: String? = nil, version: String? = nil) {
        self.name = name
        self.nozzleDiameter = nozzleDiameter
        self.zipUrl = zipUrl
        self.thumbnail = thumbnail
        self.version = version
    }

    /// `version` arrives as a string in some records and a number in others; accept both rather
    /// than failing the whole list over one entry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        nozzleDiameter = (try? container.decode([String].self, forKey: .nozzleDiameter)) ?? []
        zipUrl = try? container.decodeIfPresent(String.self, forKey: .zipUrl)
        thumbnail = try? container.decodeIfPresent(String.self, forKey: .thumbnail)
        if let text = try? container.decodeIfPresent(String.self, forKey: .version) {
            version = text
        } else if let number = try? container.decodeIfPresent(Int64.self, forKey: .version) {
            version = String(number)
        } else {
            version = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, nozzleDiameter, zipUrl, thumbnail, version
    }

    public func supportsNozzle(_ nozzle: String) -> Bool { nozzleDiameter.contains(nozzle) }
}

private struct PrinterListEnvelope: Decodable {
    struct Result: Decodable { let printerList: [CloudPrinter]? }
    let code: Int?
    let msg: String?
    let result: Result?
}

// MARK: - Client

/// The Creality Cloud surface the rest of the app depends on.
///
/// A protocol so `PrinterService` can be handed a stub. Nothing in the test suite ever
/// constructs `CrealityCloud` with a `URLSessionHTTPClient`.
public protocol CrealityCloudAPI: Sendable {
    /// The catalogue of printer *models* (this is the only "discovery" the app has — there is
    /// no LAN discovery anywhere, SPEC-04 §6).
    func printerList(nozzle: String) async throws -> [CloudPrinter]
    /// The raw `materialList` response body, which the database builder joins against the zip.
    func materialList() async throws -> Data
    /// The profile bundle for one printer model, as raw zip bytes.
    func profileZip(forPrinterNamed name: String, nozzle: String) async throws -> Data
}

public struct CrealityCloud: CrealityCloudAPI {

    private let http: HTTPFetching
    private let identifierProvider: @Sendable () -> String

    /// - Parameter identifierProvider: supplies `__CXY_DUID_` / `__CXY_REQUESTID_`. Fresh GUIDs
    ///   per request in both existing clients; injectable so tests are deterministic.
    public init(http: HTTPFetching,
                identifierProvider: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.http = http
        self.identifierProvider = identifierProvider
    }

    public func printerList(nozzle: String = CrealityCloudRequest.defaultNozzle) async throws -> [CloudPrinter] {
        let data = try await post(CrealityCloudRequest.printerListURL)
        let envelope: PrinterListEnvelope
        do { envelope = try JSONDecoder().decode(PrinterListEnvelope.self, from: data) }
        catch { throw CrealityCloudError.malformedResponse("printerList: \(error)") }

        if let code = envelope.code, code != 0 {
            throw CrealityCloudError.apiError(code: code, message: envelope.msg ?? "")
        }
        guard let list = envelope.result?.printerList else {
            throw CrealityCloudError.malformedResponse("printerList: no result.printerList")
        }
        return list.filter { $0.supportsNozzle(nozzle) }
    }

    public func materialList() async throws -> Data {
        try await post(CrealityCloudRequest.materialListURL)
    }

    public func profileZip(forPrinterNamed name: String,
                           nozzle: String = CrealityCloudRequest.defaultNozzle) async throws -> Data {
        let printers = try await printerList(nozzle: nozzle)
        guard let match = printers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                       ?? printers.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            // Distinguish "no such model" from "model exists but not at this nozzle" so the UI
            // can say something useful — the Windows app swallows both (SPEC-04 §8.3).
            throw CrealityCloudError.printerNotFound(name)
        }
        guard let urlString = match.zipUrl, !urlString.isEmpty else {
            throw CrealityCloudError.noProfileForNozzle(printer: name, nozzle: nozzle)
        }
        // The URL is attacker-controlled in the threat model: the API is unauthenticated and
        // undocumented, and `URLSession` would happily service a `file://` one.
        guard let url = CrealityCloudRequest.validatedZipURL(urlString) else {
            throw CrealityCloudError.untrustedProfileURL(urlString)
        }
        let (data, response) = try await http.data(for: CrealityCloudRequest.zipRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw CrealityCloudError.httpStatus(response.statusCode)
        }
        return data
    }

    private func post(_ url: URL) async throws -> Data {
        let request = CrealityCloudRequest.apiRequest(url: url,
                                                      duid: identifierProvider(),
                                                      requestID: identifierProvider())
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CrealityCloudError.httpStatus(response.statusCode)
        }
        return data
    }
}
