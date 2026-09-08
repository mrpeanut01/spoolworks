import Foundation

/// Locates SpoolworksCore's resource bundle without SwiftPM's generated `Bundle.module`.
///
/// `Bundle.module` is unusable for a shipped app, for two independent reasons:
///
/// 1. **It bakes in an absolute build path.** The generated accessor falls back to a literal
///    like `/Users/<whoever>/Documents/.../.build/release/Spoolworks_SpoolworksCore.bundle`. On the machine
///    that built the app that path exists, so the app silently loads resources out of the
///    developer's source tree and appears to work. On anyone else's Mac it does not exist. A
///    shipped binary must never reach into a build directory.
///
/// 2. **It calls `fatalError` when the bundle is missing**, so a missing resource aborts the
///    process instead of surfacing as an error. `ColorTableError.resourceMissing` and
///    `MaterialDatabaseError` already exist to report exactly this — `Bundle.module` traps before
///    either can be returned, which made those cases unreachable.
///
/// This resolver searches the locations a bundle can legitimately occupy, in order, and returns
/// `nil` rather than trapping. Callers keep their own descriptive errors.
public enum SpoolworksCoreResources {

    /// SwiftPM names a target's resource bundle `<package>_<target>.bundle`.
    static let bundleName = "Spoolworks_SpoolworksCore.bundle"

    /// Anchors `Bundle(for:)` to this module rather than the main executable.
    private final class BundleToken {}

    /// Resolved once. The candidate list is kept so a "resource missing" error can say where it
    /// looked — a bare "not found" is exactly what made the original launch crash hard to diagnose.
    private static let resolution: (bundle: Bundle?, searched: [URL]) = locate()

    /// The resource bundle, or `nil` if it is genuinely absent.
    public static var bundle: Bundle? { resolution.bundle }

    /// Every location the resolver tried, in order.
    public static var searchedPaths: [String] { resolution.searched.map(\.path) }

    private static func locate() -> (bundle: Bundle?, searched: [URL]) {
        var candidates: [URL] = []

        // 1. Alongside this module's own resources. Correct when SpoolworksCore is a framework, and when
        //    resources were copied next to a test binary.
        let selfBundle = Bundle(for: BundleToken.self)
        if let resources = selfBundle.resourceURL {
            candidates.append(resources.appendingPathComponent(bundleName))
        }
        candidates.append(selfBundle.bundleURL.appendingPathComponent(bundleName))

        // 2. `Contents/Resources` of the running app — where `make-app.sh` installs it, and the
        //    conventional home for an app's resources. SwiftPM's own accessor omits this, which
        //    is why the shipped app could not find it.
        if let mainResources = Bundle.main.resourceURL {
            candidates.append(mainResources.appendingPathComponent(bundleName))
        }

        // 3. The app bundle root, which is where SwiftPM's accessor looks.
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))

        // 4. Next to the executable. This covers `swift run` and `swift test` during development
        //    WITHOUT hardcoding anything: the bundle sits beside the binary in .build. It is
        //    relative to whatever is actually running, so it cannot point into someone else's
        //    source tree.
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        if let executableDirectory {
            candidates.append(executableDirectory.appendingPathComponent(bundleName))
        }

        for url in candidates {
            if let bundle = Bundle(url: url) { return (bundle, candidates) }
        }
        return (nil, candidates)
    }

    /// A diagnostic that names every path tried, so "resource missing" is something a person can
    /// act on rather than a dead end.
    public static var searchedDescription: String {
        bundleName + " not found. Looked in:\n"
            + searchedPaths.map { "  " + $0 }.joined(separator: "\n")
    }

    /// Finds a resource, or `nil`. Never traps.
    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        bundle?.url(forResource: name, withExtension: ext)
    }
}
