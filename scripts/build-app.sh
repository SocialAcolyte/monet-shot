#!/bin/bash
# Build Monet Shot and assemble an ad-hoc signed "Monet Shot.app".
# Usage: scripts/build-app.sh [--output DIR]   (default: dist/)
# Prints the bundle path last.
set -euo pipefail

# Fixed tool paths: never taken from PATH.
SWIFT=/usr/bin/swift
CODESIGN=/usr/bin/codesign
PLUTIL=/usr/bin/plutil
XATTR=/usr/bin/xattr

APP_NAME=MonetShot
DISPLAY_NAME="Monet Shot"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/dist"
while (( $# )); do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    *) echo "usage: $0 [--output DIR]" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
step() { printf '\n==> %s\n' "$*"; }

step "Building (release)"
cd "$ROOT"
"$SWIFT" build -c release --product "$APP_NAME"
BIN="$("$SWIFT" build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

APP="$OUTPUT/$DISPLAY_NAME.app"
step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# The backdrop gallery: public-domain paintings and their credits.
[[ -d "$ROOT/Resources/Backdrops" ]] && cp -R "$ROOT/Resources/Backdrops" "$APP/Contents/Resources/"
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null

step "Signing (ad-hoc)"
# iCloud-synced folders (Desktop, Documents) tag files with extended
# attributes that make strict signature checks fail; strip them first.
"$XATTR" -cr "$APP"
"$CODESIGN" --force --sign - --timestamp=none "$APP"
"$CODESIGN" --verify --strict "$APP"
echo "signed and verified"
echo "$APP"
