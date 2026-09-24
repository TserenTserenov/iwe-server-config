#!/usr/bin/env bash
# session-guard-abandon-prepared-smoke.sh -- WP-484, peer-session with Codex
# (2026-09-24-03-wp484-prepared-snapshot-fix).
#
# _prepared_source_set_has_publish_proof() can never pass once a later,
# legitimate REPLACE lands on a path the PREPARED snapshot touched -- it only
# distinguishes byte-identical delivery from divergence, not "lost" from
# "delivered, then legitimately superseded". `close --abandon-prepared`
# (_record_close_abandoned + _abandon_prepared_matches_source, plus the
# manual-abandon-attestation/v1 branch in _close_delivery_state) is the
# manual recovery path for that stuck case.
#
# This test extracts the real function bodies from session-guard.sh (not
# copies) and drives them directly against hand-built semaphore fixtures --
# no isolate-push/close/RUN-card machinery needed to reach them.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-abandon-prepared.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE="$TEST_ROOT/fixture.sh"
: > "$FIXTURE"
# A plain `sed -n '/^fn() {/,/^}$/p'` breaks on these functions: several embed
# a top-level python dict literal whose closing `}` sits at column 0 (this
# file's own convention for that construct), which reads exactly like the
# function's own end marker to a sed range. This awk state machine instead
# ignores bare `}` lines while inside the `<<'PY' ... PY` heredoc, and only
# treats the first bare `}` seen AFTER the heredoc closes as the real end of
# the bash function.
extract_fn() {  # <function-name>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { active = 1 }
    active {
      print
      if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
      if (inpy && $0 == "PY") { inpy = 0; next }
      if (!inpy && $0 == "}") { active = 0; exit }
    }
  ' "$GUARD"
}
for fn in _unique_record_field _terminal_proof_snapshot_sha _owned_semaphore_snapshot_sha \
          _append_close_fields_atomic _record_close_prepared _record_close_published \
          _record_close_abandoned _abandon_prepared_matches_source _close_delivery_state; do
  extract_fn "$fn" >> "$FIXTURE"
  printf '\n' >> "$FIXTURE"
done
for fn in _unique_record_field _terminal_proof_snapshot_sha _owned_semaphore_snapshot_sha \
          _append_close_fields_atomic _record_close_prepared _record_close_published \
          _record_close_abandoned _abandon_prepared_matches_source _close_delivery_state; do
  grep -q "^${fn}() {" "$FIXTURE" \
    || { echo "FAIL: fixture setup -- ${fn}() not found, extraction anchor no longer matches session-guard.sh" >&2; exit 1; }
done
python3 -c "
import re
text = open('$FIXTURE').read()
for m in re.findall(r\"<<'PY'\n(.*?)\nPY\", text, re.S):
    compile(m, '<fixture>', 'exec')
" || { echo "FAIL: fixture setup -- an extracted PY heredoc is not valid Python" >&2; exit 1; }
# shellcheck source=/dev/null
source "$FIXTURE"

REPO="$TEST_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test

commit_file() {  # <content> -> HEAD sha, appends one commit on current branch
  printf '%s' "$1" > "$REPO/f.txt"
  git -C "$REPO" add f.txt
  git -C "$REPO" commit -qm content >/dev/null
  git -C "$REPO" rev-parse HEAD
}

TERMINAL_FILE="$TEST_ROOT/terminal.txt"
printf 'terminal-anchor\n' > "$TERMINAL_FILE"
TERMINAL_SHA=$(_terminal_proof_snapshot_sha file "$TERMINAL_FILE")

build_prepared_semaphore() {  # -> prints semaphore path; leaves $REPO on source_head
  git -C "$REPO" checkout -q --orphan "base-$RANDOM" 2>/dev/null || true
  git -C "$REPO" rm -rqf . >/dev/null 2>&1 || true
  local base head sem
  base=$(commit_file "base content")
  head=$(commit_file "session content")
  sem="$TEST_ROOT/sem-$RANDOM.open"
  printf 'agent: claude-code\nwp: WP-484\nslug: abandon-prepared-smoke\n' > "$sem"
  local commits_json claims_json fields
  commits_json=$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$head")
  claims_json='[]'
  local placeholder_status_sha
  placeholder_status_sha=$(git -C "$REPO" hash-object -t blob /dev/null)
  fields=$(_record_close_prepared "$sem" "SESSION-1" "$REPO" "$REPO/.git" \
    "$base" "$head" "$placeholder_status_sha" \
    "$commits_json" "$claims_json" file "$TERMINAL_FILE" "$TERMINAL_SHA" \
    "https://example.invalid/repo.git" "refs/heads/main")
  [ -n "$fields" ] || { echo "FAIL: fixture setup -- _record_close_prepared returned empty digest" >&2; exit 1; }
  printf '%s\n' "$sem"
}

fail_test() { echo "FAIL: $1" >&2; exit 1; }

# --- Test 1: abandon with the exact recorded commit set succeeds, and the
#     resulting semaphore reads back as "published" via the new proof scheme.
SEM=$(build_prepared_semaphore)
HEAD_SHA=$(_unique_record_field "$SEM" close_delivery_source_head)
[ "$(_close_delivery_state "$SEM" SESSION-1)" = "prepared" ] \
  || fail_test "T1 setup: expected state=prepared before any publish/abandon record"
_abandon_prepared_matches_source "$SEM" "$HEAD_SHA" \
  || fail_test "T1: _abandon_prepared_matches_source rejected the exact recorded commit set"
PREPARE_DIGEST=$(_unique_record_field "$SEM" close_delivery_prepare_digest)
COMMITS_JSON=$(_unique_record_field "$SEM" close_delivery_source_commits)
SOURCE_STATUS=$(_unique_record_field "$SEM" close_delivery_source_status_sha256)
DIGEST=$(_record_close_abandoned "$SEM" SESSION-1 "$PREPARE_DIGEST" "$COMMITS_JSON" \
  "$HEAD_SHA" "$SOURCE_STATUS" "$TERMINAL_SHA" claude-code) \
  || fail_test "T1: _record_close_abandoned failed"
[ -n "$DIGEST" ] || fail_test "T1: _record_close_abandoned printed no digest"
[ "$(_close_delivery_state "$SEM" SESSION-1)" = "published" ] \
  || fail_test "T1: state did not transition to published after abandon record"
grep -q '^close_publish_proof: manual-abandon-attestation/v1$' "$SEM" \
  || fail_test "T1: semaphore does not carry the manual-abandon-attestation proof marker"
echo "PASS: T1 -- abandon with exact commit set transitions prepared -> published"

# --- Test 2: partial / wrong commit list is refused, not silently accepted.
SEM2=$(build_prepared_semaphore)
if _abandon_prepared_matches_source "$SEM2" "0000000000000000000000000000000000000000"; then
  fail_test "T2: _abandon_prepared_matches_source accepted a commit not in close_delivery_source_commits"
fi
echo "PASS: T2 -- wrong/partial --source-commit list is refused"

# --- Test 3: the untouched isolate-push-exit0/v1 path still round-trips
#     (regression check on the shared _close_delivery_state validation code
#     this change restructured).
SEM3=$(build_prepared_semaphore)
HEAD3=$(_unique_record_field "$SEM3" close_delivery_source_head)
PREPARE3=$(_unique_record_field "$SEM3" close_delivery_prepare_digest)
COMMITS3=$(_unique_record_field "$SEM3" close_delivery_source_commits)
STATUS3=$(_unique_record_field "$SEM3" close_delivery_source_status_sha256)
REMOTE_SHA=$(printf '%040d' 1)
DIGEST3=$(_record_close_published "$SEM3" SESSION-1 "$PREPARE3" "$REMOTE_SHA" "$COMMITS3" \
  "$HEAD3" "$STATUS3" "$TERMINAL_SHA") \
  || fail_test "T3: _record_close_published failed"
[ -n "$DIGEST3" ] || fail_test "T3: _record_close_published printed no digest"
[ "$(_close_delivery_state "$SEM3" SESSION-1)" = "published" ] \
  || fail_test "T3: normal isolate-push-exit0/v1 path no longer reads back as published"
echo "PASS: T3 -- normal isolate-push-exit0/v1 path is unaffected"

echo "ALL PASS: session-guard-abandon-prepared-smoke.sh"
