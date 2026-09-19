#!/usr/bin/env bash
# Regression (WP-530 Ф53): the opt-in terminal path for dead interactive
# semaphores. Without the flag nothing changes. With it, a semaphore is renamed
# to .open.orphaned-dead-interactive only when its pid is gone on this host,
# the lease has expired and no fresh heartbeat exists; every other case stays
# .open. The file body survives the rename and the decision is recorded.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-dead-interactive.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
REGISTRY="$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl"
TG_LOG="$TEST_ROOT/iwe-tg.log"
export IWE_SESSIONS_ROOT="$GOV/sessions"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin"
git -C "$GOV" init -q

cat > "$TEST_ROOT/bin/iwe-tg" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TG_LOG"
exit 0
EOF
chmod +x "$TEST_ROOT/bin/iwe-tg"

run_audit() {  # [extra audit flags...]
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_ZOMBIE_ESCALATE_SEC=1 IWE_HEARTBEAT_STALE_SEC="${IWE_HEARTBEAT_STALE_SEC:-600}" \
    PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" audit "$@" 2>&1
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_semaphore() {  # <path> <session> <pid> [extra frontmatter lines...]
  local path="$1" session="$2" pid="$3"
  shift 3
  {
    echo "---"
    echo "agent: claude-code"
    echo "wp: WP-530"
    echo "slug: $session"
    echo "opened_at: 2000-01-01T00:00:00Z"
    echo "created_at: 2000-01-01T00:00:00Z"
    echo "session_id: $session"
    echo "governance_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/$session"
    echo "isolated_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/$session"
    echo "pid: $pid"
    for line in "$@"; do echo "$line"; done
    echo "---"
    echo "file: inbox/WP-530/WP-530.md"
  } > "$path"
}

DEAD_PID=99999999
if kill -0 "$DEAD_PID" 2>/dev/null; then
  echo "FAIL: fixture PID unexpectedly exists: $DEAD_PID" >&2
  exit 1
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

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

# 1. Without the flag a dead, lease-expired semaphore keeps today's behaviour:
#    escalate only, file stays .open.
BASE="$SESSION_DIR/claude-code-dead-base.open"
write_semaphore "$BASE" dead-base "$DEAD_PID"
OUT=$(run_audit --cleanup-orphans)
[ -f "$BASE" ] || fail "without the flag the semaphore left .open"
[ ! -e "$BASE.orphaned-dead-interactive" ] || fail "without the flag the semaphore was quarantined"
grep -q 'dead_quarantined=0' <<<"$OUT" || fail "sweep summary missing dead_quarantined=0 without the flag"
grep -q '"action":"escalated"' "$REGISTRY" || fail "escalation was not recorded without the flag"

# 2. With the flag the same semaphore is quarantined: renamed, body intact,
#    registry action recorded, human notice sent, no other file created.
BODY_BEFORE=$(cat "$BASE")
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
[ ! -e "$BASE" ] || fail "quarantined semaphore still present as .open"
[ -f "$BASE.orphaned-dead-interactive" ] || fail "quarantine destination missing"
[ "$(cat "$BASE.orphaned-dead-interactive")" = "$BODY_BEFORE" ] || fail "semaphore body changed during quarantine"
grep -q 'dead_quarantined=1' <<<"$OUT" || fail "sweep summary did not count the quarantine"
grep -q '^QUARANTINED: claude-code-dead-base.open -> claude-code-dead-base.open.orphaned-dead-interactive' <<<"$OUT" \
  || fail "quarantine line not printed: $OUT"
grep -q '"action":"quarantined"' "$REGISTRY" || fail "quarantine was not recorded in the zombie registry"
grep -q 'dead_interactive_owner_proven:pid=99999999:lease_expired=' "$REGISTRY" || fail "quarantine reason lacks the proof fields"
grep -q 'переведена в карантин' "$TG_LOG" || fail "human notice about the quarantine was not sent"
grep -q "isolated-worktrees/dead-base" "$TG_LOG" || fail "notice does not name the retained worktree"

# 3. A quarantined semaphore no longer shows up as an active session: at this
#    point it is the only semaphore in the directory, so the whole "active
#    sessions" block must be absent from a plain audit.
OUT=$(run_audit)
! grep -q 'Активные сессии без close' <<<"$OUT" || fail "quarantined semaphore still counted as an active session"
! grep -q 'claude-code-dead-base' <<<"$OUT" || fail "quarantined semaphore still mentioned by a plain audit"

# 4. Dead pid but a fresh lease: stays .open.
FRESH_LEASE="$SESSION_DIR/claude-code-fresh-lease.open"
write_semaphore "$FRESH_LEASE" fresh-lease "$DEAD_PID"
printf 'renewed_at: %s\nsession_id: fresh-lease\n' "$(now_iso)" > "$FRESH_LEASE.lease"
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
[ -f "$FRESH_LEASE" ] || fail "fresh-lease semaphore was not left .open"
grep -q 'lease still valid' <<<"$OUT" || fail "fresh-lease refusal reason not reported"

# 5. Dead pid, expired lease, but a fresh heartbeat: stays .open.
FRESH_HB="$SESSION_DIR/claude-code-fresh-heartbeat.open"
write_semaphore "$FRESH_HB" fresh-heartbeat "$DEAD_PID" "heartbeat_at: $(now_iso)" "heartbeat_pid: $DEAD_PID"
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
[ -f "$FRESH_HB" ] || fail "fresh-heartbeat semaphore was not left .open"
grep -q 'heartbeat .* is fresh' <<<"$OUT" || fail "fresh-heartbeat refusal reason not reported"

# 6. Live pid: never quarantined, whatever the lease says.
LIVE="$SESSION_DIR/claude-code-live.open"
write_semaphore "$LIVE" live "$$"
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
[ -f "$LIVE" ] || fail "live semaphore was not left .open"
[ ! -e "$LIVE.orphaned-dead-interactive" ] || fail "live semaphore was quarantined"

# 7. Recorded on another host: not ours to judge, stays .open.
FOREIGN="$SESSION_DIR/claude-code-foreign-host.open"
write_semaphore "$FOREIGN" foreign-host "$DEAD_PID" "host: other-host.invalid"
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
[ -f "$FOREIGN" ] || fail "foreign-host semaphore was not left .open"
grep -q 'recorded host other-host.invalid is not' <<<"$OUT" || fail "foreign-host refusal reason not reported"

# 8. The flag outside audit --cleanup-orphans is an error, never silently ignored.
if OUT=$(run_audit --quarantine-dead-interactive); then
  fail "flag without --cleanup-orphans was accepted"
fi
grep -q 'применим только к audit --cleanup-orphans' <<<"$OUT" || fail "wrong diagnostic for the misplaced flag: $OUT"

# 9. Stale heartbeat, expired lease file and matching host: quarantined, and the
#    .lease sibling survives the rename as evidence.
STALE="$SESSION_DIR/claude-code-stale-heartbeat.open"
write_semaphore "$STALE" stale-heartbeat "$DEAD_PID" "host: $(hostname)" "heartbeat_at: 2000-01-01T00:10:00Z" "heartbeat_pid: $DEAD_PID"
printf 'renewed_at: 2000-01-01T00:20:00Z\nsession_id: stale-heartbeat\n' > "$STALE.lease"
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
[ -f "$STALE.orphaned-dead-interactive" ] || fail "stale-heartbeat semaphore was not quarantined: $OUT"
[ -f "$STALE.lease" ] || fail ".lease sibling did not survive the quarantine rename"
grep -q 'heartbeat=2000-01-01T00:10:00Z' "$REGISTRY" || fail "registry reason lacks the stale heartbeat timestamp"

# 10. A non-numeric threshold is refused up front instead of silently skipping
#     the fresh-heartbeat check.
if OUT=$(IWE_HEARTBEAT_STALE_SEC=abc run_audit --cleanup-orphans --quarantine-dead-interactive); then
  fail "non-numeric IWE_HEARTBEAT_STALE_SEC was accepted"
fi
grep -q 'IWE_HEARTBEAT_STALE_SEC должен быть целым' <<<"$OUT" || fail "wrong diagnostic for a non-numeric threshold: $OUT"

# 11. A SIGKILL after the quarantine rename and durable pending write, but
#     before the registry append, must rebuild the missing audit record on the
#     next pass. The renamed semaphore is no longer discoverable as *.open, so
#     recovery has to come from the pending record itself.
KILL_CASE="$SESSION_DIR/claude-code-kill-quarantine.open"
write_semaphore "$KILL_CASE" kill-quarantine "$DEAD_PID" "host: $(hostname)"
REACHED="$TEST_ROOT/reached-after-quarantine-pending"
RELEASE="$TEST_ROOT/release-quarantine-python"
write_pausing_python3 'message=message,' "$REACHED" "$RELEASE"
: > "$TG_LOG"
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_ZOMBIE_ESCALATE_SEC=1 \
  IWE_HEARTBEAT_STALE_SEC=600 PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" \
  audit --cleanup-orphans --quarantine-dead-interactive >"$TEST_ROOT/kill-quarantine.log" 2>&1 &
AUDIT_PID=$!
waited=0
while [ ! -e "$REACHED" ] && [ "$waited" -lt 500 ]; do sleep 0.01; waited=$((waited + 1)); done
[ -e "$REACHED" ] || { kill -9 "$AUDIT_PID" 2>/dev/null || true; fail "did not reach quarantine pending-write window"; }
[ -f "$KILL_CASE.orphaned-dead-interactive" ] || fail "quarantine rename did not happen before pending write"
grep -qF "\"semaphore\":\"$KILL_CASE\"" "$REGISTRY" 2>/dev/null \
  && fail "registry already contained killed quarantine before intended window"
kill -9 "$AUDIT_PID" 2>/dev/null || true
wait "$AUDIT_PID" 2>/dev/null || true
touch "$RELEASE"
rm -f "$TEST_ROOT/bin/python3"
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
grep -q 'kill-quarantine' "$TG_LOG" || fail "pending quarantine notification was not recovered"
grep -qF "\"semaphore\":\"$KILL_CASE\"" "$REGISTRY" \
  || fail "terminal quarantine was delivered after SIGKILL but its audit record was never recovered"
grep -q '"audit_recovered":true' "$REGISTRY" || fail "recovered quarantine audit record lacks its recovery marker"

# 12. `open` records host: and pid_start: for the owner pid.
OUT=$( cd "$GOV" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
  PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" open --wp WP-530 --agent claude-code --owner-pid "$$" \
  --slug open-fields-smoke --task "open fields smoke" 2>&1 ) || fail "open failed in the fixture: $OUT"
OPEN_SEM=$(grep -o 'Session OPEN: [^ ]*' <<<"$OUT" | awk '{print $3}')
[ -f "$OPEN_SEM" ] || fail "open did not report its semaphore path: $OUT"
grep -q "^host: $(hostname)$" "$OPEN_SEM" || fail "open did not record host:"
grep -qE '^pid_start: [^ ].*[^ ]$' "$OPEN_SEM" || fail "open did not record a trimmed pid_start:"

echo "PASS: dead interactive semaphores are quarantined only with the flag and only on full liveness proof; body, lease and worktree retained"
