#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# iwe-verified-sync-smoke.sh — behavioural coverage for scripts/iwe-verified-sync.sh
# (WP-545 Ф12). Drives the REAL script against a synthetic bare "origin" and a
# clone in a temp dir, with curl stubbed on PATH so alerts are captured instead
# of sent. Every check asserts an observable result (exit code, state field,
# HEAD, captured alert) — never the absence of an error alone.
#
# Usage: bash scripts/tests/iwe-verified-sync-smoke.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$REPO_ROOT/scripts/iwe-verified-sync.sh"
[ -f "$SUT" ] || { echo "не найден проверяемый скрипт: $SUT"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — факт: ${2:-нет данных}"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/iwe-verified-sync-smoke.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# curl stub: append the text= payload to a capture file, exit 0.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--data-urlencode" ]; then j=$((i+1)); echo "${!j#text=}" >> "$ALERT_CAPTURE"; fi
done
exit 0
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export ALERT_CAPTURE="$WORK/alerts.log"
export TELEGRAM_BOT_TOKEN=stub TELEGRAM_CHAT_ID=stub
export IWE_VERIFIED_SYNC_STATE_DIR="$WORK/state"
export IWE_VERIFIED_SYNC_LOCK="$WORK/git-ops.lock"
export IWE_VERIFIED_SYNC_ALERT_TTL_MIN=240
export IWE_VERIFIED_SYNC_DIRTY_GRACE_SEC=0
export IWE_VERIFIED_SYNC_FETCH_RETRY_SEC=0
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@test GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@test

# --- fixture: bare origin + author clone + server clone ----------------------
git init -q --bare -b main "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/author" 2>/dev/null
echo one > "$WORK/author/f"; git -C "$WORK/author" add f; git -C "$WORK/author" commit -qm c1
git -C "$WORK/author" push -q origin main
git clone -q "$WORK/origin.git" "$WORK/server" 2>/dev/null
SERVER="$WORK/server"

sync_it()  { bash "$SUT" sync --repo "$SERVER" --branch main --state demo; }
fresh_it() { bash "$SUT" fresh --repo "$SERVER" --branch main --state demo "$@"; }
state_get() { grep -E "^$1=" "$WORK/state/demo.state" | cut -d= -f2-; }
alerts() { [ -f "$ALERT_CAPTURE" ] && cat "$ALERT_CAPTURE" || true; }

echo "1. sync on an up-to-date clone → ok, state status=ok, sha==HEAD"
if sync_it 2>/dev/null && [ "$(state_get status)" = ok ] && [ "$(state_get sha)" = "$(git -C "$SERVER" rev-parse HEAD)" ]; then ok "fresh clone → status=ok"; else bad "fresh clone → status=ok" "$(cat "$WORK/state/demo.state" 2>/dev/null)"; fi

echo "2. fresh gate passes right after a successful sync"
if fresh_it 2>/dev/null; then ok "fresh → exit 0"; else bad "fresh → exit 0"; fi

echo "3. origin advances by 2 commits → sync fast-forwards, HEAD == origin/main"
echo two > "$WORK/author/f"; git -C "$WORK/author" commit -qam c2
echo three > "$WORK/author/f"; git -C "$WORK/author" commit -qam c3
git -C "$WORK/author" push -q origin main
EXPECT=$(git -C "$WORK/author" rev-parse HEAD)
if sync_it 2>/dev/null && [ "$(git -C "$SERVER" rev-parse HEAD)" = "$EXPECT" ] && [ "$(state_get upstream_sha)" = "$EXPECT" ]; then ok "ff-only advance"; else bad "ff-only advance" "HEAD=$(git -C "$SERVER" rev-parse --short HEAD) expect=${EXPECT:0:7}"; fi

echo "4. dirty tree → refused, HEAD unchanged, previous success kept, alert sent once"
PREV_OK=$(state_get last_success_ts)
echo local > "$SERVER/f"
echo four > "$WORK/author/f"; git -C "$WORK/author" commit -qam c4; git -C "$WORK/author" push -q origin main
sync_it 2>/dev/null; RC=$?
if [ "$RC" = 1 ] && [ "$(state_get status)" = refused ] && [ "$(state_get last_success_ts)" = "$PREV_OK" ] && [ "$(git -C "$SERVER" rev-parse HEAD)" = "$EXPECT" ]; then ok "dirty → refused, provenance kept"; else bad "dirty → refused" "rc=$RC status=$(state_get status)"; fi
if [ "$(alerts | grep -c 'в рабочей копии есть локальные правки')" = 1 ]; then ok "one dirty alert"; else bad "one dirty alert" "$(alerts)"; fi
sync_it 2>/dev/null; RC2=$?
if [ "$RC2" = 1 ] && [ "$(alerts | grep -c 'в рабочей копии есть локальные правки')" = 1 ]; then ok "second dirty tick refused again, alert deduplicated"; else bad "second dirty tick deduplicated" "rc=$RC2 $(alerts)"; fi
if [ "$(bash "$SUT" read --state demo 2>/dev/null | grep -c '^last_error=dirty: ')" = 1 ]; then ok "read returns the refusal reason"; else bad "read returns the refusal reason" "$(bash "$SUT" read --state demo 2>&1 | grep last_error)"; fi

echo "5. fresh on a dirty tree → exit 1 class dirty; clean tree with refused state → passes on last-known-good"
if ! fresh_it 2>"$WORK/fresh.err" && grep -q '\[dirty\]' "$WORK/fresh.err"; then ok "dirty tree → fresh exit 1"; else bad "dirty tree → fresh exit 1" "$(cat "$WORK/fresh.err")"; fi
git -C "$SERVER" checkout -q -- f
if fresh_it 2>/dev/null && [ "$(state_get status)" = refused ]; then ok "clean + refused state → exit 0 (last-known-good)"; else bad "clean + refused state → exit 0" "status=$(state_get status)"; fi

echo "6. clean again → sync recovers, recovery alert sent once"
if sync_it 2>/dev/null && [ "$(state_get status)" = ok ]; then ok "recovered → status=ok"; else bad "recovered → status=ok"; fi
if [ "$(alerts | grep -c '✅ Копия репозитория «demo» ')" = 1 ]; then ok "one recovery alert"; else bad "one recovery alert" "$(alerts)"; fi
if [ "$(alerts | grep -c '✅ Проверка свежести копии «demo» ')" = 1 ]; then ok "one gate recovery alert, repo name without plumbing suffix"; else bad "gate recovery alert" "$(alerts)"; fi

echo "7. rewritten origin history → diverged, refused, HEAD unchanged"
HEAD_BEFORE=$(git -C "$SERVER" rev-parse HEAD)
git -C "$WORK/author" commit -q --amend -m "c4-rewritten"
git -C "$WORK/author" push -q --force origin main
sync_it 2>/dev/null; RC=$?
if [ "$RC" = 1 ] && grep -q '^last_error=diverged' "$WORK/state/demo.state" && [ "$(git -C "$SERVER" rev-parse HEAD)" = "$HEAD_BEFORE" ]; then ok "diverged → refused"; else bad "diverged → refused" "rc=$RC err=$(state_get last_error)"; fi
# restore origin to a fast-forwardable state for the remaining checks
git -C "$WORK/author" reset -q --hard "$HEAD_BEFORE"; echo five > "$WORK/author/f"; git -C "$WORK/author" commit -qam c5; git -C "$WORK/author" push -q --force origin main
sync_it 2>/dev/null || true

echo "8. stale state (last success 7h ago, ttl 6h) → fresh fails with class stale"
sed -i.bak "s/^last_success_ts=.*/last_success_ts=$(( $(date -u +%s) - 7*3600 ))/" "$WORK/state/demo.state"
if ! fresh_it --ttl-h 6 2>"$WORK/fresh.err" && grep -q '\[stale\]' "$WORK/fresh.err"; then ok "stale → exit 1"; else bad "stale → exit 1" "$(cat "$WORK/fresh.err")"; fi

echo "9. future timestamp → class future"
sed -i.bak "s/^last_success_ts=.*/last_success_ts=$(( $(date -u +%s) + 3600 ))/" "$WORK/state/demo.state"
if ! fresh_it 2>"$WORK/fresh.err" && grep -q '\[future\]' "$WORK/fresh.err"; then ok "future → exit 1"; else bad "future → exit 1" "$(cat "$WORK/fresh.err")"; fi

echo "10. HEAD moved behind the verified sha (manual checkout) → class identity"
sync_it 2>/dev/null || true
git -C "$SERVER" reset -q --hard HEAD~1
if ! fresh_it 2>"$WORK/fresh.err" && grep -q '\[identity\]' "$WORK/fresh.err"; then ok "identity → exit 1"; else bad "identity → exit 1" "$(cat "$WORK/fresh.err")"; fi
sync_it 2>/dev/null || true

echo "11. state file replaced by a symlink → class unknown (not stale)"
mv "$WORK/state/demo.state" "$WORK/state/real.state"; ln -s "$WORK/state/real.state" "$WORK/state/demo.state"
if ! fresh_it 2>"$WORK/fresh.err" && grep -q '\[unknown\]' "$WORK/fresh.err"; then ok "symlink → unknown"; else bad "symlink → unknown" "$(cat "$WORK/fresh.err")"; fi
rm -f "$WORK/state/demo.state"; mv "$WORK/state/real.state" "$WORK/state/demo.state"

echo "12. wrong branch requested → refused wrong-branch, nothing merged"
bash "$SUT" sync --repo "$SERVER" --branch pilot --state demo-pilot 2>/dev/null; RC=$?
if [ "$RC" = 1 ] && grep -q '^last_error=wrong-branch' "$WORK/state/demo-pilot.state"; then ok "wrong-branch → refused"; else bad "wrong-branch → refused" "rc=$RC"; fi

echo "13. missing clone → refused missing"
bash "$SUT" sync --repo "$WORK/nowhere" --branch main --state demo-missing 2>/dev/null; RC=$?
if [ "$RC" = 1 ] && grep -q '^last_error=missing' "$WORK/state/demo-missing.state"; then ok "missing → refused"; else bad "missing → refused" "rc=$RC"; fi

echo "13a. origin unreachable → refused fetch-failed, HEAD and last success untouched"
PREV_OK=$(state_get last_success_ts); HEAD_BEFORE=$(git -C "$SERVER" rev-parse HEAD)
git -C "$SERVER" remote set-url origin "$WORK/does-not-exist.git"
sync_it 2>/dev/null; RC=$?
git -C "$SERVER" remote set-url origin "$WORK/origin.git"
if [ "$RC" = 1 ] && grep -q '^last_error=fetch-failed' "$WORK/state/demo.state" && [ "$(state_get last_success_ts)" = "$PREV_OK" ] && [ "$(git -C "$SERVER" rev-parse HEAD)" = "$HEAD_BEFORE" ]; then ok "fetch-failed → refused, provenance kept"; else bad "fetch-failed → refused" "rc=$RC err=$(state_get last_error)"; fi
sync_it 2>/dev/null || true

# WP-545 Ф28: a fetch failure alerts only on the second consecutive failed run.
# Fake ssh transport: logs each call, then behaves per $FAKE_SSH_MODE.
cat > "$WORK/bin/fake-ssh" <<'EOF'
#!/usr/bin/env bash
# git probes the ssh variant with `-G` before connecting; that is not an attempt.
[ "${1:-}" = "-G" ] && exit 0
echo call >> "$FAKE_SSH_CALLS"
case "$FAKE_SSH_MODE" in
  publickey) echo "git@github.com: Permission denied (publickey)." >&2; exit 255 ;;
  hang)      sleep 5; exit 255 ;;
esac
EOF
chmod +x "$WORK/bin/fake-ssh"
export FAKE_SSH_CALLS="$WORK/fake-ssh.calls"
fetch_alerts() { alerts | grep -c 'два запуска подряд' || true; }

echo "13c. first fetch failure → refused, no alert, pending marker; second → one alert; success → marker cleared silently"
PENDING="$WORK/state/demo.fetch-pending"
git -C "$SERVER" remote set-url origin "ssh://git@example.invalid/demo.git"
BEFORE=$(fetch_alerts)
FAKE_SSH_MODE=publickey GIT_SSH_COMMAND="$WORK/bin/fake-ssh" sync_it 2>/dev/null; RC1=$?
AFTER1=$(fetch_alerts)
# scheduler.sh detects a GitHub outage by the "fetch-failed:" prefix; keep it.
if [ "$RC1" = 1 ] && grep -q '^last_error=fetch-failed: fetch-auth: ' "$WORK/state/demo.state" && [ -f "$PENDING" ] && [ "$AFTER1" = "$BEFORE" ]; then
  ok "first publickey refusal → class fetch-auth, marker set, no alert"
else
  bad "first publickey refusal deferred" "rc=$RC1 err=$(state_get last_error) pending=$([ -f "$PENDING" ] && echo yes || echo no) alerts=$AFTER1/$BEFORE"
fi
FAKE_SSH_MODE=publickey GIT_SSH_COMMAND="$WORK/bin/fake-ssh" sync_it 2>/dev/null; RC2=$?
if [ "$RC2" = 1 ] && [ "$(fetch_alerts)" = $((BEFORE + 1)) ] && alerts | grep -q 'не принимает ключ сервера'; then
  ok "second consecutive refusal → exactly one alert naming the key"
else
  bad "second consecutive refusal alerts" "rc=$RC2 alerts=$(alerts | tail -2)"
fi
git -C "$SERVER" remote set-url origin "$WORK/origin.git"
RECOV_BEFORE=$(alerts | grep -c '✅ Копия репозитория «demo» ' || true)
sync_it 2>/dev/null; RC3=$?
if [ "$RC3" = 0 ] && [ ! -e "$PENDING" ] && [ "$(alerts | grep -c '✅ Копия репозитория «demo» ')" = $((RECOV_BEFORE + 1)) ]; then
  ok "success clears the marker and sends one recovery for the alert that went out"
else
  bad "recovery after fetch alert" "rc=$RC3 pending=$([ -f "$PENDING" ] && echo yes || echo no)"
fi

echo "13d. one failed run between successes → no alert at all, no recovery message"
git -C "$SERVER" remote set-url origin "ssh://git@example.invalid/demo.git"
ALL_BEFORE=$(alerts | wc -l)
FAKE_SSH_MODE=publickey GIT_SSH_COMMAND="$WORK/bin/fake-ssh" sync_it 2>/dev/null || true
git -C "$SERVER" remote set-url origin "$WORK/origin.git"
sync_it 2>/dev/null; RC=$?
if [ "$RC" = 0 ] && [ "$(alerts | wc -l)" = "$ALL_BEFORE" ] && [ ! -e "$PENDING" ]; then ok "transient single failure stays silent"; else bad "transient single failure silent" "rc=$RC lines=$(alerts | wc -l)/$ALL_BEFORE"; fi

echo "13e. fast failure is retried once; timeout (124) is classified fetch-timeout and not retried"
git -C "$SERVER" remote set-url origin "ssh://git@example.invalid/demo.git"
rm -f "$FAKE_SSH_CALLS"
FAKE_SSH_MODE=publickey GIT_SSH_COMMAND="$WORK/bin/fake-ssh" sync_it 2>/dev/null || true
FAST_CALLS=$(wc -l < "$FAKE_SSH_CALLS")
rm -f "$FAKE_SSH_CALLS"
FAKE_SSH_MODE=hang GIT_SSH_COMMAND="$WORK/bin/fake-ssh" bash "$SUT" sync --repo "$SERVER" --branch main --state demo --fetch-timeout 1 2>/dev/null || true
SLOW_CALLS=$(wc -l < "$FAKE_SSH_CALLS")
git -C "$SERVER" remote set-url origin "$WORK/origin.git"
if [ "$FAST_CALLS" = 2 ] && [ "$SLOW_CALLS" = 1 ] && grep -q '^last_error=fetch-failed: fetch-timeout: ' "$WORK/state/demo.state"; then
  ok "publickey → 2 attempts; hang → 1 attempt, class fetch-timeout"
else
  bad "retry policy" "fast=$FAST_CALLS slow=$SLOW_CALLS err=$(state_get last_error)"
fi
sync_it 2>/dev/null || true

echo "13f. fetch failure, then a dirty refusal, then one fetch failure → no fetch alert (not two in a row)"
git -C "$SERVER" remote set-url origin "ssh://git@example.invalid/demo.git"
FETCH_BEFORE=$(fetch_alerts)
FAKE_SSH_MODE=publickey GIT_SSH_COMMAND="$WORK/bin/fake-ssh" sync_it 2>/dev/null || true
echo junk > "$SERVER/untracked-13f"
sync_it 2>/dev/null || true
rm -f "$SERVER/untracked-13f"
FAKE_SSH_MODE=publickey GIT_SSH_COMMAND="$WORK/bin/fake-ssh" sync_it 2>/dev/null || true
if [ "$(fetch_alerts)" = "$FETCH_BEFORE" ] && [ -f "$PENDING" ]; then
  ok "a dirty run in between resets the count; the next failure only sets the marker"
else
  bad "stuck marker" "fetch alerts $(fetch_alerts)/$FETCH_BEFORE pending=$([ -f "$PENDING" ] && echo yes || echo no)"
fi
git -C "$SERVER" remote set-url origin "$WORK/origin.git"
sync_it 2>/dev/null || true

echo "13b. lock held by another process → skipped tick (exit 1), state not rewritten"
ATTEMPT_BEFORE=$(state_get last_attempt_ts)
( exec 9>"$IWE_VERIFIED_SYNC_LOCK"; flock 9; sleep 4 ) &
HOLDER=$!; sleep 1
bash "$SUT" sync --repo "$SERVER" --branch main --state demo --lock-wait 1 2>/dev/null; RC=$?
wait "$HOLDER"
if [ "$RC" = 1 ] && [ "$(state_get last_attempt_ts)" = "$ATTEMPT_BEFORE" ]; then ok "lock busy → exit 1, state untouched"; else bad "lock busy → exit 1" "rc=$RC attempt=$(state_get last_attempt_ts) before=$ATTEMPT_BEFORE"; fi

echo "14. read prints validated key=value lines"
# grep -c (not -q): under pipefail an early-exiting grep -q would SIGPIPE the producer
if [ "$(bash "$SUT" read --state demo 2>/dev/null | grep -c '^status=ok$')" = 1 ]; then ok "read → status=ok"; else bad "read → status=ok" "$(bash "$SUT" read --state demo 2>&1 | tr '\n' ' ')"; fi

echo "15. usage errors exit 2 (no --branch default on purpose)"
bash "$SUT" sync --repo "$SERVER" --state demo 2>/dev/null; RC=$?
if [ "$RC" = 2 ]; then ok "missing --branch → exit 2"; else bad "missing --branch → exit 2" "rc=$RC"; fi

echo "16. index digest owns idx-* alerts without changing refusal or recovery state"
echo local > "$SERVER/f"
ALERTS_BEFORE=$(wc -l < "$ALERT_CAPTURE")
IWE_VERIFIED_SYNC_ALERT_ROUTE=index-digest bash "$SUT" sync --repo "$SERVER" --branch main --state idx-demo 2>/dev/null; RC=$?
if [ "$RC" = 1 ] && grep -q '^last_error=dirty:' "$WORK/state/idx-demo.state" \
  && [ "$(wc -l < "$ALERT_CAPTURE")" -eq "$ALERTS_BEFORE" ] \
  && [ ! -e "$WORK/state/idx-demo.alert" ]; then
  ok "index refusal remains visible in state but sends no duplicate alert"
else
  bad "index digest route" "rc=$RC alerts=$(alerts)"
fi
IWE_VERIFIED_SYNC_ALERT_ROUTE=index-digest bash "$SUT" sync --repo "$SERVER" --branch main --state other-demo 2>/dev/null; RC=$?
if [ "$RC" = 1 ] && [ "$(wc -l < "$ALERT_CAPTURE")" -eq $((ALERTS_BEFORE + 1)) ]; then
  ok "non-index caller still alerts"
else
  bad "non-index alert route" "rc=$RC alerts=$(alerts)"
fi
git -C "$SERVER" restore --worktree -- f
IWE_VERIFIED_SYNC_ALERT_ROUTE=index-digest bash "$SUT" sync --repo "$SERVER" --branch main --state idx-demo 2>/dev/null; RC=$?
if [ "$RC" = 0 ] && [ ! -e "$WORK/state/idx-demo.alert" ] \
  && [ "$(wc -l < "$ALERT_CAPTURE")" -eq $((ALERTS_BEFORE + 1)) ]; then
  ok "index recovery leaves delivery to the acknowledged scheduler digest"
else
  bad "index recovery route" "rc=$RC alerts=$(alerts)"
fi

echo
echo "итог: ✅ $PASS  ❌ $FAIL"
[ "$FAIL" -eq 0 ]
