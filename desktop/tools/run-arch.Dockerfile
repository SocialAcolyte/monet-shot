# Running the desktop app on Arch under a virtual display (Xvfb + openbox +
# a tray host), to look at it on Linux: WebKitGTK, llvmpipe WebGL,
# GStreamer decode. x86_64 (Arch has no arm64 image): emulated on Apple silicon.
FROM archlinux:base-devel
# pacman's download sandbox can't set up seccomp under emulation.
RUN sed -i 's/^\[options\]/[options]\nDisableSandbox/' /etc/pacman.conf
RUN pacman -Syu --noconfirm --needed \
      rust clang cmake pkgconf git rsync nodejs npm \
      pipewire ffmpeg webkit2gtk-4.1 gtk3 libayatana-appindicator librsvg openssl xdotool \
      gst-plugins-base gst-plugins-good gst-libav \
      xorg-server-xvfb xorg-xdpyinfo xorg-xwininfo imagemagick mesa mesa-utils openbox stalonetray dbus \
      ttf-dejavu noto-fonts \
    && pacman -Scc --noconfirm
ENV CARGO_TARGET_DIR=/target CARGO_PROFILE_DEV_DEBUG=0
WORKDIR /work
