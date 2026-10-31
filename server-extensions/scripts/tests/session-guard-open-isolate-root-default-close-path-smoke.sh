#!/usr/bin/env bash
# РП-518, bug-2026-10-30-three-guards-deadlock-commit-from-isolated-root.md: a copy of the
# workspace ROOT repo opened with `open --isolate` and no --close-path got close_path
# "unknown", which the runner's root route (accepts only quick-close) and the declared
# no-runner paths cannot close. The root copy now defaults to quick-close; an explicit
# path stays as given, and a governance-repo copy keeps its old behaviour.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d ${TMPDIR:-/tmp}/session-guard-root-default.XXXXXX)
trap 'rm -rf "$TEST_ROOT" "$TEST_ROOT.origin.git"' EXIT

make_repo() {  # <dir> -- a repo with an origin, one commit pushed to main
  local dir="$1" origin="$1.origin.git"
  mkdir -p "$dir/inbox/WP-518"
  git init --bare -q "$origin"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "Test"
  git -C "$dir" remote add origin "$origin"
  echo fixture > "$dir/inbox/WP-518/WP-518.md"
  git -C "$dir" add inbox/WP-518/WP-518.md
  git -C "$dir" commit -qm init
  git -C "$dir" push -q origin HEAD:main
}

make_repo "$TEST_ROOT"                 # the workspace ROOT repo itself
make_repo "$TEST_ROOT/DS-strategy"     # the governance repo, a separate checkout
printf 'DS-strategy/\nMC-sessions/\n.iwe-runtime/\n*.origin.git/\n' > "$TEST_ROOT/.gitignore"
git -C "$TEST_ROOT" add .gitignore
git -C "$TEST_ROOT" commit -qm "ignore nested repos"
git -C "$TEST_ROOT" push -q origin HEAD:main

git init -q "$TEST_ROOT/MC-sessions"  # the guard reports into the sandbox, not the inherited live root
export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""
# `open --isolate` derives its id from the conversation identity (WP-484 F204). The
# sync gate strips the ambient CLAUDE_CODE_SESSION_ID, so supply our own instead of
# inheriting one; the three opens differ by slug, so one conversation id is enough.
export CLAUDE_CODE_SESSION_ID="fixture-root-default-conversation"

semaphore_close_path() {  # <slug> -> close_path recorded in that slug's semaphore
  local sem
  sem=$(grep -l "^slug: $1\$" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open)
  grep '^close_path: ' "$sem" | cut -d' ' -f2-
}

expect_path() {  # <label> <slug> <expected>
  local got
  got=$(semaphore_close_path "$2")
  if [ "$got" != "$3" ]; then
    echo "FAIL: $1 -- close_path is '$got', expected '$3'" >&2
    exit 1
  fi
  echo "OK: $1 -> close_path $got"
}

# A: root copy, no --close-path -> quick-close, and the open says so.
OUT_A=$(cd "$TEST_ROOT" && bash "$GUARD" open --isolate --force --force-wp-elsewhere --wp WP-518 \
  --task fixture --slug root-default --agent fixture 2>&1)
printf '%s' "$OUT_A" | grep -q "выставлен close_path quick-close" \
  || { echo "FAIL: A -- the open did not announce the default" >&2; exit 1; }
expect_path "root copy without --close-path" root-default quick-close

# B: root copy with an explicit path keeps it.
(cd "$TEST_ROOT" && bash "$GUARD" open --isolate --force --force-wp-elsewhere --wp WP-518 \
  --task fixture --slug root-explicit --agent fixture --close-path publish-only >/dev/null 2>&1)
expect_path "root copy with --close-path publish-only" root-explicit publish-only

# C: governance-repo copy without --close-path stays unknown (behaviour unchanged).
(cd "$TEST_ROOT/DS-strategy" && bash "$GUARD" open --isolate --wp WP-518 \
  --task fixture --slug gov-default --agent fixture >/dev/null 2>&1)
expect_path "governance copy without --close-path" gov-default unknown
