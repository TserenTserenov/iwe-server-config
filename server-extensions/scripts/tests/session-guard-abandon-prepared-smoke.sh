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

# --- Test 5/6: WP-561 Ч4 (peer-session 2026-10-06-07-wp561-f33-contract-tests,
#     Claude+Kimi+Codex, consensus) -- the two remaining bypass-via-FORCED_CARD
#     channels (auto-archive-cancelled, cancel-obligation) also skipped close
#     events on the resumed (--abandon-prepared) path, the same gap T4 fixed
#     for peer-session. Unlike peer-session (whose channel is a static
#     close_path field), these two are a property of which card/obligation the
#     FIRST attempt matched -- re-derived here from the already-frozen
#     close_delivery_terminal_kind/_reference the first attempt wrote into
#     PREPARED, not by re-scanning RUNNER_CARDS or re-querying
#     close_obligation.py (both would risk a different answer than the first
#     attempt got, and RUNNER_CARDS is unavailable on the resumed path at all
#     -- it is only built inside the fresh-close branch).
setup_e2e_sandbox() {  # setup_e2e_sandbox <name> -> prints E2E root; exports IWE_* for the caller
  local name="$1"
  local e2e="$TEST_ROOT/$name"
  mkdir -p "$e2e/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$e2e/scripts/agent-status-report.sh"
  chmod +x "$e2e/scripts/agent-status-report.sh"
  local origin="$e2e/origin.git"
  git init -q --bare -b main "$origin"
  local gov="$e2e/DS-strategy"
  mkdir -p "$gov/inbox/agent/tasks" "$gov/scripts"
  git -C "$gov" init -q -b main
  git -C "$gov" config user.email test@example.com
  git -C "$gov" config user.name Test
  git -C "$gov" remote add origin "$origin"
  printf '#!/usr/bin/env python3\nprint("{}")\n' > "$gov/scripts/process-runner.py"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$gov/scripts/isolate-push.sh"
  cat > "$gov/scripts/ledger-append.sh" <<'EOF2'
#!/usr/bin/env bash
printf '%s %s\n' "$3" "$4" >> "${IWE_TEST_LEDGER_LOG:?}"
EOF2
  chmod +x "$gov/scripts/process-runner.py" "$gov/scripts/isolate-push.sh" "$gov/scripts/ledger-append.sh"
  git -C "$gov" add scripts
  git -C "$gov" commit -qm init
  git -C "$gov" push -q origin main
  local sess="$e2e/MC-sessions-fixture"
  local sess_origin="$e2e/sessions-origin.git"
  git init -q --bare -b main "$sess_origin"
  git init -q -b main "$sess"
  git -C "$sess" config user.email test@example.com
  git -C "$sess" config user.name Test
  git -C "$sess" remote add origin "$sess_origin"
  echo placeholder > "$sess/00-index.md"
  git -C "$sess" add 00-index.md
  git -C "$sess" commit -qm init
  git -C "$sess" push -q origin main
  printf '%s %s %s\n' "$e2e" "$gov" "$sess"
}

record_orz_and_commit() {  # record_orz_and_commit <sem> <sess-repo> <worktree>
  local sem="$1" sess="$2" wt="$3"
  local orz
  orz=$(grep '^orz_file: ' "$sem" | cut -d' ' -f2-)
  mkdir -p "$sess/$(dirname "$orz")"
  printf -- '---\ndate: 2026-10-06\ntype: work\nwp: WP-561\nduration_h: 0.1\nartifacts: []\nagent: fixture\n---\n\n# Fixture\n\n## Главный инсайт\nx\n\n## Контекст\nx\n\n## Достигнуто\nx\n\n## Ключевые решения\nx\n' > "$sess/$orz"
  git -C "$sess" add "$orz"
  git -C "$sess" commit -qm orz
  git -C "$sess" push -q origin main
  echo work > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "session work"
  git -C "$wt" rev-parse HEAD
}

read -r E2E5 GOV5 SESS5 <<<"$(setup_e2e_sandbox e2e5)"
export IWE_ROOT="$E2E5" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="fixture" \
       IWE_SESSIONS_ROOT="$SESS5" IWE_FROZEN_CANONICAL_PATH="" \
       CLAUDE_CODE_SESSION_ID="archive-e2e" IWE_TEST_LEDGER_LOG="$E2E5/ledger.log"
: > "$IWE_TEST_LEDGER_LOG"
OPEN_OUT5=$(bash "$GUARD" open --wp WP-561 --task fixture --slug archive-e2e --agent fixture --isolate --force)
WT5=$(printf '%s\n' "$OPEN_OUT5" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
[ -n "$WT5" ] && [ -d "$WT5" ] || fail_test "T5 setup: open --isolate gave no worktree"
E2E5_SEM=$(find "$E2E5/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
HARNESS5=$(grep '^harness_session_id: ' "$E2E5_SEM" | cut -d' ' -f2-)
[ -n "$HARNESS5" ] || fail_test "T5 setup: no harness_session_id recorded (CLAUDE_CODE_SESSION_ID did not flow through)"
SRC5=$(record_orz_and_commit "$E2E5_SEM" "$SESS5" "$WT5")
# A valid RUN-quick-close card for mode=archive-cancelled, matching every
# field _terminal_card_snapshot_sha validates (process_id, status,
# current_step, owner_session_id, results.*.wp, requested_slug, run_id/
# filename pairing, all_pushed) -- built by hand once rather than through a
# real quick-close run, same trade-off test-session-guard-force-no-reflection.sh
# already makes for this exact card shape.
cat > "$GOV5/inbox/agent/tasks/RUN-quick-close-archive-e2e.md" <<EOF2
---
process_id: quick-close
run_id: quick-close-archive-e2e
requested_slug: archive-e2e
owner_session_id: $HARNESS5
status: cancelled
current_step: wp-archive-run
all_pushed: true
results:
  gather-session-facts:
    wp: "561"
---
EOF2
if IWE_SESSION_GUARD_FAULT_POINT=after-prepared bash "$GUARD" close --wp WP-561 --slug archive-e2e --agent fixture >/dev/null 2>"$E2E5/c1.err"; then
  fail_test "T5 setup: close did not stop at the after-prepared fault point"
fi
E2E5_SESSION_ID=$(_unique_record_field "$E2E5_SEM" close_delivery_session_id)
[ "$(_close_delivery_state "$E2E5_SEM" "$E2E5_SESSION_ID")" = "prepared" ] \
  || { cat "$E2E5/c1.err" >&2; fail_test "T5 setup: session is not PREPARED after the fault"; }
grep -q '^close_delivery_terminal_kind: file$' "$E2E5_SEM" \
  || fail_test "T5 setup: fresh path did not record terminal_kind=file for the archive-cancelled card"
: > "$IWE_TEST_LEDGER_LOG"
bash "$GUARD" close --wp WP-561 --slug archive-e2e --agent fixture --abandon-prepared \
  --i-understand-loss-risk --source-commit "$SRC5" --reason "smoke: T5" >/dev/null 2>"$E2E5/c2.err" \
  || { cat "$E2E5/c2.err" >&2; fail_test "T5: resumed --abandon-prepared close failed"; }
[ "$(grep -c '^session_closed_direct ' "$IWE_TEST_LEDGER_LOG")" = "1" ] \
  || { cat "$IWE_TEST_LEDGER_LOG" >&2; fail_test "T5: expected exactly one session_closed_direct on the resumed auto-archive-cancelled path"; }
echo "PASS: T5 -- resumed auto-archive-cancelled close re-derives FORCED_CARD from frozen terminal proof and writes session_closed_direct"

read -r E2E6 GOV6 SESS6 <<<"$(setup_e2e_sandbox e2e6)"
export IWE_ROOT="$E2E6" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="fixture" \
       IWE_SESSIONS_ROOT="$SESS6" IWE_FROZEN_CANONICAL_PATH="" \
       CLAUDE_CODE_SESSION_ID="obligation-e2e" IWE_TEST_LEDGER_LOG="$E2E6/ledger.log"
: > "$IWE_TEST_LEDGER_LOG"
OPEN_OUT6=$(bash "$GUARD" open --wp WP-561 --task fixture --slug obligation-e2e --agent fixture --isolate --force)
WT6=$(printf '%s\n' "$OPEN_OUT6" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
[ -n "$WT6" ] && [ -d "$WT6" ] || fail_test "T6 setup: open --isolate gave no worktree"
E2E6_SEM=$(find "$E2E6/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
HARNESS6=$(grep '^harness_session_id: ' "$E2E6_SEM" | cut -d' ' -f2-)
[ -n "$HARNESS6" ] || fail_test "T6 setup: no harness_session_id recorded"
SRC6=$(record_orz_and_commit "$E2E6_SEM" "$SESS6" "$WT6")
# Stub close_obligation.py -- same convention this file already uses for
# ledger-append.sh/isolate-push.sh/process-runner.py (fixture replacement for
# an external CLI, not the real implementation under test). No RUN-quick-close
# card exists, so the fresh path falls through to this check (:10688-10719).
cat > "$GOV6/scripts/close_obligation.py" <<EOF2
#!/usr/bin/env python3
import json, sys
if sys.argv[1] == "cancel-status" and sys.argv[3] == "$HARNESS6":
    print(json.dumps({"cancelled": True, "action": "cancel-close", "actor": "pilot"}))
else:
    print(json.dumps({"cancelled": False}))
EOF2
chmod +x "$GOV6/scripts/close_obligation.py"
if IWE_SESSION_GUARD_FAULT_POINT=after-prepared bash "$GUARD" close --wp WP-561 --slug obligation-e2e --agent fixture >/dev/null 2>"$E2E6/c1.err"; then
  fail_test "T6 setup: close did not stop at the after-prepared fault point"
fi
E2E6_SESSION_ID=$(_unique_record_field "$E2E6_SEM" close_delivery_session_id)
[ "$(_close_delivery_state "$E2E6_SEM" "$E2E6_SESSION_ID")" = "prepared" ] \
  || { cat "$E2E6/c1.err" >&2; fail_test "T6 setup: session is not PREPARED after the fault"; }
grep -q '^close_delivery_terminal_reference: cancel-obligation:' "$E2E6_SEM" \
  || fail_test "T6 setup: fresh path did not record a cancel-obligation terminal reference"
: > "$IWE_TEST_LEDGER_LOG"
bash "$GUARD" close --wp WP-561 --slug obligation-e2e --agent fixture --abandon-prepared \
  --i-understand-loss-risk --source-commit "$SRC6" --reason "smoke: T6" >/dev/null 2>"$E2E6/c2.err" \
  || { cat "$E2E6/c2.err" >&2; fail_test "T6: resumed --abandon-prepared close failed"; }
[ "$(grep -c '^session_closed_direct ' "$IWE_TEST_LEDGER_LOG")" = "1" ] \
  || { cat "$IWE_TEST_LEDGER_LOG" >&2; fail_test "T6: expected exactly one session_closed_direct on the resumed cancel-obligation path"; }
echo "PASS: T6 -- resumed cancel-obligation close re-derives FORCED_CARD from frozen terminal proof and writes session_closed_direct"

# --- Test 8: force-no-reflection channel on resume (cold review,
#     2026-10-06: the first cut of this fix only covered auto-archive-cancelled
#     and cancel-obligation, missing this third documented channel -- a live
#     repro confirmed session_closed_direct was 0 on resume before this test
#     was added). The card shape is the same "file" terminal-kind category as
#     T5 (current_step: blocked-witness-unavailable instead of
#     wp-archive-run); --force-no-reflection is only needed on the FIRST
#     (faulted) attempt to reach that fresh-path branch at all -- the resumed
#     attempt deliberately omits it, to prove the generic event does not
#     depend on re-passing the flag (only the custom reason text does, and
#     this test does not claim to restore that).
read -r E2E8 GOV8 SESS8 <<<"$(setup_e2e_sandbox e2e8)"
export IWE_ROOT="$E2E8" IWE_GOVERNANCE_REPO="DS-strategy" IWE_AGENT="fixture" \
       IWE_SESSIONS_ROOT="$SESS8" IWE_FROZEN_CANONICAL_PATH="" \
       CLAUDE_CODE_SESSION_ID="reflection-e2e" IWE_TEST_LEDGER_LOG="$E2E8/ledger.log"
: > "$IWE_TEST_LEDGER_LOG"
OPEN_OUT8=$(bash "$GUARD" open --wp WP-561 --task fixture --slug reflection-e2e --agent fixture --isolate --force)
WT8=$(printf '%s\n' "$OPEN_OUT8" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
[ -n "$WT8" ] && [ -d "$WT8" ] || fail_test "T8 setup: open --isolate gave no worktree"
E2E8_SEM=$(find "$E2E8/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | head -1)
HARNESS8=$(grep '^harness_session_id: ' "$E2E8_SEM" | cut -d' ' -f2-)
[ -n "$HARNESS8" ] || fail_test "T8 setup: no harness_session_id recorded"
SRC8=$(record_orz_and_commit "$E2E8_SEM" "$SESS8" "$WT8")
cat > "$GOV8/inbox/agent/tasks/RUN-quick-close-reflection-e2e.md" <<EOF2
---
process_id: quick-close
run_id: quick-close-reflection-e2e
requested_slug: reflection-e2e
owner_session_id: $HARNESS8
status: cancelled
current_step: blocked-witness-unavailable
all_pushed: true
results:
  gather-session-facts:
    wp: "561"
---
EOF2
if IWE_SESSION_GUARD_FAULT_POINT=after-prepared bash "$GUARD" close --wp WP-561 --slug reflection-e2e --agent fixture \
     --force-no-reflection "smoke: original reason" >/dev/null 2>"$E2E8/c1.err"; then
  fail_test "T8 setup: close did not stop at the after-prepared fault point"
fi
E2E8_SESSION_ID=$(_unique_record_field "$E2E8_SEM" close_delivery_session_id)
[ "$(_close_delivery_state "$E2E8_SEM" "$E2E8_SESSION_ID")" = "prepared" ] \
  || { cat "$E2E8/c1.err" >&2; fail_test "T8 setup: session is not PREPARED after the fault"; }
grep -q '^close_delivery_terminal_kind: file$' "$E2E8_SEM" \
  || fail_test "T8 setup: fresh path did not record terminal_kind=file for the blocked-witness card"
: > "$IWE_TEST_LEDGER_LOG"
bash "$GUARD" close --wp WP-561 --slug reflection-e2e --agent fixture --abandon-prepared \
  --i-understand-loss-risk --source-commit "$SRC8" --reason "smoke: T8" >/dev/null 2>"$E2E8/c2.err" \
  || { cat "$E2E8/c2.err" >&2; fail_test "T8: resumed --abandon-prepared close failed"; }
[ "$(grep -c '^session_closed_direct ' "$IWE_TEST_LEDGER_LOG")" = "1" ] \
  || { cat "$IWE_TEST_LEDGER_LOG" >&2; fail_test "T8: expected exactly one session_closed_direct on the resumed force-no-reflection path"; }
echo "PASS: T8 -- resumed force-no-reflection close re-derives FORCED_CARD and writes session_closed_direct without the flag being re-passed"

# --- Test 7: negative -- a resumed close whose frozen terminal proof is
#     neither a close_path channel nor one of the three re-derivable
#     sentinels must NOT fabricate a FORCED_CARD (no double emission, no
#     false positive channel attribution). Reuses T3's isolate-push-exit0/v1
#     semaphore shape, which has no close_path and no archive/obligation/
#     blocked-witness terminal reference.
SEM7="$TEST_ROOT/sem7.open"
cp "$SEM3" "$SEM7"
# T3's semaphore never reached the resumed-close branch in a live `close`
# invocation; exercise the exact bash fragment under test directly instead
# -- same level this file already tests _record_close_prepared/_abandon_
# prepared_matches_source at (T1-T3), not through the CLI.
FORCED_CARD=""
_wp561_t7_kind=$(_unique_record_field "$SEM7" close_delivery_terminal_kind || true)
_wp561_t7_ref=$(_unique_record_field "$SEM7" close_delivery_terminal_reference || true)
case "$_wp561_t7_ref" in
  cancel-obligation:*)
    FORCED_CARD="$_wp561_t7_ref"
    ;;
  *)
    if [ "$_wp561_t7_kind" = file ] && [ -f "$_wp561_t7_ref" ] \
       && grep -q '^current_step: wp-archive-run$' "$_wp561_t7_ref"; then
      FORCED_CARD="$_wp561_t7_ref"
    fi
    ;;
esac
[ -z "$FORCED_CARD" ] \
  || fail_test "T7: FORCED_CARD was fabricated ($FORCED_CARD) for a semaphore with no archive/obligation terminal proof"
echo "PASS: T7 -- a semaphore with no archive/obligation terminal proof does not fabricate FORCED_CARD on resume"

echo "ALL PASS: session-guard-abandon-prepared-smoke.sh"
