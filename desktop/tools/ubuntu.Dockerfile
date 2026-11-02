# Ubuntu 24.04 with what the desktop workspace needs to build and test.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates git pkg-config clang libclang-dev \
      libpipewire-0.3-dev ffmpeg \
      libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev libxdo-dev \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && /root/.cargo/bin/rustup target add wasm32-unknown-unknown
ENV PATH=/root/.cargo/bin:$PATH CARGO_TARGET_DIR=/target
WORKDIR /src/desktop
