#!/usr/bin/env bash
# Build and test the desktop workspace in a Linux container, from macOS or anywhere.
#
#   desktop/tools/docker-arch.sh                          # cargo test -p monetshot-capture, on Arch
#   desktop/tools/docker-arch.sh cargo check --workspace
#   DISTRO=ubuntu desktop/tools/docker-arch.sh cargo test
#
# The repo is mounted at /src; build output and the cargo registry live in
# Docker volumes, so nothing Linux-built lands in the Mac's target/.
# The images are x86_64 (Arch has no arm64 image); Docker runs them emulated
# on Apple silicon, which is slower but builds what users run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
distro="${DISTRO:-arch}"
image="monetshot-$distro"
platform="linux/amd64"

if ! docker image inspect "$image" >/dev/null 2>&1 || [[ "${REBUILD:-}" == 1 ]]; then
  docker build --platform "$platform" -t "$image" -f "$here/$distro.Dockerfile" "$here"
fi

if [[ $# -eq 0 ]]; then set -- cargo test -p monetshot-capture; fi
tty=(); [[ -t 1 ]] && tty=(-t)
exec docker run --rm -i "${tty[@]}" --platform "$platform" \
  -v "$repo":/src \
  -v "monetshot-$distro-target":/target \
  -v "monetshot-$distro-cargo":/root/.cargo/registry \
  "$image" "$@"
