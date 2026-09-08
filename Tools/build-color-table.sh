#!/bin/bash
# Regenerates Sources/SpoolworksCore/Resources/colors.bin from the shipped colors.db.
#
# `colors.db` is not SQLite despite the name: it is a ZIP holding one UTF-8 CSV
# (`colornames.csv`, the meodai/color-names dataset). See SPEC/05-color.md §1.
#
# Why a generated blob rather than unzipping at runtime: Foundation has no unzip, so shipping
# the .db would mean hand-rolling a ZIP local-header parser plus a full CSV parse on every
# load, for a file we control. The blob makes the hot loop a scan over contiguous UInt32s.
#
# ROW ORDER IS LOAD-BEARING. ColorMatcher.cs:87 updates its best match on a strict `<`, so the
# first matching CSV row wins any distance tie. This script therefore appends rows in the exact
# order they appear in the CSV and never sorts, dedupes, or hashes them. Reordering would
# silently change which name a tie resolves to. Verified tie cases live in ColorMatcherTests.
#
# The script is idempotent: same input bytes in, byte-identical colors.bin out.
#
# Usage: Tools/build-color-table.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DB="$REPO_ROOT/reference/colors.db"
OUT_DIR="$REPO_ROOT/Sources/SpoolworksCore/Resources"
OUT_FILE="$OUT_DIR/colors.bin"
EXPECTED_RECORDS=31861

for tool in unzip python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' not found on PATH" >&2
        exit 1
    fi
done

if [[ ! -f "$SOURCE_DB" ]]; then
    echo "error: source dataset not found at $SOURCE_DB" >&2
    exit 1
fi

WORK="$(mktemp -d)"
STAGE=""
cleanup() {
    rm -rf "$WORK"
    [[ -n "$STAGE" ]] && rm -f "$STAGE"
    return 0
}
trap cleanup EXIT

# The C# loader opens archive.Entries[0] by index, not by name (ColorMatcher.cs:43), so the
# member name is not load-bearing — but assert there is exactly one member so a future rebuild
# that adds a second file fails here instead of silently picking the wrong one.
ENTRY_COUNT="$(unzip -Z1 "$SOURCE_DB" | grep -c . || true)"
if [[ "$ENTRY_COUNT" != "1" ]]; then
    echo "error: expected exactly 1 entry in $SOURCE_DB, found $ENTRY_COUNT" >&2
    exit 1
fi

unzip -p "$SOURCE_DB" > "$WORK/colornames.csv"

mkdir -p "$OUT_DIR"

# Stage the output INSIDE $OUT_DIR, not in $WORK.
#
# The final `mv` below is only atomic when it is a rename(2), and rename(2) only works within a
# single filesystem. `$WORK` is a `mktemp -d` under /var/folders, which is a different volume
# from the repository on essentially every machine, so moving from there was copy-then-unlink —
# i.e. exactly the non-atomic, interruptible write the comment claimed it was avoiding. A
# sibling of the target is guaranteed to be on the target's filesystem.
STAGE="$(mktemp "$OUT_DIR/.colors.bin.XXXXXXXX")"

python3 - "$WORK/colornames.csv" "$STAGE" "$EXPECTED_RECORDS" <<'PYTHON'
import struct
import sys

csv_path, out_path, expected = sys.argv[1], sys.argv[2], int(sys.argv[3])

raw = open(csv_path, "rb").read()
# UTF-8, no BOM, LF-only, no trailing newline (SPEC-05 §1.1). Decode strictly: a Latin-1
# misread would corrupt the 739 non-ASCII names ("5-Masted Preussen", "Zurich Blue", ...).
text = raw.decode("utf-8")
lines = text.split("\n")

# Line 1 is the attribution URL, not a header. ColorMatcher.cs:48 discards it unconditionally.
attribution = lines[0]
if not attribution.startswith("https://"):
    print("error: line 1 is not the expected attribution URL: %r" % attribution, file=sys.stderr)
    sys.exit(1)

rgbs = []
names = []
seen_names = set()

for line in lines[1:]:
    # ColorMatcher.cs:52 splits with a "commas outside quotes" regex, but no name in the
    # dataset contains a comma or a quote, so a plain split is behaviourally identical.
    parts = line.split(",")
    if len(parts) < 2:          # ColorMatcher.cs:54 — tolerant of 2-column rows
        continue
    name = parts[0].replace('"', "").strip()   # ColorMatcher.cs:55
    hexv = parts[1].strip()                    # ColorMatcher.cs:56
    if not hexv.startswith("#") or len(hexv) != 7:   # ColorMatcher.cs:57
        continue
    try:
        value = int(hexv[1:], 16)
    except ValueError:
        continue
    # Append in CSV order. No sort, no dict, no dedupe — see the header comment.
    rgbs.append(value & 0xFFFFFF)
    names.append(name)
    if name in seen_names:
        print("warning: duplicate name %r kept at index %d" % (name, len(names) - 1),
              file=sys.stderr)
    seen_names.add(name)

count = len(rgbs)
print("records parsed: %d" % count)

if count != expected:
    print("error: expected %d records, got %d — refusing to write %s"
          % (expected, count, out_path), file=sys.stderr)
    sys.exit(1)

# ---- Layout (all integers little-endian) -------------------------------------------------
#   0   4   magic "K2CT"
#   4   4   format version (1)
#   8   4   record count
#  12   4   names blob length in bytes
#  16   8   FNV-1a 64 hash of every byte from offset 24 to EOF
#  24   count*4        packed 0x00RRGGBB, CSV row order
#   .   (count+1)*4    byte offsets into the names blob; entry i spans [off[i], off[i+1])
#   .   namesLength    UTF-8 name bytes, concatenated, no separators
# The trailing sentinel offset makes slicing branch-free and lets the reader validate the
# blob length without a special case for the last record.
name_bytes = [n.encode("utf-8") for n in names]
offsets = [0]
for nb in name_bytes:
    offsets.append(offsets[-1] + len(nb))
names_blob = b"".join(name_bytes)
assert offsets[-1] == len(names_blob)

payload = b"".join([
    struct.pack("<%dI" % count, *rgbs),
    struct.pack("<%dI" % len(offsets), *offsets),
    names_blob,
])

# FNV-1a 64. Chosen over CRC32 because it is a dozen lines on both sides and needs no table,
# and this only has to catch truncation/corruption, not adversarial tampering.
h = 0xCBF29CE484222325
for byte in payload:
    h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF

header = struct.pack("<4sIIIQ", b"K2CT", 1, count, len(names_blob), h)
blob = header + payload

with open(out_path, "wb") as f:
    f.write(blob)

print("names blob:     %d bytes" % len(names_blob))
print("checksum:       0x%016X" % h)
print("total size:     %d bytes" % len(blob))
print("first record:   %r #%06x" % (names[0], rgbs[0]))
print("last record:    %r #%06x  (index %d)" % (names[-1], rgbs[-1], count - 1))
PYTHON

# `mktemp` creates the stage 0600; the shipped resource is world-readable like every other
# checked-in file.
chmod 644 "$STAGE"
# A same-filesystem `mv` is rename(2): the resource is either the old file or the whole new one,
# never a truncated blob an interrupted run left behind.
mv -f "$STAGE" "$OUT_FILE"
STAGE=""
echo "wrote $OUT_FILE"
