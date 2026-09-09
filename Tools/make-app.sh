#!/usr/bin/env bash
#
# make-app.sh — assemble a double-clickable Spoolworks.app from the SwiftPM binary.
#
# There is no Xcode on this machine (Command Line Tools only), so there is no .xcodeproj and no
# xcodebuild anywhere in this repo — see docs/DECISIONS.md D-002. This script does by hand the three
# things Xcode would otherwise do: lay out the bundle, write an Info.plist, and codesign.
#
# Usage:
#   Tools/make-app.sh                     release build into .build/app
#   Tools/make-app.sh --debug             debug build (faster; colour lookup is ~370× slower)
#   Tools/make-app.sh --output /tmp/out   choose the output directory
#   Tools/make-app.sh --open              launch the bundle when it is built
#
# Note on the build command: `swift build -c release` alone fails for this package, because the
# SpoolworksTests target uses `@testable import SpoolworksCore` and release builds are not testable (D-007).
# Building the product explicitly avoids the test target entirely.

set -euo pipefail

CONFIGURATION="release"
OUTPUT_DIR=""
LAUNCH=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${PACKAGE_DIR}"

APP_NAME="Spoolworks"
DISPLAY_NAME="Spoolworks"
BUNDLE_ID="com.obsidiang.spoolworks"
# Windows AssemblyInfo reports 16.0.0.0; this is a rewrite, so the macOS port versions from 1.
SHORT_VERSION="0.4.0"
MIN_SYSTEM_VERSION="14.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)   CONFIGURATION="debug"; shift ;;
        --release) CONFIGURATION="release"; shift ;;
        --output)  OUTPUT_DIR="$2"; shift 2 ;;
        --open)    LAUNCH=1; shift ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "make-app.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# Defaults inside .build/, which .gitignore already covers, so a build never dirties the tree.
[[ -n "${OUTPUT_DIR}" ]] || OUTPUT_DIR="${PACKAGE_DIR}/.build/app"

cd "${PACKAGE_DIR}"

# ---------------------------------------------------------------------------- build

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
swift build -c "${CONFIGURATION}" --product "${APP_NAME}"

BIN_DIR="$(swift build -c "${CONFIGURATION}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "make-app.sh: expected an executable at ${EXECUTABLE}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------- layout

APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "${EXECUTABLE}" "${CONTENTS}/MacOS/${APP_NAME}"

# SwiftPM resource bundles. `Bundle.module` resolves them from `Bundle.main.resourceURL`, so
# Contents/Resources is exactly where they have to land. SpoolworksCore's carries colors.bin — without it
# every nearest-colour lookup fails. The test target's bundle is deliberately not shipped.
shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do
    name="$(basename "${bundle}")"
    if [[ "${name}" == *"SpoolworksTests"* ]]; then
        continue
    fi
    echo "    resource bundle: ${name}"
    cp -R "${bundle}" "${CONTENTS}/Resources/"
done
shopt -u nullglob

# The material-database seeds. `BundledMaterialSeed` resolves `<family>.json` through
# `SpoolworksCoreResources`, which looks only inside the app's own resource bundle — there is no
# source-tree fallback any more, so if the seeds are not in the bundle the catalogue is empty.
CORE_BUNDLE="${CONTENTS}/Resources/${APP_NAME}_SpoolworksCore.bundle"
# db/{k1,k2,hi}.json are declared resources of the SpoolworksCore target, so SwiftPM builds them into the
# resource bundle and the copy that used to happen here is gone. That copy was what let the
# source-tree seed fallback look harmless: without it the app had no seeds at all unless packaged,
# so a plain `swift run` silently read them out of the repository.
if [[ ! -d "${CORE_BUNDLE}" ]]; then
    echo "make-app.sh: no SpoolworksCore resource bundle at ${CORE_BUNDLE}; the app would ship with no colour table and no material seeds" >&2
    exit 1
fi
seeded=0
for family in k1 k2 hi; do
    [[ -f "${CORE_BUNDLE}/${family}.json" ]] && seeded=$((seeded + 1))
done
echo "    material seeds: ${seeded} of 3 (from the package resource bundle)"
if [[ "${seeded}" -ne 3 ]]; then
    echo "make-app.sh: only ${seeded} of 3 material seeds are in the resource bundle; refusing to ship an app that cannot seed its catalogue" >&2
    exit 1
fi

# ---------------------------------------------------------------------------- icon

# Resources/AppIcon.icns is generated from the Modernist tokens by Tools/make-icon.swift and
# committed. It replaced a best-effort conversion of the Windows app's .ico, which was both the
# wrong product's branding and one of the unlicensed upstream files.
ICON_SOURCE="${REPO_ROOT}/Resources/AppIcon.icns"
ICON_NAME=""
if [[ -f "${ICON_SOURCE}" ]]; then
    cp "${ICON_SOURCE}" "${CONTENTS}/Resources/${APP_NAME}.icns"
    ICON_NAME="${APP_NAME}"
    echo "    icon: Resources/AppIcon.icns"
else
    echo "    icon: none — run 'swift Tools/make-icon.swift' to generate one"
fi

# ---------------------------------------------------------------------------- Info.plist

# Written here rather than kept as a checked-in file under Sources/SpoolworksUI/: SwiftPM treats any
# undeclared file inside a target directory as an unhandled resource and warns on every build,
# and Package.swift is out of scope for this workstream.
BUILD_NUMBER="$( (cd "${REPO_ROOT}" && git rev-list --count HEAD) 2>/dev/null || echo 1 )"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_SYSTEM_VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <!-- Required for the menu bar, the Settings scene and normal window management: without a
         principal class the process launches as an accessory with no menus. -->
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- Required before the process may touch AVFoundation at all. Without it macOS does not
         return an error, it *terminates* the app the moment a capture device is opened — which is
         why CameraColorScanner checks for this key before it touches a capture API, and why the
         verify step below refuses to ship a bundle missing it. -->
    <key>NSCameraUsageDescription</key>
    <string>Spoolworks uses the camera to read a spool's filament colour so it can be written to the tag.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Spoolworks. Derived from DnG-Crafts/K2-RFID; see repository for licensing.</string>
$( [[ -n "${ICON_NAME}" ]] && printf '    <key>CFBundleIconFile</key>\n    <string>%s</string>\n' "${ICON_NAME}" )
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS}/PkgInfo"

# ---------------------------------------------------------------------------- sign

# Prefer a stable local signing identity; fall back to ad-hoc.
#
# This is not about Gatekeeper — an ad-hoc signature is fine for launching locally, and real
# distribution signing and notarisation are still out of scope. It is about the **Keychain**.
#
# A keychain item's access control names the applications allowed to read it, and an application
# is identified by its code signature's designated requirement. An ad-hoc signature has no
# designated requirement at all, so every rebuild looks like a different application and the app
# has to be re-authorised for its own saved SSH password every single time. Signing with a
# certificate produces a requirement tied to that certificate:
#
#     designated => identifier "com.obsidiang.spoolworks" and certificate leaf = H"2e915e…"
#
# which is identical across rebuilds. One authorisation, then it holds.
#
# To create the certificate: Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…,
# name it as below, Identity Type "Self Signed Root", Certificate Type "Code Signing". Nothing
# breaks without it — the build simply falls back to ad-hoc.
SIGN_IDENTITY="${SPOOLWORKS_SIGN_IDENTITY:-Spoolworks Local Signing}"
if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "==> Codesigning as '${SIGN_IDENTITY}'"
else
    echo "==> Codesigning (ad-hoc — no '${SIGN_IDENTITY}' certificate found)"
    echo "    the app will ask for keychain access again after every rebuild; see the note in this script"
    SIGN_IDENTITY="-"
fi

# codesign refuses to sign anything carrying `com.apple.FinderInfo` ("resource fork, Finder
# information, or similar detritus not allowed"). Two sources put it there: `cp -R` copying
# attributes across, and — if the checkout lives in a synced folder such as Dropbox or iCloud
# Drive — the file provider stamping newly created directories a moment after they appear. The
# second is a race, so the strip-and-sign is retried rather than done once.
signed=0
for attempt in 1 2 3; do
    xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
    if codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'; then
        if codesign --verify "${APP_BUNDLE}" 2>/dev/null; then
            signed=1
            break
        fi
    fi
    sleep 1
done
if [[ ${signed} -eq 0 ]]; then
    echo "make-app.sh: could not codesign ${APP_BUNDLE} after 3 attempts" >&2
    exit 1
fi
codesign --verify --verbose=1 "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------- verify

echo "==> Verifying bundle"
# The resource bundle is verified too: without colors.bin every colour lookup throws, and without
# the seeds the catalogue starts empty and cannot recover.
for required in "Contents/MacOS/${APP_NAME}" "Contents/Info.plist" "Contents/PkgInfo" \
                "Contents/Resources/${APP_NAME}_SpoolworksCore.bundle/colors.bin" \
                "Contents/Resources/${APP_NAME}_SpoolworksCore.bundle/k1.json" \
                "Contents/Resources/${APP_NAME}_SpoolworksCore.bundle/k2.json" \
                "Contents/Resources/${APP_NAME}_SpoolworksCore.bundle/hi.json" \
                "Contents/Resources/${APP_NAME}_SpoolworksCore.bundle/filament-swatches.json"; do
    if [[ ! -e "${APP_BUNDLE}/${required}" ]]; then
        echo "make-app.sh: missing ${required}" >&2
        exit 1
    fi
done
# A shipped binary must not contain an absolute path into anyone's home directory. SwiftPM's
# generated Bundle.module accessor bakes in the build directory as a fallback, and #filePath does
# the same; on the build machine those paths exist, so the app loads resources out of the source
# tree and appears to work while being broken on every other Mac. SpoolworksCore resolves resources through
# SpoolworksCoreResources instead — this check is what stops that regressing.
#
# This guard must fail CLOSED. An earlier version piped `strings` straight into `grep -c`, so a
# failed `strings` produced empty input, `grep -c` printed 0, and the check passed silently.
if ! symbols="$(strings "${CONTENTS}/MacOS/${APP_NAME}")"; then
    echo "make-app.sh: could not scan the binary for leaked paths (strings failed); refusing to guess" >&2
    exit 1
fi
# Two patterns: the concrete build root is the path that actually leaks, and the generic
# home-directory prefixes catch a developer homed somewhere other than /Users (CI runners,
# Linux-style layouts). Neither is anchored to a line start, so an embedded path is caught too.
leaks="$( { printf '%s\n' "${symbols}" | grep -F "${PACKAGE_DIR}";
            printf '%s\n' "${symbols}" | grep -E '/(Users|home)/[^/ ]+/'; } | sort -u || true )"
if [[ -n "${leaks}" ]]; then
    echo "make-app.sh: the binary contains absolute developer paths — it would read resources from a developer's machine:" >&2
    printf '%s\n' "${leaks}" | head -5 | sed 's/^/    /' >&2
    exit 1
fi
echo "    no developer paths in the binary"

# The camera usage description is checked rather than assumed. A bundle without it does not
# degrade — the colour scanner terminates the whole app the first time it is opened — and the
# failure would only ever be found by a user, on the one machine where nobody was watching.
if ! plutil -extract NSCameraUsageDescription raw -o - "${CONTENTS}/Info.plist" >/dev/null 2>&1; then
    echo "make-app.sh: Info.plist has no NSCameraUsageDescription; the colour scanner would kill the app" >&2
    exit 1
fi
echo "    camera usage description present"

plutil -lint "${CONTENTS}/Info.plist" | sed 's/^/    /'

echo
echo "Built ${APP_BUNDLE}"
echo "  version    ${SHORT_VERSION} (${BUILD_NUMBER})"
echo "  bundle id  ${BUNDLE_ID}"
echo "  minimum    macOS ${MIN_SYSTEM_VERSION}"
echo
echo "Run it with:  open \"${APP_BUNDLE}\""

if [[ ${LAUNCH} -eq 1 ]]; then
    open "${APP_BUNDLE}"
fi
