#!/usr/bin/env bash
# Inside the run container: copy the read-only checkout (/src) to /work
# without the Mac's node_modules/target, then build the app (debug; BUNDLE=deb
# also makes the .deb, no bundle otherwise).
set -euo pipefail
rsync -a --delete --exclude node_modules --exclude target --exclude .git --exclude 'ui/dist' --exclude '.DS_Store' \
  --exclude 'Sources' --exclude 'shared/fixtures/render' /src/ /work/
cd /work/desktop/app
[[ -d node_modules ]] || npm ci --no-audit --no-fund
npx tauri build --debug ${BUNDLE:+--bundles $BUNDLE} ${BUNDLE:---no-bundle} --config '{"build":{"beforeBuildCommand":"npm run build"}}' 2>&1 | grep -E "error|warning: unused|Finished|Built application" || true
ls -la /target/debug/monet-shot
