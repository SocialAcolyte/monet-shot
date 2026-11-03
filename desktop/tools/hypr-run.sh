#!/usr/bin/env bash
# The Omarchy run, end to end, from macOS (Docker Desktop) or a Linux host:
# a vkms display device, the hypr image, the app build, Hyprland with
# Omarchy 4's config, every proof in hypr-check.sh, then Omarchy 3's
# (Waybar) bar and pill. Results + screenshots: docs/porting/screens/omarchy/.
#
#   desktop/tools/hypr-run.sh            # all of it
#   KEEP=1 desktop/tools/hypr-run.sh     # leave the container (ms-hypr) running
#   TARGET=dir OUT=dir                   # cargo target (default: a volume), results
#
# Needs a Linux host (hypr-kmod.sh: vkms); the CI job hyprland-run is this.
# The container is privileged: it needs the DRM card, uinput, and udev.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${OUT:-$repo/docs/porting/screens/omarchy}"
platform=linux/amd64
name=ms-hypr

"$here/hypr-kmod.sh"

docker image inspect monetshot-run-arch >/dev/null 2>&1 ||
  docker build --platform $platform -t monetshot-run-arch -f "$here/run-arch.Dockerfile" "$here"
if ! docker image inspect monetshot-hypr >/dev/null 2>&1 || [[ ${REBUILD:-} == 1 ]]; then
  docker build --platform $platform -t monetshot-hypr -f "$here/hypr-arch.Dockerfile" "$here"
fi

docker rm -f $name >/dev/null 2>&1 || true
mkdir -p "$out"
docker run -d --name $name --platform $platform --privileged --net=host \
  -v "$repo":/src:ro -v "${TARGET:-monetshot-run-target}":/target -v monetshot-run-work:/work -v "$out":/shots \
  monetshot-hypr sleep infinity >/dev/null
done_() {
  # Hyprland's own log (stdout stops after the config loads) and crash reports.
  docker exec $name sh -c 'cp /run/user/1000/hypr/*/hyprland.log /tmp/hypr/hyprland-own.log; cp /home/run/.cache/hyprland/*.txt /tmp/hypr/' >/dev/null 2>&1 || true
  mkdir -p "$out/logs"; docker cp $name:/tmp/hypr/. "$out/logs/" >/dev/null 2>&1 || true
  [[ ${KEEP:-} == 1 ]] || docker rm -f $name >/dev/null
}
trap done_ EXIT
x() { docker exec $name "$@"; }

x bash /src/desktop/tools/hypr-build.sh
: > "$out/results.txt"
# Bounded, so a hang still leaves the logs (the EXIT trap copies them).
timeout 40m docker exec $name bash /src/desktop/tools/hypr-check.sh all
