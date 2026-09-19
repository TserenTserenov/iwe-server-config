#!/usr/bin/env bash
# Regression (WP-538 Ф9): one sweep pass sends ONE Telegram summary instead
# of one message per orphaned/quarantined semaphore, and a message queued
# during a pass that never reaches delivery (process killed, or iwe-tg
# itself fails) is not lost -- the next pass recovers and resends it.
#
# Cold-review round 1 (Codex, 19.09) found the first version of this feature
# lost a queued message permanently on interruption/delivery failure, and
# left its in-memory queue declared after the pass ended, silently
# swallowing any later same-process notify call. Cases 3 and 4 are exactly
# those two findings, reproduced against the real script, not a
# reimplementation.
#
# Cold-review round 2 (Codex, 19.09) found the round-1 fix still had a real
# gap: a SIGKILL landing between the pending-file write and the registry
# write was never tested with an actual killed process (only simulated
# transport failure), a recovered pass's type breakdown was wrong (it read
# counters that only track fresh classifications), and the registry carried
# no pass key, so the summary's "search by pass key" instruction had nothing
# to match against. Cases 5 and 6 are exactly those findings.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-sweep-batch.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
REGISTRY="$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl"
PENDING="$TEST_ROOT/.iwe-runtime/sweep-notify-pending.log"
TG_LOG="$TEST_ROOT/iwe-tg.log"
export IWE_SESSIONS_ROOT="$GOV/sessions"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin"
git -C "$GOV" init -q

fail() { echo "FAIL: $*" >&2; exit 1; }

write_iwe_tg() {  # <exit code to simulate>
  # A summary can itself contain newlines (several per-semaphore messages
  # joined together) -- prefixing every call with a marker line lets
  # call_count() below count actual invocations instead of raw file lines.
  cat > "$TEST_ROOT/bin/iwe-tg" <<EOF
#!/usr/bin/env bash
printf 'CALL>>>\n%s\n' "\$*" >> "$TG_LOG"
exit $1
EOF
  chmod +x "$TEST_ROOT/bin/iwe-tg"
}

# WP-538 Ф9 cold-review round 2, case 5: a python3 proxy that runs the REAL
# python3 to completion (so the write it wraps genuinely happens), then
# signals it got there and blocks -- giving the test a real window to send a
# real SIGKILL to session-guard.sh's own process, landing exactly between
# the pending-file write and append_zombie_event's registry write. Matched
# by a marker substring unique to _sweep_notify_pending_append's heredoc, so
# every OTHER python3 call in the script (there are several) passes straight
# through untouched.
write_pausing_python3() {  # <marker substring> <reached-file> <release-file>
  local marker="$1" reached="$2" release="$3" real_python3
  real_python3=$(command -v python3)
  cat > "$TEST_ROOT/bin/python3" <<EOF
#!/usr/bin/env bash
STDIN_CONTENT=\$(cat)
if [ "\$1" = "-" ] && grep -qF '$marker' <<<"\$STDIN_CONTENT"; then
  printf '%s' "\$STDIN_CONTENT" | "$real_python3" "\$@"
  rc=\$?
  touch "$reached"
  i=0
  while [ ! -e "$release" ] && [ "\$i" -lt 500 ]; do sleep 0.01; i=\$((i + 1)); done
  exit "\$rc"
fi
printf '%s' "\$STDIN_CONTENT" | exec "$real_python3" "\$@"
EOF
  chmod +x "$TEST_ROOT/bin/python3"
}

run_audit() {  # [extra audit flags...]
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_ZOMBIE_ESCALATE_SEC=1 \
    PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" audit "$@" 2>&1
}

write_semaphore() {  # <path> <session>
  local path="$1" session="$2"
  {
    echo "---"
    echo "agent: kimi"  # no pid: field -> missing_or_invalid_owner_pid path, ages out fast
    echo "wp: WP-538"
    echo "slug: $session"
    echo "opened_at: 2000-01-01T00:00:00Z"
    echo "created_at: 2000-01-01T00:00:00Z"
    echo "session_id: $session"
    echo "---"
    echo "file: inbox/WP-538/WP-538.md"
  } > "$path"
}

call_count() { grep -c '^CALL>>>$' "$TG_LOG" 2>/dev/null || echo 0; }

# 1. A mass pass (3 stale semaphores, well under the summary threshold) sends
#    exactly ONE Telegram message, and it names all three sessions.
write_iwe_tg 0
: > "$TG_LOG"
for n in a b c; do write_semaphore "$SESSION_DIR/claude-code-mass-$n.open" "mass-$n"; done
OUT=$(run_audit --cleanup-orphans)
grep -q 'zombies_escalated=3' <<<"$OUT" || fail "sweep did not count all 3 escalations: $OUT"
[ "$(call_count)" -eq 1 ] || fail "mass pass sent $(call_count) Telegram messages, want 1"
grep -q -- '--admission-key unexpected:session-guard:sweep-' "$TG_LOG" \
  || fail "sweep summary bypassed the shared notification admission key"
grep -q '3 событий за проход' "$TG_LOG" || fail "summary header missing the event count"
for n in a b c; do
  grep -q "mass-$n" "$TG_LOG" || fail "summary is missing session mass-$n"
done
[ ! -s "$PENDING" ] || fail "pending file not cleared after confirmed delivery"

# 2. Above the threshold (6 stale semaphores) still sends exactly ONE
#    message, in compact form: counts by type + registry path, not six
#    full per-semaphore texts. The pass key printed in that message must be
#    the same one recorded on the registry entries themselves (Codex round 2,
#    item 3) -- otherwise "ищи по ключу прохода" has nothing to search for.
write_iwe_tg 0
: > "$TG_LOG"
for n in 1 2 3 4 5 6; do write_semaphore "$SESSION_DIR/claude-code-many-$n.open" "many-$n"; done
OUT=$(run_audit --cleanup-orphans)
grep -q 'zombies_escalated=6' <<<"$OUT" || fail "sweep did not count all 6 escalations: $OUT"
[ "$(call_count)" -eq 1 ] || fail "large pass sent $(call_count) Telegram messages, want 1"
grep -q '6 событий за проход' "$TG_LOG" || fail "compact summary missing the event count"
grep -q 'осиротевшие: 6' "$TG_LOG" || fail "compact summary missing the per-type escalated count"
grep -qF "$REGISTRY" "$TG_LOG" || fail "compact summary does not point at the registry path"
grep -q 'many-1' "$TG_LOG" && fail "compact summary leaked per-semaphore detail it should have omitted"
PASS_KEY=$(grep -oE '[0-9]{8}T[0-9]{6}Z' "$TG_LOG" | head -1)
[ -n "$PASS_KEY" ] || fail "could not extract the pass key from the compact summary"
grep -q "\"pass_key\":\"$PASS_KEY\"" "$REGISTRY" \
  || fail "no registry record carries this pass's key -- 'ищи по ключу прохода' would find nothing"

# 3. Delivery failure: the queued message is NOT lost -- it survives in the
#    crash-recovery file and rides along with the NEXT pass's summary. This
#    is the exact loss Codex's round-1 review found in the first version.
write_iwe_tg 1
: > "$TG_LOG"
write_semaphore "$SESSION_DIR/claude-code-lost-if-broken.open" "lost-if-broken"
run_audit --cleanup-orphans >/dev/null
[ -s "$PENDING" ] || fail "failed delivery did not leave a crash-recovery record"
grep -q '"action":"escalated"' "$REGISTRY" || fail "the event itself was not recorded in the registry"

write_iwe_tg 0
: > "$TG_LOG"
write_semaphore "$SESSION_DIR/claude-code-second-pass.open" "second-pass"
OUT=$(run_audit --cleanup-orphans)
[ "$(call_count)" -eq 1 ] || fail "recovery pass sent $(call_count) messages, want 1 combined summary"
grep -q 'lost-if-broken' "$TG_LOG" || fail "message from the failed pass was not recovered by the next pass"
grep -q 'second-pass' "$TG_LOG" || fail "recovery pass dropped its own new event"
[ ! -s "$PENDING" ] || fail "pending file not cleared once the recovered message was confirmed delivered"

# 4. Queue does not leak across sweeps in the same process: after one sweep
#    finishes, _SWEEP_NOTIFY_QUEUE must be gone (unset), not merely emptied,
#    so a later same-process call to _session_guard_notify delivers
#    immediately instead of being silently absorbed into a queue nothing
#    will ever flush again. Unit-level, not through the CLI: today's only
#    caller (audit --cleanup-orphans) exits right after one sweep, so this
#    can't be observed end-to-end -- it protects whichever future caller
#    calls the sweep a second time, or notifies from outside one, in the
#    same process.
extract_fn() {  # <function name>
  awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" {p=1} p{print} p && /^}/{exit}' "$GUARD"
}
UNIT_OUT=$(bash -c '
  set -euo pipefail
  '"$(extract_fn _sweep_notify_pending_append)"'
  '"$(extract_fn _session_guard_notify)"'
  '"$(extract_fn _sweep_flush_notify_queue)"'
  _SWEEP_QUARANTINE_SUMMARY_THRESHOLD=5
  _SWEEP_NOTIFY_PENDING_FILE=$(mktemp)
  _SWEEP_PASS_KEY=test-pass
  _SWEEP_NOTIFY_ESCALATED_COUNT=0
  _SWEEP_NOTIFY_QUARANTINED_COUNT=0
  iwe-tg() { :; }
  command() { [ "$1" = "-v" ] && [ "$2" = "iwe-tg" ] && return 0; builtin command "$@"; }
  _SWEEP_NOTIFY_QUEUE=()
  _session_guard_notify "one sweep event" "semX" "escalated" "test-pass"
  _sweep_flush_notify_queue
  unset _SWEEP_NOTIFY_QUEUE
  _session_guard_notify "later, unrelated call" "semY" "escalated" "test-pass"
  declare -p _SWEEP_NOTIFY_QUEUE >/dev/null 2>&1 \
    && echo "LEAKED: later call was absorbed into a queue instead of delivered" \
    || echo "OK: later call saw no queue, delivered on its own"
' 2>&1)
grep -q '^OK:' <<<"$UNIT_OUT" || fail "queue leaked across the unset boundary: $UNIT_OUT"

# 5. Real process kill (Codex round 2, item 1): a SIGKILL landing in the
#    genuine vulnerable window -- after the pending-file write completes,
#    before append_zombie_event's registry write starts -- must not lose the
#    notification. Test 3 above proves the delivery-RETRY path; this proves
#    the CRASH itself, against the real script's real process, not a
#    simulation of its control flow.
REACHED="$TEST_ROOT/reached-after-pending-write"
RELEASE="$TEST_ROOT/release-python3"
rm -f "$REACHED" "$RELEASE"
write_pausing_python3 'message=message,' "$REACHED" "$RELEASE"
write_iwe_tg 0
: > "$TG_LOG"
write_semaphore "$SESSION_DIR/claude-code-killed-mid-write.open" "killed-mid-write"
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_ZOMBIE_ESCALATE_SEC=1 \
  PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" audit --cleanup-orphans \
  >"$TEST_ROOT/killed-pass.log" 2>&1 &
AUDIT_PID=$!

waited=0
while [ ! -e "$REACHED" ] && [ "$waited" -lt 500 ]; do sleep 0.01; waited=$((waited + 1)); done
if [ ! -e "$REACHED" ]; then
  kill -9 "$AUDIT_PID" 2>/dev/null || true
  fail "python3 proxy never reached the pending-write marker -- test did not exercise the real code path"
fi
[ -s "$PENDING" ] || fail "pending file was not written before the kill -- test raced too early"
grep -q 'killed-mid-write' "$REGISTRY" 2>/dev/null \
  && fail "registry already had the event before the kill -- test did not land in the intended window"

kill -9 "$AUDIT_PID" 2>/dev/null || true
wait "$AUDIT_PID" 2>/dev/null || true
touch "$RELEASE"  # let the now-orphaned python3 proxy exit instead of idling out its own timeout
rm -f "$TEST_ROOT/bin/python3"  # restore the real python3 for the recovery pass below

grep -q 'killed-mid-write' "$REGISTRY" 2>/dev/null \
  && fail "registry was written despite the process being killed first -- the kill did not land where expected"

write_iwe_tg 0
: > "$TG_LOG"
OUT=$(run_audit --cleanup-orphans)
[ "$(call_count)" -eq 1 ] || fail "recovery pass after a real kill sent $(call_count) messages, want 1"
grep -q 'killed-mid-write' "$TG_LOG" || fail "notification lost across a real SIGKILL, not just recovered from a simulated failure"
grep -q '1 событий за проход' "$TG_LOG" \
  || fail "recovered event was duplicated inside the one Telegram summary: $(cat "$TG_LOG")"
[ "$(grep -o 'killed-mid-write' "$TG_LOG" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "recovered semaphore appears more than once inside the summary body: $(cat "$TG_LOG")"
grep -q 'killed-mid-write' "$REGISTRY" || fail "the killed pass's event was never recorded in the registry, even after recovery"
grep -q '"audit_recovered":true' "$REGISTRY" || fail "registry did not mark the audit record rebuilt from the durable pending event"
[ "$(grep -c 'killed-mid-write.*\"action\":\"escalated\"' "$REGISTRY")" -eq 1 ] \
  || fail "recovery and current-pass classification created duplicate audit records"
[ ! -s "$PENDING" ] || fail "pending file not cleared once the message recovered from a real kill was confirmed delivered"

# 6. Codex round 2, item 4: a delivery failure for 6 events (above the
#    summary threshold, so the COMPACT form is used) followed by a recovery
#    pass with zero new events of its own must still show the correct type
#    breakdown for the recovered events. Round 1's fix read
#    _SWEEP_ZOMBIES_ESCALATED/_SWEEP_DEAD_QUARANTINED for that breakdown --
#    both count only THIS pass's fresh classifications, so a pure-recovery
#    pass read as "6 событий ... осиротевшие: 0, в карантине: 0", correct
#    total, wrong split.
write_iwe_tg 1
: > "$TG_LOG"
for n in 1 2 3 4 5 6; do write_semaphore "$SESSION_DIR/claude-code-failed-$n.open" "failed-$n"; done
run_audit --cleanup-orphans >/dev/null
PENDING_LINES=$(grep -c . "$PENDING" 2>/dev/null || echo 0)
[ "$PENDING_LINES" -eq 6 ] || fail "expected 6 pending records after the failed 6-event pass, got $PENDING_LINES"
FAILED_ADMISSION_KEY=$(grep -oE 'unexpected:session-guard:sweep-[0-9a-f]+' "$TG_LOG" | tail -1)
[ -n "$FAILED_ADMISSION_KEY" ] || fail "failed delivery did not carry a stable admission key"

sleep 2
write_iwe_tg 0
: > "$TG_LOG"
OUT=$(run_audit --cleanup-orphans)
grep -q 'zombies_escalated=0' <<<"$OUT" || fail "recovery pass should classify zero FRESH events, got: $OUT"
[ "$(call_count)" -eq 1 ] || fail "recovery pass sent $(call_count) messages, want 1"
grep -q '6 событий за проход' "$TG_LOG" || fail "recovered compact summary missing the total event count"
grep -q 'осиротевшие: 6' "$TG_LOG" || fail "recovered compact summary shows the wrong type breakdown for events recovered from a prior pass"
grep -q 'в карантине: 0' "$TG_LOG" || fail "recovered compact summary should show zero quarantines for an all-escalation batch"
RECOVERED_ADMISSION_KEY=$(grep -oE 'unexpected:session-guard:sweep-[0-9a-f]+' "$TG_LOG" | tail -1)
[ "$RECOVERED_ADMISSION_KEY" = "$FAILED_ADMISSION_KEY" ] \
  || fail "pure recovery changed admission key: $FAILED_ADMISSION_KEY -> $RECOVERED_ADMISSION_KEY"
PASS_KEY=$(grep -oE '[0-9]{8}T[0-9]{6}Z' "$TG_LOG" | head -1)
grep -q "\"pass_key\":\"$PASS_KEY\"" "$REGISTRY" \
  || fail "recovered summary points to pass key $PASS_KEY absent from the registry"
[ ! -s "$PENDING" ] || fail "pending file not cleared once the recovered 6-event batch was confirmed delivered"

echo "PASS: one sweep pass sends one Telegram summary (small and large), a failed delivery or a real SIGKILL is recovered by the next pass with a correct type breakdown and a searchable pass key, and the queue does not leak across passes"
