#!/usr/bin/env bash
# Regression (WP-484 Ф343, peer-session 2026-11-27-10): the sweep's one-time
# escalation for a dead interactive owner waits until the death proof can be
# decided (lease expiry), and once proven it names the exact `heal` cure
# instead of "nothing to do". An already-reported semaphore is counted, not
# re-printed every pass. `markers` reports owner, work and allowed action
# without touching anything.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-escalation-proof.XXXXXX")
SLEEPER_PID=""
trap '[ -n "$SLEEPER_PID" ] && kill "$SLEEPER_PID" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
REGISTRY="$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl"
export DS_PUBLISH_DIGEST_DIR="$TEST_ROOT/notify-digest"   # never the pilot's real digest
export IWE_SESSIONS_ROOT="$GOV/sessions"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin" "$TEST_ROOT/scripts"
git -C "$GOV" init -q
ln -s "$ROOT_DIR/scripts/open-log-snapshot.sh" "$TEST_ROOT/scripts/open-log-snapshot.sh"
cat > "$TEST_ROOT/bin/iwe-tg" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_ROOT/iwe-tg.log"
EOF
chmod +x "$TEST_ROOT/bin/iwe-tg"

fail() { echo "FAIL: $*" >&2; exit 1; }

guard() {  # <subcommand> [args...]
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_ZOMBIE_ESCALATE_SEC=1 IWE_HEARTBEAT_STALE_SEC=600 \
    PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" "$@" 2>&1
}

write_semaphore() {  # <path> <session id> <opened_at> [pid]; agent comes from the file name
  local agent
  agent=$(basename -- "$1"); agent="${agent%%-"$2".open}"
  {
    echo "---"
    echo "agent: $agent"
    echo "wp: WP-484"
    echo "slug: slug-$2"
    echo "opened_at: $3"
    echo "created_at: $3"
    echo "session_id: $2"
    echo "task: fixture $2"
    echo "host: $(uname -n)"
    echo "isolated_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/$2"
    [ -n "${4:-}" ] && echo "pid: $4"
    echo "---"
  } > "$1"
}

DEAD_PID=99999999
kill -0 "$DEAD_PID" 2>/dev/null && fail "fixture PID unexpectedly exists: $DEAD_PID"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD_ISO="2000-01-01T00:00:00Z"

# 1. Dead pid, lease still valid: nothing escalated yet, the mark is surfaced.
FRESH="$SESSION_DIR/claude-code-fresh-dead.open"
write_semaphore "$FRESH" fresh-dead "$NOW_ISO" "$DEAD_PID"
OUT=$(guard audit --cleanup-orphans) || fail "guard audit --cleanup-orphans failed: $OUT"
grep -q 'claude-code-fresh-dead.open remains .open' <<<"$OUT" || fail "lease-valid dead mark not surfaced: $OUT"
grep -q 'escalation waits until the death proof can be decided' <<<"$OUT" || fail "deferral reason not printed: $OUT"
if [ -f "$REGISTRY" ] && grep -q 'claude-code-fresh-dead.open' "$REGISTRY"; then
  fail "escalation recorded while the lease was still valid"
fi
rm -f "$FRESH"

# 2. Dead pid, lease expired, copy gone: proven -> the notice names the cure.
PROVEN="$SESSION_DIR/claude-code-proven-dead.open"
write_semaphore "$PROVEN" proven-dead "$OLD_ISO" "$DEAD_PID"
OUT=$(guard audit --cleanup-orphans) || fail "guard audit --cleanup-orphans failed: $OUT"
[ -f "$PROVEN" ] || fail "the sweep removed the mark; it must only report it"
grep -q '"action":"escalated"' "$REGISTRY" || fail "proven escalation not recorded"
grep -q 'сними мёртвую сессию proven-dead' "$DS_PUBLISH_DIGEST_DIR"/*.jsonl \
  || fail "proven notice lacks the phrase for the agent: $(cat "$DS_PUBLISH_DIGEST_DIR"/*.jsonl)"
grep -q 'session-guard.sh heal proven-dead --apply' "$DS_PUBLISH_DIGEST_DIR"/*.jsonl \
  || fail "proven notice lacks the exact heal command"
if grep -q 'Делать ничего не нужно' "$DS_PUBLISH_DIGEST_DIR"/*.jsonl; then
  fail "proven notice still says nothing needs to be done"
fi
grep -q 'claude-code-proven-dead.open remains .open' <<<"$OUT" || fail "first pass did not print the warning"

# 3. The next pass counts the reported mark but does not print it again.
OUT=$(guard audit --cleanup-orphans) || fail "guard audit --cleanup-orphans failed: $OUT"
if grep -q 'claude-code-proven-dead.open remains .open' <<<"$OUT"; then
  fail "an already-reported dead mark was printed again"
fi
grep -q 'ambiguous=1' <<<"$OUT" || fail "an already-reported dead mark is no longer counted: $OUT"
[ "$(grep -c 'claude-code-proven-dead.open' "$REGISTRY")" -eq 1 ] || fail "escalation recorded twice"

# 4. A mark without pid: printed until and on its first report, then only counted.
NOPID="$SESSION_DIR/kimi-nopid.open"
write_semaphore "$NOPID" nopid "$OLD_ISO"
OUT=$(guard audit --cleanup-orphans) || fail "guard audit --cleanup-orphans failed: $OUT"
grep -q 'kimi-nopid.open is .* without owner PID' <<<"$OUT" || fail "pid-less mark not printed on its first report"
OUT=$(guard audit --cleanup-orphans) || fail "guard audit --cleanup-orphans failed: $OUT"
if grep -q 'kimi-nopid.open is .* without owner PID' <<<"$OUT"; then
  fail "an already-reported pid-less mark was printed again"
fi
grep -q 'ambiguous=2' <<<"$OUT" || fail "pid-less and dead marks are not both counted: $OUT"

# 5. `markers`: one row per mark with owner, work and the allowed action;
#    nothing on disk changes.
sleep 300 & SLEEPER_PID=$!
LIVE="$SESSION_DIR/claude-code-live.open"
write_semaphore "$LIVE" live "$NOW_ISO" "$SLEEPER_PID"
BEFORE=$(ls -la "$SESSION_DIR"; cat "$SESSION_DIR"/*.open "$REGISTRY")
OUT=$(guard markers) || fail "guard markers failed: $OUT"
AFTER=$(ls -la "$SESSION_DIR"; cat "$SESSION_DIR"/*.open "$REGISTRY")
[ "$BEFORE" = "$AFTER" ] || fail "markers changed files on disk"
grep -A3 'claude-code-proven-dead.open' <<<"$OUT" | grep -q 'владелец: мёртв, доказано' || fail "proven row wrong: $OUT"
grep -A3 'claude-code-proven-dead.open' <<<"$OUT" | grep -q 'действие: снять без решения пилота: session-guard.sh heal proven-dead --apply' \
  || fail "proven row lacks the heal action: $OUT"
grep -A3 'kimi-nopid.open' <<<"$OUT" | grep -q 'владелец: не проверить' || fail "pid-less row wrong: $OUT"
grep -A3 'claude-code-live.open' <<<"$OUT" | grep -q 'действие: не трогать' || fail "live row wrong: $OUT"
grep -q 'Итого открытых отметок на .*: 3 (владелец жив 1, мёртв доказанно 1, не проверить 1)' <<<"$OUT" \
  || fail "summary line wrong: $OUT"

# 6. Proven death but unsaved work in the copy: heal would ask the pilot's
#    code, so the notice asks to pick the work up first, not "no decision".
DIRTY_WT="$TEST_ROOT/.iwe-runtime/isolated-worktrees/dirty-dead"
mkdir -p "$DIRTY_WT"; git -C "$DIRTY_WT" init -q
git -C "$DIRTY_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$DIRTY_WT" update-ref refs/remotes/origin/main HEAD
echo draft > "$DIRTY_WT/note.md"
DIRTY="$SESSION_DIR/claude-code-dirty-dead.open"
write_semaphore "$DIRTY" dirty-dead "$OLD_ISO" "$DEAD_PID"
guard audit --cleanup-orphans >/dev/null || fail "audit failed on the dirty-copy mark"
grep -q 'подбери работу мёртвой сессии dirty-dead' "$TEST_ROOT/iwe-tg.log" \
  || fail "dirty proven notice does not ask to pick the work up: $(cat "$TEST_ROOT/iwe-tg.log" 2>/dev/null)"
if grep -q 'сними мёртвую сессию dirty-dead' "$TEST_ROOT/iwe-tg.log"; then
  fail "dirty proven notice promises removal without the pilot's decision"
fi
OUT=$(guard markers) || fail "guard markers failed: $OUT"
grep -A3 'claude-code-dirty-dead.open' <<<"$OUT" | grep -q 'действие: сначала подобрать и опубликовать работу' \
  || fail "dirty proven row does not ask to publish first: $OUT"
rm -f "$DIRTY"

# 7. Dead pid, expired lease, fresh heartbeat: deferred like a valid lease.
BEAT="$SESSION_DIR/claude-code-beat-dead.open"
write_semaphore "$BEAT" beat-dead "$OLD_ISO" "$DEAD_PID"
awk -v hb="$NOW_ISO" '{ print } /^pid: / { print "heartbeat_at: " hb }' "$BEAT" > "$BEAT.tmp"
mv "$BEAT.tmp" "$BEAT"
OUT=$(guard audit --cleanup-orphans) || fail "guard audit failed: $OUT"
grep -q 'is fresh; escalation waits until the death proof can be decided; claude-code-beat-dead.open remains .open' <<<"$OUT" \
  || fail "fresh heartbeat did not defer the escalation: $OUT"
if grep -q 'claude-code-beat-dead.open' "$REGISTRY"; then
  fail "escalation recorded while the heartbeat was fresh"
fi

echo "PASS: dead-owner escalation waits for the lease or a fresh heartbeat and names the heal cure once proven (pick-up first when work is unsaved); reported marks are counted, not re-printed; markers reports without changing anything"
