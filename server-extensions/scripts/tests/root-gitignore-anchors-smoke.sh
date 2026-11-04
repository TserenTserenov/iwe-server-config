#!/usr/bin/env bash
# Regression for WP-539 Ф21 Б4 (03.11): the root .gitignore anchored nested repos
# as "/X/". A trailing slash matches only a directory, so when DS-ai-systems was
# moved and a symlink left in its place, git saw the symlink as an untracked file:
# the root counted as dirty and canon-refresh.sh refused to fast-forward it, which
# silently kept the merged session-guard fix off the host.
#
# Checks, on a copy of the real root .gitignore:
#   1. no single-segment top-level anchor keeps a trailing slash;
#   2. every such anchor ignores both a directory and a symlink of that name.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GITIGNORE="$ROOT_DIR/.gitignore"
[ -f "$GITIGNORE" ] || { echo "FAIL: $GITIGNORE not found"; exit 1; }
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/root-gitignore-anchors.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAIL=0
SLASHED=$(grep -nE '^/[^/*?]+/$' "$GITIGNORE" || true)
if [ -n "$SLASHED" ]; then
    echo "FAIL: top-level anchors with a trailing slash (miss symlinks):"
    echo "$SLASHED"
    FAIL=1
fi

git init -q "$TEST_ROOT/repo"
cp "$GITIGNORE" "$TEST_ROOT/repo/.gitignore"
mkdir -p "$TEST_ROOT/target"
CHECKED=0
while IFS= read -r anchor; do
    name=${anchor#/}
    mkdir -p "$TEST_ROOT/repo/$name"
    : > "$TEST_ROOT/repo/$name/file"
    git -C "$TEST_ROOT/repo" check-ignore -q "$name/file" \
        || { echo "FAIL: directory $name is not ignored"; FAIL=1; }
    rm -rf "${TEST_ROOT:?}/repo/$name"
    ln -s "$TEST_ROOT/target" "$TEST_ROOT/repo/$name"
    git -C "$TEST_ROOT/repo" check-ignore -q "$name" \
        || { echo "FAIL: symlink $name is not ignored"; FAIL=1; }
    rm -f "$TEST_ROOT/repo/$name"
    CHECKED=$((CHECKED + 1))
done < <(grep -E '^/[^/*?]+$' "$GITIGNORE")

[ "$CHECKED" -gt 0 ] || { echo "FAIL: no top-level anchors found to check"; FAIL=1; }
[ "$FAIL" -eq 0 ] && echo "PASS: root-gitignore-anchors-smoke.sh ($CHECKED anchors, directory and symlink)"
exit "$FAIL"
