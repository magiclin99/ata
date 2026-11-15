#!/bin/bash
# Regenerates Resources/dmg/DS_Store: the Finder window layout of the release disk image (window size, background,
# icon positions; see scripts/dmg-settings.py). Run it only when the layout or background changes.
#
#   scripts/make-dmg-layout.sh
#
# Why a stored file instead of running dmgbuild in every release: dmgbuild mounts a writable image and copies the app
# onto it, and on Macs with an endpoint security scanner the copied app keeps the volume busy, so it can't be
# detached. Writing the layout once with a placeholder (no executable) avoids that; scripts/release.sh then builds
# the image with plain `hdiutil create -srcfolder`. The volume name is always "ATA", which the stored layout's
# background reference relies on.
#
# dmgbuild comes from a throwaway venv with hash-pinned packages (scripts/requirements-dmg.txt).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'hdiutil detach -quiet "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes -r "$ROOT/scripts/requirements-dmg.txt"
mkdir -p "$WORK/ATA.app"   # placeholder with the real name; only its position matters
"$WORK/venv/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D app="$WORK/ATA.app" \
    -D background="$ROOT/Resources/dmg/background.tiff" "ATA" "$WORK/layout.dmg" >/dev/null
mkdir "$WORK/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/mnt" "$WORK/layout.dmg"
cp "$WORK/mnt/.DS_Store" "$ROOT/Resources/dmg/DS_Store"
hdiutil detach -quiet "$WORK/mnt"
echo "wrote Resources/dmg/DS_Store"
