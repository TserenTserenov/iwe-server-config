#!/usr/bin/env bash
# WP-561 F61 (17.11, live case): `open` refused nothing about where the
# governance copy lives, while the close runner refuses a hand-made copy in a
# scratchpad or temporary directory -- a session opened from such a copy could
# only fail at close. `open` now refuses the same copy up front.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-volatile.XXXXXX")
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/agent-tmp.XXXXXX")
trap 'git -C "$REPO" worktree prune 2>/dev/null; rm -rf "$TEST_ROOT" "$OUTSIDE"' EXIT

REPO="$TEST_ROOT/DS-strategy"
ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$REPO/scripts"
git init --bare -q "$ORIGIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "$ORIGIN"
printf '#!/usr/bin/env python3\nprint("{}")\n' > "$REPO/scripts/process-runner.py"
git -C "$REPO" add scripts/process-runner.py
git -C "$REPO" commit -qm init
git -C "$REPO" push -q origin HEAD:main

MC="$TEST_ROOT/MC-sessions"
mkdir -p "$MC"
git -C "$MC" init -q

export IWE_ROOT="$TEST_ROOT"
export IWE_GOVERNANCE_REPO="DS-strategy"
export IWE_AGENT="fixture"
export IWE_FROZEN_CANONICAL_PATH=""
export IWE_SESSIONS_ROOT="$MC"

fail() { echo "FAIL: $*" >&2; exit 1; }
sem_for() { grep -l "^slug: $1\$" "$TEST_ROOT"/.iwe-runtime/sessions/fixture-*.open 2>/dev/null || true; }

# A: a hand-made copy in an agent scratchpad outside IWE_ROOT is refused, no mark left.
SCRATCH="$OUTSIDE/session/scratchpad/gov-wt"
mkdir -p "$(dirname "$SCRATCH")"
git -C "$REPO" worktree add -q --detach "$SCRATCH" HEAD
ERR_A="$TEST_ROOT/a.err"
if (cd "$SCRATCH" && bash "$GUARD" open --wp WP-484 --task fixture --slug scratch-a --agent fixture) >/dev/null 2>"$ERR_A"; then
  fail "open accepted a governance copy in a scratchpad"
fi
grep -q 'scratchpad' "$ERR_A" || { cat "$ERR_A" >&2; fail "refusal does not name the scratchpad"; }
grep -q -- '--isolate' "$ERR_A" || fail "refusal does not point to --isolate"
[ -z "$(sem_for scratch-a)" ] || fail "refused open left a semaphore"
echo "PASS: open refuses a governance copy in an agent scratchpad"

# B: a hand-made copy in a temporary directory (no scratchpad in the path) is refused too.
TMPCOPY="$OUTSIDE/plain-wt"
git -C "$REPO" worktree add -q --detach "$TMPCOPY" HEAD
if (cd "$TMPCOPY" && bash "$GUARD" open --wp WP-484 --task fixture --slug tmp-b --agent fixture) >/dev/null 2>"$TEST_ROOT/b.err"; then
  fail "open accepted a governance copy in a temporary directory"
fi
grep -q 'временном каталоге' "$TEST_ROOT/b.err" || { cat "$TEST_ROOT/b.err" >&2; fail "refusal does not name the temporary directory"; }
[ -z "$(sem_for tmp-b)" ] || fail "refused open left a semaphore"
echo "PASS: open refuses a governance copy in a temporary directory"

# C: the canonical checkout inside IWE_ROOT still opens as before.
(cd "$REPO" && bash "$GUARD" open --wp WP-484 --task fixture --slug canon-c --agent fixture) >/dev/null 2>&1 \
  || fail "ordinary open from the canonical checkout was refused"
[ -n "$(sem_for canon-c)" ] || fail "ordinary open left no semaphore"
echo "PASS: ordinary open inside IWE_ROOT is unchanged"

echo "PASS: session-guard open refuses volatile governance copies (WP-561 Ф61)"
