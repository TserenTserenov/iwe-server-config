#!/usr/bin/env bash
# Smoke test for refs-sync-broker.sh (WP-530 F66 Требование А). Throwaway
# sandbox repos and registry only -- never touches a real IWE_ROOT.
set -euo pipefail

BROKER="$HOME/IWE/scripts/refs-sync-broker.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# IWE_ROOT only -- IWE_RUNTIME is a platform-wide agent-runtime identifier
# (.claude/settings.json), not a path; the broker derives its state dir from
# $IWE_ROOT/.iwe-runtime with no env override (real-world bug found and
# fixed 2026-09-26, same class as wp-reopen-gate.sh's).
export IWE_ROOT="$SANDBOX/root"
IWE_RUNTIME="$SANDBOX/root/.iwe-runtime"
mkdir -p "$IWE_ROOT"

# --- fixture: a bare origin and a clone the broker will fetch into ---
BARE="$SANDBOX/origin.git"
REPO="$IWE_ROOT/gov-repo"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO"
echo "content v1" > "$REPO/card.md"
git -C "$REPO" add card.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "v1"
git -C "$REPO" push -q origin main

REGISTRY="$SANDBOX/registry.yaml"
cat > "$REGISTRY" <<EOF
repos:
  - path: gov-repo
    remote: origin
    refspec: "+refs/heads/main:refs/remotes/origin/main"
EOF
export REFS_SYNC_REGISTRY="$REGISTRY"

# 1. run: fetches into refs/remotes/*, does NOT touch the working tree.
echo "content v2 on remote, not yet in working tree" > /dev/null   # doc only
BARE_CLONE_FOR_PUSH="$SANDBOX/push-clone"
git clone -q "$BARE" "$BARE_CLONE_FOR_PUSH"
echo "content v2" > "$BARE_CLONE_FOR_PUSH/card.md"
git -C "$BARE_CLONE_FOR_PUSH" add card.md
git -C "$BARE_CLONE_FOR_PUSH" -c user.email=t@t -c user.name=t commit -q -m "v2"
git -C "$BARE_CLONE_FOR_PUSH" push -q origin main

bash "$BROKER" run
remote_head=$(git -C "$REPO" rev-parse origin/main)
bare_head=$(git -C "$BARE" rev-parse main)
[ "$remote_head" = "$bare_head" ] || fail "после run() refs/remotes/origin/main должен совпадать с origin, не совпал"
[ "$(cat "$REPO/card.md")" = "content v1" ] || fail "run() не должен трогать рабочее дерево, но card.md изменился"
pass "run() обновляет refs/remotes/origin/main и не трогает рабочее дерево"

# 2. dirty working tree + untracked file: run() must still succeed (fetch,
#    not merge -- freeze-safety is the whole point of Требование А).
echo "local WIP" >> "$REPO/card.md"
echo "untracked scratch" > "$REPO/scratch.md"
BARE_CLONE_FOR_PUSH2="$SANDBOX/push-clone2"
git clone -q "$BARE" "$BARE_CLONE_FOR_PUSH2"
echo "content v3" > "$BARE_CLONE_FOR_PUSH2/card.md"
git -C "$BARE_CLONE_FOR_PUSH2" add card.md
git -C "$BARE_CLONE_FOR_PUSH2" -c user.email=t@t -c user.name=t commit -q -m "v3"
git -C "$BARE_CLONE_FOR_PUSH2" push -q origin main

bash "$BROKER" run
remote_head=$(git -C "$REPO" rev-parse origin/main)
bare_head=$(git -C "$BARE" rev-parse main)
[ "$remote_head" = "$bare_head" ] || fail "run() на грязном дереве должен всё равно обновить refs/remotes, не обновил"
git -C "$REPO" diff --quiet -- card.md && fail "рабочее дерево не должно было измениться, но diff пуст (потеряна собственная грязь?)"
grep -q "local WIP" "$REPO/card.md" || fail "локальная незакоммиченная правка потерялась после run()"
[ -f "$REPO/scratch.md" ] || fail "untracked-файл потерялся после run()"
pass "run() на грязном/замороженном дереве обновляет только refs/remotes, чужая грязь не трогается"

# 3. status: never_run before first run (fresh sandbox), fresh after.
FRESH_SANDBOX=$(mktemp -d)
IWE_ROOT="$FRESH_SANDBOX" bash "$BROKER" status | grep -q "never_run" \
  || fail "status на чистом sandbox должен вернуть never_run"
rm -rf "$FRESH_SANDBOX"
out=$(bash "$BROKER" status)
echo "$out" | grep -q "state=fresh" || fail "status после недавнего run() должен вернуть state=fresh: $out"
pass "status: never_run на чистом sandbox, fresh сразу после run()"

# 4. status: stale after the heartbeat ages past STALE_AFTER.
REFS_SYNC_STALE_AFTER=0 bash "$BROKER" run
sleep 1
out=$(REFS_SYNC_STALE_AFTER=0 bash "$BROKER" status)
echo "$out" | grep -q "state=stale" || fail "status с REFS_SYNC_STALE_AFTER=0 должен вернуть state=stale: $out"
pass "status: stale, когда heartbeat старше порога"

# 4b. flock missing from PATH must fail LOUDLY, not silently look like "lock
#    already held" -- live incident, tsekh-1, 2026-09-26: the systemd unit's
#    PATH lacked util-linux, so every single invocation logged a plausible
#    "SKIP: another broker instance holds the lock" forever, no heartbeat
#    ever written, and systemd still reported exit 0/SUCCESS -- silence
#    that looked exactly like a healthy, contended broker.
rm -f "$IWE_RUNTIME/refs-sync-broker/heartbeat.json" "$IWE_RUNTIME/refs-sync-broker/broker.log"
BASH_ABS=$(command -v bash)
NO_FLOCK_BIN=$(mktemp -d)
for tool in git python3 mkdir mv date cat timeout mktemp rm printf grep; do
  real=$(command -v "$tool") || continue
  ln -s "$real" "$NO_FLOCK_BIN/$tool"
done
set +e
out=$("$BASH_ABS" -c 'export PATH="$1"; exec "$2" "$3" "$4"' _ "$NO_FLOCK_BIN" "$BASH_ABS" "$BROKER" run 2>&1)
rc=$?
set -e
rm -rf "$NO_FLOCK_BIN"
[ "$rc" -ne 0 ] || fail "run() без flock в PATH должен провалиться (exit != 0), вернул 0"
# log() now tees to stderr too (cold review's own tsekh-1 incident,
# 2026-09-26: it used to write ONLY to broker.log, invisible to systemd's
# journal -- the file was accurate the whole time, but nothing an operator
# actually looks at first showed it), so this is what the journal would see.
echo "$out" | grep -q "flock binary not found" || fail "вывод не называет отсутствие flock как причину: $out"
grep -q "flock binary not found" "$IWE_RUNTIME/refs-sync-broker/broker.log" \
  || fail "лог-файл тоже должен содержать эту причину, не только stderr"
[ ! -f "$IWE_RUNTIME/refs-sync-broker/heartbeat.json" ] || fail "heartbeat не должен быть записан при отсутствии flock"
pass "отсутствие flock в PATH -> явный отказ (FATAL), не молчаливое 'lock уже занят'"

# 5. concurrent run(): the second invocation must not block or error --
#    it observes the lock held and exits 0 quietly (own state space, non-
#    blocking flock, not a session-guard semaphore -- Codex, round 3).
(
  exec 9>"$IWE_RUNTIME/refs-sync-broker/broker.lock"
  flock 9
  sleep 2
) &
HOLDER_PID=$!
sleep 0.3
start=$(date +%s)
bash "$BROKER" run
elapsed=$(( $(date +%s) - start ))
wait "$HOLDER_PID"
[ "$elapsed" -lt 2 ] || fail "run() должен выйти немедленно при занятом локе (non-blocking flock), занял ${elapsed}с"
pass "run() при занятом локе выходит немедленно, не блокируется и не проваливается с ошибкой"

# 6. a missing/unreachable repo in the registry is skipped, not fatal --
#    the rest of the registry still runs.
cat > "$REGISTRY" <<EOF
repos:
  - path: does-not-exist
    remote: origin
    refspec: "+refs/heads/main:refs/remotes/origin/main"
  - path: gov-repo
    remote: origin
    refspec: "+refs/heads/main:refs/remotes/origin/main"
EOF
bash "$BROKER" run
LOG="$IWE_RUNTIME/refs-sync-broker/broker.log"
grep -q "SKIP does-not-exist" "$LOG" || fail "отсутствующий репозиторий должен быть пропущен с записью в лог"
grep -q "OK gov-repo" "$LOG" || fail "существующий репозиторий в том же прогоне не должен страдать от отсутствующего"
pass "отсутствующий репозиторий в реестре пропускается, остальные всё равно обрабатываются"

# --- registry validation, added after cold review (2026-09-26, Critical +
# Medium findings): a bad entry must abort the WHOLE run loudly, never
# silently sync a narrower subset while looking healthy.

# 7. refspec destination not targeting refs/remotes/* -- would move a LOCAL
#    branch under a live/frozen working tree if it were ever allowed through.
cat > "$REGISTRY" <<EOF
repos:
  - path: gov-repo
    remote: origin
    refspec: "+refs/heads/main:refs/heads/main"
EOF
set +e
bash "$BROKER" run >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "refspec не на refs/remotes/* должен провалить run() целиком"
grep -q "registry_invalid" "$IWE_RUNTIME/refs-sync-broker/heartbeat.json" \
  || fail "heartbeat должен зафиксировать registry_invalid, не тихий успех"
pass "refspec не на refs/remotes/* -> run() проваливается целиком, не тихо принимается"

# 8. path containing ".." -- registry-level traversal guard.
cat > "$REGISTRY" <<EOF
repos:
  - path: "../escape"
    remote: origin
    refspec: "+refs/heads/main:refs/remotes/origin/main"
EOF
set +e
bash "$BROKER" run >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "path с .. должен провалить run() на этапе валидации реестра"
pass "path с .. в реестре -> run() проваливается на валидации"

# 9. one bad entry must not let a GOOD entry in the same file get fetched
#    partially -- the whole registry is rejected together (High finding:
#    "silently syncing a subset forever" must not be possible).
cat > "$REGISTRY" <<EOF
repos:
  - path: gov-repo
    remote: origin
    refspec: "+refs/heads/main:refs/remotes/origin/main"
  - path: also-broken
    remote: origin
    refspec: "bad-refspec-no-colon"
EOF
BEFORE_HEAD=$(git -C "$REPO" rev-parse origin/main)
BARE_CLONE_FOR_PUSH3="$SANDBOX/push-clone3"
git clone -q "$BARE" "$BARE_CLONE_FOR_PUSH3"
echo "content v4, should NOT be fetched" > "$BARE_CLONE_FOR_PUSH3/card.md"
git -C "$BARE_CLONE_FOR_PUSH3" add card.md
git -C "$BARE_CLONE_FOR_PUSH3" -c user.email=t@t -c user.name=t commit -q -m "v4"
git -C "$BARE_CLONE_FOR_PUSH3" push -q origin main
set +e
bash "$BROKER" run >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "смешанный реестр (валидная + сломанная запись) должен провалить весь run()"
AFTER_HEAD=$(git -C "$REPO" rev-parse origin/main)
[ "$BEFORE_HEAD" = "$AFTER_HEAD" ] || fail "валидная запись в том же реестре, что и сломанная, всё равно была fetch'нута -- частичная синхронизация недопустима"
pass "одна сломанная запись в реестре блокирует ВЕСЬ прогон, даже валидные записи не выполняются частично"

# reset registry to the known-good single entry for any future tests below.
cat > "$REGISTRY" <<EOF
repos:
  - path: gov-repo
    remote: origin
    refspec: "+refs/heads/main:refs/remotes/origin/main"
EOF

echo "ALL PASS"
