#!/bin/sh
# ATA for Mac installer.
#
#   curl -fsSL https://github.com/magiclin99/ata/releases/latest/download/install.sh | sh
#
# What it does, in order (nothing else):
#   1. Finds the latest release of github.com/magiclin99/ata (or ATA_VERSION, e.g. 1.0.0).
#   2. Downloads ATA-<version>.zip and ATA-<version>.zip.sha256 from that release into a temporary folder.
#   3. Checks the zip's SHA-256 against the published checksum. Stops if they differ.
#   4. Unpacks it and checks that ATA.app is intact and signed by ATA's publisher: codesign --verify --deep --strict
#      against the pinned requirement below (bundle id + SHA-1 of ATA's signing certificate, the same certificate
#      as mac-app/signing/ata-signing-cert.pem in the repository). Anything else is refused.
#   5. Quits ATA if it is running, replaces /Applications/ATA.app (asks for your password only if /Applications is
#      not writable for you), and opens the new copy.
# Safe to re-run: it always ends with exactly one current copy of ATA.app. Nothing runs as root except the copy
# into /Applications when that needs it. It does not change any security setting.
#
# Options (environment variables):
#   ATA_VERSION=1.0.0        install this version instead of the latest
#   ATA_INSTALL_DIR=DIR      install into DIR instead of /Applications
#   ATA_DRY_RUN=1            download and verify only; print what would be done, change nothing (or pass --dry-run)
#   ATA_NO_LAUNCH=1          do not open ATA after installing
#   ATA_BASE_URL=URL         download from URL/<file> instead of the GitHub release (testing; file:// works)
#
# Why no Gatekeeper prompt: files downloaded with curl are not marked as "downloaded from the internet"
# (no com.apple.quarantine attribute), so macOS opens the app without the "unidentified developer" dialog.
# The app is signed with ATA's own self-signed certificate, not with an Apple Developer ID.

set -eu

REPO="magiclin99/ata"
APP_NAME="ATA.app"
BUNDLE_ID="io.github.magiclin99.ata.mac"
# Every ATA release is signed with this one certificate. A checksum only proves the zip matches what is on the
# release page; this requirement proves who signed the app.
REQUIREMENT='identifier "io.github.magiclin99.ata.mac" and certificate leaf = H"3da39545619d4949fa758c6becc77f9e2e3ce65e"'


say() { printf '%s\n' "ATA installer: $*"; }
die() { printf '%s\n' "ATA installer: error: $*" >&2; exit 1; }

main() {
    dry_run="${ATA_DRY_RUN:-0}"
    for a in "$@"; do
        case "$a" in
            --dry-run) dry_run=1 ;;
            -h|--help) sed -n '2,27p' "$0" 2>/dev/null || true; exit 0 ;;
            *) die "unknown option: $a" ;;
        esac
    done
    dest_dir="${ATA_INSTALL_DIR:-/Applications}"

    [ "$(uname -s)" = "Darwin" ] || die "ATA for Mac needs macOS."
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 14 ] 2>/dev/null || die "ATA needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."
    for t in curl shasum ditto codesign; do
        command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
    done

    version="${ATA_VERSION:-}"
    if [ -n "${ATA_BASE_URL:-}" ]; then
        base="${ATA_BASE_URL%/}"
        [ -n "$version" ] || die "ATA_BASE_URL needs ATA_VERSION as well."
    else
        if [ -z "$version" ]; then
            # /releases/latest redirects to /releases/tag/v<version>; no API token or JSON parsing needed.
            latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
                || die "no published release found at https://github.com/$REPO/releases (or GitHub is unreachable)."
            tag="${latest##*/}"
            case "$tag" in v[0-9]*) version="${tag#v}" ;; *) die "no published release found at https://github.com/$REPO/releases" ;; esac
        fi
        base="https://github.com/$REPO/releases/download/v$version"
    fi
    case "$version" in *[!0-9A-Za-z.-]*|"") die "bad version: $version" ;; esac

    zip="ATA-$version.zip"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ata-install.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT INT TERM

    say "downloading ATA $version from $base/"
    curl -fSL --progress-bar -o "$tmp/$zip" "$base/$zip" || die "download failed: $base/$zip"
    curl -fsSL -o "$tmp/$zip.sha256" "$base/$zip.sha256" || die "download failed: $base/$zip.sha256"

    want="$(awk '{print $1; exit}' "$tmp/$zip.sha256")"
    got="$(shasum -a 256 "$tmp/$zip" | awk '{print $1}')"
    [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $zip (expected $want, got $got). Nothing was installed."
    say "checksum OK (SHA-256 $got)"

    mkdir "$tmp/unpacked"
    ditto -x -k "$tmp/$zip" "$tmp/unpacked" || die "cannot unpack $zip"
    new="$tmp/unpacked/$APP_NAME"
    [ -d "$new" ] || die "$zip does not contain $APP_NAME"
    codesign --verify --deep --strict "$new" 2>/dev/null \
        || die "the code signature of $APP_NAME is broken or missing. Nothing was installed."
    codesign --verify --deep --strict -R="$REQUIREMENT" "$new" 2>/dev/null \
        || die "$APP_NAME is not signed with ATA's certificate (expected: $REQUIREMENT). Nothing was installed."
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new/Contents/Info.plist" 2>/dev/null || true)"
    [ "$id" = "$BUNDLE_ID" ] || die "unexpected bundle id in $zip: $id"
    say "signature OK (signed with ATA's certificate)"

    target="$dest_dir/$APP_NAME"
    # Information only: say whether the copy being replaced came from ATA's publisher (e.g. not a local build).
    if [ -e "$target" ]; then
        if codesign --verify --deep --strict -R="$REQUIREMENT" "$target" >/dev/null 2>&1; then
            say "the installed $target is signed with ATA's certificate"
        else
            say "note: the installed $target is not signed with ATA's certificate (a local build, damaged or another app); it will be replaced"
        fi
    fi
    if [ "$dry_run" = 1 ]; then
        say "dry run: would quit ATA if running, replace $target with ATA $version, and open it. Nothing was changed."
        exit 0
    fi

    quit_running

    sudo=""
    if [ ! -d "$dest_dir" ]; then mkdir -p "$dest_dir" 2>/dev/null || sudo="sudo"; fi
    if [ -z "$sudo" ] && [ ! -w "$dest_dir" ]; then sudo="sudo"; fi
    if [ -n "$sudo" ] && [ -e "$target" ] && [ -w "$target" ] && [ -w "$dest_dir" ]; then sudo=""; fi
    [ -z "$sudo" ] || say "$dest_dir is not writable for $(id -un); using sudo for the copy (you may be asked for your password)"

    # Copy next to the target first, then swap, so an interrupted install never leaves a half-copied app.
    staging="$dest_dir/.ATA-install-$$.app"
    $sudo rm -rf "$staging"
    $sudo ditto "$new" "$staging"
    if [ -e "$target" ]; then
        old="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null || echo unknown)"
        $sudo rm -rf "$target"
        say "removed the old copy ($old)"
    fi
    $sudo mv "$staging" "$target"
    say "installed ATA $version to $target"

    if [ "${ATA_NO_LAUNCH:-0}" != 1 ]; then
        open "$target" && say "opened ATA. It runs in the menu bar; open ATA again from Applications to see its window."
    fi
    say "done. To uninstall: quit ATA, then delete $target."
}

quit_running() {
    # SIGTERM: ATA handles it like choosing Quit (Bluetooth is stopped cleanly). No AppleScript, so no
    # "Terminal wants to control ATA" prompt.
    pat="/$APP_NAME/Contents/MacOS/ATA( |\$)"
    if pgrep -f "$pat" >/dev/null 2>&1; then
        say "quitting the running ATA"
        pkill -TERM -f "$pat" >/dev/null 2>&1 || true
        i=0
        while pgrep -f "$pat" >/dev/null 2>&1 && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
        if pgrep -f "$pat" >/dev/null 2>&1; then pkill -KILL -f "$pat" >/dev/null 2>&1 || true; sleep 1; fi
    fi
}

# Everything above only defines functions; this last line runs them, so a truncated download does nothing.
main "$@"
