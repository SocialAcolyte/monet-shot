#!/usr/bin/env bash
# Inside the run container: a 1600x1000 virtual display with a window
# manager and a system-tray host, and a session bus. Prints the GL renderer.
#   docker exec ms-linux bash /src/desktop/tools/linux-run-display.sh
set -euo pipefail
export DISPLAY=:99
pgrep -x Xvfb >/dev/null || (Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &)
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done
[[ -f /tmp/dbus.env ]] || dbus-launch --sh-syntax > /tmp/dbus.env
. /tmp/dbus.env
pgrep -x openbox >/dev/null || (openbox >/tmp/openbox.log 2>&1 &)
pgrep -x stalonetray >/dev/null || (stalonetray --geometry 4x1+1450+0 --icon-size 24 --kludges force_icons_size -bg "#202020" >/tmp/tray.log 2>&1 &)
sleep 1
xdpyinfo | grep dimensions
glxinfo -B 2>/dev/null | grep -E "renderer string|core profile version" || true
