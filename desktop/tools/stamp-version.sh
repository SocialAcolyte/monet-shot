#!/usr/bin/env bash
# Stamp the one version in VERSION (repo root) into every build:
#   Resources/Info.plist (CFBundleShortVersionString; CFBundleVersion +1)
#   desktop/Cargo.toml [workspace.package] version, desktop/app/src-tauri/Cargo.toml,
#   desktop/app/src-tauri/tauri.conf.json, desktop/app/package.json,
#   desktop/packaging/omarchy/PKGBUILD (pkgver, pkgrel=1)
#
#   desktop/tools/stamp-version.sh           # stamp VERSION everywhere
#   desktop/tools/stamp-version.sh --check   # exit 1 if anything disagrees (CI)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
v="$(tr -d '[:space:]' < "$root/VERSION")"
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be x.y.z, got '$v'" >&2; exit 2; }
check=0; [[ "${1:-}" == --check ]] && check=1

plist="$root/Resources/Info.plist"
ws="$root/desktop/Cargo.toml"
appcargo="$root/desktop/app/src-tauri/Cargo.toml"
tauri="$root/desktop/app/src-tauri/tauri.conf.json"
pkgjson="$root/desktop/app/package.json"
pkgbuild="$root/desktop/packaging/omarchy/PKGBUILD"

# What each file says now.
current() {
  case "$1" in
    plist) /usr/bin/env python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$plist" ;;
    ws) sed -n '/^\[workspace.package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' "$ws" | head -1 ;;
    appcargo) sed -n '/^\[package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' "$appcargo" | head -1 ;;
    tauri|pkgjson) /usr/bin/env python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "${!1}" ;;
    pkgbuild) sed -n 's/^pkgver=//p' "$pkgbuild" ;;
  esac
}

bad=0
for f in plist ws appcargo tauri pkgjson pkgbuild; do
  [[ -f "${!f}" ]] || continue
  have="$(current "$f")"
  if [[ "$have" != "$v" ]]; then
    if (( check )); then echo "${!f#$root/}: $have (VERSION is $v)"; bad=1; continue; fi
    case "$f" in
      plist) /usr/bin/env python3 - "$plist" "$v" <<'PY'
import plistlib, sys
p, v = sys.argv[1], sys.argv[2]
d = plistlib.load(open(p, "rb"))
d["CFBundleShortVersionString"] = v
d["CFBundleVersion"] = str(int(d.get("CFBundleVersion", "0")) + 1)
plistlib.dump(d, open(p, "wb"))
PY
      ;;
      ws) sed -i.bak "/^\[workspace.package\]/,/^\[/s/^version *= *\".*\"/version = \"$v\"/" "$ws" && rm "$ws.bak" ;;
      appcargo) sed -i.bak "/^\[package\]/,/^\[/s/^version *= *\".*\"/version = \"$v\"/" "$appcargo" && rm "$appcargo.bak" ;;
      tauri|pkgjson) /usr/bin/env python3 - "${!f}" "$v" <<'PY'
import json, sys, re
p, v = sys.argv[1], sys.argv[2]
s = open(p).read()
# Keep the file's own formatting: replace the first top-level "version" only.
s = re.sub(r'("version"\s*:\s*")[^"]*(")', lambda m: m.group(1) + v + m.group(2), s, count=1)
open(p, "w").write(s)
PY
      ;;
      pkgbuild) sed -i.bak -e "s/^pkgver=.*/pkgver=$v/" -e "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild" && rm "$pkgbuild.bak" ;;
    esac
    echo "${!f#$root/}: $have -> $v"
  fi
done
exit $bad
