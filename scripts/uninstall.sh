#!/bin/bash
# Remove MonetShot. Keeps config and logs unless --purge is given.
set -euo pipefail
APP_NAME=MonetShot
DEST="$HOME/Applications/$APP_NAME.app"
/usr/bin/pkill -x "$APP_NAME" 2>/dev/null && echo "quit running $APP_NAME" || true
if [[ -d "$DEST" ]]; then rm -rf "$DEST"; echo "removed $DEST"; else echo "$DEST was not installed"; fi
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/Library/Application Support/$APP_NAME" "$HOME/Library/Logs/$APP_NAME"
  echo "removed config and logs"
else
  echo "kept ~/Library/Application Support/$APP_NAME and ~/Library/Logs/$APP_NAME (use --purge to remove)"
fi
