# Arch (Omarchy's base) with what the desktop workspace needs to build and test.
FROM archlinux:base-devel
# pacman's download sandbox can't set up seccomp under emulation (amd64 on arm64).
RUN sed -i 's/^\[options\]/[options]\nDisableSandbox/' /etc/pacman.conf
RUN pacman -Syu --noconfirm --needed \
      rustup clang cmake pkgconf git \
      pipewire ffmpeg \
      webkit2gtk-4.1 gtk3 libayatana-appindicator librsvg openssl xdotool \
    && pacman -Scc --noconfirm \
    && rustup default stable \
    && rustup target add wasm32-unknown-unknown
ENV CARGO_TARGET_DIR=/target
WORKDIR /src/desktop
