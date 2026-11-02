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
swiftc -O -swift-version 6 -module-name MonetShotFixtures \
  "$root/shared/tools/fixtures/main.swift" $(cat "$build/sources.txt" | tr '\n' ' ') \
  -o "$build/fixtures"
"$build/fixtures" "$root"
