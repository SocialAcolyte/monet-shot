#!/usr/bin/env bash
# Set up Monet Shot's Omarchy integration for the current user:
#   Omarchy 4 (Lua Hyprland, omarchy-shell bar): window rules, the bar widget
#     plugin, and (if you say yes) SUPER + ALT + R to record / stop.
#   Omarchy 3 (hyprlang, Waybar): the same rules + bind, and a Waybar module.
#
#   install.sh              asks before each change
#   install.sh --yes        doesn't ask
#   install.sh --uninstall  takes out exactly what it put in
#
# Every edited file gets a one-time backup (<file>.monet-shot.bak) and every
# addition sits between "# >>> monet-shot" / "# <<< monet-shot" markers (or
# the Lua/JSON/CSS comment form), so running it twice changes nothing.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
share="${MONETSHOT_OMARCHY:-/usr/share/monet-shot/omarchy}"
[[ -f "$share/hyprland.lua" ]] || share="$here"   # run from a checkout

yes=0; uninstall=0
for a in "$@"; do
  case "$a" in
    --yes|-y) yes=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

hypr="$HOME/.config/hypr"
say() { printf '%s\n' "$*"; }
ask() {
  (( yes )) && return 0
  [[ -t 0 ]] || { say "  (skipped: not a terminal; pass --yes)"; return 1; }
  read -r -p "$1 [Y/n] " r
  [[ -z $r || $r == [Yy]* ]]
}
backup() { [[ -f "$1" && ! -f "$1.monet-shot.bak" ]] && cp "$1" "$1.monet-shot.bak" || true; }

# Adds a marked block to a file (comment prefix $3), once.
add_block() {
  local file="$1" body="$2" c="$3"
  grep -qF -e "$c >>> monet-shot" "$file" 2>/dev/null && { say "  already in $file"; return 0; }
  backup "$file"
  mkdir -p "$(dirname "$file")"
  printf '\n%s >>> monet-shot\n%s\n%s <<< monet-shot\n' "$c" "$body" "$c" >> "$file"
  say "  added to $file"
}

remove_block() {
  local file="$1" c="$2"
  [[ -f "$file" ]] || return 0
  grep -qF -e "$c >>> monet-shot" "$file" || return 0
  python3 - "$file" "$c" <<'PY'
import re, sys
p, c = sys.argv[1], re.escape(sys.argv[2])
s = open(p).read()
s = re.sub(r"\n?" + c + r" >>> monet-shot\n.*?" + c + r" <<< monet-shot\n?", "\n", s, flags=re.S)
open(p, "w").write(s)
PY
  say "  removed from $file"
}

omarchy4() { [[ -f "$hypr/hyprland.lua" ]] || command -v omarchy-shell >/dev/null 2>&1; }

reload_hypr() { command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true; }

# --- Omarchy 4 ---------------------------------------------------------------
install4() {
  say "Omarchy 4: Hyprland Lua + omarchy-shell"
  say "• Window rules (pill on top and out of screen shares, editors float)"
  if ask "  add them to $hypr/hyprland.lua?"; then
    add_block "$hypr/hyprland.lua" "dofile(\"$share/hyprland.lua\")" "--"
  fi
  say "• Shortcut: SUPER + ALT + R records / stops"
  if ask "  add it to $hypr/bindings.lua?"; then
    add_block "$hypr/bindings.lua" "$(grep -v '^--' "$share/bindings.lua")" "--"
  fi
  say "• Bar widget (click: record / stop, right-click: pause)"
  if ask "  install the omarchy-shell plugin?"; then
    local dest="$HOME/.config/omarchy/plugins/monet-shot"
    mkdir -p "$dest"
    cp "$share/plugin/manifest.json" "$share/plugin/Widget.qml" "$dest/"
    # Omarchy 4's shell places widgets in left / center / right; ours goes
    # after the clock. Enabling goes through the running shell (its IPC).
    # The shell rescans its plugin folders on request, not at once: try a few times.
    local why="omarchy-plugin-enable isn't here" enabled=0 refused=0
    if command -v omarchy-plugin-validate >/dev/null 2>&1 && ! why=$(omarchy-plugin-validate "$dest" 2>&1); then
      refused=1; say "  omarchy-plugin-validate refused it ($why); not enabling"
    elif command -v omarchy-plugin-enable >/dev/null 2>&1; then
      omarchy-shell -q shell rescanPlugins
      for _ in 1 2 3 4 5; do
        if why=$(omarchy-plugin-enable monet-shot --section center --after omarchy.clock 2>&1); then enabled=1; break; fi
        sleep 1
      done
    fi
    if (( enabled )); then
      say "  enabled beside the clock"
    elif (( ! refused )); then
      say "  copied to $dest; not enabled ($why)"
      say "  enable it with: omarchy plugin enable monet-shot --section center --after omarchy.clock"
    fi
  fi
  reload_hypr
}

uninstall4() {
  remove_block "$hypr/hyprland.lua" "--"
  remove_block "$hypr/bindings.lua" "--"
  if command -v omarchy-plugin-disable >/dev/null 2>&1; then omarchy-plugin-disable monet-shot >/dev/null 2>&1 || true; fi
  rm -rf "$HOME/.config/omarchy/plugins/monet-shot"
  reload_hypr
}

# --- Omarchy 3 ---------------------------------------------------------------
waybar_dir="$HOME/.config/waybar"

install3() {
  say "Omarchy 3: hyprlang + Waybar"
  say "• Window rules + SUPER ALT R to record / stop"
  if ask "  source them from $hypr/hyprland.conf?"; then
    add_block "$hypr/hyprland.conf" "source = $share/hyprland.conf" "#"
  fi
  say "• Waybar module (click: record / stop, right-click: pause)"
  if [[ -f "$waybar_dir/config.jsonc" ]] && ask "  add it to $waybar_dir/config.jsonc?"; then
    backup "$waybar_dir/config.jsonc"
    python3 - "$waybar_dir/config.jsonc" "$share/waybar-module.jsonc" <<'PY'
import re, sys
p, mod = sys.argv[1], sys.argv[2]
s = open(p).read()
if '"custom/monet-shot"' in s:
    print("  already in", p); sys.exit(0)
block = "".join(l for l in open(mod) if not l.lstrip().startswith("//")).strip()
# Into modules-center, after Omarchy's recording indicator if it's there.
def put(m):
    items = m.group(2)
    if '"custom/screenrecording-indicator"' in items:
        items = items.replace('"custom/screenrecording-indicator"', '"custom/screenrecording-indicator", "custom/monet-shot"', 1)
    else:
        items = items.rstrip() + (', ' if items.strip() else '') + '"custom/monet-shot"'
    return m.group(1) + items + m.group(3)
s, n = re.subn(r'("modules-center"\s*:\s*\[)(.*?)(\])', put, s, count=1, flags=re.S)
if n == 0:
    sys.exit("no modules-center in " + p)
# The module's own block, before the closing brace of the top-level object.
i = s.rstrip().rfind("}")
head = s[:i].rstrip()
sep = "" if head.endswith(",") or head.endswith("{") else ","
s = head + sep + "\n  // >>> monet-shot\n  " + block.replace("\n", "\n  ") + "\n  // <<< monet-shot\n" + s[i:]
open(p, "w").write(s)
print("  added to", p)
PY
    local css="$waybar_dir/style.css"
    if grep -qF '/* >>> monet-shot */' "$css" 2>/dev/null; then
      say "  already in $css"
    else
      backup "$css"
      printf '\n/* >>> monet-shot */\n%s\n/* <<< monet-shot */\n' "$(cat "$share/waybar.css")" >> "$css"
      say "  added to $css"
    fi
    if command -v omarchy-restart-waybar >/dev/null 2>&1; then omarchy-restart-waybar; else pkill -SIGUSR2 waybar || true; fi
  fi
  reload_hypr
}

uninstall3() {
  remove_block "$hypr/hyprland.conf" "#"
  if [[ -f "$waybar_dir/config.jsonc" ]] && grep -q "custom/monet-shot" "$waybar_dir/config.jsonc"; then
    python3 - "$waybar_dir/config.jsonc" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r',?\s*// >>> monet-shot.*?// <<< monet-shot\n', '\n', s, flags=re.S)
s = s.replace(', "custom/monet-shot"', '').replace('"custom/monet-shot", ', '').replace('"custom/monet-shot"', '')
open(p, "w").write(s)
PY
    say "  removed from $waybar_dir/config.jsonc"
  fi
  if [[ -f "$waybar_dir/style.css" ]]; then
    python3 - "$waybar_dir/style.css" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n?/\* >>> monet-shot \*/\n.*?/\* <<< monet-shot \*/\n?', '\n', s, flags=re.S)
open(p, "w").write(s)
PY
  fi
  if command -v omarchy-restart-waybar >/dev/null 2>&1; then omarchy-restart-waybar; else pkill -SIGUSR2 waybar || true; fi
  reload_hypr
}

# --- Checks that apply to both ------------------------------------------------
checks() {
  if ! id -nG | tr ' ' '\n' | grep -qx input; then
    say ""
    say "Note: clicks (for auto-zoom) and double-tap Shift (pause) read /dev/input,"
    say "which needs the input group:  sudo usermod -aG input \"\$USER\"  then log out and in."
  fi
  if ! pacman -Q xdg-desktop-portal-hyprland >/dev/null 2>&1; then
    say "Note: xdg-desktop-portal-hyprland isn't installed; Hyprland needs it to share the screen."
  fi
}

if (( uninstall )); then
  if omarchy4; then uninstall4; else uninstall3; fi
  say "Monet Shot's Omarchy integration is removed."
  exit 0
fi
if omarchy4; then install4; else install3; fi
checks
say "Done."
