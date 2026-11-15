#!/bin/bash
# Tests install.sh's authenticity check without touching /Applications or a running ATA: every case is a
# --dry-run against a local file:// "release" built from a fixture app.
#
#   scripts/test-install.sh [path/to/ATA.app]     (default: build/release/ATA.app from scripts/release.sh)
#
# Cases:
#   1. the release-signed app                       → accepted
#   2. the same app re-signed ad-hoc                → refused ("not signed with ATA's certificate")
#   3. the same app signed by another self-signed cert (throwaway, generated here) → refused
#   4. the release-signed app with a modified file  → refused ("broken or missing")
#   5. a correct app whose zip fails the checksum   → refused
# The throwaway certificate lives in a temporary keychain that is deleted at the end; the user's keychain search
# list is extended only while signing case 3 and restored exactly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/build/release/ATA.app}"
[ -d "$SRC" ] || { echo "no app at $SRC (run scripts/release.sh first)" >&2; exit 2; }
V=9.9.9
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ata-install-test.XXXXXX")"
KC="$WORK/throwaway.keychain-db"
SEARCH_BEFORE=()
while IFS= read -r l; do l="${l#"${l%%[![:space:]]*}"}"; l="${l%\"}"; SEARCH_BEFORE+=("${l#\"}"); done \
    < <(security list-keychains -d user)
cleanup() {
    security list-keychains -d user -s "${SEARCH_BEFORE[@]}"
    [ -f "$KC" ] && security delete-keychain "$KC" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

release_of() {   # release_of <case> <app>  → $WORK/<case>/ATA-$V.zip + .sha256
    mkdir -p "$WORK/$1"
    ditto -c -k --norsrc --noextattr --keepParent "$2" "$WORK/$1/ATA-$V.zip"
    (cd "$WORK/$1" && shasum -a 256 "ATA-$V.zip" > "ATA-$V.zip.sha256")
}
fail=0
expect() {   # expect <case> <accept|reject> <message substring>
    local out rc=0
    out="$(ATA_BASE_URL="file://$WORK/$1" ATA_VERSION=$V ATA_INSTALL_DIR="$WORK/dest" sh "$ROOT/install.sh" --dry-run 2>&1)" || rc=$?
    if { [ "$2" = accept ] && [ $rc -eq 0 ]; } || { [ "$2" = reject ] && [ $rc -ne 0 ]; }; then
        if [[ "$out" == *"$3"* ]]; then echo "PASS  $1: ${2}ed"; return; fi
    fi
    echo "FAIL  $1: expected $2 with \"$3\" (exit $rc)"; printf '%s\n' "$out" | sed 's/^/      /'; fail=1
}

# 1. Release-signed.
release_of valid "$SRC"
expect valid accept "signed with ATA's certificate"

# 2. Ad-hoc.
mkdir -p "$WORK/apps/adhoc"; ditto "$SRC" "$WORK/apps/adhoc/ATA.app"
codesign --force --sign - "$WORK/apps/adhoc/ATA.app/Contents/Frameworks/WebRTC.framework" 2>/dev/null
codesign --force --sign - --identifier io.github.magiclin99.ata.mac "$WORK/apps/adhoc/ATA.app" 2>/dev/null
codesign --verify --deep --strict "$WORK/apps/adhoc/ATA.app"   # valid signature, just not ours
release_of adhoc "$WORK/apps/adhoc/ATA.app"
expect adhoc reject "not signed with ATA's certificate"

# 3. Another self-signed certificate with the same name and bundle id (what an impostor would make).
umask 077
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ATA Release Signing (magiclin99)
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -config "$WORK/cert.cnf" \
    -keyout "$WORK/k.pem" -out "$WORK/c.pem" 2>/dev/null
PW="$(openssl rand -hex 16)"
printf '%s' "$PW" > "$WORK/pw"
openssl pkcs12 -export -inkey "$WORK/k.pem" -in "$WORK/c.pem" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -macalg sha1 -passout "file:$WORK/pw" -out "$WORK/other.p12"
security -i <<EOF >/dev/null
create-keychain -p $PW $KC
unlock-keychain -p $PW $KC
import $WORK/other.p12 -k $KC -f pkcs12 -P $PW -T /usr/bin/codesign
set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PW $KC
EOF
OTHER_SHA1="$(openssl x509 -in "$WORK/c.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
mkdir -p "$WORK/apps/other"; ditto "$SRC" "$WORK/apps/other/ATA.app"
security list-keychains -d user -s "${SEARCH_BEFORE[@]}" "$KC"
codesign --force --keychain "$KC" --sign "$OTHER_SHA1" --timestamp=none "$WORK/apps/other/ATA.app/Contents/Frameworks/WebRTC.framework" 2>/dev/null
codesign --force --keychain "$KC" --sign "$OTHER_SHA1" --timestamp=none --identifier io.github.magiclin99.ata.mac "$WORK/apps/other/ATA.app" 2>/dev/null
security list-keychains -d user -s "${SEARCH_BEFORE[@]}"
release_of other "$WORK/apps/other/ATA.app"
expect other reject "not signed with ATA's certificate"

# 4. Modified after signing.
mkdir -p "$WORK/apps/tampered"; ditto "$SRC" "$WORK/apps/tampered/ATA.app"
printf 'x' >> "$WORK/apps/tampered/ATA.app/Contents/Resources/LICENSE.txt"
release_of tampered "$WORK/apps/tampered/ATA.app"
expect tampered reject "broken or missing"

# 5. Checksum mismatch.
release_of badsum "$SRC"
echo "0000000000000000000000000000000000000000000000000000000000000000  ATA-$V.zip" > "$WORK/badsum/ATA-$V.zip.sha256"
expect badsum reject "checksum mismatch"

[ $fail -eq 0 ] && echo "all install.sh authenticity cases passed" || { echo "install.sh authenticity test FAILED" >&2; exit 1; }
