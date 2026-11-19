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

echo
echo "Итог: $PASS прошло, $FAIL не прошло"
[[ "$FAIL" -eq 0 ]]
