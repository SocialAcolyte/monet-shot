#!/usr/bin/env bash
# Inside the hypr container: copy the read-only checkout (/src) to /work
# without the Mac's node_modules/target, build the wasm core and the dev app
# (it loads the UI from Vite, so the editor's check script can run), and
# start Vite on :5183.
set -euo pipefail
export PATH=$HOME/.cargo/bin:$PATH
rsync -a --exclude node_modules --exclude target --exclude .git --exclude 'ui/dist' --exclude '.DS_Store' \
  --exclude 'Sources' --exclude 'shared/fixtures/render' /src/ /work/
cd /work/desktop/app
[[ -d node_modules ]] || npm ci --no-audit --no-fund
npm ls monetshot-core-wasm >/dev/null 2>&1 || npm install --no-audit --no-fund ../crates/core-wasm/pkg >/dev/null
# The wasm core: the checkout's build when it has one (it's the same on every
# platform), else build it (CI: rust-wasm + the pinned wasm-bindgen).
if [[ ! -f /work/desktop/crates/core-wasm/pkg/package.json ]]; then
  command -v wasm-bindgen >/dev/null || bash /work/desktop/tools/install-wasm-bindgen.sh
  npm run wasm 2>&1 | tail -3
fi
(cd /work/desktop && cargo build -p monet-shot 2>&1 | grep -E "^(error|warning: unused)|Finished" -A5)
ls -la /target/debug/monet-shot
if ! curl -fs -o /dev/null http://localhost:5183/; then
  (npx vite --port 5183 --strictPort >/tmp/vite.log 2>&1 &)
  for _ in $(seq 120); do curl -fs -o /dev/null http://localhost:5183/ && break; sleep 0.5; done
fi
curl -fs -o /dev/null http://localhost:5183/ && echo "vite up on :5183"
