#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# payment-registry-alert.sh — one incident per outage of the payment registry
# exchange (WP-568, 02.11): the night of 01-02.11 sent about 75 identical chat
# messages, one per failed tick of three services, for a single cause: the LMS
# database did not answer.
#
# Usage: payment-registry-alert.sh failure|success <unit>
#
# failure: announces the incident in the chat at once; while it lasts, repeats
#          at most once per PR_ALERT_REPEAT_SEC, whichever of the three services
#          fails — as a line in the morning digest, not the chat (WP-568 Ф12 П5,
#          06.11: an LMS outage of four days gave 4 chat messages a day). With no
#          digest on the host the repeat goes to the chat as before.
# success: forgets this service's failure; once none is failing, sends a single
#          recovery message (only if the incident was announced).
set -uo pipefail

mode="${1:?failure|success}"
unit="${2:?unit name}"
state_dir="${HOME:-/home/tseren}/IWE/.claude/state/failure-alert/payment-registry"
repeat_sec="${PR_ALERT_REPEAT_SEC:-21600}"
now=$(date +%s)

case "$unit" in
  payment-registry-sync-payment.service)      what="платежи" ;;
  payment-registry-sync-subscription.service) what="подписки" ;;
  payment-registry-sync-contract.service)     what="договоры" ;;
  *) echo "неизвестная служба: $unit" >&2; exit 2 ;;
esac

# Only the personal chat decides success: a failed team copy must not re-announce.
send_direct() {
  send_tg "${TELEGRAM_CHAT_ID}" "$1" || return 1
  if [ -n "${TELEGRAM_TEAM_CHAT_ID:-}" ]; then
    send_tg "${TELEGRAM_TEAM_CHAT_ID}" "$1" || echo "не доставлено в командный чат" >&2
  fi
}

send_tg() {
  curl -s --fail --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=$1" --data-urlencode "text=$2" > /dev/null
}

# repeat_via_gateway <text>: the shared gateway (iwe-tg, source iwe-failure-alert,
# channel "decision" without TELEGRAM_NEEDS_DECISION) puts the repeat into the
# digest, or delivers it live itself where no digest is read on the host. Either
# outcome is a delivery; a refusal (no gateway, quarantine, failed digest write)
# returns 1 and the caller sends it directly as before.
repeat_via_gateway() {
  command -v iwe-tg >/dev/null 2>&1 || return 1
  local out
  out=$(iwe-tg --source iwe-failure-alert "$1" 2>&1) || { echo "шлюз отказал: $out" >&2; return 1; }
  case "$out" in
    *"iwe-tg: outcome=deferred"*|*"iwe-tg: outcome=sent"*) return 0 ;;
  esac
  echo "шлюз не подтвердил доставку, отправляю сам: $out" >&2
  return 1
}

# Duration in Russian without declension traps: "2 ч 15 мин", "40 мин".
human_duration() {
  local minutes=$(( $1 / 60 ))
  if [ "$minutes" -ge 60 ]; then
    echo "$((minutes / 60)) ч $((minutes % 60)) мин"
  else
    echo "$minutes мин"
  fi
}

# Only fixed phrases leave this function: the journal itself may hold payment
# data and must not reach the chat. The window keeps earlier runs out: the alert
# starts right after the failure, whose final line is the one matched here.
cause_of() {
  local tail_log
  tail_log=$(journalctl -u "$1" --since "-1min" --no-pager -o cat 2>/dev/null) || tail_log=""
  case "$tail_log" in
    *"Cannot read Aisystant"*|*"Failed to fetch subscriptions from Aisystant"*)
      echo "не читается база Aisystant (сервер LMS не отвечает или отказал в доступе)|проверить сервер LMS и сообщить его администратору; сам реестр чинить не нужно" ;;
    *)
      echo "по журналу не определена|открыть новую беседу с Claude и сказать «разбери сбой платёжного реестра»" ;;
  esac
}

failing_list() {
  local f names=""
  for f in "$state_dir"/failing/*; do
    [ -e "$f" ] || continue
    names="${names:+$names, }$(basename "$f")"
  done
  echo "$names"
}

mkdir -p "$state_dir/failing" || exit 1
exec 9>"$state_dir/lock"
flock 9 || exit 1

announced_at=$(cat "$state_dir/announced-at" 2>/dev/null) || announced_at=""
case "$announced_at" in ""|*[!0-9]*) announced_at=0 ;; esac
since=$(cat "$state_dir/since" 2>/dev/null) || since=""
case "$since" in ""|*[!0-9]*) since=$now ;; esac

if [ "$mode" = "failure" ]; then
  : > "$state_dir/failing/$what"
  [ -f "$state_dir/since" ] || echo "$now" > "$state_dir/since"
  if [ "$announced_at" -gt 0 ] && [ $((now - announced_at)) -lt "$repeat_sec" ]; then
    echo "инцидент уже объявлен, повтор подавлен: $what"
    exit 0
  fi
  cause=$(cause_of "$unit")
  if [ "$announced_at" -gt 0 ]; then
    head="🚨 Платёжный реестр: обмена нет уже $(human_duration $((now - since))) ($(failing_list))."
  else
    head="🚨 Платёжный реестр: нет обмена данными ($(failing_list))."
  fi
  text="$head
Причина: ${cause%%|*}.
Данные, как правило, не теряются: после восстановления обмен догонит их сам.
Что делать: ${cause#*|}.
Следующее сообщение в чат: при восстановлении. Пока простой длится, раз в $((repeat_sec / 3600)) ч — строка в утренней сводке."
  if [ "$announced_at" -gt 0 ] && repeat_via_gateway "$text"; then
    echo "$now" > "$state_dir/announced-at"
    exit 0
  fi
  # A failed send leaves announced-at untouched, so the next tick retries.
  send_direct "$text" || exit 1
  echo "$now" > "$state_dir/announced-at"
  exit 0
fi

rm -f "$state_dir/failing/$what"
[ -z "$(failing_list)" ] || exit 0
if [ "$announced_at" -gt 0 ]; then
  send_direct "✅ Платёжный реестр: обмен восстановлен, простой $(human_duration $((now - since))). Отставшие данные подтягиваются штатно." || exit 1
fi
rm -f "$state_dir/announced-at" "$state_dir/since"
