#!/bin/bash
# day-open-preflight-sync-drift-smoke.sh — regression coverage for the
# sync_drift health-check in day-open-preflight.sh (WP-484, 14.09, пир-сессия
# с Kimi+Codex).
#
# Independent second channel for the same fact sync-extensions-auto.sh's
# alerting covers: a 3-day-long delivery outage on the Mac stayed invisible
# because every Telegram alert fell inside the frequency throttle. This
# check must surface the same drift even when that Telegram channel is
# silent — so it's tested here on its own, not assumed to follow from the
# alerting fix.
#
# Covers: fresh repo (no drift, ok), stale repo past threshold (fail with
# age+name), repo behind but under threshold (still ok), missing repo
# directory (not a failure — absent is a valid "not installed here" state).
#
# Usage: bash scripts/tests/day-open-preflight-sync-drift-smoke.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/day-open-preflight.sh"
[ -f "$SCRIPT" ] || { echo "не найден проверяемый скрипт: $SCRIPT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq недоступен — тест пропущен (окружение без jq)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — факт: ${2:-нет данных}"; FAIL=$((FAIL + 1)); }

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/day-open-preflight-sync-drift-smoke.XXXXXX")
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# make_repo_pair <name> <commits_behind_age_offset_sec|""> — creates a bare
# "origin" and a clone; when an offset is given, adds one commit to origin
# with that backdated author/committer date and does NOT pull it into the
# clone, simulating a clone that fell behind by that much wall-clock time.
make_repo_pair() {
  local name="$1" behind_age="${2:-}"
  local origin="$WORKDIR/$name-origin.git" clone="$WORKDIR/$name"
  git init --quiet --bare "$origin"
  git clone --quiet "$origin" "$clone"
  git -C "$clone" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "seed"
  git -C "$clone" push --quiet origin HEAD:main -u
  if [ -n "$behind_age" ]; then
    local ts
    ts=$(( $(date -u +%s) - behind_age ))
    local upstream="$WORKDIR/$name-upstream"
    git clone --quiet "$origin" "$upstream"
    GIT_AUTHOR_DATE="@$ts" GIT_COMMITTER_DATE="@$ts" \
      git -C "$upstream" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "unseen-by-clone"
    git -C "$upstream" push --quiet origin HEAD:main
  fi
  printf '%s' "$clone"
}

run_preflight() {
  local iwe_root="$1"
  IWE_ROOT="$iwe_root" bash "$SCRIPT" 2>/dev/null
}

# --- Сценарий 1: свежий репозиторий, не отстаёт — ok -------------------------
IWE1="$WORKDIR/iwe1"; mkdir -p "$IWE1"
FRESH=$(make_repo_pair "fresh")
rm -rf "$IWE1"; cp -R "$FRESH" "$IWE1"
OUT1=$(run_preflight "$IWE1")
[ "$(echo "$OUT1" | jq -r .sync_drift)" = "ok" ] && ok "свежий репозиторий: sync_drift=ok" \
    || bad "свежий репозиторий: sync_drift=ok" "$(echo "$OUT1" | jq -r .sync_drift)"

# --- Сценарий 2: отстаёт на 8 часов (> порога 6ч по умолчанию) — fail -------
IWE2="$WORKDIR/iwe2"; mkdir -p "$IWE2"
STALE=$(make_repo_pair "stale" 28800)
rm -rf "$IWE2"; cp -R "$STALE" "$IWE2"
OUT2=$(SYNC_DRIFT_THRESHOLD_SEC=21600 run_preflight "$IWE2")
[ "$(echo "$OUT2" | jq -r .sync_drift)" = "fail" ] && ok "отстаёт на 8ч (порог 6ч): sync_drift=fail" \
    || bad "отстаёт на 8ч: sync_drift=fail" "$(echo "$OUT2" | jq -r .sync_drift)"
echo "$OUT2" | jq -r .sync_drift_reason | grep -q "iwe2" && ok "отстаёт на 8ч: причина называет репозиторий" \
    || bad "отстаёт на 8ч: причина содержит имя репозитория" "$(echo "$OUT2" | jq -r .sync_drift_reason)"

# --- Сценарий 3: отстаёт на 2 часа (< порога 6ч) — всё ещё ok ---------------
IWE3="$WORKDIR/iwe3"; mkdir -p "$IWE3"
UNDER=$(make_repo_pair "under" 7200)
rm -rf "$IWE3"; cp -R "$UNDER" "$IWE3"
OUT3=$(SYNC_DRIFT_THRESHOLD_SEC=21600 run_preflight "$IWE3")
[ "$(echo "$OUT3" | jq -r .sync_drift)" = "ok" ] && ok "отстаёт на 2ч (< порога 6ч): sync_drift=ok" \
    || bad "отстаёт на 2ч: sync_drift=ok" "$(echo "$OUT3" | jq -r .sync_drift)"

# --- Сценарий 4: iwe-server-config отсутствует — не считается сбоем --------
IWE4="$WORKDIR/iwe4"; mkdir -p "$IWE4"
FRESH4=$(make_repo_pair "fresh4")
rm -rf "$IWE4"; cp -R "$FRESH4" "$IWE4"
# no iwe-server-config subdirectory created — should be silently skipped
OUT4=$(run_preflight "$IWE4")
[ "$(echo "$OUT4" | jq -r .sync_drift)" = "ok" ] && ok "iwe-server-config не установлен: sync_drift не считается провалом" \
    || bad "iwe-server-config отсутствует: sync_drift=ok" "$(echo "$OUT4" | jq -r .sync_drift)"

# --- Сценарий 5: origin недостижим (сеть упала) — unknown, НЕ ok ------------
# Cold-review finding (14.09): недоступный origin без кэшированного
# origin/<default> раньше молча читался как "ok" — ровно тот класс
# силентного отказа, который весь этот health-check должен ловить.
IWE5="$WORKDIR/iwe5"; mkdir -p "$IWE5"
git init --quiet "$IWE5"
git -C "$IWE5" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "seed"
git -C "$IWE5" remote add origin "https://127.0.0.1:1/nonexistent.git"  # unreachable, no cached ref
OUT5=$(run_preflight "$IWE5")
[ "$(echo "$OUT5" | jq -r .sync_drift)" = "unknown" ] && ok "origin недостижим: sync_drift=unknown, не молчаливый ok" \
    || bad "origin недостижим: sync_drift=unknown" "$(echo "$OUT5" | jq -r .sync_drift)"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
