#!/usr/bin/env bash
# Installs the wasm-bindgen CLI at exactly the version desktop/Cargo.lock uses
# (they must match, or the generated JS refuses the .wasm). core-wasm's
# build.sh needs it; so do `tauri build` / `tauri dev` (beforeBuildCommand).
#   desktop/tools/install-wasm-bindgen.sh [--root DIR]
set -euo pipefail
lock="$(cd "$(dirname "$0")/.." && pwd)/Cargo.lock"
v=$(awk '/^name = "wasm-bindgen"$/{getline; gsub(/version = |"/, ""); print; exit}' "$lock")
[[ -n $v ]] || { echo "no wasm-bindgen in $lock" >&2; exit 1; }
if command -v wasm-bindgen >/dev/null && [[ "$(wasm-bindgen --version)" == "wasm-bindgen $v" ]]; then
  echo "wasm-bindgen $v already installed"; exit 0
fi
cargo install wasm-bindgen-cli --version "$v" --locked "$@"
