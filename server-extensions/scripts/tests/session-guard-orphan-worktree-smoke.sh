#!/usr/bin/env bash
# Regression: stale/dead ownership is not fencing. Only an exact terminal
# outcome may reap an ordinary worktree; an exact scheduled drain may only
# freeze its semaphore. Manual recovery is proof-gated and ledger-idempotent.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-orphan-worktree.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
MANAGED_WORKTREES="$TEST_ROOT/.iwe-runtime/isolated-worktrees"
PUSH_MARKER="$TEST_ROOT/isolate-push-called"
LEDGER_ROOT="$TEST_ROOT/ledger"
export IWE_SESSIONS_ROOT="$GOV/sessions"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" "$MANAGED_WORKTREES" "$TEST_ROOT/bin"
git -C "$GOV" init -q

cat > "$TEST_ROOT/bin/iwe-tg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$GOV/scripts/isolate-push.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PUSH_MARKER"
exit 0
EOF
cat > "$GOV/scripts/ledger-append.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${IWE_TEST_LEDGER_FAIL:-0}" != 1 ] || exit 42
python3 - "$IWE_LEDGER_DIR" "$2" "$3" "$4" <<'PY'
import json
import os
import sys

root, date, kind, event_json = sys.argv[1:]
year, month, _ = date.split("-")
path = os.path.join(root, "day", year, month, "day-%s.yaml" % date)
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    with open(path, encoding="utf-8") as source:
        document = json.load(source)
else:
    document = {"events": []}
document["events"].append({"kind": kind, "data": json.loads(event_json)})
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as target:
    json.dump(document, target)
    target.write("\n")
    target.flush()
    os.fsync(target.fileno())
os.replace(temporary, path)
PY
EOF
chmod +x "$TEST_ROOT/bin/iwe-tg" "$GOV/scripts/isolate-push.sh" "$GOV/scripts/ledger-append.sh"

run_sweep() {
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_ZOMBIE_ESCALATE_SEC=1 IWE_ZOMBIE_CLEANUP_SEC=1 \
    PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" audit --cleanup-orphans 2>&1
}

write_card() {  # <worktree> <slug> <harness> <wp> <status>
  local worktree="$1" slug="$2" harness="$3" wp="$4" status="$5"
  mkdir -p "$worktree/inbox/agent/tasks"
  cat > "$worktree/inbox/agent/tasks/RUN-quick-close-$slug.md" <<EOF
---
process_id: quick-close
run_id: quick-close-$slug
requested_slug: $slug
owner_session_id: $harness
status: $status
current_step: done
results:
  gather-session-facts:
    wp: $wp
---
EOF
}

write_semaphore() {  # <path> <slug> <session> <harness> <worktree> [pid]
  local path="$1" slug="$2" session="$3" harness="$4" worktree="$5" pid="${6:-}"
  cat > "$path" <<EOF
---
agent: kimi
wp: WP-537
slug: $slug
${pid:+pid: $pid
}opened_at: 2000-01-01T00:00:00Z
created_at: 2000-01-01T00:00:00Z
session_id: $session
${harness:+harness_session_id: $harness}
isolated_worktree: $worktree
---
file: inbox/agent/tasks/RUN-quick-close-$slug.md
EOF
}

DEAD_PID=99999999
if kill -0 "$DEAD_PID" 2>/dev/null; then
  echo "FAIL: fixture PID unexpectedly exists: $DEAD_PID" >&2
  exit 1
fi

# Age alone, even past the old cleanup threshold, must not rename `.open`.
AGE_WORKTREE="$MANAGED_WORKTREES/age-only"
write_card "$AGE_WORKTREE" age-only harness-age WP-537 running
AGE_OPEN="$SESSION_DIR/kimi-age-only.open"
write_semaphore "$AGE_OPEN" age-only age-only harness-age "$AGE_WORKTREE"
AGE_OUT=$(run_sweep)
[ -f "$AGE_OPEN" ] || { echo "FAIL: age-only semaphore left .open" >&2; exit 1; }
[ ! -e "$AGE_OPEN.orphaned-zombie-no-pid" ] || { echo "FAIL: age-only semaphore was quarantined" >&2; exit 1; }
[ -d "$AGE_WORKTREE" ] || { echo "FAIL: age-only worktree was removed" >&2; exit 1; }
[ ! -e "$PUSH_MARKER" ] || { echo "FAIL: age-only route called isolate-push" >&2; exit 1; }
grep -q 'age cannot fence a writer' <<<"$AGE_OUT" || { echo "FAIL: age-only escalation was not explicit" >&2; exit 1; }
grep -q '"action":"escalated"' "$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl" || { echo "FAIL: age-only escalation was not recorded" >&2; exit 1; }

# A terminal-looking card does not upgrade an age-only/no-PID observation.
AGE_TERMINAL_WORKTREE="$MANAGED_WORKTREES/age-terminal"
write_card "$AGE_TERMINAL_WORKTREE" age-terminal harness-age-terminal WP-537 completed
AGE_TERMINAL_OPEN="$SESSION_DIR/kimi-age-terminal.open"
write_semaphore "$AGE_TERMINAL_OPEN" age-terminal age-terminal harness-age-terminal "$AGE_TERMINAL_WORKTREE"
run_sweep >/dev/null
[ -f "$AGE_TERMINAL_OPEN" ] || { echo "FAIL: terminal card let age-only route fence a writer" >&2; exit 1; }
[ ! -e "$PUSH_MARKER" ] || { echo "FAIL: age-only terminal card triggered publish" >&2; exit 1; }

# A dead PID proves owner absence, but not safe publication/removal.
DEAD_WORKTREE="$MANAGED_WORKTREES/dead-no-proof"
write_card "$DEAD_WORKTREE" dead-no-proof harness-dead WP-537 running
DEAD_OPEN="$SESSION_DIR/kimi-dead-no-proof.open"
write_semaphore "$DEAD_OPEN" dead-no-proof dead-no-proof harness-dead "$DEAD_WORKTREE" "$DEAD_PID"
DEAD_OUT=$(run_sweep)
[ -f "$DEAD_OPEN" ] || { echo "FAIL: generic dead PID removed the operational barrier" >&2; exit 1; }
[ ! -e "$DEAD_OPEN.orphaned-dead-pid" ] || { echo "FAIL: generic dead PID was quarantined without terminal proof" >&2; exit 1; }
[ -d "$DEAD_WORKTREE" ] || { echo "FAIL: generic dead-PID worktree was removed" >&2; exit 1; }
[ ! -e "$PUSH_MARKER" ] || { echo "FAIL: generic dead-PID route called isolate-push" >&2; exit 1; }
grep -q 'remains .open' <<<"$DEAD_OUT" || { echo "FAIL: generic dead-PID ambiguity was not surfaced" >&2; exit 1; }

# Even a terminal-looking ordinary session remains `.open`: sweep has no
# generation fence and therefore only escalates.  The same proof may be
# consumed later by the explicit recovery transaction after a controlled
# quarantine, never by the generic dead-PID classifier itself.
TERMINAL_WORKTREE="$MANAGED_WORKTREES/dead-terminal"
write_card "$TERMINAL_WORKTREE" dead-terminal harness-dead-terminal WP-537 completed
TERMINAL_OPEN="$SESSION_DIR/kimi-dead-terminal.open"
write_semaphore "$TERMINAL_OPEN" dead-terminal dead-terminal harness-dead-terminal "$TERMINAL_WORKTREE" "$DEAD_PID"
TERMINAL_OUT=$(run_sweep)
[ -f "$TERMINAL_OPEN" ] || { echo "FAIL: terminal-looking generic dead owner left .open" >&2; exit 1; }
[ ! -e "$TERMINAL_OPEN.orphaned-dead-pid" ] || { echo "FAIL: generic sweep consumed terminal proof without a recovery transaction" >&2; exit 1; }
[ ! -e "$PUSH_MARKER" ] || { echo "FAIL: generic terminal-looking route called isolate-push" >&2; exit 1; }
grep -q 'remains .open' <<<"$TERMINAL_OUT" || { echo "FAIL: terminal-looking generic ambiguity was not surfaced" >&2; exit 1; }

# Scheduled ownership is narrower: exact dead-owner drain proof freezes only.
rm -f "$PUSH_MARKER"
SCHEDULED_UUID=123e4567-e89b-42d3-a456-426614174000
SCHEDULED_WORKTREE="$MANAGED_WORKTREES/scheduled-drained"
mkdir -p "$SCHEDULED_WORKTREE"
SCHEDULED_OPEN="$SESSION_DIR/kimi-$SCHEDULED_UUID.open"
cat > "$SCHEDULED_OPEN" <<EOF
---
agent: kimi
wp: WP-537
slug: scheduled-drained
pid: $DEAD_PID
opened_at: 2026-09-11T20:00:00Z
created_at: 2026-09-11T20:00:00Z
session_id: $SCHEDULED_UUID
harness_session_id: harness-scheduled
isolated_worktree: $SCHEDULED_WORKTREE
close_path: pipeline
scheduled_owner: wp-run-scheduled-tsekh1/v1
scheduled_run_id: nightly-537
scheduled_drain_proof: process-group-empty/v1
scheduled_drain_session_id: $SCHEDULED_UUID
scheduled_drain_owner_pid: $DEAD_PID
scheduled_drain_run_id: nightly-537
scheduled_drain_at: 2026-09-11T20:01:00Z
---
EOF
run_sweep >/dev/null
SCHEDULED_FROZEN="$SCHEDULED_OPEN.orphaned-scheduled-drained"
[ -f "$SCHEDULED_FROZEN" ] || { echo "FAIL: exact scheduled drain was not frozen" >&2; exit 1; }
[ -d "$SCHEDULED_WORKTREE" ] || { echo "FAIL: scheduled freeze removed its worktree" >&2; exit 1; }
[ ! -e "$PUSH_MARKER" ] || { echo "FAIL: scheduled freeze published its worktree" >&2; exit 1; }

# A mismatched drain identity is not proof and must leave `.open` untouched.
MISMATCH_UUID=123e4567-e89b-42d3-a456-426614174001
MISMATCH_WORKTREE="$MANAGED_WORKTREES/scheduled-mismatch"
mkdir -p "$MISMATCH_WORKTREE"
MISMATCH_OPEN="$SESSION_DIR/kimi-$MISMATCH_UUID.open"
cat > "$MISMATCH_OPEN" <<EOF
---
agent: kimi
wp: WP-537
slug: scheduled-mismatch
pid: $DEAD_PID
opened_at: 2026-09-11T20:00:00Z
created_at: 2026-09-11T20:00:00Z
session_id: $MISMATCH_UUID
harness_session_id: harness-scheduled-mismatch
isolated_worktree: $MISMATCH_WORKTREE
close_path: pipeline
scheduled_owner: wp-run-scheduled-tsekh1/v1
scheduled_run_id: nightly-538
scheduled_drain_proof: process-group-empty/v1
scheduled_drain_session_id: $MISMATCH_UUID
scheduled_drain_owner_pid: 99999998
scheduled_drain_run_id: nightly-538
scheduled_drain_at: 2026-09-11T20:01:00Z
---
EOF
MISMATCH_OUT=$(run_sweep)
[ -f "$MISMATCH_OPEN" ] || { echo "FAIL: mismatched scheduled proof removed .open" >&2; exit 1; }
[ ! -e "$MISMATCH_OPEN.orphaned-scheduled-drained" ] || { echo "FAIL: mismatched scheduled proof froze semaphore" >&2; exit 1; }
grep -q 'exact drain proof is absent' <<<"$MISMATCH_OUT" || { echo "FAIL: mismatched scheduled proof was not escalated" >&2; exit 1; }

# Deterministic freeze/admission race: hold the old session's persistent lock,
# let sweep acquire the global admission lock and block behind it, then queue a
# same-WP scheduled open.  Releasing the session lock lets sweep publish the
# frozen hold while it still owns admission; the queued open must observe that
# hold and never publish a new generation.
RACE_UUID=223e4567-e89b-42d3-a456-426614174000
RACE_NEW_UUID=223e4567-e89b-42d3-a456-426614174001
RACE_WORKTREE="$MANAGED_WORKTREES/scheduled-race"
mkdir -p "$RACE_WORKTREE"
RACE_OPEN="$SESSION_DIR/kimi-$RACE_UUID.open"
cat > "$RACE_OPEN" <<EOF
---
agent: kimi
wp: WP-599
slug: scheduled-race
pid: $DEAD_PID
opened_at: 2026-09-11T20:00:00Z
created_at: 2026-09-11T20:00:00Z
session_id: $RACE_UUID
isolated_worktree: $RACE_WORKTREE
close_path: pipeline
scheduled_owner: wp-run-scheduled-tsekh1/v1
scheduled_run_id: nightly-race
scheduled_drain_proof: process-group-empty/v1
scheduled_drain_session_id: $RACE_UUID
scheduled_drain_owner_pid: $DEAD_PID
scheduled_drain_run_id: nightly-race
scheduled_drain_at: 2026-09-11T20:01:00Z
---
EOF
RACE_CANON=$(python3 -c 'import os,sys; p=sys.argv[1]; print(os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p)))' "$RACE_OPEN")
RACE_LOCK_ID=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$RACE_CANON")
TRANSITION_DIR="$TEST_ROOT/.iwe-runtime/session-transition-locks"
mkdir -p "$TRANSITION_DIR"
chmod 700 "$TRANSITION_DIR"
RACE_LOCK="$TRANSITION_DIR/$RACE_LOCK_ID.lock"
: > "$RACE_LOCK"
chmod 600 "$RACE_LOCK"
ADMISSION_LOCK="$TRANSITION_DIR/scheduled-quarantine-transition.lock"
: > "$ADMISSION_LOCK"
chmod 600 "$ADMISSION_LOCK"
FLOCK_TOOL=$(command -v flock)
exec 194<> "$RACE_LOCK"
"$FLOCK_TOOL" -x 194
run_sweep > "$TEST_ROOT/race-sweep.out" &
RACE_SWEEP_PID=$!
exec 193<> "$ADMISSION_LOCK"
RACE_GLOBAL_HELD=0
for _ in $(seq 1 100); do
  if "$FLOCK_TOOL" -xn 193; then
    "$FLOCK_TOOL" -u 193
    sleep 0.02
  else
    RACE_GLOBAL_HELD=1
    break
  fi
done
[ "$RACE_GLOBAL_HELD" -eq 1 ] \
  || { echo "FAIL: sweep did not acquire global admission lock in race fixture" >&2; exit 1; }
(
  set +e
  cd "$GOV"
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_SESSION_ID="$RACE_NEW_UUID" \
    /bin/bash "$GUARD" open --wp WP-599 --task race --slug scheduled-race-new \
    --agent kimi --owner-pid "$$" --close-path pipeline \
    --scheduled-owner wp-run-scheduled-tsekh1/v1 --scheduled-run-id nightly-race-new \
    > "$TEST_ROOT/race-open.out" 2>&1
  printf '%s\n' "$?" > "$TEST_ROOT/race-open.rc"
) &
RACE_OPEN_PID=$!
sleep 0.05
"$FLOCK_TOOL" -u 194
exec 194>&-
exec 193>&-
wait "$RACE_SWEEP_PID"
wait "$RACE_OPEN_PID"
[ -f "$RACE_OPEN.orphaned-scheduled-drained" ] \
  || { echo "FAIL: race sweep did not publish frozen quarantine" >&2; exit 1; }
[ "$(cat "$TEST_ROOT/race-open.rc")" -ne 0 ] \
  || { echo "FAIL: queued same-WP open crossed the freeze transition" >&2; exit 1; }
[ ! -e "$SESSION_DIR/kimi-$RACE_NEW_UUID.open" ] \
  || { echo "FAIL: queued same-WP open published a new generation" >&2; exit 1; }
grep -q 'same-WP frozen/pending quarantine' "$TEST_ROOT/race-open.out" \
  || { echo "FAIL: queued open did not report the authoritative frozen hold" >&2; exit 1; }

# recover-orphaned without terminal proof changes neither quarantine nor ledger.
RECOVERY_NO_PROOF_WORKTREE="$MANAGED_WORKTREES/recovery-no-proof"
write_card "$RECOVERY_NO_PROOF_WORKTREE" recovery-no-proof harness-recovery-no-proof WP-537 running
RECOVERY_NO_PROOF="$SESSION_DIR/kimi-recovery-no-proof.open.orphaned-dead-pid"
write_semaphore "$RECOVERY_NO_PROOF" recovery-no-proof recovery-no-proof harness-recovery-no-proof "$RECOVERY_NO_PROOF_WORKTREE" "$DEAD_PID"
if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_LEDGER_DIR="$LEDGER_ROOT" \
   /bin/bash "$GUARD" recover-orphaned "$(basename "$RECOVERY_NO_PROOF")" >/dev/null 2>&1; then
  echo "FAIL: recovery without terminal proof succeeded" >&2
  exit 1
fi
[ -f "$RECOVERY_NO_PROOF" ] || { echo "FAIL: recovery without proof changed quarantine" >&2; exit 1; }
[ ! -e "$RECOVERY_NO_PROOF.recovery-pending" ] && [ ! -e "$RECOVERY_NO_PROOF.recovered" ] || { echo "FAIL: recovery without proof created terminal state" >&2; exit 1; }
[ ! -d "$LEDGER_ROOT" ] || { echo "FAIL: recovery without proof touched ledger" >&2; exit 1; }

# A writer failure leaves a stable pending state; retry appends exactly once.
RECOVERY_WORKTREE="$MANAGED_WORKTREES/recovery-terminal"
write_card "$RECOVERY_WORKTREE" recovery-terminal harness-recovery-terminal WP-537 completed
RECOVERY_BASE="$SESSION_DIR/kimi-recovery-terminal.open.orphaned-dead-pid"
write_semaphore "$RECOVERY_BASE" recovery-terminal recovery-terminal harness-recovery-terminal "$RECOVERY_WORKTREE" "$DEAD_PID"
if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_LEDGER_DIR="$LEDGER_ROOT" IWE_TEST_LEDGER_FAIL=1 \
   /bin/bash "$GUARD" recover-orphaned "$(basename "$RECOVERY_BASE")" >/dev/null 2>&1; then
  echo "FAIL: injected ledger failure reported recovery success" >&2
  exit 1
fi
[ ! -e "$RECOVERY_BASE" ] && [ -f "$RECOVERY_BASE.recovery-pending" ] || { echo "FAIL: ledger failure did not retain recovery-pending" >&2; exit 1; }
[ ! -e "$RECOVERY_BASE.recovered" ] || { echo "FAIL: ledger failure marked quarantine recovered" >&2; exit 1; }

IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_LEDGER_DIR="$LEDGER_ROOT" \
  /bin/bash "$GUARD" recover-orphaned "$(basename "$RECOVERY_BASE")" >/dev/null
[ ! -e "$RECOVERY_BASE.recovery-pending" ] && [ -f "$RECOVERY_BASE.recovered" ] || { echo "FAIL: retry did not finish recovery" >&2; exit 1; }
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_LEDGER_DIR="$LEDGER_ROOT" \
  /bin/bash "$GUARD" recover-orphaned "$(basename "$RECOVERY_BASE")" >/dev/null
RECOVERY_EVENT_COUNT=$(python3 - "$LEDGER_ROOT" <<'PY'
import json
import os
import sys

count = 0
for directory, _, files in os.walk(os.path.join(sys.argv[1], "day")):
    for name in files:
        if not name.endswith(".yaml"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as source:
            document = json.load(source)
        count += sum(event.get("kind") == "session_recovered_closed" for event in document.get("events", []))
print(count)
PY
)
[ "$RECOVERY_EVENT_COUNT" -eq 1 ] || { echo "FAIL: recovery retry wrote $RECOVERY_EVENT_COUNT terminal events" >&2; exit 1; }

# Kimi and other non-Claude runtimes legitimately have no harness_session_id.
# The guard's own runtime-neutral session_id is the terminal-card owner in
# that shape and must be sufficient for exact proof/recovery.
KIMI_SESSION=123e4567-e89b-42d3-a456-426614174099
KIMI_RECOVERY_WORKTREE="$MANAGED_WORKTREES/recovery-kimi-no-harness"
write_card "$KIMI_RECOVERY_WORKTREE" recovery-kimi-no-harness "$KIMI_SESSION" WP-537 completed
KIMI_RECOVERY_BASE="$SESSION_DIR/kimi-$KIMI_SESSION.open.orphaned-dead-pid"
write_semaphore "$KIMI_RECOVERY_BASE" recovery-kimi-no-harness "$KIMI_SESSION" "" \
  "$KIMI_RECOVERY_WORKTREE" "$DEAD_PID"
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_LEDGER_DIR="$LEDGER_ROOT" \
  /bin/bash "$GUARD" recover-orphaned "$(basename "$KIMI_RECOVERY_BASE")" >/dev/null
[ ! -e "$KIMI_RECOVERY_BASE" ] && [ -f "$KIMI_RECOVERY_BASE.recovered" ] \
  || { echo "FAIL: runtime-neutral Kimi recovery without harness id did not finish" >&2; exit 1; }

# Duplicate identity is ambiguous and fails before any state transition.
DUPLICATE_WORKTREE="$MANAGED_WORKTREES/recovery-duplicate"
write_card "$DUPLICATE_WORKTREE" recovery-duplicate harness-recovery-duplicate WP-537 completed
DUPLICATE_BASE="$SESSION_DIR/kimi-recovery-duplicate.open.orphaned-dead-pid"
write_semaphore "$DUPLICATE_BASE" recovery-duplicate recovery-duplicate harness-recovery-duplicate "$DUPLICATE_WORKTREE" "$DEAD_PID"
printf '%s\n' 'session_id: second-identity' >> "$DUPLICATE_BASE"
if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_LEDGER_DIR="$LEDGER_ROOT" \
   /bin/bash "$GUARD" recover-orphaned "$(basename "$DUPLICATE_BASE")" >/dev/null 2>&1; then
  echo "FAIL: duplicate recovery identity succeeded" >&2
  exit 1
fi
[ -f "$DUPLICATE_BASE" ] && [ ! -e "$DUPLICATE_BASE.recovery-pending" ] || { echo "FAIL: duplicate recovery identity mutated quarantine" >&2; exit 1; }

# Housekeeping uses the same persistent authority locks as regular sessions.
# A second open cannot reclaim by age/PID, an alias of IWE_ROOT resolves to the
# same lock, close removes only its identity-bound lease (not another current
# pointer), and a completed exact receipt may then be retired for a new UUID.
HK_REASON=orphan-smoke-housekeeping
HK_FILE="$SESSION_DIR/kimi-housekeeping-$HK_REASON.open"
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  /bin/bash "$GUARD" open --housekeeping "$HK_REASON" --agent kimi >/dev/null
HK_FIRST_SESSION=$(sed -n 's/^session_id: //p' "$HK_FILE")
python3 - "$HK_FIRST_SESSION" <<'PY'
import sys
import uuid
value = uuid.UUID(sys.argv[1])
assert value.version == 4 and str(value) == sys.argv[1]
PY
HK_BEFORE=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$HK_FILE")
if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
   /bin/bash "$GUARD" open --housekeeping "$HK_REASON" --agent kimi >/dev/null 2>&1; then
  echo "FAIL: repeated housekeeping open reclaimed an active barrier" >&2
  exit 1
fi
[ "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$HK_FILE")" = "$HK_BEFORE" ] \
  || { echo "FAIL: rejected housekeeping re-entry rewrote its semaphore" >&2; exit 1; }

cat > "$HK_FILE.lease" <<EOF
renewed_at: 2026-09-12T00:00:00Z
session_id: $HK_FIRST_SESSION
EOF
printf '%s\n' "$SESSION_DIR/kimi-foreign-generation.open" > "$SESSION_DIR/current-kimi.ptr"
IWE_ROOT_ALIAS="$TEST_ROOT/root-alias"
ln -s . "$IWE_ROOT_ALIAS"
CANON_HK_FILE=$(python3 -c 'import os,sys; p=sys.argv[1]; print(os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p)))' "$HK_FILE")
HK_LOCK_ID=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$CANON_HK_FILE")
HK_LOCK_FILE="$TEST_ROOT/.iwe-runtime/session-transition-locks/$HK_LOCK_ID.lock"
FLOCK_TOOL=$(command -v flock)
exec 194<> "$HK_LOCK_FILE"
"$FLOCK_TOOL" -x 194
if (cd "$IWE_ROOT_ALIAS/DS-strategy" && IWE_ROOT="$IWE_ROOT_ALIAS" \
    IWE_GOVERNANCE_REPO=DS-strategy IWE_SESSION_TRANSITION_WAIT_SEC=0 \
    /bin/bash "$GUARD" close --housekeeping "$HK_REASON" --agent kimi \
    >/dev/null 2>&1); then
  echo "FAIL: IWE_ROOT alias acquired a second lock for the same housekeeping semaphore" >&2
  exit 1
fi
[ -f "$HK_FILE" ] || { echo "FAIL: alias lock collision removed housekeeping .open" >&2; exit 1; }
"$FLOCK_TOOL" -u 194
exec 194>&-
(cd "$IWE_ROOT_ALIAS/DS-strategy" && IWE_ROOT="$IWE_ROOT_ALIAS" \
  IWE_GOVERNANCE_REPO=DS-strategy /bin/bash "$GUARD" close \
  --housekeeping "$HK_REASON" --agent kimi >/dev/null)
[ ! -e "$HK_FILE" ] && [ -f "$HK_FILE.closed" ] && [ ! -e "$HK_FILE.lease" ] \
  || { echo "FAIL: exact housekeeping close did not finish projection-safe transition" >&2; exit 1; }
grep -qF "$SESSION_DIR/kimi-foreign-generation.open" "$SESSION_DIR/current-kimi.ptr" \
  || { echo "FAIL: housekeeping close removed a foreign current pointer" >&2; exit 1; }

IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  /bin/bash "$GUARD" open --housekeeping "$HK_REASON" --agent kimi >/dev/null
HK_SECOND_SESSION=$(sed -n 's/^session_id: //p' "$HK_FILE")
[ "$HK_SECOND_SESSION" != "$HK_FIRST_SESSION" ] && [ ! -e "$HK_FILE.closed" ] \
  || { echo "FAIL: housekeeping generation did not retire exact receipt/create a fresh UUID" >&2; exit 1; }
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  /bin/bash "$GUARD" close --housekeeping "$HK_REASON" --agent kimi >/dev/null

# A configured missing flock prerequisite is a hard diagnostic failure and
# never falls back to the reclaimable historical mkdir/TTL authority.
MISSING_FLOCK_REASON=missing-flock
if IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
   IWE_FLOCK_BIN=/definitely/missing/flock /bin/bash "$GUARD" open \
   --housekeeping "$MISSING_FLOCK_REASON" --agent kimi >/dev/null 2>&1; then
  echo "FAIL: housekeeping mutation succeeded without trusted flock" >&2
  exit 1
fi
[ ! -e "$SESSION_DIR/kimi-housekeeping-$MISSING_FLOCK_REASON.open" ] \
  || { echo "FAIL: missing-flock failure published a housekeeping semaphore" >&2; exit 1; }

# A wrapper is allowed to replace itself with the final guard command.  Then
# its advertised owner PID is the guard's own PID, not a PPID-chain member.
TAIL_EXEC_SESSION=heartbeat-tail-exec
TAIL_EXEC_SEM="$SESSION_DIR/kimi-$TAIL_EXEC_SESSION.open"
printf '%s\n' '---' 'agent: kimi' "session_id: $TAIL_EXEC_SESSION" '---' > "$TAIL_EXEC_SEM"
(
  owner_pid=$$
  exec env IWE_ROOT="$TEST_ROOT" /bin/bash "$GUARD" heartbeat --agent kimi \
    --session-id "$TAIL_EXEC_SESSION" --owner-pid "$owner_pid"
) >/dev/null
grep -q '^heartbeat_at: ' "$TAIL_EXEC_SEM" \
  || { echo "FAIL: tail-exec owner PID was accepted without recording heartbeat" >&2; exit 1; }
rm -f "$TAIL_EXEC_SEM"

# A per-agent current pointer is only a projection.  Neither heartbeat caller
# may guess one generation when two matching `.open` semaphores coexist.
HEARTBEAT_A="$SESSION_DIR/kimi-heartbeat-a.open"
HEARTBEAT_B="$SESSION_DIR/kimi-heartbeat-b.open"
printf '%s\n' '---' 'agent: kimi' 'session_id: heartbeat-a' '---' > "$HEARTBEAT_A"
printf '%s\n' '---' 'agent: kimi' 'session_id: heartbeat-b' '---' > "$HEARTBEAT_B"
printf '%s\n' "$HEARTBEAT_A" > "$SESSION_DIR/current-kimi.ptr"
if IWE_ROOT="$TEST_ROOT" /bin/bash "$ROOT_DIR/scripts/agent-heartbeat.sh" \
   --agent kimi >/dev/null 2>&1; then
  echo "FAIL: one-shot heartbeat guessed the current pointer with two open generations" >&2
  exit 1
fi
if IWE_ROOT="$TEST_ROOT" /bin/bash "$ROOT_DIR/scripts/kimi-auto-heartbeat.sh" \
   --interval 1 >/dev/null 2>&1; then
  echo "FAIL: auto-heartbeat guessed one of two open generations" >&2
  exit 1
fi
rm -f "$HEARTBEAT_A" "$HEARTBEAT_B" "$SESSION_DIR/current-kimi.ptr"

echo "PASS: orphan ownership transitions require exact terminal or scheduled-drain proof"
echo "PASS: housekeeping transitions share persistent alias-safe locks and fail closed without flock"
echo "PASS: heartbeat callers fail closed on ambiguous session projections"
