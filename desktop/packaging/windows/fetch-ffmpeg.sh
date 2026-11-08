#!/usr/bin/env bash
# Fetch the ffmpeg + ffprobe that ship inside the Windows installer (Tauri
# sidecars), into desktop/packaging/windows/bin/ as Tauri expects them:
#   ffmpeg-x86_64-pc-windows-msvc.exe, ffprobe-x86_64-pc-windows-msvc.exe
#
# Source: BtbN's GPL builds (libx264, NVENC, QSV, AMF, dshow, AAC). GPL is
# fine for a separate executable shipped alongside; the installer carries
# its licence (LICENSE.ffmpeg.txt) and where to get the source.
#
#   FFMPEG_ZIP_URL   the release asset. Default: the newest numbered release
#                    build (ffmpeg-nX.Y-latest-win64-gpl-X.Y.zip) in BtbN's
#                    "latest" release, looked up each time, because BtbN only
#                    keeps the last few versions and old names disappear.
#   FFMPEG_SHA256    its sha256. If unset, the release's checksums.sha256 is
#                    used and the hash printed, so it can be pinned here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
release="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"
if [[ -z "${FFMPEG_ZIP_URL:-}" ]]; then
  auth=(); [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  name="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${auth[@]}" https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest \
    | grep -oE '"name": *"ffmpeg-n[0-9]+\.[0-9]+-latest-win64-gpl-[0-9]+\.[0-9]+\.zip"' \
    | sed -E 's/.*"(ffmpeg-[^"]+)"/\1/' | sort -V | tail -1)"
  [[ -n "$name" ]] || { echo "no win64-gpl release build in BtbN's latest release" >&2; exit 1; }
  FFMPEG_ZIP_URL="$release/$name"
fi
url="$FFMPEG_ZIP_URL"
want="${FFMPEG_SHA256:-}"
out="$here/bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "fetching $url"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o "$work/ffmpeg.zip" "$url"
got="$(shasum -a 256 "$work/ffmpeg.zip" 2>/dev/null || sha256sum "$work/ffmpeg.zip")"; got="${got%% *}"
if [[ -z "$want" ]]; then
  sums="$(dirname "$url")/checksums.sha256"
  want="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "$sums" | awk -v f="$(basename "$url")" '$2==f || $2=="*"f {print $1}')"
  [[ -n "$want" ]] || { echo "no checksum for $(basename "$url") in $sums" >&2; exit 1; }
  echo "checksum from the release: $want (pin it with FFMPEG_SHA256)"
fi
[[ "$got" == "$want" ]] || { echo "sha256 mismatch: got $got, want $want" >&2; exit 1; }

unzip -q "$work/ffmpeg.zip" -d "$work/x"
mkdir -p "$out"
for t in ffmpeg ffprobe; do
  src="$(find "$work/x" -type f -name "$t.exe" | head -1)"
  [[ -n "$src" ]] || { echo "$t.exe not in the archive" >&2; exit 1; }
  cp "$src" "$out/$t-x86_64-pc-windows-msvc.exe"
done
lic="$(find "$work/x" -maxdepth 2 -type f -name 'LICENSE*' | head -1)"
[[ -n "$lic" ]] && cp "$lic" "$out/LICENSE.ffmpeg.txt"
printf 'ffmpeg from %s\nsha256 %s\nSource: https://github.com/BtbN/FFmpeg-Builds and https://ffmpeg.org/download.html\n' "$url" "$got" > "$out/SOURCE.ffmpeg.txt"
ls -la "$out"
