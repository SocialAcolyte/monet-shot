#!/bin/bash
# Build and install MonetShot to ~/Applications. No password needed.
# Idempotent: run again to upgrade. Quits a running copy first.
set -euo pipefail
APP_NAME=MonetShot
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/Applications/$APP_NAME.app"
step() { printf '\n==> %s\n' "$*"; }

# Build first: if it fails, nothing installed is touched.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
"$ROOT/scripts/build-app.sh" --output "$STAGE" >/dev/null || { echo "Build failed. Nothing was changed." >&2; exit 1; }

step "Installing $DEST"
if /usr/bin/pgrep -qx "$APP_NAME"; then
  /usr/bin/osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/pgrep -qx "$APP_NAME" || break; sleep 0.5; done
  /usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$STAGE/$APP_NAME.app" "$DEST"
/usr/bin/codesign --verify --strict "$DEST"
echo "installed $DEST"
echo
echo "Launch:     open \"$DEST\""
echo "Logs:       tail -f ~/Library/Logs/$APP_NAME/$(echo $APP_NAME | tr '[:upper:]' '[:lower:]').log"
echo "Uninstall:  $ROOT/scripts/uninstall.sh"
