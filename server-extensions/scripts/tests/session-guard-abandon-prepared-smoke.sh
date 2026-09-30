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
  "$HEAD_SHA" "$SOURCE_STATUS" "$TERMINAL_SHA" claude-code "smoke: superseded by later REPLACE") \
  || fail_test "T1: _record_close_abandoned failed"
[ -n "$DIGEST" ] || fail_test "T1: _record_close_abandoned printed no digest"
[ "$(_close_delivery_state "$SEM" SESSION-1)" = "published" ] \
  || fail_test "T1: state did not transition to published after abandon record"
grep -q '^close_publish_proof: manual-abandon-attestation/v1$' "$SEM" \
  || fail_test "T1: semaphore does not carry the manual-abandon-attestation proof marker"
grep -q '^close_publish_abandoned_reason: smoke: superseded by later REPLACE$' "$SEM" \
  || fail_test "T1: the abandon reason is not recorded in the attestation"
# The reason is bound into the digest: editing it afterwards breaks the receipt.
sed -i.bak 's/^close_publish_abandoned_reason: .*/close_publish_abandoned_reason: tampered/' "$SEM"
[ "$(_close_delivery_state "$SEM" SESSION-1 || true)" != "published" ] \
  || fail_test "T1: a tampered abandon reason still reads back as published"
echo "PASS: T1 -- abandon with exact commit set transitions prepared -> published, reason is immutable"

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

# --- Test 4: end-to-end close of a peer-session that was stopped at PREPARED and
#     resumed through --abandon-prepared. The resumed path used to write neither
#     session_closed_direct nor session_closed (FORCED_CARD was only set on a
#     fresh close); --reason is optional but must be one line when given.
#     Runs entirely in a sandbox IWE_ROOT with stubbed ledger/isolate-push.
E2E="$TEST_ROOT/e2e"
mkdir -p "$E2E/scripts"
cat > "$E2E/scripts/agent-status-report.sh" <<'EOF2'
#!/usr/bin/env bash
exit 0
EOF2
chmod +x "$E2E/scripts/agent-status-report.sh"
E2E_ORIGIN="$E2E/origin.git"
git init -q --bare -b main "$E2E_ORIGIN"
GOV="$E2E/DS-strategy"
mkdir -p "$GOV/inbox/agent/tasks" "$GOV/scripts"
git -C "$GOV" init -q -b main
git -C "$GOV" config user.email test@example.com
git -C "$GOV" config user.name Test
git -C "$GOV" remote add origin "$E2E_ORIGIN"
printf '#!/usr/bin/env python3\nprint("{}")\n' > "$GOV/scripts/process-runner.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GOV/scripts/isolate-push.sh"
# Ledger stub: records "<event-name> <payload>" so the test can read events back.
cat > "$GOV/scripts/ledger-append.sh" <<'EOF2'
#!/usr/bin/env bash
printf '%s %s\n' "$3" "$4" >> "${IWE_TEST_LEDGER_LOG:?}"
EOF2
chmod +x "$GOV/scripts/process-runner.py" "$GOV/scripts/isolate-push.sh" "$GOV/scripts/ledger-append.sh"
git -C "$GOV" add scripts
git -C "$GOV" commit -qm init
git -C "$GOV" push -q origin main
SESS="$E2E/MC-sessions-fixture"
SESS_ORIGIN="$E2E/sessions-origin.git"
git init -q --bare -b main "$SESS_ORIGIN"
git init -q -b main "$SESS"
git -C "$SESS" config user.email test@example.com
git -C "$SESS" config user.name Test
git -C "$SESS" remote add origin "$SESS_ORIGIN"
echo placeholder > "$SESS/00-index.md"
git -C "$SESS" add 00-index.md
git -C "$SESS" commit -qm init
git -C "$SESS" push -q origin main

export IWE_ROOT="$E2E" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="fixture" \
       IWE_SESSIONS_ROOT="$SESS" IWE_FROZEN_CANONICAL_PATH="" \
       CLAUDE_CODE_SESSION_ID="abandon-e2e" IWE_TEST_LEDGER_LOG="$E2E/ledger.log"
: > "$IWE_TEST_LEDGER_LOG"
OPEN_OUT=$(git -C "$GOV" rev-parse --show-toplevel >/dev/null && (cd "$GOV" && bash "$GUARD" open --wp WP-484 --task fixture --slug abandon-e2e --agent fixture --isolate --force --close-path peer-session))
WT=$(printf '%s\n' "$OPEN_OUT" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
[ -n "$WT" ] && [ -d "$WT" ] || fail_test "T4 setup: open --isolate gave no worktree"
E2E_SEM=$(find "$E2E/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
grep -q '^close_path: peer-session$' "$E2E_SEM" || fail_test "T4 setup: close_path not recorded"
ORZ=$(grep '^orz_file: ' "$E2E_SEM" | cut -d' ' -f2-)
mkdir -p "$SESS/$(dirname "$ORZ")"
printf -- '---\ndate: 2026-09-01\ntype: work\nwp: WP-484\nduration_h: 0.1\nartifacts: []\nagent: fixture\n---\n\n# Fixture\n\n## Главный инсайт\nx\n\n## Контекст\nx\n\n## Достигнуто\nx\n\n## Ключевые решения\nx\n' > "$SESS/$ORZ"
git -C "$SESS" add "$ORZ"
git -C "$SESS" commit -qm orz
git -C "$SESS" push -q origin main
echo work > "$WT/work.txt"
git -C "$WT" add work.txt
git -C "$WT" commit -qm "session work"
WORK_SHA=$(git -C "$WT" rev-parse HEAD)
echo "commit: DS-strategy $WORK_SHA" >> "$E2E_SEM"

# Stop at PREPARED.
if IWE_SESSION_GUARD_FAULT_POINT=after-prepared bash "$GUARD" close --wp WP-484 --slug abandon-e2e --agent fixture >/dev/null 2>"$E2E/c1.err"; then
  fail_test "T4 setup: close did not stop at the after-prepared fault point"
fi
[ "$(_close_delivery_state "$E2E_SEM" "$(_unique_record_field "$E2E_SEM" close_delivery_session_id)")" = "prepared" ] \
  || { cat "$E2E/c1.err" >&2; fail_test "T4 setup: session is not PREPARED after the fault"; }
SRC=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0])' "$(_unique_record_field "$E2E_SEM" close_delivery_source_commits)")

: > "$IWE_TEST_LEDGER_LOG"  # drop events written by open and the first, faulted close
# Negative: a multi-line --reason is refused, session stays PREPARED, no events.
if bash "$GUARD" close --wp WP-484 --slug abandon-e2e --agent fixture --abandon-prepared \
     --i-understand-loss-risk --source-commit "$SRC" --reason $'two\nlines' >/dev/null 2>"$E2E/c2.err"; then
  fail_test "T4: --abandon-prepared with a multi-line --reason was accepted"
fi
grep -q -- '--reason' "$E2E/c2.err" || fail_test "T4: refusal does not mention --reason"
[ ! -s "$IWE_TEST_LEDGER_LOG" ] || fail_test "T4: events written by a refused close"
[ "$(_close_delivery_state "$E2E_SEM" "$(_unique_record_field "$E2E_SEM" close_delivery_session_id)")" = "prepared" ] \
  || fail_test "T4: a refused close changed the PREPARED state"
echo "PASS: T4a -- a multi-line --reason is refused and leaves the session PREPARED"

# Positive, the automatic release handler's shape: NO --reason. The resumed close
# must succeed, write both day events once and record no reason line.
bash "$GUARD" close --wp WP-484 --slug abandon-e2e --agent fixture --abandon-prepared \
  --i-understand-loss-risk --source-commit "$SRC" >/dev/null 2>"$E2E/c3.err" \
  || { cat "$E2E/c3.err" >&2; fail_test "T4: resumed --abandon-prepared close without --reason failed"; }
[ "$(grep -c '^session_closed_direct ' "$IWE_TEST_LEDGER_LOG")" = "1" ] \
  || { cat "$IWE_TEST_LEDGER_LOG" >&2; fail_test "T4: expected exactly one session_closed_direct on the resumed path"; }
[ "$(grep -c '^session_closed ' "$IWE_TEST_LEDGER_LOG")" = "1" ] \
  || { cat "$IWE_TEST_LEDGER_LOG" >&2; fail_test "T4: expected exactly one session_closed on the resumed path"; }
grep -q 'peer-session' "$IWE_TEST_LEDGER_LOG" || fail_test "T4: events do not name the peer-session channel"
if grep -q '^close_publish_abandoned_reason:' "$E2E_SEM.closed"; then
  fail_test "T4: a reason line was recorded although none was given"
fi
echo "PASS: T4b -- resumed peer-session close without --reason writes both events once"

echo "ALL PASS: session-guard-abandon-prepared-smoke.sh"
