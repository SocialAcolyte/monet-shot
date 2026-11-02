#!/usr/bin/env bash
# Inside the run container: screenshot the virtual display (or one window by
# title) into /shots/<name>.png.   linux-run-shot.sh <name> [window title]
set -euo pipefail
export DISPLAY=:99
mkdir -p /shots
if [[ -n "${2:-}" ]]; then
  id=$(xdotool search --name "$2" | tail -1)
  import -window "$id" "/shots/$1.png"
else
  import -window root "/shots/$1.png"
fi
echo "/shots/$1.png"
