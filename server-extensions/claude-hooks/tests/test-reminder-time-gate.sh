#!/usr/bin/env bash
# test-reminder-time-gate.sh — reminders and events before 09:00 MSK (WP-538/568).
# Each case feeds a PreToolUse event and checks the decision the hook prints.
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/.." && pwd)/reminder-time-gate.py"
fails=0

# check <want: deny|ask|pass> <description> <event json>
check() {
  local want="$1" what="$2" out got
  out=$(printf '%s' "$3" | python3 "$HOOK" 2>/dev/null)
  got=$(printf '%s' "$out" | python3 -c 'import json,sys
t=sys.stdin.read().strip()
print(json.loads(t)["hookSpecificOutput"]["permissionDecision"] if t else "pass")')
  if [ "$got" = "$want" ]; then echo "  ok   ${what}"; else echo "  FAIL ${what} (got ${got}, want ${want}): ${out}"; fails=$((fails + 1)); fi
}

tg() { printf '{"tool_name":"mcp__iwe-knowledge__send_telegram_message","tool_input":{"text":"t"%s}}' "$1"; }
cal() { printf '{"tool_name":"mcp__claude_ai_Google_Calendar__create_event","tool_input":{"summary":"s","endTime":"x"%s}}' "$1"; }

echo "Telegram"
check pass "immediate message, no schedule" "$(tg '')"
check pass "05:30Z = 08:30 MSK" "$(tg ',"schedule_at":"2026-11-17T05:30:00Z"')"
check ask  "06:00Z = 09:00 MSK exactly" "$(tg ',"schedule_at":"2026-11-17T06:00:00Z"')"
check ask  "07:02Z = 10:02 MSK (incident 16.11)" "$(tg ',"schedule_at":"2026-11-17T07:02:00Z"')"
check pass "22:00Z = 01:00 MSK next day is before 09:00" "$(tg ',"schedule_at":"2026-11-16T22:00:00Z"')"
check pass "lower-case z is UTC too" "$(tg ',"schedule_at":"2026-11-17T05:30:00z"')"
check deny "no zone: the bot reads it as UTC" "$(tg ',"schedule_at":"2026-11-17T08:30:00"')"
check deny "offset +03:00: the bot drops it" "$(tg ',"schedule_at":"2026-11-17T08:30:00+03:00"')"
check ask  "unparseable time asks, never passes" "$(tg ',"schedule_at":"tomorrowZ"')"

echo "Calendar"
check pass "08:30 Europe/Moscow" "$(cal ',"startTime":"2026-11-17T08:30:00","timeZone":"Europe/Moscow"')"
check ask  "09:30 Europe/Moscow" "$(cal ',"startTime":"2026-11-17T09:30:00","timeZone":"Europe/Moscow"')"
check ask  "08:30 Asia/Nicosia = 09:30 MSK" "$(cal ',"startTime":"2026-11-17T08:30:00","timeZone":"Asia/Nicosia"')"
check ask  "07:30 with no zone: the calendar may read it as UTC (10:30 MSK)" "$(cal ',"startTime":"2026-11-17T07:30:00"')"
check pass "05:30Z on a calendar event" "$(cal ',"startTime":"2026-11-17T05:30:00Z"')"
check pass "all-day event" "$(cal ',"startTime":"2026-11-17T00:00:00","allDay":true')"
check pass "update without a new time" '{"tool_name":"mcp__claude_ai_Google_Calendar__update_event","tool_input":{"eventId":"e","summary":"s"}}'
check ask  "update moving only the time zone" '{"tool_name":"mcp__claude_ai_Google_Calendar__update_event","tool_input":{"eventId":"e","timeZone":"Asia/Tokyo"}}'
check ask  "unknown zone name asks" "$(cal ',"startTime":"2026-11-17T07:00:00","timeZone":"Mars/Base"')"

echo "Other"
check pass "other tool untouched" '{"tool_name":"mcp__iwe-knowledge__search","tool_input":{"q":"x"}}'
check ask  "broken input asks" 'not json'

echo
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "${fails} FAIL(S)"; exit 1; }
