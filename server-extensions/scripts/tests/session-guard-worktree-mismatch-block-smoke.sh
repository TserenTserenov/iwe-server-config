#!/usr/bin/env bash
# session-guard-worktree-mismatch-block-smoke.sh — regression for the WP-539
# check 6a hard block (peer-session 2026-10-10-03-tsekh1-sync-lag-fix). The
# check stayed warn-only past its one-week observation window (ArchGate
# WP-539, 2026-08-18) and the exact gap it watches for recurred twice: 8
# unpublished commits in the frozen canonical checkout 2026-10-09/10, then an
# unrelated overnight incident 2026-10-10/11. Flipped to a hard block
# 2026-10-11 (pilot decision "реши сам системно").
#
# Exercises worktree_mismatch_check() directly (same extraction method as
# session-guard-canonical-fallback-warn-smoke.sh) rather than the whole
# pre-commit-check dispatcher: the dispatcher's other gates (scope,
# merge-aware carve-out, lease) are orthogonal to this one and would make a
# black-box run of the full CLI fail or pass for reasons unrelated to what
# this test checks.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
extract_function() { # <function-name>
  local start end
  start=$(grep -n "^$1()" "$GUARD" | head -1 | cut -d: -f1)
  end=$(awk -v start="$start" 'NR>=start && /^}/{print NR; exit}' "$GUARD")
  [ -n "$start" ] && [ -n "$end" ] || return 1
  sed -n "${start},${end}p" "$GUARD"
}
FUNCS_SRC="$(extract_function semaphore_governance_worktree)
$(extract_function worktree_mismatch_check)"

TEST_ROOT=$(mktemp -d /private/tmp/session-guard-worktree-mismatch.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# Registered worktree: a real git checkout, as semaphore_governance_worktree()
# resolves the field through `git -C <path> rev-parse --show-toplevel`.
WORKTREE="$TEST_ROOT/.iwe-runtime/isolated-worktrees/session-abc"
mkdir -p "$WORKTREE"
git init -q "$WORKTREE"

# A second, unrelated checkout: the canonical mistake this check exists to
# catch is a git command running here instead of in $WORKTREE.
CANON="$TEST_ROOT/canon"
mkdir -p "$CANON"
git init -q "$CANON"

run_check() { # <cwd> <semaphore-files-dir> -> sets RC, OUT, ERR
  local cwd="$1" sem_dir="$2" sems out_file err_file
  sems=$(find "$sem_dir" -name '*.open' 2>/dev/null)
  out_file=$(mktemp) err_file=$(mktemp)
  RC=0
  bash -c "
    $FUNCS_SRC
    cd '$cwd' && worktree_mismatch_check \"\$1\"
  " bash "$sems" >"$out_file" 2>"$err_file" || RC=$?
  OUT=$(cat "$out_file"); ERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

SEM_DIR="$TEST_ROOT/sems"
mkdir -p "$SEM_DIR"
cat > "$SEM_DIR/claude-1.open" <<EOF
governance_worktree: $WORKTREE
EOF

# Scenario 1: git runs in the registered worktree itself -- must pass (rc 0).
run_check "$WORKTREE" "$SEM_DIR"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: commit in the registered worktree must pass, rc=$RC stderr=[$ERR]" >&2
  exit 1
fi
echo "OK: commit inside the registered worktree is never blocked"

# Scenario 2: git runs in a DIFFERENT checkout -- the live incident shape.
# Must now fail (rc 1), with CURRENT_TOPLEVEL/REGISTERED_WORKTREES set for
# the caller's message.
run_check "$CANON" "$SEM_DIR"
if [ "$RC" -ne 1 ]; then
  echo "FAIL: commit outside the registered worktree must be reported as a mismatch, rc=$RC" >&2
  exit 1
fi
echo "OK: commit outside the registered worktree is reported as a mismatch (caller turns this into exit 6)"

# Scenario 3: no semaphore names a worktree at all (empty sems dir) -- a
# session with nothing registered is unaffected, as before this check
# existed.
EMPTY_SEM_DIR="$TEST_ROOT/sems-empty"
mkdir -p "$EMPTY_SEM_DIR"
run_check "$CANON" "$EMPTY_SEM_DIR"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: no registered worktree at all must never be blocked, rc=$RC stderr=[$ERR]" >&2
  exit 1
fi
echo "OK: a session with no registered worktree is unaffected"

echo "PASS: worktree_mismatch_check() blocks the exact mismatch the WP-539 incidents exercised, and only that"
