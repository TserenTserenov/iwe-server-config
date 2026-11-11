#!/usr/bin/env bash
# Reserve the pilot's time for a session that has just opened (WP-561 Ф55).
#
#   plan-reserve-on-open.sh WP-N SESSION_ID MINUTES
#
# Called by `session-guard.sh open --estimate-minutes N`, so the reservation no
# longer depends on an agent remembering the protocol-open extension. Picks the
# channel the host has: the bridge receiver socket on Tsekh, the forced-command
# Mac key otherwise; with neither it submits nothing. Prints one line for the
# agent to relay to the pilot and always exits 0: a reservation problem must
# never fail `open`. The bridge decides the reservation against the day budget
# later; this script only submits it (plan-session-reserve.py, exit codes there).
set -u

wp="${1:?usage: plan-reserve-on-open.sh WP-N SESSION_ID MINUTES}"
session="${2:?session id required}"
minutes="${3:?minutes required}"
iwe_root="${IWE_ROOT:-$HOME/IWE}"
socket="${IWE_PLAN_RECEIVER_SOCKET:-/run/iwe-plan-bridge/receiver.sock}"
mac_key="${IWE_PLAN_MAC_KEY:-$HOME/.ssh/iwe-plan-mac}"
mac_target="${IWE_PLAN_MAC_TARGET:-iwe-plan-mac@95.216.75.148}"

case "$wp" in WP-[0-9]*) ;; *) exit 0 ;; esac
case "$minutes" in '' | *[!0-9]* | 0) echo "⚠️  Бронь времени не подана: оценка «${minutes}» — не число минут" >&2; exit 0 ;; esac

reserve() {  # extra arguments go to the reservation client
  if [ -S "$socket" ]; then
    timeout 90 python3 "$iwe_root/DS-my-strategy/scripts/plan-session-reserve.py" \
      --wp "$wp" --session "$session" --minutes "$minutes" "$@"
  elif [ -f "$mac_key" ]; then
    timeout 90 ssh -i "$mac_key" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o ConnectTimeout=10 "$mac_target" \
      reserve --wp "$wp" --session "$session" --minutes "$minutes" "$@"
  else
    return 3
  fi
}

event_id_of() {  # reservation_event_id from the client's JSON line
  python3 -c 'import json, sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["reservation_event_id"])' 2>/dev/null
}

output=$(reserve 2>/dev/null)
code=$?
if [ "$code" -eq 4 ]; then
  # Reservation in, start not: resend only the start, or tomorrow's answer
  # to the daily summary cannot close this reservation.
  event_id=$(printf '%s\n' "$output" | event_id_of)
  if [ -n "$event_id" ]; then
    output=$(reserve --resume-start "$event_id" 2>/dev/null)
    code=$?
  fi
fi

case "$code" in
  0) echo "Бронь времени пилота: $minutes мин на $wp сегодня подана (решение по дневному бюджету принимает мост)" ;;
  3) ;;  # no channel on this host: nothing submitted, nothing to tell
  5) echo "⚠️  Бронь времени не подана: очередь была занята; повторить: bash $iwe_root/scripts/plan-reserve-on-open.sh $wp $session $minutes" >&2 ;;
  4) echo "⚠️  Бронь подана, а отметка о начале не дошла: повторить ту же команду с --resume-start (plan-session-reserve.py)" >&2 ;;
  255) echo "⚠️  Бронь времени не подана: нет связи с «Цехом»; повторить позже: bash $iwe_root/scripts/plan-reserve-on-open.sh $wp $session $minutes" >&2 ;;
  *) reason=$(printf '%s\n' "$output" | python3 -c 'import json, sys
try:
    r = json.loads(sys.stdin.read().strip().splitlines()[-1])
    print(r.get("code") or (r.get("reservation") or {}).get("code") or "")
except Exception:
    print("")' 2>/dev/null)
     echo "⚠️  Бронь времени не подана: отказ приёмника ${reason:-без кода} (код $code); вручную не повторять, показать пилоту" >&2 ;;
esac
exit 0
