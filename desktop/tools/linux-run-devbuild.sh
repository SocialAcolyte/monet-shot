#!/usr/bin/env bash
# Inside the run container: sync the checkout and rebuild the dev binary
# (loads the Vite server). Extra args are sed scripts applied to the copy's
# src-tauri/src/lib.rs, for trying a change before its owner lands it.
set -euo pipefail
rsync -a --exclude node_modules --exclude target --exclude .git --exclude 'ui/dist' --exclude '.DS_Store' \
  --exclude 'Sources' --exclude 'shared/fixtures/render' /src/ /work/
for s in "$@"; do sed -i "$s" /work/desktop/app/src-tauri/src/lib.rs; done
cd /work/desktop && cargo build -p monet-shot 2>&1 | grep -E "^error|Finished" -A5
