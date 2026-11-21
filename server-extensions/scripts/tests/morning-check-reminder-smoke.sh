#!/bin/bash
# Smoke test for .claude/hooks/morning-check-reminder.sh (WP-561 F78).
# Each scenario checks the context the conversation actually receives.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/.claude/hooks/morning-check-reminder.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/morning-check-smoke.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
FAILS=0

fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

# A governance repo with a fresh evening focus in the working file.
GOV="${WORK}/gov"
mkdir -p "${GOV}/current"
git -C "${GOV}" init -q
cat > "${GOV}/current/priorities.yaml" <<'EOF'
last_updated: "2026-11-21"
today:
  - WP-561
  - WP-151
EOF

run_hook() {  # <state dir> <entrypoint> <hour> [today] [session id; "-" = no hook input]
  local input='{"session_id": "'"${5:-s1}"'"}'
  [ "${5:-}" = - ] && input=''
  printf '%s' "${input}" | CLAUDE_PROJECT_DIR="${WORK}/project-$RANDOM" IWE_MORNING_CHECK_STATE_DIR="$1/.claude/state" \
    CLAUDE_CODE_ENTRYPOINT="$2" IWE_MORNING_CHECK_HOUR="$3" \
    IWE_MORNING_CHECK_TODAY="${4:-2026-11-21}" IWE_MORNING_CHECK_GOV_REPO="${GOV}" \
    bash "${HOOK}"
}
mark_asked() {  # <state dir> [today]
  IWE_MORNING_CHECK_STATE_DIR="$1/.claude/state" IWE_MORNING_CHECK_TODAY="${2:-2026-11-21}" \
    bash "${HOOK}" --asked >/dev/null
}
context_of() { jq -r '.hookSpecificOutput.additionalContext // ""'; }
publish_ledger() {  # <today> ; ledger text on stdin, committed and set as origin/main
  local path="machine/ledger/day/${1:0:4}/${1:5:2}/day-$1.yaml"
  mkdir -p "${GOV}/$(dirname "${path}")"
  cat > "${GOV}/${path}"
  git -C "${GOV}" -c user.email=t@t -c user.name=t add "${path}" >/dev/null
  git -C "${GOV}" -c user.email=t@t -c user.name=t commit -qm "ledger $1"
  git -C "${GOV}" update-ref refs/remotes/origin/main HEAD
}

# 1. Headless run is silent and does not take the day's question.
P1="${WORK}/p1"; mkdir -p "${P1}"
[ "$(run_hook "${P1}" sdk-cli 09)" = '{}' ] || fail "headless run must be silent"
[ ! -e "${P1}/.claude/state/morning-check-2026-11-21" ] || fail "headless run must not take the marker"

# 2. Before 05:00 is silent and does not take the marker.
[ "$(run_hook "${P1}" claude-vscode 04)" = '{}' ] || fail "before 05:00 must be silent"
[ ! -e "${P1}/.claude/state/morning-check-2026-11-21" ] || fail "before 05:00 must not take the marker"

# 3. First interactive conversation gets the offered focus and the state question,
#    to be asked first, before the work (21.11 it came at the end of a 52-minute answer).
CTX="$(run_hook "${P1}" claude-vscode 08 2026-11-21 s1 | context_of)"
case "${CTX}" in *"Выбор на сегодня, названный вчера"*"WP-561, WP-151"*) ;; *) fail "first conversation must see the evening choice: ${CTX:0:120}" ;; esac
case "${CTX}" in *"Первым блоком твоего ответа, до работы по поручению"*) ;; *) fail "question must be asked first, before the work" ;; esac
case "${CTX}" in *"в конце этого же ответа"*) fail "question must not be put at the end of the answer" ;; esac
case "${CTX}" in *'"choice": "offered"'*) ;; *) fail "evening focus must be recorded as offered" ;; esac
case "${CTX}" in *"шкале 0–5"*) ;; *) fail "state question missing" ;; esac
case "${CTX}" in *'morning-check-reminder.sh\" --asked'*|*'morning-check-reminder.sh" --asked'*) ;; *) fail "context must tell the agent to mark the day after asking" ;; esac
# The write command stays literal text for the agent (no substitution at hook time).
case "${CTX}" in *'ledger-append.sh" day 2026-11-21 pilot_answer "$(python3 -c'*) ;; *) fail "write command must stay literal" ;; esac
# The sample event is valid JSON with the evening items and the question id.
SAMPLE="$(printf '%s\n' "${CTX}" | grep -m1 '^{"subtype": "morning_check"')"
printf '%s' "${SAMPLE}" | jq -e '.focus.evening_items == ["WP-561","WP-151"] and .focus.choice == "offered" and .question_id == "morning-2026-11-21"' >/dev/null \
  || fail "sample event must be valid JSON with evening items and question id: ${SAMPLE:0:120}"
[ ! -e "${P1}/.claude/state/morning-check-2026-11-21" ] || fail "showing the instruction must not mark the day"

# 3a. The same conversation is not reminded twice.
[ "$(run_hook "${P1}" claude-vscode 08 2026-11-21 s1)" = '{}' ] || fail "same conversation must get the instruction once"

# 4. Another conversation before anyone asked still gets it (one ignoring conversation
#    no longer loses the day); after --asked every conversation is silent.
CTX="$(run_hook "${P1}" claude-vscode 09 2026-11-21 s2 | context_of)"
[ -n "${CTX}" ] || fail "second conversation must get the instruction while the day is not marked"
mark_asked "${P1}"
[ -d "${P1}/.claude/state/morning-check-2026-11-21" ] || fail "--asked must create the day marker"
[ "$(run_hook "${P1}" claude-vscode 09 2026-11-21 s3)" = '{}' ] || fail "after --asked a new conversation must be silent"

# 4a. Older host input without a session id: the day is marked at once, as before.
P9="${WORK}/p9"; mkdir -p "${P9}"
CTX="$(run_hook "${P9}" claude-vscode 08 2026-11-21 - | context_of)"
[ -n "${CTX}" ] || fail "without a session id the first conversation must still be asked"
[ "$(run_hook "${P9}" claude-vscode 08 2026-11-21 -)" = '{}' ] || fail "without a session id the second call must be silent"

# 5. Next day with a stale focus file asks the open question.
CTX="$(run_hook "${P1}" cli 07 2026-11-22 | context_of)"
case "${CTX}" in *"Что сегодня в выборе"*'"choice": "open"'*) ;;
  *) fail "stale focus must give the open question: ${CTX:0:120}" ;; esac

# 5a. Answered in Telegram already (pilot_answer wp 561 via telegram-reply on origin): silent.
publish_ledger 2026-11-23 <<'EOF2'
schema: ledger/v1
events:
- ts: '2026-11-23T05:10:00Z'
  source: telegram-poller
  kind: pilot_answer
  data:
    wp: '561'
    answer_text: да, 4
    channel: telegram-reply
  event_id: e1
EOF2
[ "$(run_hook "${P1}" claude-vscode 08 2026-11-23)" = '{}' ] || fail "answered in Telegram must be silent"
# An answer to another WP question in Telegram does not count.
P8="${WORK}/p8"; mkdir -p "${P8}"
sed "s/wp: '561'/wp: '484'/" "${GOV}/machine/ledger/day/2026/11/day-2026-11-23.yaml" | publish_ledger 2026-11-23
CTX="$(run_hook "${P8}" claude-vscode 08 2026-11-23 | context_of)"
[ -n "${CTX}" ] || fail "a Telegram answer to another WP must not silence the question"

# 5b. Answered in a conversation (morning_check for today): the first answer counts, silent.
P10="${WORK}/p10"; mkdir -p "${P10}"
publish_ledger 2026-11-24 <<'EOF3'
schema: ledger/v1
events:
- ts: '2026-11-24T06:00:00Z'
  source: morning-check
  kind: pilot_answer
  data:
    subtype: morning_check
    question_id: morning-2026-11-24
    for_date: '2026-11-24'
    state_morning: 4
  event_id: e2
EOF3
[ "$(run_hook "${P10}" claude-vscode 08 2026-11-24)" = '{}' ] || fail "a morning_check answer for today must silence the question"

# 5c. Delivered in Telegram, not answered: one-line reminder, the question is not repeated.
P11="${WORK}/p11"; mkdir -p "${P11}"
publish_ledger 2026-11-25 <<'EOF4'
schema: ledger/v1
events:
- ts: '2026-11-25T03:00:20Z'
  source: morning-check-telegram
  kind: morning_question_sent
  data:
    for_date: '2026-11-25'
    question_id: morning-2026-11-25
    channel: telegram
    message_id: '301'
  event_id: e3
EOF4
CTX="$(run_hook "${P11}" claude-vscode 08 2026-11-25 | context_of)"
case "${CTX}" in *"ждёт ответа в Telegram"*) ;; *) fail "delivered question must give a reminder: ${CTX:0:120}" ;; esac
case "${CTX}" in *"Не повторяй вопрос"*) ;; *) fail "delivered question must not be repeated" ;; esac
case "${CTX}" in *"задай два коротких вопроса"*) fail "delivered question must not be asked again" ;; esac

# 6. Kill switch.
P6="${WORK}/p6"; mkdir -p "${P6}"
[ "$(IWE_MORNING_CHECK=off run_hook "${P6}" claude-vscode 08)" = '{}' ] || fail "IWE_MORNING_CHECK=off must be silent"

# Every output is valid JSON for Claude Code.
P7="${WORK}/p7"; mkdir -p "${P7}"
run_hook "${P7}" claude-vscode 10 | jq -e . >/dev/null || fail "output must be valid JSON"

if [ "${FAILS}" -eq 0 ]; then
  echo "PASS: morning-check-reminder (12 scenarios)"
else
  echo "morning-check-reminder: ${FAILS} failure(s)"
  exit 1
fi
