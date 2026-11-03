#!/usr/bin/env bash
# Inside the hypr container, as root, with a session up (hypr-session.sh):
# the proofs, one step per subcommand, results and screenshots in /shots.
#
#   hypr-check.sh install        install.sh --yes on the live session; binds/rules loaded
#   hypr-check.sh desktop        something to record: a terminal and a moving window
#   hypr-check.sh take <name>    a demo take (MONETSHOT_DEMO_RECORD=1 STOP=7) with
#                                pointer moves to known spots + a uinput click;
#                                checks video, cursor.json, picker, pill, bar JSON
#   hypr-check.sh bind <name>    SUPER+ALT+R (the installed bind) starts and stops a take
#   hypr-check.sh editor <take> <name>  devchecks/editor.js on a copy of the take, then export
#   hypr-check.sh home <take> <name>    devchecks/home.js on a library of two copies of the take
# No -e: a step that breaks is a FAIL line, and the next step still runs.
set -uo pipefail
L=/tmp/hypr S=/shots UH=/home/run
mkdir -p "$S"; chmod 777 "$S"   # grim runs as the session user
reset_app_log() { : > "$L/app.log"; chown run:run "$L/app.log"; }
ok=0 bad=0
pass() { ok=$((ok+1)); echo "ok   $*" | tee -a "$S/results.txt"; }
fail() { bad=$((bad+1)); echo "FAIL $*" | tee -a "$S/results.txt"; }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
note() { echo "     $*" | tee -a "$S/results.txt"; }
u() { runuser -u run -- bash -c ". $L/env; $1"; }
hc() { u "hyprctl $*"; }
# hd 'hl.dsp.…(…)': a Lua dispatcher (Hyprland 0.57's Lua config takes no
# classic dispatcher strings); says so when Hyprland didn't answer "ok".
hd() { local r; r=$(u "hyprctl dispatch '$1'" 2>&1); [[ $r == ok ]] || echo "     dispatch $1: $r" | tee -a "$S/results.txt"; }
cursor_to() { hd "hl.dsp.cursor.move({ x = $1, y = $2 })"; }
mover_to() { hd "hl.dsp.window.move({ window = \"title:^mover\$\", x = $1, y = $2 })"; }
library() { echo "$UH/Videos/MonetShot"; }
newest_take() { ls -td "$(library)"/*/ 2>/dev/null | head -1 | sed 's:/$::'; }
status_json() { u "monet-shot status" 2>/dev/null; }
phase() { status_json | jq -r '.phase // "off"' 2>/dev/null; }
wait_phase() { # wait_phase <regex> <seconds>
  local t=$(( $2 * 4 ))
  while (( t-- > 0 )); do [[ $(phase) =~ $1 ]] && return 0; sleep 0.25; done; return 1
}
app_running() { pgrep -u run -x monet-shot >/dev/null; }

start_app() { # start_app [VAR=value ...] [-- args]
  local envs=() args=()
  while (( $# )) && [[ $1 != -- ]]; do envs+=("$1"); shift; done; [[ ${1:-} == -- ]] && shift; args=("$@")
  local path='$PATH'; [[ -n ${PATH_NOBAR:-} ]] && path=/usr/local/bin:/usr/bin:/bin
  u "cd /tmp && PATH=$path exec env ${envs[*]} monet-shot ${args[*]} >>$L/app.log 2>&1" </dev/null >/dev/null 2>&1 &
  for _ in $(seq 120); do app_running && return 0; sleep 0.25; done; return 1
}
stop_app() { pkill -u run -x monet-shot 2>/dev/null || true; for _ in $(seq 40); do app_running || return 0; sleep 0.25; done; pkill -9 -u run -x monet-shot || true; }

cmd_install() {
  local share=/src/desktop/packaging/omarchy
  u "bash $share/install.sh --yes" 2>&1 | tee "$S/install-$(om).txt"
  check "install.sh ran without errors on Omarchy $(om)" test "${PIPESTATUS[0]}" -eq 0
  check "Hyprland has no config errors" bash -c "[[ \$(runuser -u run -- bash -c '. $L/env; hyprctl configerrors') =~ ^(|no errors)$'\n'?$ ]]"
  hc "configerrors" | sed 's/^/     /' | tee -a "$S/results.txt"
  local b; b=$(hc "binds -j" | jq -c '.[] | select(.key=="R" and .modmask==72)')
  note "bind: $b"
  # Lua binds show their function's id as the arg; ours carries a description.
  if [[ $(om) == 4 ]]; then
    local pl; pl=$(u "omarchy-shell shell listPlugins" 2>&1)
    note "omarchy-shell plugins: $(echo "$pl" | tr '\n' ' ' | cut -c1-600)"
    check "the omarchy-shell plugin is enabled" grep -q 'enabled beside the clock' "$S/install-4.txt"
  fi
  check "SUPER+ALT+R is bound (Monet Shot: record or stop)" bash -c "jq -e 'select(.description | test(\"Monet Shot\"))' <<<'$b' >/dev/null"
}
om() { [[ -f $UH/.config/hypr/hyprland.lua ]] && echo 4 || echo 3; }

cmd_desktop() {
  # A clock in a terminal (moves every frame) and a second window we slide around.
  u "cd /tmp && exec foot --title clock -e sh -c 'while :; do printf \"\\r%s \" \$(date +%T.%N); sleep 0.05; done'" </dev/null >/dev/null 2>&1 &
  u "cd /tmp && exec foot --title mover -o colors-dark.background=ff00ff -e sh -c 'echo Monet Shot on Hyprland; cat'" </dev/null >/dev/null 2>&1 &
  for _ in $(seq 40); do (( $(hc "clients -j" | jq '[.[] | select(.class=="foot")] | length') >= 2 )) && break; sleep 0.5; done
  hd 'hl.dsp.window.float({ window = "title:^mover$", action = "toggle" })'
  hd 'hl.dsp.window.resize({ window = "title:^mover$", x = 420, y = 160 })'
  mover_to 600 500
  hc "clients -j" | jq -c '.[] | {class, title, at, size, floating}' | sed 's/^/     /' | tee -a "$S/results.txt"
}

# The pointer path for a take: logical layout points, held 0.6 s each. The
# first is the "mover" window's top-left corner, so the picture can be
# checked against the log there.
SPOTS=("600 500" "200 150" "1400 200" "1400 750" "300 700" "800 450")

cmd_take() {
  local name=$1; shift
  local before; before=$(cat "$L/picker.log" 2>/dev/null | wc -l)
  local prev; prev=$(newest_take)
  stop_app; reset_app_log
  start_app MONETSHOT_DEMO_RECORD=1 MONETSHOT_DEMO_STOP="${STOP:-7}" "$@" || { fail "$name: the app starts"; return; }
  # What the bar (Waybar module / omarchy-shell plugin) is fed, for the whole take.
  u "exec timeout 60 monet-shot status --waybar --follow" </dev/null > "$S/$name-bar.jsonl" 2>/dev/null &
  local follow=$!
  if wait_phase 'countdown|starting|recording' 30; then
    sleep 0.4
    hc "clients -j" > "$S/$name-clients-countdown.json"
    u "grim $S/$name-countdown.png" || true
    shot_pill "$name-countdown"
  fi
  check "$name: the take starts recording (portal answered)" wait_phase recording 40
  : > "$S/$name-moves.txt"
  for s in "${SPOTS[@]}"; do
    cursor_to $s
    echo "$(date +%s.%N) $s $(hc 'cursorpos')" >> "$S/$name-moves.txt"
    sleep 0.6
  done
  # A click through uinput at the last spot (evdev sees a real device).
  YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool click 0xC0 >/dev/null 2>&1 && echo "$(date +%s.%N) click" >> "$S/$name-moves.txt"
  hc "clients -j" > "$S/$name-clients-recording.json"
  u "grim $S/$name-recording.png" || true
  shot_bar "$name-bar"
  # Slide the mover across, so the video has motion to check.
  for x in 640 700 760 820 880; do mover_to $x 500; sleep 0.1; done
  mover_to 600 500
  wait_phase 'idle' 60 || true
  kill $follow 2>/dev/null || true
  local take; take=$(newest_take)
  check "$name: a new recording folder" test -n "$take" -a "$take" != "$prev"
  [[ -n $take && $take != "$prev" ]] || return 0
  echo "$take" > "$S/$name-take.txt"
  local after; after=$(cat "$L/picker.log" 2>/dev/null | wc -l)
  note "picker asked $((after - before)) time(s) for this take"
  echo $((after - before)) > "$S/$name-picker-count.txt"
  verify_take "$name" "$take"
}

verify_take() {
  local name=$1 take=$2 shot=$2
  ls "$take" | sed 's/^/     /' | tee -a "$S/results.txt"
  local video; video=$(jq -r '.video // "screen.mp4"' "$take/meta.json")
  [[ -f $take/$video ]] || video=$(ls "$take" | grep -E 'screen\.(mp4|mov)$' | head -1)
  local probe; probe=$(ffprobe -v error -count_frames -select_streams v:0 \
     -show_entries stream=codec_name,width,height,nb_read_frames,avg_frame_rate -show_entries format=duration -of json "$take/$video")
  echo "$probe" | jq -c '{s: .streams[0], d: .format.duration}' | sed 's/^/     /' | tee -a "$S/results.txt"
  local frames; frames=$(echo "$probe" | jq -r '.streams[0].nb_read_frames // 0')
  check "$name: $video plays (decodes $frames frames)" test "$frames" -gt 60
  jq -c '{pixelWidth, pixelHeight, pointScale, duration, source, video}' "$take/meta.json" | sed 's/^/     meta /' | tee -a "$S/results.txt"
  cp "$take/meta.json" "$S/$name-meta.json"; cp "$take/cursor.json" "$S/$name-cursor.json"
  # Frames: start, middle, end.
  local d; d=$(echo "$probe" | jq -r '.format.duration')
  ffmpeg -v error -y -ss 1 -i "$take/$video" -frames:v 1 "$S/$name-frame-1s.png"
  python3 /src/desktop/tools/hypr-cursor-check.py "$take" "$S/$name-moves.txt" "$S/$name" | tee -a "$S/results.txt"
  [[ ${PIPESTATUS[0]} == 0 ]] && pass "$name: cursor.json lines up with Hyprland's pointer and the picture" || fail "$name: cursor.json lines up with Hyprland's pointer and the picture"
}

cmd_pill() { # what the rules did to the pill, from a take's clients dump
  local name=$1 phase=$2 f="$S/$1-clients-$2.json"
  local p; p=$(jq -c '.[] | select(.title=="Monet Shot Pill") | {at, size, floating, pinned, mapped, hidden, monitor, workspace: .workspace.name}' "$f")
  note "pill ($phase): ${p:-none}"
  echo "${p:-}"
}

# The pill's window, as the rules left it: floating, pinned, top centre, y 40.
check_pill() {
  local name=$1 phase=$2 f="$S/$1-clients-$2.json"
  local p; p=$(jq -c '[.[] | select(.title=="Monet Shot Pill")][0] // empty | {at, size, floating, pinned, mapped, hidden, workspace: .workspace.name}' "$f")
  note "pill during $phase: ${p:-not mapped}"
  [[ -n $p ]] || { fail "$name: the pill is mapped during $phase"; return; }
  local mw; mw=$(hc "monitors -j" | jq '.[0].width / .[0].scale')
  check "$name: pill floating + pinned during $phase" jq -e '.floating and .pinned' <<<"$p"
  check "$name: pill at the rule's size (180x34) during $phase" jq -e '.size == [180, 34]' <<<"$p"
  check "$name: pill at the rule's place (centred, y 40) during $phase" \
    jq -e --argjson mw "$mw" '((.at[0] + .size[0] / 2) - $mw / 2 | fabs) <= 1 and .at[1] == 40' <<<"$p"
}

# Is the pill in the recording? The video at the pill's place vs the screenshot.
pill_in_video() {
  local name=$1 take; take=$(cat "$S/$name-take.txt")
  local p; p=$(jq -c '[.[] | select(.title=="Monet Shot Pill")][0] // empty | {at, size}' "$S/$name-clients-recording.json")
  [[ -n $p ]] || return 0
  local x y w h; read -r x y w h < <(jq -r '"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' <<<"$p")
  ffmpeg -v error -y -ss 2.5 -i "$take/screen.mp4" -frames:v 1 -vf "crop=$((w+40)):$((h+40)):$((x-20)):$((y-20)),scale=iw*3:ih*3:flags=neighbor" "$S/$name-pill-in-video.png"
  magick "$S/$name-recording.png" -crop "$((w+40))x$((h+40))+$((x-20))+$((y-20))" -scale 300% "$S/$name-pill-on-screen.png" 2>/dev/null || true
  local mean; mean=$(ffmpeg -v error -ss 2.5 -i "$take/screen.mp4" -frames:v 1 -vf "crop=$w:$h:$x:$y" -f rawvideo -pix_fmt gray - | python3 -c 'import sys; b=sys.stdin.buffer.read(); print(round(sum(b)/max(1,len(b)),1))')
  note "video where the pill is on screen: mean luma $mean/255 (pill-in-video.png vs pill-on-screen.png)"
}

cmd_bind() {
  local name=$1 before prev; before=$(cat "$L/picker.log" 2>/dev/null | wc -l); prev=$(newest_take)
  stop_app; reset_app_log
  start_app || { fail "$name: the app starts"; return; }
  sleep 4
  note "SUPER+ALT+R: $(hc "binds -j" | jq -c '[.[] | select(.key=="R" and .modmask==72)][0] | {dispatcher, arg, description}')"
  # The keys themselves, through the uinput keyboard (ydotoold): Hyprland
  # matches its own bind, as for a person. (A Lua bind's function can't be
  # dispatched from hyprctl.)
  local kb; kb=$(hc "devices -j" | jq -r '[.keyboards[] | select(.name | test("ydotool"))][0].name // empty')
  [[ -n $kb ]] || { fail "$name: Hyprland has the uinput keyboard (devices -j)"; stop_app; return; }
  note "keyboard: $kb"
  keys() { YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool key 125:1 56:1 19:1 19:0 56:0 125:0 >/dev/null 2>&1; }
  keys
  check "$name: pressing SUPER+ALT+R starts a take" wait_phase recording 40
  sleep 3
  keys
  check "$name: pressing SUPER+ALT+R again stops it" wait_phase 'saving|idle' 20
  wait_phase idle 60 || true
  local take; take=$(newest_take)
  check "$name: the take is saved" test -n "$take" -a "$take" != "$prev"
  note "picker asked $(( $(cat "$L/picker.log" 2>/dev/null | wc -l) - before )) time(s)"
  stop_app
}

cmd_editor() {
  local take=$1 name=$2 copy="$UH/Videos/check-$(basename "$1")"
  rm -rf "$copy"; cp -a "$take" "$copy"; chown -R run:run "$copy"
  stop_app; reset_app_log
  start_app MONETSHOT_DEV_SCRIPT=/work/desktop/app/ui/devchecks/editor.js -- "\"$copy\"" || { fail "$name: the editor opens"; return; }
  sleep 25; u "grim $S/$name-editor.png" || true
  local t=0; until grep -q "check: done" "$L/app.log" || (( t++ > 900 )); do sleep 1; done
  grep -o "check: .*" "$L/app.log" | sed 's/^/     /' | tee "$S/$name-editor-checks.txt" | tee -a "$S/results.txt" >/dev/null
  local done_line; done_line=$(grep -o "check: done.*" "$L/app.log" | tail -1)
  check "$name: editor checks all pass ($done_line)" bash -c "[[ '$done_line' =~ \ 0\ failed ]]"
  local out; out=$(ls -t "$UH"/Videos/MonetShot/*.mp4 "$UH"/Videos/*.mp4 2>/dev/null | head -1)
  if [[ -n $out ]]; then
    note "export: $out $(ffprobe -v error -show_entries stream=codec_name,width,height -show_entries format=duration -of csv=p=0 "$out" | tr '\n' ' ')"
    ffmpeg -v error -y -ss 2 -i "$out" -frames:v 1 "$S/$name-export-2s.png"
  fi
  stop_app
}

# devchecks/home.js (ms-win's; Windows: windows-run.ps1 stage "home"): Home's
# cards, Move to Trash, Show in folder, open; in the editor, add a video,
# Record a new take (the portal again, from inside the editor; stopped here
# with `monet-shot toggle`), reorder clips, undo, save.
cmd_home() {
  local take=$1 name=$2 h=$UH/ms-home
  rm -rf "$h" "$UH/.local/share/Trash"; mkdir -p "$h/recordings"
  cp -a "$take" "$h/recordings/Open me.reel"; cp -a "$take" "$h/recordings/Trash me.reel"
  cp "$take/screen.mp4" "$h/footage.mp4"; chown -R run:run "$h"
  : > "$L/xdg-open.log"; chmod 666 "$L/xdg-open.log"
  stop_app; reset_app_log
  local before; before=$(cat "$L/picker.log" 2>/dev/null | wc -l)
  start_app MONETSHOT_HOME="$h" MONETSHOT_DEV_SCRIPT=/work/desktop/app/ui/devchecks/home.js || { fail "$name: the app starts (home)"; return; }
  hl() { cat "$L/app.log" "$h"/logs/* 2>/dev/null; }
  wait_log() { local t=$(( $2 * 2 )); while (( t-- > 0 )); do hl | grep -qE "$1" && return 0; sleep 0.5; done; return 1; }
  wait_log 'home: (ok|FAIL) Home shows' 90 && { sleep 2; u "grim $S/$name-home.png" || true; }
  if wait_log 'recording into' 180; then
    sleep 3; u "grim $S/$name-home-new-take.png" || true
    u "MONETSHOT_HOME=$h monet-shot toggle" </dev/null >/dev/null 2>&1 || true
  else fail "$name: Record a new take (from the editor) starts recording"; fi
  local done_=0; wait_log 'home: done [0-9]+ ok, [0-9]+ failed' 180 && done_=1
  sleep 1; u "grim $S/$name-home-clips.png" || true
  stop_app
  hl | grep -E 'home:|recording into|ERROR' | sed 's/^/     /' | tee "$S/$name-home-log.txt" | tee -a "$S/results.txt" >/dev/null
  note "picker asked $(( $(cat "$L/picker.log" 2>/dev/null | wc -l) - before )) time(s) for the new take"
  local fails; fails=$(hl | grep -o 'home: FAIL.*')
  if [[ -n $fails ]]; then while IFS= read -r f; do fail "$name: $f"; done <<<"$fails"; fi
  if (( ! done_ )); then fail "$name: home.js's editor part finished ('home: done')"
  elif [[ -z $fails ]]; then pass "$name: home.js, $(hl | grep -c 'home: ok') checks ok"; fi
  check "$name: Trash me.reel left the library for the freedesktop Trash" \
    bash -c "[[ ! -e '$h/recordings/Trash me.reel' ]] && ls '$UH/.local/share/Trash/files' | grep -q 'Trash me'"
  note "xdg-open asked for: $(tr '\n' ' ' < "$L/xdg-open.log")"
  check "$name: Show in folder handed the recordings folder to the file manager" grep -q recordings "$L/xdg-open.log"
  local takes; takes=$(ls -d "$h/recordings/Open me.reel"/take-* 2>/dev/null | wc -l)
  check "$name: Open me.reel has $takes take folders (the video and the new recording added; Windows checks >= 2)" test "$takes" -ge 2
}

summary() { echo "== $ok ok, $bad failed" | tee -a "$S/results.txt"; }

# Omarchy 3's Waybar module. Hyprland 0.57 (Arch, today) reads only Lua
# configs, so a 3.x hyprlang session can't start any more; instead install.sh
# runs against a 3.x home (its Waybar path) and that Waybar runs in the live
# Hyprland session, in place of omarchy-shell's bar.
cmd_waybar() {
  local h=/home/run3
  rm -rf "$h"; mkdir -p "$h/.config" "$h/.local/share"
  cp -a /opt/omarchy3 "$h/.local/share/omarchy"; cp -R /opt/omarchy3/config/. "$h/.config/"
  mkdir -p "$h/.config/omarchy/current"; ln -sfn "$h/.local/share/omarchy/themes/$(ls /opt/omarchy3/themes | head -1)" "$h/.config/omarchy/current/theme"
  chown -R run:run "$h"
  local p3=$h/.local/share/omarchy/bin:/usr/local/bin:/usr/bin:/bin
  u "HOME=$h OMARCHY_PATH=$h/.local/share/omarchy PATH=$p3 bash /src/desktop/packaging/omarchy/install.sh --yes" 2>&1 | tee "$S/install-3.txt" | sed 's/^/     /' | tee -a "$S/results.txt"
  check "install.sh (Omarchy 3) added the Waybar module" grep -q '"custom/monet-shot"' "$h/.config/waybar/config.jsonc"
  # One Waybar: install.sh restarted Omarchy's (omarchy-restart-waybar); ours replaces it, with its log.
  pkill -u run -x quickshell 2>/dev/null || true; pkill -u run -x waybar 2>/dev/null || true; sleep 1
  u "cd $h && exec env OMARCHY_PATH=$h/.local/share/omarchy PATH=$p3 waybar -c $h/.config/waybar/config.jsonc -s $h/.config/waybar/style.css" </dev/null >"$L/waybar.log" 2>&1 &
  sleep 6
  check "Waybar runs with the module" pgrep -u run -x waybar
}

# The pill as a person sees it: grim is a screencopy client, so no_screen_share
# blacks the pill out of it too. Lift the prop for one shot, then put it back.
shot_pill() {
  local w='title:^Monet Shot Pill$'
  hd "hl.dsp.window.set_prop({ window = \"$w\", prop = \"no_screen_share\", value = \"0\" })"
  sleep 0.15
  u "grim -g '600,20 400,80' $S/$1-pill.png" || true
  hd "hl.dsp.window.set_prop({ window = \"$w\", prop = \"no_screen_share\", value = \"1\" })"
}

shot_bar() { # shot_bar <name>: the top 40 px, centre half
  u "grim -g '400,0 800x40' $S/$1.png" || true
  u "grim -s 3 -g '700,0 300x30' $S/$1-zoom.png" || true
}

cmd_all() {
  echo "== Omarchy $(cd /opt/omarchy4 && git describe --tags 2>/dev/null), $(Hyprland --version | head -1)" | tee -a "$S/results.txt"
  bash /src/desktop/tools/hypr-session.sh start 4 2>&1 | tee -a "$S/results.txt"
  if [[ ${PIPESTATUS[0]} != 0 ]]; then fail "Hyprland starts on the vkms card with Omarchy 4's config"; summary; return; fi
  pass "Hyprland starts on the vkms card with Omarchy 4's config"
  local t=0; until u "omarchy-shell shell ping" >/dev/null 2>&1 || (( t++ > 60 )); do sleep 0.5; done
  check "omarchy-shell (Quickshell) answers its IPC" u "omarchy-shell shell ping"
  cmd_install; cmd_desktop
  sleep 8; u "grim $S/o4-desktop.png" || true
  STOP=8 cmd_take o4-take1
  check_pill o4-take1 countdown
  check "o4-take1: the portal's picker was asked once" test "$(cat "$S/o4-take1-picker-count.txt" 2>/dev/null)" = 1
  cmd_take o4-take2
  check "o4-take2: the restore token skips the picker" test "$(cat "$S/o4-take2-picker-count.txt" 2>/dev/null)" = 0
  cmd_bind o4-bind
  cmd_editor "$(cat "$S/o4-take1-take.txt")" o4
  cmd_home "$(cat "$S/o4-take1-take.txt")" o4
  # Hyprland with no bar showing our clock (not Omarchy, or its bar off):
  # the pill stays up while recording.
  pkill -u run -x quickshell 2>/dev/null || true
  PATH_NOBAR=1 cmd_take nobar
  check_pill nobar recording
  pill_in_video nobar
  cmd_waybar
  cmd_take waybar
  check "Waybar stayed up through the take" pgrep -u run -x waybar
  tail -5 "$L/waybar.log" | sed 's/^/     waybar: /' | tee -a "$S/results.txt"
  summary
}

# Every step announces itself, with the time, in the results.
for f in $(declare -F | awk '$3 ~ /^cmd_/ && $3 != "cmd_all" {print $3}'); do
  eval "_$f() $(declare -f "$f" | tail -n +2)"
  eval "$f() { echo \"-- [\$(date +%T)] ${f#cmd_} \$*\" | tee -a \"\$S/results.txt\"; _$f \"\$@\"; }"
done
c=${1:-all}; shift || true
"cmd_$c" "$@"
[[ $c == all ]] || summary
(( bad == 0 ))
