#!/usr/bin/env bash
# Fetch the ffmpeg + ffprobe that ship inside the Windows installer (Tauri
# sidecars), into desktop/packaging/windows/bin/ as Tauri expects them:
#   ffmpeg-x86_64-pc-windows-msvc.exe, ffprobe-x86_64-pc-windows-msvc.exe
#
# Source: BtbN's GPL builds (libx264, NVENC, QSV, AMF, dshow, AAC). GPL is
# fine for a separate executable shipped alongside; the installer carries
# its licence (LICENSE.ffmpeg.txt) and where to get the source.
#
#   FFMPEG_ZIP_URL   the release asset (default below)
#   FFMPEG_SHA256    its sha256. If unset, the release's checksums.sha256 is
#                    used and the hash printed, so it can be pinned here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
url="${FFMPEG_ZIP_URL:-https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-win64-gpl-7.1.zip}"
want="${FFMPEG_SHA256:-}"
out="$here/bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "fetching $url"
curl -fsSL -o "$work/ffmpeg.zip" "$url"
got="$(shasum -a 256 "$work/ffmpeg.zip" 2>/dev/null || sha256sum "$work/ffmpeg.zip")"; got="${got%% *}"
if [[ -z "$want" ]]; then
  sums="$(dirname "$url")/checksums.sha256"
  want="$(curl -fsSL "$sums" | awk -v f="$(basename "$url")" '$2==f || $2=="*"f {print $1}')"
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
