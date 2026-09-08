#!/bin/bash
# Regenerates the golden AES vectors by compiling and running this repository's own
# Arduino AES implementation natively.
#
# Why this exists: the Swift port must be byte-identical to the firmware that programs real
# tags. Rather than trust hand-computed constants, we compile the reference and diff against
# it. A hand-computed value in an early draft of the spec turned out to be wrong; this script
# is how that was caught.
#
# Usage: Tools/aes-reference-check.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AES_DIR="$REPO_ROOT/reference/arduino-aes"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f "$AES_DIR/AES.cpp" ]]; then
    echo "error: reference AES not found at $AES_DIR" >&2
    exit 1
fi

cd "$WORK"
cp "$AES_DIR/AES.cpp" "$AES_DIR/AES.h" .

# The reference targets Arduino, which supplies PROGMEM via pgmspace.h. Stub it for the host.
cat > pgmspace.h <<'EOF'
#ifndef PGMSPACE_STUB_H
#define PGMSPACE_STUB_H
#define PROGMEM
#define pgm_read_byte(addr) (*(const unsigned char *)(addr))
#endif
EOF

cat > harness.cpp <<'EOF'
#include "AES.h"
#include <cstdio>
#include <cstring>

static void dump(const char *label, unsigned char *b, int n) {
    printf("%-28s", label);
    for (int i = 0; i < n; i++) printf("%02X", b[i]);
    printf("\n");
}

int main() {
    AES aes;
    unsigned char out[16];

    // keytype 0 = u_key  (key derivation), keytype 1 = d_key (payload).
    unsigned char uid[4] = {0x80, 0xA6, 0x79, 0x39};
    unsigned char uid16[16];
    for (int i = 0; i < 16; i++) uid16[i] = uid[i % 4];
    aes.encrypt(0, uid16, out);
    dump("KDF ciphertext (UID tiled)", out, 16);
    dump("  -> derived sector key", out, 6);

    unsigned char zeros[16];
    memset(zeros, 0, 16);
    aes.encrypt(1, zeros, out);
    dump("payload AES(zeros)", out, 16);

    unsigned char rec[16];
    memcpy(rec, "AB1240276A210100", 16);
    aes.encrypt(1, rec, out);
    dump("payload AES(record blk0)", out, 16);
    return 0;
}
EOF

clang++ -std=c++11 -I. -o aescheck AES.cpp harness.cpp
echo "Golden vectors from the Arduino reference implementation:"
echo
./aescheck
