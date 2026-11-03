# The Omarchy stack in a container: Hyprland on its own DRM backend (a vkms
# virtual display, see hypr-kmod.sh) rendering with llvmpipe, seatd for the
# seat, udev for input, PipeWire + WirePlumber, xdg-desktop-portal +
# xdg-desktop-portal-hyprland, omarchy-shell (Quickshell) and Waybar, and
# Omarchy's own config trees (4.x Lua, 3.x hyprlang) checked out at a tag.
#
# Built on the Linux run image (run-arch.Dockerfile: app build deps, WebKitGTK,
# GStreamer, ffmpeg), which hypr-run.sh builds first when it's missing.
ARG BASE=monetshot-run-arch
FROM ${BASE}
RUN pacman -Syu --noconfirm --needed \
      rust-wasm hyprland xorg-xwayland xdg-desktop-portal xdg-desktop-portal-hyprland \
      pipewire wireplumber seatd ydotool grim jq socat python foot \
      quickshell qt6-wayland qt6-svg waybar ttf-jetbrains-mono-nerd \
    && pacman -Scc --noconfirm
# Omarchy at the tags users run: 4.x (Lua Hyprland, omarchy-shell) and the
# last 3.x (hyprlang, Waybar).
ARG OMARCHY4=v4.0.6
ARG OMARCHY3=v3.8.4
RUN git clone -q --depth 1 -b ${OMARCHY4} https://github.com/basecamp/omarchy.git /opt/omarchy4 \
 && git clone -q --depth 1 -b ${OMARCHY3} https://github.com/basecamp/omarchy.git /opt/omarchy3
# The session user (Hyprland won't run as root). seat: seatd; input: evdev
# for the app's clicks and double-tap Shift, as install.sh tells users.
RUN useradd -m -u 1000 -G video,input,seat run \
 && install -d -m 700 -o run -g run /run/user/1000
# No systemd in here: what Omarchy hands to it runs directly.
COPY hypr-shims/ /usr/local/bin/
ENV CARGO_TARGET_DIR=/target CARGO_PROFILE_DEV_DEBUG=0
WORKDIR /work
