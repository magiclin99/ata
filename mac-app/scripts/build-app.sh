#!/bin/bash
# Builds ATA.app (and the ata-fakephone CLI) with SwiftPM, embeds WebRTC.framework and the localizations, signs it.
#
#   scripts/build-app.sh            debug build: SPEC §9 debug flags enabled  → build/ATA.app
#   scripts/build-app.sh release    release build: debug flags compiled out   → build/ATA.app
#
# Signing (environment):
#   ATA_SIGN_IDENTITY        code-signing identity (SHA-1 or name). Default "-" = ad-hoc.
#   ATA_SIGN_KEYCHAIN        keychain file holding that identity (e.g. ~/ata-secrets/mac/ata-signing.keychain-db).
#                            codesign only finds identities in keychains on the user search list, so the keychain is
#                            added to the list for the duration of the signing step and the exact previous list is
#                            restored on exit. The login keychain is not touched.
#   ATA_SIGN_KEYCHAIN_PASSWORD_FILE   if set, the keychain is unlocked with the password in this file (via stdin,
#                            never on a command line).
#   ATA_APP_OUT              output path of the .app (default build/ATA.app)
#   ATA_UNIVERSAL=1          build arm64 + x86_64 (what releases ship)
#
# Ad-hoc signatures change with every build, so macOS treats each build as a new app (Bluetooth prompt again). Signing with the stable self-signed identity keeps the designated requirement
# `identifier "io.github.magiclin99.ata.mac" and certificate leaf = H"<cert sha1>"` identical across builds.
set -euo pipefail
SIGN_ID="${ATA_SIGN_IDENTITY:--}"

CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"

ARCH_FLAGS=()
[ "${ATA_UNIVERSAL:-0}" = 1 ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product ATA
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product ata-fakephone
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="${ATA_APP_OUT:-$ROOT/build/ATA.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/ATA" "$APP/Contents/MacOS/ATA"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT"/Resources/MenuBarIcon*.png "$APP/Contents/Resources/"
for l in "$ROOT"/Resources/*.lproj; do ditto "$l" "$APP/Contents/Resources/$(basename "$l")"; done
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
printf 'APPL????' > "$APP/Contents/PkgInfo"
ditto "$BIN/WebRTC.framework" "$APP/Contents/Frameworks/WebRTC.framework"
# Headers / module map are build-time only.
rm -rf "$APP/Contents/Frameworks/WebRTC.framework/Versions/A/Headers" "$APP/Contents/Frameworks/WebRTC.framework/Headers" \
       "$APP/Contents/Frameworks/WebRTC.framework/Versions/A/Modules" "$APP/Contents/Frameworks/WebRTC.framework/Modules"

# The executable must find @rpath/WebRTC.framework in Contents/Frameworks.
RPATHS="$(otool -l "$APP/Contents/MacOS/ATA")"   # (no `| grep -q`: with pipefail an early exit reads as failure)
if [[ "$RPATHS" != *"@executable_path/../Frameworks"* ]]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ATA"
fi

SIGN_FLAGS=(--force --sign "$SIGN_ID")
if [ "$SIGN_ID" != "-" ]; then
    # Apple's timestamp service only serves Apple-issued certificates.
    SIGN_FLAGS+=(--timestamp=none)
    if [ -n "${ATA_SIGN_KEYCHAIN:-}" ]; then
        KC="$ATA_SIGN_KEYCHAIN"
        [ -f "$KC" ] || { echo "ATA_SIGN_KEYCHAIN: no such keychain: $KC" >&2; exit 1; }
        SIGN_FLAGS+=(--keychain "$KC")
        if [ -n "${ATA_SIGN_KEYCHAIN_PASSWORD_FILE:-}" ]; then
            # `security -i` reads the command from stdin: the password never shows up in `ps`.
            printf 'unlock-keychain -p %s %s\n' "$(cat "$ATA_SIGN_KEYCHAIN_PASSWORD_FILE")" "$KC" | security -i >/dev/null
        fi
        SEARCH_BEFORE=()
        while IFS= read -r l; do l="${l#"${l%%[![:space:]]*}"}"; l="${l%\"}"; SEARCH_BEFORE+=("${l#\"}"); done \
            < <(security list-keychains -d user)
        restore_search_list() { security list-keychains -d user -s "${SEARCH_BEFORE[@]}"; }
        trap restore_search_list EXIT
        security list-keychains -d user -s "${SEARCH_BEFORE[@]}" "$KC"
    fi
fi

# Inside-out signing.
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/WebRTC.framework"
codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID" "$APP"
[ "$(type -t restore_search_list)" = function ] && { restore_search_list; trap - EXIT; }
codesign --verify --deep --strict "$APP"

[ "$SIGN_ID" = "-" ] && SIGNED_WITH="ad-hoc" || SIGNED_WITH="$SIGN_ID"
echo "built $APP ($CONFIG, signed: $SIGNED_WITH)"
echo "fake phone: $BIN/ata-fakephone"
