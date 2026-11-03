#!/bin/sh
# Builds the editor's wasm: desktop/crates/core-wasm/pkg/ (ES module for the
# webview, `--target web`) with a package.json, so the UI can depend on it as
# "monetshot-core-wasm": "file:../crates/core-wasm/pkg".
# Needs: rustup target add wasm32-unknown-unknown
#        cargo install wasm-bindgen-cli --version <the wasm-bindgen in Cargo.lock> --locked
# Usage: build.sh [out-dir] [web|nodejs]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/pkg}
target=${2:-web}
cd "$here/../.."
cargo build -p monetshot-core-wasm --target wasm32-unknown-unknown --release
# CARGO_TARGET_DIR moves cargo's output (the PKGBUILD sets it).
wasm-bindgen --target "$target" --out-dir "$out" --out-name monetshot_core_wasm \
  "${CARGO_TARGET_DIR:-target}/wasm32-unknown-unknown/release/monetshot_core_wasm.wasm"
cat > "$out/package.json" <<JSON
{
  "name": "monetshot-core-wasm",
  "version": "0.1.1",
  "type": "module",
  "main": "monetshot_core_wasm.js",
  "types": "monetshot_core_wasm.d.ts",
  "files": ["monetshot_core_wasm.js", "monetshot_core_wasm.d.ts", "monetshot_core_wasm_bg.wasm", "monetshot_core_wasm_bg.wasm.d.ts"]
}
JSON
echo "built $out" >&2
