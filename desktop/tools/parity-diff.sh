#!/usr/bin/env bash
# What changed on the Mac side since the desktop last caught up, so porting
# starts from a list (docs/PARITY.md §4).
#
#   desktop/tools/parity-diff.sh            # changed Swift files + commits since shared/LAST_SYNC
#   desktop/tools/parity-diff.sh --diff     # ... and the diff itself
#   desktop/tools/parity-diff.sh --mark     # after porting: write HEAD to shared/LAST_SYNC
#
# Uncommitted Swift changes are listed too (marked "working tree").
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
sync_file=shared/LAST_SYNC
paths=(Sources Package.swift Resources docs/spec.md)

if [[ "${1:-}" == --mark ]]; then
  git rev-parse HEAD > "$sync_file"
  echo "LAST_SYNC = $(cat "$sync_file")"
  exit 0
fi
[[ -f "$sync_file" ]] || { echo "no $sync_file yet (ms-core writes it with the fixtures)" >&2; exit 2; }
base="$(awk 'NF{print $1; exit}' "$sync_file")"  # first word; notes may follow
git cat-file -e "$base^{commit}" 2>/dev/null || { echo "$sync_file names an unknown commit: $base" >&2; exit 2; }

echo "Mac changes since $(git log -1 --format='%h %s (%cs)' "$base")"
echo
commits="$(git log --format='  %h %s' "$base"..HEAD -- "${paths[@]}")"
if [[ -n "$commits" ]]; then echo "Commits:"; echo "$commits"; echo; fi
echo "Files:"
{ git diff --stat=100 "$base"..HEAD -- "${paths[@]}" | sed '$d' | sed 's/^/  /'
  git status --porcelain -- "${paths[@]}" | sed 's/^/  working tree: /'
} | sort -u
if [[ "${1:-}" == --diff ]]; then
  echo
  git --no-pager diff "$base" -- "${paths[@]}"
fi
echo
echo "Then: regenerate fixtures (shared/tools/fixtures), port until cargo test is green, update the PARITY.md ledger, and run $0 --mark."
