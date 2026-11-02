# Running the desktop app under a virtual display (Xvfb + a small WM), native
# arch (arm64 on Apple silicon), to look at it on Linux: WebKitGTK, llvmpipe
# WebGL, GStreamer decode. Not a build image for release.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates git pkg-config clang libclang-dev rsync \
      libpipewire-0.3-dev ffmpeg \
      libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev libxdo-dev \
      xvfb xdotool imagemagick x11-utils openbox dbus-x11 at-spi2-core \
      libgl1-mesa-dri libegl-mesa0 mesa-utils \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-gl gstreamer1.0-tools \
      fonts-dejavu-core fonts-noto-core \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/* \
    && curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH=/root/.cargo/bin:$PATH
WORKDIR /work
