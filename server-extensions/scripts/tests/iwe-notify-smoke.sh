#!/usr/bin/env bash
# iwe-notify-smoke.sh — the delivery contract of scripts/iwe-notify
# (WP-568 Ф12 С4, ArchGate 06.11.2026): the gateway's decision is final
# (delivered / transport failed / quarantined -> no second send); a direct
# Bot API send happens only when the gateway is absent or did not run, and
# each direct send leaves one row in direct-send-log.tsv. Also checks that
# semaphore-watchdog.sh sends through iwe-notify with its own source id.
# The gateway and curl are stubs that record their calls; nothing leaves
# the host.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NOTIFY="$REPO_ROOT/scripts/iwe-notify"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iwe-notify-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — факт: ${2:-нет данных}"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/iwe/DS-strategy/scripts"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$CURL_CALLS"' 'exit "${CURL_RC:-0}"' > "$WORK/bin/curl"
GATEWAY="$WORK/iwe/DS-strategy/scripts/iwe-tg"
# GATEWAY_STAGE: what the gateway's library would have written before dying.
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$GATEWAY_CALLS"' \
  '[ -z "${GATEWAY_STAGE:-}" ] || printf "%s\n" "$GATEWAY_STAGE" > "$IWE_NOTIFY_STAGE_FILE"' \
  'exit "${GATEWAY_RC:-0}"' > "$GATEWAY"
chmod +x "$WORK/bin/curl" "$GATEWAY"
export PATH="$WORK/bin:$PATH" CURL_CALLS="$WORK/curl-calls" GATEWAY_CALLS="$WORK/gateway-calls"
export TELEGRAM_BOT_TOKEN=t TELEGRAM_CHAT_ID=c DS_PUBLISH_ADMISSION_DIR="$WORK/adm"
unset IWE_NOTIFY_GATEWAY IWE_GOVERNANCE_REPO
LOG="$WORK/adm/direct-send-log.tsv"

count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
reset() { rm -f "$CURL_CALLS" "$GATEWAY_CALLS" "$LOG"; }

# run_case <label> <gateway rc> <expect direct: yes|no> [reason]
run_case() {
  local label="$1" grc="$2" direct="$3" reason="${4:-}" rc
  reset
  GATEWAY_RC="$grc" IWE_ROOT="$WORK/iwe" "$NOTIFY" --source s-test "текст" 2>/dev/null; rc=$?
  if [ "$(count "$GATEWAY_CALLS")" != 1 ] || ! grep -q -- "--source s-test -- текст" "$GATEWAY_CALLS"; then
    bad "$label: шлюз вызван один раз с --source" "$(cat "$GATEWAY_CALLS" 2>&1)"; return
  fi
  if [ "$direct" = no ]; then
    [ "$(count "$CURL_CALLS")" = 0 ] && [ ! -f "$LOG" ] && [ "$rc" = "$grc" ] \
      && ok "$label: решение шлюза окончательно, прямой отправки нет (код $rc)" \
      || bad "$label: без прямой отправки" "curl=$(count "$CURL_CALLS") log=$(count "$LOG") rc=$rc"
  else
    [ "$(count "$CURL_CALLS")" = 1 ] && [ "$(count "$LOG")" = 1 ] \
      && awk -F'\t' -v r="$reason" '$2=="s-test" && $3==r && $4=="sent"' "$LOG" | grep -q . \
      && ok "$label: прямая отправка и строка журнала ($reason)" \
      || bad "$label: прямая отправка" "curl=$(count "$CURL_CALLS") log=$(cat "$LOG" 2>&1)"
  fi
}

run_case "доставлено или в сводку" 0 no
run_case "сбой транспорта у шлюза" 2 no
run_case "карантин" 3 no
run_case "сводка не записалась" 4 yes gateway-exit-4
run_case "у шлюза нет библиотеки/настроек" 1 yes gateway-exit-1
run_case "шлюз убит до сети" 137 yes gateway-exit-137

# Finding 3 of the 06.11 review (peer-session 2026-11-07-04): the gateway died
# after its library had started sending -> a direct send could duplicate the
# message; none is made, the row records why and the gateway's code is kept.
# held_case <label> <stage> <gateway rc> <reason>
held_case() {
  local label="$1" stage="$2" grc="$3" reason="$4" rc
  reset
  GATEWAY_STAGE="$stage" GATEWAY_RC="$grc" IWE_ROOT="$WORK/iwe" "$NOTIFY" --source s-test "текст" 2>/dev/null; rc=$?
  [ "$(count "$CURL_CALLS")" = 0 ] && [ "$rc" = "$grc" ] \
    && awk -F'\t' -v r="$reason" '$2=="s-test" && $3==r && $4=="skipped"' "$LOG" | grep -q . \
    && ok "$label: прямой отправки нет, строка $reason" \
    || bad "$label: без дубля" "curl=$(count "$CURL_CALLS") rc=$rc log=$(cat "$LOG" 2>&1)"
}
held_case "шлюз убит после начала отправки" attempt 143 ambiguous-gateway-exit-143
held_case "шлюз упал после подтверждения Telegram" sent 1 gateway-sent-exit-1
reset
GATEWAY_STAGE=attempt GATEWAY_RC=2 IWE_ROOT="$WORK/iwe" "$NOTIFY" --source s-test "текст" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && [ "$(count "$CURL_CALLS")" = 0 ] && [ ! -f "$LOG" ] \
  && ok "сбой транспорта у шлюза после попытки: решение шлюза, строки нет" || bad "код 2 после попытки" "rc=$rc log=$(cat "$LOG" 2>&1)"

reset
CURL_RC=22 IWE_ROOT="$WORK/empty" "$NOTIFY" --source s-test "текст" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && awk -F'\t' '$3=="no-gateway" && $4=="failed"' "$LOG" | grep -q . \
  && ok "прямая отправка отклонена Telegram: исход failed в журнале, код 1" || bad "отказ прямой отправки" "rc=$rc log=$(cat "$LOG" 2>&1)"

reset
IWE_ROOT="$WORK/empty" "$NOTIFY" --source s-test "текст" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(count "$CURL_CALLS")" = 1 ] && awk -F'\t' '$3=="no-gateway"' "$LOG" | grep -q . \
  && ok "нет шлюза: прямая отправка, как раньше, и строка журнала" \
  || bad "нет шлюза" "rc=$rc curl=$(count "$CURL_CALLS") log=$(cat "$LOG" 2>&1)"

reset
IWE_NOTIFY_GATEWAY="$WORK/missing" IWE_ROOT="$WORK/iwe" "$NOTIFY" --source s-test "текст" 2>/dev/null
[ "$(count "$CURL_CALLS")" = 1 ] && awk -F'\t' '$3=="gateway-not-executable"' "$LOG" | grep -q . \
  && ok "указанного шлюза нет на диске: прямая отправка" \
  || bad "шлюза нет на диске" "curl=$(count "$CURL_CALLS") log=$(cat "$LOG" 2>&1)"

reset
TELEGRAM_BOT_TOKEN="" IWE_ROOT="$WORK/empty" "$NOTIFY" --source s-test "текст" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(count "$CURL_CALLS")" = 0 ] && [ ! -f "$LOG" ] \
  && ok "нет шлюза и ключей: ничего не шлёт, не падает" \
  || bad "нет ключей" "rc=$rc curl=$(count "$CURL_CALLS")"

reset
echo "из потока" | GATEWAY_RC=0 IWE_ROOT="$WORK/iwe" "$NOTIFY" --source s-test 2>/dev/null
grep -q -- "--source s-test -- из потока" "$GATEWAY_CALLS" 2>/dev/null \
  && ok "текст из stdin доходит до шлюза" || bad "stdin" "$(cat "$GATEWAY_CALLS" 2>&1)"

# Review 07.11: a text starting with "-" must reach the gateway as text (after
# "--"), not as an unknown flag that makes the gateway exit 1 and the message
# go out directly, bypassing the gateway.
reset
printf -- '- пункт списка' | GATEWAY_RC=0 IWE_ROOT="$WORK/iwe" "$NOTIFY" --source s-test 2>/dev/null
grep -q -- "--source s-test -- - пункт списка" "$GATEWAY_CALLS" 2>/dev/null && [ "$(count "$CURL_CALLS")" = 0 ] \
  && ok "текст с «-» в начале доходит до шлюза как текст" || bad "текст с «-»" "$(cat "$GATEWAY_CALLS" 2>&1)"
reset
GATEWAY_RC=0 IWE_ROOT="$WORK/iwe" "$NOTIFY" --source=s-test "текст" 2>/dev/null
grep -q -- "--source s-test -- текст" "$GATEWAY_CALLS" 2>/dev/null \
  && ok "форма --source=id принимается" || bad "--source=id" "$(cat "$GATEWAY_CALLS" 2>&1)"
reset
TELEGRAM_ENV=test IWE_ROOT="$WORK/empty" "$NOTIFY" --source s-test "текст" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(count "$CURL_CALLS")" = 0 ] \
  && ok "тестовый режим: прямая отправка заблокирована, как в библиотеке" || bad "тестовый режим" "rc=$rc curl=$(count "$CURL_CALLS")"

IWE_ROOT="$WORK/iwe" "$NOTIFY" "без источника" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok "без --source: отказ с кодом 1" || bad "без --source" "rc=$rc"
reset
IWE_ROOT="$WORK/iwe" "$NOTIFY" --source "$(printf 'a\tb')" "текст" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(count "$GATEWAY_CALLS")" = 0 ] && [ ! -f "$LOG" ] \
  && ok "источник с табуляцией: отказ с кодом 1 до шлюза и журнала" || bad "проверка источника" "rc=$rc"

# semaphore-watchdog.sh: an old open semaphore (rule B) -> one message
# through iwe-notify with source semaphore-watchdog.
reset
W="$WORK/wd"
mkdir -p "$W/scripts" "$W/iwe/.iwe-runtime/sessions" "$W/iwe/DS-my-strategy/scripts/lib"
cp "$REPO_ROOT/scripts/semaphore-watchdog.sh" "$NOTIFY" "$W/scripts/"
printf 'iwe_sessions_root() { echo "%s/none"; }\n' "$W" > "$W/iwe/DS-my-strategy/scripts/lib/governance-repo-path.sh"
cp "$GATEWAY" "$W/iwe/DS-my-strategy/scripts/iwe-tg"
printf 'wp: WP-1\nslug: s\nopened_at: 2020-01-01T00:00:00Z\n' > "$W/iwe/.iwe-runtime/sessions/x.open"
IWE_ROOT="$W/iwe" GATEWAY_RC=0 bash "$W/scripts/semaphore-watchdog.sh" 2>/dev/null
[ "$(count "$GATEWAY_CALLS")" = 1 ] && grep -q -- "--source semaphore-watchdog -- Замок на файлы по РП WP-1" "$GATEWAY_CALLS" \
  && [ "$(count "$CURL_CALLS")" = 0 ] \
  && ok "сторож блокировок шлёт через шлюз со своим источником" \
  || bad "сторож блокировок" "gateway=$(cat "$GATEWAY_CALLS" 2>&1) curl=$(count "$CURL_CALLS")"

# Outcome line (peer-session 2026-11-08-06): one stdout line tells a phone
# delivery from a digest line; exit codes stay as before.
# outcome_case <label> <expected outcome> <env...> -- run with that env
outcome_case() {
  local label="$1" want="$2" out; shift 2
  reset
  out="$(env "$@" "$NOTIFY" --source s-test "текст" 2>/dev/null)"
  [ "$out" = "iwe-notify: outcome=$want" ] \
    && ok "исход «${want}»: $label" || bad "исход «${want}»: $label" "stdout=$out"
}
outcome_case "Telegram подтвердил приём" sent GATEWAY_STAGE=sent GATEWAY_RC=0 IWE_ROOT="$WORK/iwe"
outcome_case "шлюз отложил в сводку" deferred GATEWAY_RC=0 IWE_ROOT="$WORK/iwe"
outcome_case "сбой транспорта у шлюза" transport-failed GATEWAY_RC=2 IWE_ROOT="$WORK/iwe"
outcome_case "карантин" quarantined GATEWAY_RC=3 IWE_ROOT="$WORK/iwe"
outcome_case "шлюз упал после начала отправки" skipped GATEWAY_STAGE=attempt GATEWAY_RC=143 IWE_ROOT="$WORK/iwe"
outcome_case "нет шлюза" direct-sent IWE_ROOT="$WORK/empty"
outcome_case "нет шлюза, Telegram отклонил" direct-failed CURL_RC=22 IWE_ROOT="$WORK/empty"
outcome_case "нет шлюза и ключей" not-sent TELEGRAM_BOT_TOKEN= IWE_ROOT="$WORK/empty"

outcome_case "шлюз упал после подтверждения Telegram" sent GATEWAY_STAGE=sent GATEWAY_RC=1 IWE_ROOT="$WORK/iwe"

# macOS system bash 3.2 (launchd jobs): an empty array under set -u must not
# stop the direct send (review 08.11). Skipped where /bin/bash is not 3.x.
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]'; then
  reset
  out="$(IWE_ROOT="$WORK/empty" /bin/bash "$NOTIFY" --source s-test "текст" 2>/dev/null)"
  [ "$out" = "iwe-notify: outcome=direct-sent" ] && [ "$(count "$CURL_CALLS")" = 1 ] \
    && ok "bash 3.2: прямая отправка без кнопок работает" || bad "bash 3.2" "stdout=$out curl=$(count "$CURL_CALLS")"
fi

# The gateway's own stdout never reaches the caller's outcome line.
reset
printf '%s\n' '#!/bin/bash' 'echo "noise on stdout"' 'exit 0' > "$WORK/noisy-gw"; chmod +x "$WORK/noisy-gw"
out="$(IWE_NOTIFY_GATEWAY="$WORK/noisy-gw" "$NOTIFY" --source s-test "текст" 2>/dev/null)"
[ "$out" = "iwe-notify: outcome=deferred" ] && ok "вывод шлюза не попадает в строку исхода" || bad "вывод шлюза" "stdout=$out"

# --reply-markup: with a gateway the text goes through it without buttons and
# its verdict stays final (quarantine -> no direct send); without a gateway the
# one direct send carries the buttons.
reset
GATEWAY_RC=3 IWE_ROOT="$WORK/iwe" "$NOTIFY" --source s-test --reply-markup '{"inline_keyboard":[]}' "текст" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(count "$GATEWAY_CALLS")" = 1 ] && ! grep -q "inline_keyboard" "$GATEWAY_CALLS" \
  && [ "$(count "$CURL_CALLS")" = 0 ] \
  && ok "кнопки при шлюзе: текст через шлюз без кнопок, карантин окончателен" \
  || bad "кнопки при шлюзе" "rc=$rc gateway=$(cat "$GATEWAY_CALLS" 2>&1) curl=$(count "$CURL_CALLS")"
reset
IWE_ROOT="$WORK/empty" "$NOTIFY" --source s-test --reply-markup '{"inline_keyboard":[]}' "текст" >/dev/null 2>&1
grep -q "reply_markup=" "$CURL_CALLS" 2>/dev/null && [ "$(count "$CURL_CALLS")" = 1 ] \
  && ok "кнопки без шлюза: одна прямая отправка с кнопками" || bad "кнопки без шлюза" "$(cat "$CURL_CALLS" 2>&1)"

# Copies of this canon (server-extensions, template) must be byte-equal, or the
# three hosts would run three different 0/2/3 contracts (peer-session
# 2026-11-08-06, Kimi). A copy whose repository is not on this host is skipped.
# IWE_NOTIFY_COPIES overrides the list (colon-separated paths).
COPIES="${IWE_NOTIFY_COPIES:-$HOME/IWE/iwe-server-config/server-extensions/scripts/iwe-notify:$HOME/IWE/FMT-exocortex-template/scripts/iwe-notify}"
IFS=: read -r -a copy_list <<< "$COPIES"
for copy in "${copy_list[@]}"; do
  if [ ! -d "$(dirname "$(dirname "$copy")")" ]; then
    echo "  ⏭  копия $copy: репозитория нет на этом хосте — пропуск"
  elif cmp -s "$NOTIFY" "$copy"; then
    ok "копия совпадает с каноном: $copy"
  else
    bad "копия расходится с каноном (перенесите scripts/iwe-notify побайтово)" "$copy"
  fi
done

echo "итог: ✅ $PASS  ❌ $FAIL"
[ "$FAIL" -eq 0 ]
