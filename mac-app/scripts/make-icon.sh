#!/bin/bash
# Regenerates the app icon and the menu bar template image from the brand assets in Resources/brand/
# (copied from the project's brand kit, whose generator is the source of truth).
#
#   scripts/make-icon.sh      → Resources/AppIcon.icns, Resources/MenuBarIcon.png, Resources/MenuBarIcon@2x.png
#
# Needs `sips`, `iconutil` (macOS) and `rsvg-convert` (Homebrew librsvg) for the menu bar image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Resources"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/AppIcon.iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s brand/icon-macos-1024.png --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) brand/icon-macos-1024.png --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o AppIcon.icns

# Menu bar: the one-colour mark as a template image (macOS tints it for light/dark menu bars). 18 pt tall.
rsvg-convert -w 18 -h 18 brand/ata-mark-mono.svg -o MenuBarIcon.png
rsvg-convert -w 36 -h 36 brand/ata-mark-mono.svg -o MenuBarIcon@2x.png
echo "wrote Resources/AppIcon.icns, MenuBarIcon.png, MenuBarIcon@2x.png"
