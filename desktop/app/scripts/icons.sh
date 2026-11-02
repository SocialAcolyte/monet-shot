#!/bin/sh
# Derives src-tauri/icons from the one canonical icon, Resources/AppIcon.icns
# (macOS only: iconutil). Re-run when the icon changes; the outputs are kept
# in the repo so Linux and Windows builds don't need a Mac.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
iconutil -c iconset "$here/../../Resources/AppIcon.icns" -o "$tmp/AppIcon.iconset"
cd "$here"
npx tauri icon "$tmp/AppIcon.iconset/icon_512x512@2x.png" -o src-tauri/icons
# Mobile and Store sizes are not used.
rm -rf src-tauri/icons/android src-tauri/icons/ios src-tauri/icons/Square*Logo.png src-tauri/icons/StoreLogo.png
