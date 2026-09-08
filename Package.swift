// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spoolworks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Spoolworks", targets: ["Spoolworks"]),
        .executable(name: "spooldiag", targets: ["SpoolworksDiag"]),
        .library(name: "SpoolworksCore", targets: ["SpoolworksCore"]),
    ],
    targets: [
        // C shim isolating PCSC.framework, whose modulemap declares `requires !swift`.
        // PCSC headers are included only from shim.c; the Swift-visible header declares
        // a narrow k2_* API with plain C types. See docs/DECISIONS.md D-003.
        .target(
            name: "CPCSC",
            linkerSettings: [.linkedFramework("PCSC")]
        ),
        // Pure Swift. No SwiftUI/AppKit imports — keeps the whole domain unit-testable.
        .target(
            name: "SpoolworksCore",
            dependencies: ["CPCSC"],
            resources: [.process("Resources")]
        ),
        // The UI lives in a library target so it can be tested. A target containing `@main`
        // cannot be a dependency, so the executable below is a two-line shim.
        .target(
            name: "SpoolworksUI",
            dependencies: ["SpoolworksCore"]
        ),
        .executableTarget(
            name: "Spoolworks",
            dependencies: ["SpoolworksUI"]
        ),
        // Headless diagnostic CLI: enumerate readers, dump tags, verify hardware
        // without launching the GUI. Used for hardware-in-the-loop testing.
        .executableTarget(
            name: "SpoolworksDiag",
            dependencies: ["SpoolworksCore"]
        ),
        // Tests are a plain executable, not a testTarget: this machine has Command Line Tools
        // without Xcode, so XCTest is absent and the bundled Testing.framework is incomplete
        // (missing lib_TestingInterop.dylib). See docs/DECISIONS.md D-007. Run with: swift run SpoolworksTests
        .executableTarget(
            name: "SpoolworksTests",
            dependencies: ["SpoolworksCore", "SpoolworksUI"],
            resources: [.process("Fixtures")],
            swiftSettings: [.define("SPOOLWORKS_TESTS")]
        ),
    ]
)
