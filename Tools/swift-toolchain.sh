# swift-toolchain.sh — sourced, not run. Works out how to call `swift build` on this machine.
#
# Command Line Tools 27 (Swift 6.4) cannot build this package as it stands, and the fault is not in
# the package:
#
#   1. Its macOS 27 SDK implements SwiftUI's @State as a macro, and the SwiftUIMacros compiler plugin
#      that expands it ships with Xcode, not with Command Line Tools. Every view holding @State
#      fails: "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found".
#   2. Its default build system, swiftbuild, stops before compiling anything, whichever SDK it is
#      given: "SessionFailedError … Unknown error parsing property list".
#
# It still installs the macOS 26 SDKs, and SwiftPM's native build system builds the package against
# those. So when the active developer directory is Command Line Tools, it has no SwiftUIMacros
# plugin, and its default SDK is macOS 27 or later, this pins SDKROOT to the newest older SDK and
# asks for the native build system. Anywhere else — Xcode, an older toolchain — it changes nothing.
#
# Overrides, which skip the detection:
#   SPOOLWORKS_SDKROOT=/path/to/MacOSXNN.N.sdk   build against this SDK
#   SPOOLWORKS_BUILD_SYSTEM=native|swiftbuild    pass this to --build-system
#
# After `spoolworks_configure_swift`, pass the flags as
#   swift build ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} …
# The guarded expansion is what keeps an empty array legal under `set -u` in macOS's bash 3.2.

SWIFT_BUILD_FLAGS=()

spoolworks_configure_swift() {
    local developer default_sdk default_major older sdk major minor best_major best_minor

    if [[ -n "${SPOOLWORKS_SDKROOT:-}${SPOOLWORKS_BUILD_SYSTEM:-}" ]]; then
        [[ -z "${SPOOLWORKS_SDKROOT:-}" ]] || export SDKROOT="${SPOOLWORKS_SDKROOT}"
        [[ -z "${SPOOLWORKS_BUILD_SYSTEM:-}" ]] || SWIFT_BUILD_FLAGS=(--build-system "${SPOOLWORKS_BUILD_SYSTEM}")
        echo "==> Toolchain: SDK ${SPOOLWORKS_SDKROOT:-default}, build system ${SPOOLWORKS_BUILD_SYSTEM:-default} (from the environment)"
        return 0
    fi

    developer="$(xcode-select -p 2>/dev/null || true)"
    [[ "${developer}" == *CommandLineTools* ]] || return 0
    [[ ! -e "${developer}/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]] || return 0

    # The SDK `swift` would pick by default. SDKROOT is removed for the question: xcrun answers
    # with whatever the calling shell already exported.
    default_sdk="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
    default_major="${default_sdk%%.*}"
    if ! [[ "${default_major}" =~ ^[0-9]+$ ]] || (( default_major < 27 )); then
        return 0
    fi

    # The newest macOS SDK older than the default. Only a real SDK counts: Command Line Tools 27
    # leaves an empty `MacOSX26.0.sdk` directory behind, with no SDKSettings and no standard library,
    # and building against that fails as surely as the macOS 27 SDK does.
    older=""
    best_major=-1
    best_minor=-1
    for sdk in "${developer}"/SDKs/MacOSX*.*.sdk; do
        [[ -d "${sdk}" && ! -L "${sdk}" ]] || continue
        [[ -f "${sdk}/SDKSettings.json" || -f "${sdk}/SDKSettings.plist" ]] || continue
        [[ "$(basename "${sdk}")" =~ ^MacOSX([0-9]+)\.([0-9]+)\.sdk$ ]] || continue
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        (( major < default_major )) || continue
        if (( major > best_major || (major == best_major && minor > best_minor) )); then
            best_major="${major}"
            best_minor="${minor}"
            older="${sdk}"
        fi
    done
    if [[ -z "${older}" ]]; then
        echo "error: Command Line Tools with the macOS ${default_sdk} SDK cannot build SwiftUI's @State without Xcode's SwiftUIMacros plugin, and no older macOS SDK is installed to build against. Install Xcode, or set SPOOLWORKS_SDKROOT to an older SDK." >&2
        return 1
    fi

    export SDKROOT="${older}"
    SWIFT_BUILD_FLAGS=(--build-system native)
    echo "==> Toolchain: Command Line Tools' macOS ${default_sdk} SDK has no SwiftUIMacros; building against $(basename "${older}") with SwiftPM's native build system"
}
