#!/bin/sh
# Regenerates shared/fixtures/ from the Swift MonetShotKit, as it is in the
# working tree: compiles Sources/MonetShotKit/**/*.swift together with
# shared/tools/fixtures/main.swift (no Package.swift change) and runs it.
# Then: cd desktop && cargo test -p monetshot-core
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
build=${TMPDIR:-/tmp}/monetshot-fixtures-build
mkdir -p "$build"
find "$root/Sources/MonetShotKit" -name '*.swift' > "$build/sources.txt"
# The music grid lives in Mac work not yet committed; fixtures that need it
# are listed in shared/PENDING.
flags=""
[ -f "$root/Sources/MonetShotKit/Music/MusicGrid.swift" ] && flags="-D MONETSHOT_MUSIC_GRID"
swiftc -O -swift-version 6 -module-name MonetShotFixtures $flags \
  "$root/shared/tools/fixtures/main.swift" $(cat "$build/sources.txt" | tr '\n' ' ') \
  -o "$build/fixtures"
"$build/fixtures" "$root"
