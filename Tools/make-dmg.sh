#!/bin/bash
#
# Builds a distributable disk image containing Spoolworks.app.
#
# A DMG rather than a .pkg on purpose: there is no Developer ID certificate here, so the app is
# ad-hoc signed. macOS blocks an unsigned *installer package* far more firmly than it blocks
# dragging an app out of a disk image, and the drag-to-Applications idiom needs no admin rights.
# The Gatekeeper caveat is real either way and is spelled out in the README placed inside the
# image — see "First launch" there.
#
# Usage:
#   Tools/make-dmg.sh [--output DIR] [--debug|--release]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${PACKAGE_DIR}"

APP_NAME="Spoolworks"
VOLUME_NAME="Spoolworks"
# Release artifacts go in a VISIBLE directory, not under .build/. `.build` is SwiftPM's own
# scratch space: it is hidden, and `swift package clean` deletes it — neither is what you want
# for the thing you are about to hand to someone.
OUTPUT_DIR="${PACKAGE_DIR}/dist"
CONFIGURATION="release"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { echo "make-dmg.sh: --output needs a directory" >&2; exit 2; }
            OUTPUT_DIR="$2"; shift 2 ;;
        --debug)   CONFIGURATION="debug"; shift ;;
        --release) CONFIGURATION="release"; shift ;;
        -h|--help)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            echo "make-dmg.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------- build the app

echo "==> Building ${APP_NAME}.app (${CONFIGURATION})"
"${SCRIPT_DIR}/make-app.sh" "--${CONFIGURATION}" >/dev/null
APP_BUNDLE="${PACKAGE_DIR}/.build/app/${APP_NAME}.app"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "make-dmg.sh: make-app.sh did not produce ${APP_BUNDLE}" >&2
    exit 1
fi

VERSION="$(defaults read "${APP_BUNDLE}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")"
BUILD="$(defaults read "${APP_BUNDLE}/Contents/Info" CFBundleVersion 2>/dev/null || echo "0")"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION}.dmg"

# ---------------------------------------------------------------------------- stage

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/spoolworks-dmg.XXXXXXXX")"
MOUNT_POINT=""

# One idempotent cleanup for every exit path. The verify step below mounts the image, and an
# interrupt between attach and detach would otherwise leave it mounted with a stale mount point.
cleanup() {
    if [[ -n "${MOUNT_POINT}" ]] && mount | grep -q " on ${MOUNT_POINT} "; then
        hdiutil detach "${MOUNT_POINT}" -quiet -force 2>/dev/null || true
    fi
    [[ -n "${MOUNT_POINT}" ]] && rmdir "${MOUNT_POINT}" 2>/dev/null
    rm -rf "${STAGE}"
}
trap cleanup EXIT
# Turn a signal into a normal exit so the EXIT trap runs exactly once.
trap 'exit 130' INT TERM

echo "==> Staging"
cp -R "${APP_BUNDLE}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

# The Gatekeeper instruction is the single most important thing in the image: without it, a
# first-time user sees "Spoolworks is damaged and can't be opened", which is what macOS says about an
# unsigned app carrying a quarantine flag. It is not damaged.
cat > "${STAGE}/READ ME FIRST.txt" <<'READ_ME'
K2 RFID for macOS
=================

Read and write Creality K1/K2/HI filament spool tags with a USB PC/SC NFC reader.

INSTALL
    Drag Spoolworks.app onto the Applications folder in this window.

FIRST LAUNCH — IMPORTANT
    This app is not signed with an Apple Developer ID, so macOS will refuse to
    open it the normal way. It is not damaged; it simply has no paid signature.

    Right-click (or Control-click) Spoolworks in Applications, choose "Open", then
    click "Open" again in the dialog. You only need to do this once.

    If macOS still refuses, open Terminal and run:

        xattr -dr com.apple.quarantine /Applications/Spoolworks.app

WHAT YOU NEED
    - macOS 14 (Sonoma) or later
    - A PC/SC USB reader. Developed against an ACS ACR1552; an ACR122U uses the
      same command set. No driver install is needed — macOS includes PC/SC.
    - Blank MIFARE Classic 1K tags.

WHAT IT DOES, AND DOES NOT, DO
    It programs blank MIFARE Classic 1K tags and reads back tags it wrote.

    It cannot read a genuine Creality factory tag. Those use keys that are not
    published, and no tool in this project — Windows, Android or Arduino —
    can read them either. That is a property of the original project, not a
    limitation of this port.

USING IT
    Tag ▸ Read   Place a tag on the reader. It is read automatically.
    Tag ▸ Write  Choose filament, weight and colour, then present a tag. It is
                 written automatically.

    Programming a BLANK tag rewrites its sector keys, which cannot be undone.
    That step always asks first, unless you turn on the advanced option.

    A full backup of every readable sector is captured before any write, and
    every write is verified by reading the tag back.

SOURCE
    https://github.com/DnG-Crafts/K2-RFID
READ_ME

# ---------------------------------------------------------------------------- build the image

mkdir -p "${OUTPUT_DIR}"
rm -f "${DMG_PATH}"

echo "==> Creating disk image"
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGE}" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "${DMG_PATH}" >/dev/null

# ---------------------------------------------------------------------------- verify

echo "==> Verifying"
hdiutil verify "${DMG_PATH}" >/dev/null

# Mount it and confirm the app inside is intact and its signature still validates. Building an
# image whose contents are broken is easy to do and invisible until a user complains.
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/spoolworks-verify.XXXXXXXX")"
hdiutil attach "${DMG_PATH}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet   # detached by cleanup on any exit
verify_failed=0
for required in \
    "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" \
    "${APP_NAME}.app/Contents/Info.plist" \
    "${APP_NAME}.app/Contents/Resources/${APP_NAME}_SpoolworksCore.bundle/colors.bin" \
    "${APP_NAME}.app/Contents/Resources/${APP_NAME}_SpoolworksCore.bundle/k2.json" \
    "READ ME FIRST.txt"
do
    if [[ ! -e "${MOUNT_POINT}/${required}" ]]; then
        echo "    MISSING: ${required}" >&2
        verify_failed=1
    fi
done
if ! codesign --verify --deep "${MOUNT_POINT}/${APP_NAME}.app" 2>/dev/null; then
    echo "    signature does not validate inside the image" >&2
    verify_failed=1
fi
hdiutil detach "${MOUNT_POINT}" -quiet
rmdir "${MOUNT_POINT}" 2>/dev/null || true

if [[ "${verify_failed}" -ne 0 ]]; then
    echo "make-dmg.sh: the image is incomplete; refusing to report success" >&2
    exit 1
fi

SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"

echo
echo "Built ${DMG_PATH}"
echo "  version   ${VERSION} (${BUILD})"
echo "  size      ${SIZE}"
echo "  sha256    ${SHA}"
echo
echo "NOTE: ad-hoc signed — no Developer ID certificate is available on this machine."
echo "      First launch needs right-click ▸ Open. This is explained in the image's README."
