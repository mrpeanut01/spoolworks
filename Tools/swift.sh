#!/usr/bin/env bash
#
# swift.sh — `swift build`, `swift run` or `swift test` with this machine's toolchain workaround
# applied when it needs one (see swift-toolchain.sh). On a toolchain that needs nothing, it is
# plain `swift`.
#
# Usage, from the repository root:
#   Tools/swift.sh build
#   Tools/swift.sh run SpoolworksTests
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=swift-toolchain.sh
source "${SCRIPT_DIR}/swift-toolchain.sh"
spoolworks_configure_swift >&2 || exit 1

if [[ $# -eq 0 ]]; then
    exec swift
fi
subcommand="$1"
shift
exec swift "${subcommand}" ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} "$@"
