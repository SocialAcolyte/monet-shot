#!/usr/bin/env bash
# xdg-desktop-portal-hyprland's custom_picker_binary, for a session nobody can
# click in: picks the first output (or what /tmp/hypr/pick says, e.g.
# "window:<handle>") and allows a restore token. Each call is logged, so a
# take that used the token instead shows no new line.
pick=$(cat /tmp/hypr/pick 2>/dev/null || echo "screen:$(hyprctl monitors -j 2>/dev/null | jq -r '.[0].name')")
echo "$(date +%T.%N) picker asked ($*); answered $pick" >> /tmp/hypr/picker.log
echo "[SELECTION]r/$pick"
