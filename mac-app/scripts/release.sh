#!/bin/bash
# Builds a signed release of ATA and packages it for GitHub Releases.
#
#   scripts/release.sh
#
# Output in dist/ (VERSION from Resources/Info.plist):
#   ATA-VERSION.zip  ATA-VERSION.dmg  ATA.dmg (same file, fixed name for the website)  *.sha256  SHA256SUMS.txt
#   install.sh (unchanged installer; it uses the versioned zip)
#
# Signing identity: the self-signed certificate in signing/ata-signing-cert.pem (public part, in the repo). The
# script refuses to publish anything signed by a different certificate, because a different certificate means a
# different designated requirement, i.e. every user would get the Bluetooth prompt again and lose their pairings.
#
# Environment (defaults are the local secrets layout created by scripts/make-signing-identity.sh):
#   ATA_SIGN_KEYCHAIN                 default ~/ata-secrets/mac/ata-signing.keychain-db
#   ATA_SIGN_KEYCHAIN_PASSWORD_FILE   default ~/ata-secrets/mac/keychain-password.txt (if it exists)
# CI (.github/workflows/release-mac.yml at the repository root) imports the .p12 into a temporary keychain and sets both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
CERT="$ROOT/signing/ata-signing-cert.pem"
CERT_SHA1="$(openssl x509 -in "$CERT" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
CERT_SHA1_LC="$(printf '%s' "$CERT_SHA1" | tr 'A-F' 'a-f')"

export ATA_SIGN_IDENTITY="$CERT_SHA1"
export ATA_SIGN_KEYCHAIN="${ATA_SIGN_KEYCHAIN:-$HOME/ata-secrets/mac/ata-signing.keychain-db}"
if [ -z "${ATA_SIGN_KEYCHAIN_PASSWORD_FILE:-}" ] && [ -f "$HOME/ata-secrets/mac/keychain-password.txt" ]; then
    export ATA_SIGN_KEYCHAIN_PASSWORD_FILE="$HOME/ata-secrets/mac/keychain-password.txt"
fi

echo "== ATA $VERSION ($BUILD), signing with certificate SHA-1 $CERT_SHA1"
STAGE="$ROOT/build/release"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ATA_UNIVERSAL=1 ATA_APP_OUT="$STAGE/ATA.app" scripts/build-app.sh release
APP="$STAGE/ATA.app"

echo "== checks"
codesign --verify --deep --strict --verbose=1 "$APP"
DR="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
WANT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1_LC\""
if [ "$DR" != "$WANT" ]; then
    echo "designated requirement mismatch:" >&2; echo "  got:  $DR" >&2; echo "  want: $WANT" >&2; exit 1
fi
echo "designated requirement: $DR"
FW_DR="$(codesign -d -r- "$APP/Contents/Frameworks/WebRTC.framework" 2>&1 | sed -n 's/^designated => //p')"
case "$FW_DR" in *"H\"$CERT_SHA1_LC\""*) ;; *) echo "WebRTC.framework not signed with the release certificate: $FW_DR" >&2; exit 1 ;; esac
# Debug hooks (SPEC §9 flags, loopback signaling) must be compiled out.
if strings "$APP/Contents/MacOS/ATA" | grep -q -e '--debug-show-pairing' -e 'LoopbackSignalServer'; then
    echo "release binary still contains debug hooks" >&2; exit 1
fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ]
for b in "$APP/Contents/MacOS/ATA" "$APP/Contents/Frameworks/WebRTC.framework/WebRTC"; do
    lipo "$b" -verify_arch arm64 x86_64 || { echo "$b is not universal (arm64 + x86_64)" >&2; exit 1; }
done
echo "universal: arm64 + x86_64"

echo "== package"
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="ATA-$VERSION.zip"
DMG="ATA-$VERSION.dmg"
# No resource forks / extended attributes: the zip holds only the bundle (no __MACOSX/ entries).
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$DIST/$ZIP"
if unzip -Z1 "$DIST/$ZIP" | grep -q '^__MACOSX/'; then echo "$ZIP contains __MACOSX entries" >&2; exit 1; fi

# Disk image with a background (arrow from ATA to Applications) and fixed icon positions. The Finder layout is a
# stored file (Resources/dmg/DS_Store, made by scripts/make-dmg-layout.sh) that expects the volume name "ATA" and the
# background at /.background.tiff, so plain `hdiutil create` is enough (no writable mount, no Finder scripting).
DMGROOT="$STAGE/dmg"
mkdir -p "$DMGROOT"
ditto "$APP" "$DMGROOT/ATA.app"
ln -s /Applications "$DMGROOT/Applications"
cp "$ROOT/Resources/dmg/DS_Store" "$DMGROOT/.DS_Store"
cp "$ROOT/Resources/dmg/background.tiff" "$DMGROOT/.background.tiff"
chflags hidden "$DMGROOT/.background.tiff"
hdiutil create -quiet -volname "ATA" -srcfolder "$DMGROOT" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DIST/$DMG"
# Sign the disk image too (same identity), so its origin can be checked with `codesign -dv`.
KC="$ATA_SIGN_KEYCHAIN"
KC_PASSWORD_FILE="${ATA_SIGN_KEYCHAIN_PASSWORD_FILE:-}"
. "$ROOT/scripts/signing-keychain.sh"
signing_keychain_open
codesign --force --sign "$CERT_SHA1" --keychain "$KC" --timestamp=none --identifier "$BUNDLE_ID.dmg" "$DIST/$DMG"
signing_keychain_close

# Same disk image under a fixed name, so the website can always link releases/latest/download/ATA.dmg.
cp "$DIST/$DMG" "$DIST/ATA.dmg"
cmp -s "$DIST/$DMG" "$DIST/ATA.dmg"

cp "$ROOT/install.sh" "$DIST/install.sh"
(
    cd "$DIST"
    for f in "$ZIP" "$DMG" ATA.dmg install.sh; do shasum -a 256 "$f" > "$f.sha256"; done
    shasum -a 256 "$ZIP" "$DMG" ATA.dmg install.sh > SHA256SUMS.txt
)

echo "== verify dmg"
MNT="$(mktemp -d /tmp/ata-dmg.XXXXXX)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DIST/$DMG"
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
codesign --verify --deep --strict "$MNT/ATA.app"
[ "$(codesign -d -r- "$MNT/ATA.app" 2>&1 | sed -n 's/^designated => //p')" = "$WANT" ]
[ -L "$MNT/Applications" ] && [ -f "$MNT/.DS_Store" ] && [ -f "$MNT/.background.tiff" ] \
    || { echo "disk image is missing its Applications link, window layout or background" >&2; exit 1; }
hdiutil detach -quiet "$MNT"; trap - EXIT
echo "dmg mounts; ATA.app inside verifies"

echo "== signing keychain"
echo "signing keychain: $(swift "$ROOT/scripts/keychain-state.swift" "$ATA_SIGN_KEYCHAIN" 2>/dev/null), not on the search list"
echo "== done"
ls -l "$DIST"
cat "$DIST/SHA256SUMS.txt"
