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
if [ "$(alerts | grep -c '\[dirty\]')" = 1 ]; then ok "one dirty alert"; else bad "one dirty alert" "$(alerts)"; fi
sync_it 2>/dev/null; RC2=$?
if [ "$RC2" = 1 ] && [ "$(alerts | grep -c '\[dirty\]')" = 1 ]; then ok "second dirty tick refused again, alert deduplicated"; else bad "second dirty tick deduplicated" "rc=$RC2 $(alerts)"; fi
if [ "$(bash "$SUT" read --state demo 2>/dev/null | grep -c '^last_error=dirty: ')" = 1 ]; then ok "read returns the refusal reason"; else bad "read returns the refusal reason" "$(bash "$SUT" read --state demo 2>&1 | grep last_error)"; fi

echo "5. fresh on a dirty tree → exit 1 class dirty; clean tree with refused state → passes on last-known-good"
if ! fresh_it 2>"$WORK/fresh.err" && grep -q '\[dirty\]' "$WORK/fresh.err"; then ok "dirty tree → fresh exit 1"; else bad "dirty tree → fresh exit 1" "$(cat "$WORK/fresh.err")"; fi
git -C "$SERVER" checkout -q -- f
if fresh_it 2>/dev/null && [ "$(state_get status)" = refused ]; then ok "clean + refused state → exit 0 (last-known-good)"; else bad "clean + refused state → exit 0" "status=$(state_get status)"; fi

echo "6. clean again → sync recovers, recovery alert sent once"
if sync_it 2>/dev/null && [ "$(state_get status)" = ok ]; then ok "recovered → status=ok"; else bad "recovered → status=ok"; fi
if [ "$(alerts | grep -c '✅ verified-sync demo ')" = 1 ]; then ok "one recovery alert"; else bad "one recovery alert" "$(alerts)"; fi

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

echo
echo "итог: ✅ $PASS  ❌ $FAIL"
[ "$FAIL" -eq 0 ]
