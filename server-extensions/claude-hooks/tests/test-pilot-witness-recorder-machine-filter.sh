#!/usr/bin/env bash
# Regression (WP-484, 19.11, live case 18.11 x3): pilot-witness-recorder.sh wrote a
# background-task notification, delivered as a prompt, into the pilot-witness file,
# and the reflection step took it as the pilot's answer. The hook must skip the two
# confirmed machine signatures and keep everything else, including look-alikes.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pilot-witness-recorder.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1 — $2"; FAIL=$((FAIL + 1)); }

SID="test-session-1"
FILE="$SANDBOX/.iwe-runtime/pilot-witness/$SID.jsonl"

# send <prompt>: feed one UserPromptSubmit payload to the hook; exit code must stay 0.
send() {
  local rc
  jq -cn --arg sid "$SID" --arg prompt "$1" '{session_id:$sid,prompt:$prompt}' \
    | IWE_ROOT="$SANDBOX" bash "$HOOK"
  rc=$?
  [[ "$rc" -eq 0 ]] || fail "хук не должен блокировать ввод" "код возврата $rc"
}
lines() { [[ -f "$FILE" ]] && wc -l < "$FILE" | tr -d ' ' || echo 0; }
last_text() { tail -n 1 "$FILE" | jq -r '.text'; }

echo "== pilot-witness-recorder: машинные сообщения не пишутся =="

NOTE=$'<task-notification>\n<task-id>bz059h5zg</task-id>\n<status>completed</status>\n</task-notification>'

send "$NOTE"
[[ "$(lines)" == "0" ]] && ok "голое <task-notification> не записано" || fail "голое <task-notification> не записано" "строк: $(lines)"

send $'[SYSTEM NOTIFICATION - NOT USER INPUT]\nThis is an automated background-task event.\n\n'"$NOTE"
[[ "$(lines)" == "0" ]] && ok "уведомление с преамбулой не записано" || fail "уведомление с преамбулой не записано" "строк: $(lines)"

send $'\r\n  \n<task-notification>\r\n<status>completed</status>\r\n</task-notification>'
[[ "$(lines)" == "0" ]] && ok "ведущие пробелы и CRLF не прячут уведомление" || fail "ведущие пробелы и CRLF не прячут уведомление" "строк: $(lines)"

send $'<agent-message from="a7296090177c0e1a3">\n[Subagent hand-back] отчёт проверки\n</agent-message>'
[[ "$(lines)" == "0" ]] && ok "отчёт субагента (<agent-message) не записан" || fail "отчёт субагента (<agent-message) не записан" "строк: $(lines)"

echo "== настоящие сообщения и похожий текст сохраняются =="

send "1 и 3"
[[ "$(lines)" == "1" && "$(last_text)" == "1 и 3" ]] && ok "обычный ответ записан" || fail "обычный ответ записан" "строк: $(lines)"

for LOOKALIKE in '<не-делай>это так</не-делай>' 'ответ про [SYSTEM NOTIFICATION в середине фразы' 'пишу о теге <task-notification> как о примере' '<send_user_message_question_reply>да, делай</send_user_message_question_reply>' 'пишу про тег <agent-message в середине'; do
  BEFORE=$(lines)
  send "$LOOKALIKE"
  [[ "$(lines)" == "$((BEFORE + 1))" && "$(last_text)" == "$LOOKALIKE" ]] \
    && ok "похожий текст записан: $LOOKALIKE" || fail "похожий текст записан: $LOOKALIKE" "строк: $(lines)"
done

BEFORE=$(lines)
jq -cn --arg sid "$SID" '{session_id:$sid,prompt:null}' | IWE_ROOT="$SANDBOX" bash "$HOOK"
[[ "$?" -eq 0 && "$(lines)" == "$BEFORE" ]] && ok "prompt: null — ничего не записано, ввод не блокируется" || fail "prompt: null" "строк: $(lines)"

echo "== WP-484 И-47: будильник ScheduleWakeup =="
TR="$SANDBOX/transcript.jsonl"
now_iso() { date -u -v"${1:-+0S}" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "${1:-0 sec}" +%Y-%m-%dT%H:%M:%S.000Z; }
schedule_call() { # <prompt>: an assistant ScheduleWakeup call, JSON with spaces after colons
  jq -n --arg p "$1" '{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "ScheduleWakeup", "input": {"delaySeconds": 3600, "prompt": $p}}]}}'
}
user_entry() { # <text> <timestamp> [wakeup]
  jq -cn --arg t "$1" --arg ts "$2" --arg w "${3:-}" '{type: "user", timestamp: $ts, message: {role: "user", content: $t}}
    + (if $w == "" then {} else {wakeupSource: "loop_wakeup", turnOrigin: "scheduled", isMeta: true} end)'
}
send_tr() { # <prompt> [extra-json]: payload with transcript_path
  jq -cn --arg sid "$SID" --arg prompt "$1" --arg tr "$TR" --argjson extra "${2:-{\}}" \
    '{session_id: $sid, prompt: $prompt, transcript_path: $tr} + $extra' | IWE_ROOT="$SANDBOX" bash "$HOOK"
}
WAKE="РП-529, выпуск 0.42.2. Проверь время (date -u)."

: > "$TR"
BEFORE=$(lines)
send_tr "$WAKE" '{"wakeupSource": "loop_wakeup"}'
[[ "$(lines)" == "$BEFORE" ]] && ok "признак wakeupSource во входе: не записано" || fail "признак wakeupSource во входе" "строк: $(lines)"
send_tr "$WAKE" '{"turnOrigin": "scheduled"}'
[[ "$(lines)" == "$BEFORE" ]] && ok "признак turnOrigin=scheduled во входе: не записано" || fail "признак turnOrigin во входе" "строк: $(lines)"

{ schedule_call "$WAKE" | jq -c .; user_entry "$WAKE" "$(now_iso)" wakeup; } > "$TR"
send_tr "$WAKE"
[[ "$(lines)" == "$BEFORE" ]] && ok "свежая запись будильника в записи беседы: не записано" || fail "свежая запись будильника" "строк: $(lines)"

{ schedule_call "часы: 3" | jq -c .; user_entry "часы: 3" "$(now_iso -1H)" wakeup; } > "$TR"
send_tr "часы: 3"
[[ "$(lines)" == "$((BEFORE + 1))" && "$(last_text)" == "часы: 3" ]] \
  && ok "старый будильник «часы: 3», текущей записи нет: ответ пилота записан" || fail "старый будильник с тем же текстом" "строк: $(lines)"
[[ "$(tail -n 1 "$FILE" | jq -r '.suspected_wakeup')" == "true" ]] \
  && ok "совпадение с текстом будильника помечено suspected_wakeup" || fail "пометка suspected_wakeup" "$(tail -n 1 "$FILE")"

{ user_entry "часы: 3" "$(now_iso)"; } > "$TR"
send_tr "часы: 3"
[[ "$(lines)" == "$((BEFORE + 2))" && "$(tail -n 1 "$FILE" | jq -r '.suspected_wakeup')" == "null" ]] \
  && ok "свежая реплика пилота без признака будильника записана без пометки" || fail "реплика пилота без признака" "$(tail -n 1 "$FILE")"
[[ "$(tail -n 1 "$FILE" | jq -c '.input_keys')" == '["prompt","session_id","transcript_path"]' ]] \
  && ok "в записи — имена полей входа хука, без значений" || fail "input_keys" "$(tail -n 1 "$FILE")"

rm -f "$TR"
send_tr "ответ без записи беседы"
[[ "$(lines)" == "$((BEFORE + 3))" ]] && ok "запись беседы недоступна: ответ записан как раньше" || fail "запись беседы недоступна" "строк: $(lines)"

[[ ! -e "$SANDBOX/.iwe-runtime/pilot-witness-recorder.diag.log" ]] \
  && ok "журнал диагностики больше не пишется" || fail "журнал диагностики" "файл есть"

echo
echo "Итог: $PASS прошло, $FAIL не прошло"
[[ "$FAIL" -eq 0 ]]
