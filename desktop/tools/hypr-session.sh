#!/usr/bin/env bash
# Inside the hypr container, as root: bring up an Omarchy session the way a
# login does, minus systemd. Hyprland runs on its own DRM backend (the vkms
# card from hypr-kmod.sh), as user `run`, with Omarchy's config at a tag.
#
#   hypr-session.sh start 4|3   # Omarchy 4.x (Lua, omarchy-shell) or 3.x (hyprlang, Waybar)
#   hypr-session.sh prep 4|3    # all of start but Hyprland and the portals (no DRM needed)
#   hypr-session.sh stop        # Hyprland and the user session, not the system bits
#   hypr-session.sh env         # prints the session env (eval it, or source /tmp/hypr/env)
#
# Mode: HYPR_MODE (default 1600x900@60), HYPR_SCALE (default 1).
set -euo pipefail
U=run UH=/home/run RT=/run/user/1000 L=/tmp/hypr
mkdir -p "$L"; chmod 777 "$L"
cmd=${1:-start} major=${2:-4}

as_run() { runuser -u "$U" -- env -i HOME="$UH" USER="$U" LOGNAME="$U" SHELL=/bin/bash \
  PATH=/usr/local/bin:/usr/bin:/bin XDG_RUNTIME_DIR="$RT" LANG=C.UTF-8 "$@"; }

system_up() {
  # Device nodes made after the container started (uinput) aren't in its /dev.
  mknods() {
    for d in /sys/class/input/event* /sys/class/drm/card* /sys/class/drm/renderD*; do
      [[ -e $d/dev ]] || continue
      local n; n=/dev/$( [[ $d == */drm/* ]] && echo dri/ || echo input/ )$(basename "$d")
      [[ -e $n ]] && continue
      mkdir -p "$(dirname "$n")"; IFS=: read -r ma mi < "$d/dev"; mknod "$n" c "$ma" "$mi"
    done
    chgrp video /dev/dri/* 2>/dev/null || true; chmod 660 /dev/dri/* 2>/dev/null || true
    chgrp input /dev/input/event* 2>/dev/null || true; chmod 660 /dev/input/event* 2>/dev/null || true
  }
  ls /dev/dri/card* >/dev/null 2>&1 || mknods
  # A virtual mouse + keyboard (uinput), so clicks and keys reach evdev as on hardware.
  if [[ -c /dev/uinput ]] && ! pgrep -x ydotoold >/dev/null; then
    (ydotoold --socket-path=/tmp/.ydotool_socket --socket-own=1000:1000 </dev/null >"$L/ydotoold.log" 2>&1 &)
    for _ in $(seq 50); do grep -qs ydotoold /proc/bus/input/devices && break; sleep 0.1; done
  fi
  mknods
  # udev: libinput (Hyprland) only takes devices udev has tagged.
  if ! pgrep -x systemd-udevd >/dev/null; then
    /usr/lib/systemd/systemd-udevd --daemon </dev/null >"$L/udevd.log" 2>&1 || true
    udevadm trigger --subsystem-match=input --subsystem-match=drm >/dev/null 2>&1 || true
    timeout 10 udevadm settle -t 5 >/dev/null 2>&1 || true
  fi
  pgrep -x seatd >/dev/null || (seatd -g seat </dev/null >"$L/seatd.log" 2>&1 &)
  for _ in $(seq 50); do [[ -S /run/seatd.sock ]] && break; sleep 0.1; done
}

user_up() {
  [[ -S $RT/bus ]] || as_run dbus-daemon --session --address="unix:path=$RT/bus" --fork --nopidfile </dev/null >"$L/dbus.log" 2>&1
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus"
  pgrep -u "$U" -x pipewire >/dev/null || (as_run DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" pipewire </dev/null >"$L/pipewire.log" 2>&1 &)
  sleep 0.5
  pgrep -u "$U" -x wireplumber >/dev/null || (as_run DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" wireplumber </dev/null >"$L/wireplumber.log" 2>&1 &)
}

# Omarchy's config, laid out as its installer does: the repo in
# ~/.local/share/omarchy, config/* copied into ~/.config, a theme linked.
omarchy_config() {
  local src=/opt/omarchy$major om="$UH/.local/share/omarchy"
  rm -rf "$om" "$UH/.config" "$UH/.local/state/omarchy"
  mkdir -p "$UH/.local/share" "$UH/.config" "$UH/.local/state/omarchy"
  cp -a "$src" "$om"
  cp -R "$om/config/." "$UH/.config/"
  local theme; theme=$(ls "$om/themes" | head -1)
  mkdir -p "$UH/.config/omarchy/current"
  ln -sfn "$om/themes/$theme" "$UH/.config/omarchy/current/theme"
  # The share picker can't be clicked here: answer it from a script (it
  # logs each time it's asked, so a restore token shows as no new line).
  sed -i "s|custom_picker_binary = .*|custom_picker_binary = /src/desktop/tools/hypr-picker.sh|" "$UH/.config/hypr/xdph.conf"
  # The virtual display: a mode Omarchy's "preferred" (vkms: 1024x768) isn't.
  local mode=${HYPR_MODE:-1600x900@60} scale=${HYPR_SCALE:-1}
  if [[ $major == 4 ]]; then
    sed -i "s|^hl.monitor({ output = \"\", .*|hl.monitor({ output = \"\", mode = \"$mode\", position = \"0x0\", scale = $scale })|" "$UH/.config/hypr/monitors.lua"
  else
    sed -i "s|^monitor=,preferred,auto,auto|monitor=,$mode,0x0,$scale|" "$UH/.config/hypr/monitors.conf"
  fi
  # The app, as the package puts it on PATH.
  ln -sfn "${MONETSHOT_BIN:-/target/debug/monet-shot}" /usr/local/bin/monet-shot
  chown -R "$U:$U" "$UH"
}

hypr_up() {
  ls /dev/dri/card* >/dev/null 2>&1 || { echo "no DRM device: run desktop/tools/hypr-kmod.sh on the host first" >&2; exit 1; }
  as_run DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" LIBSEAT_BACKEND=seatd \
    AQ_DRM_DEVICES="$(ls /dev/dri/card* | head -1)" OMARCHY_PATH="$UH/.local/share/omarchy" \
    XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland LIBGL_ALWAYS_SOFTWARE=1 \
    Hyprland </dev/null >"$L/hyprland.log" 2>&1 &
  local hpid=$! sig=""
  for _ in $(seq 120); do
    # (|| true: under -e -o pipefail an empty ls would end the script, silently.)
    sig=$(ls "$RT/hypr" 2>/dev/null | head -1 || true)
    [[ -n $sig && -S $RT/hypr/$sig/.socket.sock ]] && break
    kill -0 $hpid 2>/dev/null || { sig=""; echo "Hyprland exited" >&2; break; }
    sleep 0.5
  done
  [[ -n $sig ]] || { echo "Hyprland didn't start:" >&2; tail -40 "$L/hyprland.log" >&2
    tail -60 "$RT"/hypr/*/hyprland.log >&2 2>/dev/null || true
    tail -60 "$UH"/.cache/hyprland/hyprlandCrashReport*.txt >&2 2>/dev/null || true; exit 1; }
  local wl; wl=$(cd "$RT" && ls wayland-* 2>/dev/null | grep -v lock | head -1 || true)
  cat >"$L/env" <<EOF
export XDG_RUNTIME_DIR=$RT
export DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus
export HYPRLAND_INSTANCE_SIGNATURE=$sig
export WAYLAND_DISPLAY=$wl
export XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=Hyprland
export OMARCHY_PATH=$UH/.local/share/omarchy
export PATH=$UH/.local/share/omarchy/bin:/usr/local/bin:/usr/bin:/bin
export YDOTOOL_SOCKET=/tmp/.ydotool_socket
export HOME=$UH
EOF
  chmod 644 "$L/env"
  # The portals see the compositor through the bus's activation environment.
  timeout 10 runuser -u "$U" -- bash -c ". $L/env; dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE XDG_SESSION_TYPE" || echo "dbus-update-activation-environment failed" >&2
  (as_run bash -c ". $L/env; exec /usr/lib/xdg-desktop-portal-hyprland" </dev/null >"$L/xdph.log" 2>&1 &)
  sleep 1
  (as_run bash -c ". $L/env; exec /usr/lib/xdg-desktop-portal -r" </dev/null >"$L/xdp.log" 2>&1 &)
  sleep 1
  echo "Hyprland $sig on $wl (Omarchy $major)"
  timeout 10 runuser -u "$U" -- bash -c ". $L/env; hyprctl monitors -j" | jq -c '.[] | {name, width, height, refreshRate, scale, reserved}'
}

hyprctl_run() { as_run bash -c ". $L/env; hyprctl \"\$@\"" _ "$@"; }

stop() {
  pkill -u "$U" -x monet-shot 2>/dev/null || true
  pkill -u "$U" -f xdg-desktop-portal 2>/dev/null || true
  pkill -u "$U" -x Hyprland 2>/dev/null || true
  for _ in $(seq 20); do pgrep -u "$U" -x Hyprland >/dev/null || break; sleep 0.5; done
  pkill -u "$U" -x quickshell 2>/dev/null || true
  pkill -u "$U" -x waybar 2>/dev/null || true
  rm -rf "$RT/hypr" "$RT"/wayland-*
}

step() { echo "     [$(date +%T)] $1" >&2; "$1"; }
case $cmd in
  start) step stop; step system_up; step user_up; step omarchy_config; step hypr_up ;;
  prep) step stop; step system_up; step user_up; step omarchy_config; echo "prepared (Omarchy $major), no Hyprland" ;;
  stop) stop ;;
  env) cat "$L/env" ;;
  *) echo "usage: $0 start 4|3 | stop | env" >&2; exit 2 ;;
esac
