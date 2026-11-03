#!/usr/bin/env bash
# Give a Linux host without a GPU a virtual display device, so Hyprland can
# run on its own DRM backend (as on a real machine) with Mesa's llvmpipe.
#
# vkms (virtual KMS: one connector, any mode) is what Hyprland needs, and
# uinput gives the session a mouse and keyboard. Ubuntu ships vkms in
# linux-modules-extra (GitHub's ubuntu-latest runners included), Arch in the
# kernel package.
#
#   desktop/tools/hypr-kmod.sh     # load vkms + uinput (sudo)
#
# Docker Desktop (macOS) can't do this: its LinuxKit kernel has no vkms, and
# a vkms.ko built from vanilla sources of the same version, with its own
# config and compiler, is refused ("disagrees about version of symbol
# module_layout": LinuxKit's tree is patched, and Docker publishes no
# headers/Module.symvers for it). Run on a Linux host or the hyprland-run CI job.
set -euo pipefail

if [[ $(uname -s) != Linux ]] || ! command -v modprobe >/dev/null; then
  if docker run --rm --privileged alpine:3.20 sh -c 'ls /dev/dri/card*' >/dev/null 2>&1; then
    echo "the Docker VM has a DRM device"; exit 0
  fi
  echo "no DRM device for Hyprland here: this needs a Linux host (vkms), see the comment in $0" >&2
  exit 1
fi

sudo=; [[ $(id -u) == 0 ]] || sudo=sudo
$sudo modprobe uinput 2>/dev/null || true
if ! ls /dev/dri/card* >/dev/null 2>&1; then
  if ! $sudo modprobe vkms 2>/dev/null && command -v apt-get >/dev/null; then
    echo "vkms isn't installed: linux-modules-extra-$(uname -r)"
    $sudo apt-get update -qq
    $sudo DEBIAN_FRONTEND=noninteractive apt-get install -yqq "linux-modules-extra-$(uname -r)" >/dev/null
    $sudo modprobe vkms
  fi
fi
ls /dev/dri/card* >/dev/null 2>&1 || { echo "still no /dev/dri/card* after modprobe vkms" >&2; exit 1; }
echo "kernel $(uname -r): $(ls /dev/dri | tr '\n' ' ')$( [[ -c /dev/uinput ]] && echo '+ /dev/uinput')"
