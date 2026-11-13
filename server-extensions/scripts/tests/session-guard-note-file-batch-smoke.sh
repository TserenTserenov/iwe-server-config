#!/usr/bin/env bash
# Regression for WP-539 (И-2/И-3, peer session 2026-11-13-09 with Kimi and
# Codex): `note-file --paths-from0 FILE --repo-root ROOT`.
#
# The Tsekh git sync claimed every fast-forward path with one session-guard
# process per path (~0.37 s each); a 385-path gap overran the unit's 150 s
# budget 37 times in a row. The batch mode must:
#   - write exactly the same file:/file_v2: pairs as the single-path claim;
#   - be all-or-nothing: one bad path leaves the semaphore byte-identical;
#   - be idempotent (a retry adds nothing) and keep the same refusals.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-batch.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

GOV="$TEST_ROOT/DS-strategy"
mkdir -p "$GOV/inbox/WP-999" "$GOV/inbox/agent/tasks" "$GOV/docs"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-999/WP-999.md"
git -C "$GOV" init -q
git -C "$GOV" config user.email test@test.local
git -C "$GOV" config user.name test
echo seed > "$GOV/README"
echo doc > "$GOV/docs/a.md"
git -C "$GOV" add README docs/a.md inbox/WP-999/WP-999.md
git -C "$GOV" commit -q -m seed

guard() {  # guard <subcommand> [args...]; runs from inside the governance checkout
  (cd "$GOV" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    bash "$GUARD" "$@")
}

guard open --housekeeping batch-test --agent fixture >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || { echo "FAIL: fixture session did not open"; exit 1; }

nul_list() {  # nul_list <out> <path>...
  local out="$1"; shift
  : > "$out"
  for p in "$@"; do printf '%s\0' "$p" >> "$out"; done
}
same_bytes() { cmp -s "$TEST_ROOT/sem.before" "$SEM" && echo same || echo differ; }
pairs() { grep -E '^file(_v2)?: ' "$SEM" | grep -v "orz\|sessions/" ; }

# --- byte compatibility with the single-path claim -------------------------
mkdir -p "$GOV/inbox/agent/tasks"
for i in 1 2 3; do echo card > "$GOV/inbox/agent/tasks/RUN-$i.md"; done
LIST="$TEST_ROOT/list"
nul_list "$LIST" inbox/agent/tasks/RUN-1.md docs/a.md docs inbox/agent/tasks/RUN-future.md
OUT=$(guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture 2>&1); RC=$?
check "batch of 4: succeeds" "0" "$RC"
check "batch: summary printed" "1" "$(printf '%s\n' "$OUT" | grep -c 'Noted in scope (batch): 4 new of 4 paths')"
check "batch: timing line printed" "1" "$(printf '%s\n' "$OUT" | grep -c 'note-file batch: 4 paths, 4 new, .*lock wait .*total .* ms')"
check "batch: future file warned once" "1" "$(printf '%s\n' "$OUT" | grep -c 'пока нет в репозитории')"
check "directory claimed with trailing slash" "1" "$(grep -cxF 'file: docs/' "$SEM")"
BATCH_PAIRS=$(pairs)

# Same paths through the single-path claim in a fresh session must give the same bytes.
cp "$SEM" "$TEST_ROOT/sem.batch"
guard close --housekeeping batch-test --agent fixture >/dev/null 2>&1
rm -f "$SEM" "$SEM.lease"
guard open --housekeeping batch-test --agent fixture >/dev/null 2>&1
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
for p in inbox/agent/tasks/RUN-1.md docs/a.md docs inbox/agent/tasks/RUN-future.md; do
  guard note-file "$GOV/$p" --agent fixture >/dev/null 2>&1
done
check "single-path claims are byte-identical to batch claims" "$BATCH_PAIRS" "$(pairs)"

# --- idempotent retry --------------------------------------------------------
cp "$SEM" "$TEST_ROOT/sem.before"
OUT=$(guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture 2>&1); RC=$?
check "retry: succeeds" "0" "$RC"
check "retry: nothing new" "1" "$(printf '%s\n' "$OUT" | grep -c 'Noted in scope (batch): 0 new of 4 paths')"
check "retry: semaphore unchanged" same "$(same_bytes)"

# --- all-or-nothing ----------------------------------------------------------
cp "$SEM" "$TEST_ROOT/sem.before"
nul_list "$LIST" inbox/agent/tasks/RUN-2.md ../outside.md inbox/agent/tasks/RUN-3.md "$GOV/README"
OUT=$(guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture 2>&1); RC=$?
check "bad paths: refused" "1" "$RC"
check "bad paths: counted" "1" "$(printf '%s\n' "$OUT" | grep -c 'refused 2 of 4 paths')"
check "bad paths: semaphore byte-identical" same "$(same_bytes)"
check "bad paths: valid neighbour not claimed" "0" "$(grep -cxF 'file: inbox/agent/tasks/RUN-2.md' "$SEM")"

printf 'inbox/agent/tasks/RUN-2.md\0truncated' > "$LIST"
guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture >/dev/null 2>&1; RC=$?
check "unterminated last element: refused" "1" "$RC"
check "unterminated last element: semaphore byte-identical" same "$(same_bytes)"

printf 'inbox/agent/tasks/RUN-2.md\0\0' > "$LIST"
guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture >/dev/null 2>&1; RC=$?
check "empty element: refused" "1" "$RC"

nul_list "$LIST" inbox/agent/tasks/RUN-2.md
guard note-file --paths-from0 "$LIST" --repo-root "$GOV/docs" --agent fixture >/dev/null 2>&1; RC=$?
check "--repo-root below the repository root: refused" "1" "$RC"

# --- tracked symlinks are claimed by their own path --------------------------
ln -s a.md "$GOV/docs/in-link"
ln -s /etc/hosts "$GOV/docs/ext-link"
nul_list "$LIST" docs/in-link docs/ext-link
guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture >/dev/null 2>&1; RC=$?
check "symlinks: batch succeeds" "0" "$RC"
check "symlink claimed by its own path" "1" "$(grep -cxF 'file: docs/in-link' "$SEM")"
check "outward symlink claimed by its own path" "1" "$(grep -cxF 'file: docs/ext-link' "$SEM")"

# --- a file inside a nested checkout is refused, not claimed on the outer repo
mkdir -p "$GOV/nested"
git -C "$GOV/nested" init -q
echo n > "$GOV/nested/f.md"
cp "$SEM" "$TEST_ROOT/sem.before"
nul_list "$LIST" nested/f.md
OUT=$(guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture 2>&1); RC=$?
check "nested-repo file: refused" "1" "$RC"
check "nested-repo file: reason named" "1" "$(printf '%s\n' "$OUT" | grep -c 'вложенному репозиторию')"
check "nested-repo file: semaphore byte-identical" same "$(same_bytes)"
cp "$SEM" "$TEST_ROOT/sem.before"

# --- argument contract -------------------------------------------------------
guard note-file --paths-from0 "$LIST" --agent fixture >/dev/null 2>&1; RC=$?
check "missing --repo-root: refused" "1" "$RC"
guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --forget --agent fixture >/dev/null 2>&1; RC=$?
check "batch --forget: refused" "1" "$RC"
guard note-file "$GOV/README" --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture >/dev/null 2>&1; RC=$?
check "positional path with --paths-from0: refused" "1" "$RC"
guard note-file "$GOV/README" --repo-root "$GOV" --agent fixture >/dev/null 2>&1; RC=$?
check "--repo-root without --paths-from0: refused" "1" "$RC"
: > "$LIST"
OUT=$(guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture 2>&1); RC=$?
check "empty list: success without a claim" "0" "$RC"
check "empty list: semaphore byte-identical" same "$(same_bytes)"

check "no temp file left next to the semaphore" "0" "$(find "$(dirname "$SEM")" -name '.note-batch-*' | wc -l | tr -d ' ')"

# --- scale: the size that overran the unit, well inside its budget -----------
for i in $(seq 1 400); do echo c > "$GOV/inbox/agent/tasks/RUN-big-$i.md"; done
: > "$LIST"
for i in $(seq 1 400); do printf 'inbox/agent/tasks/RUN-big-%s.md\0' "$i" >> "$LIST"; done
START=$(date +%s)
guard note-file --paths-from0 "$LIST" --repo-root "$GOV" --agent fixture >/dev/null 2>&1; RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "400 paths: succeeds" "0" "$RC"
check "400 paths: all claimed" "400" "$(grep -c '^file: inbox/agent/tasks/RUN-big-' "$SEM")"
check "400 paths: under 15 s" "yes" "$([ "$ELAPSED" -lt 15 ] && echo yes || echo "no (${ELAPSED}s)")"

if [ "$FAILURES" -eq 0 ]; then
  echo "session-guard-note-file-batch-smoke: all checks passed"
else
  echo "session-guard-note-file-batch-smoke: $FAILURES failure(s)"
  exit 1
fi
