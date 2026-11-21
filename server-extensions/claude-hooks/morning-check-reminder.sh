#!/bin/bash
# morning-check-reminder.sh
# Event: UserPromptSubmit
# WP-561 F77/F78 (pilot decision 20.11, option A; second-point rule 21.11): the
# slot protocol of WP-151 needs a morning answer, but day open runs unattended at
# 03:03. The morning question (confirm the choice for today named at last night's
# day close, productive state 0-5) goes to Telegram from tsekh-1; an interactive
# conversation on this host is the second point. The agent records the answer as
# one ledger event pilot_answer/morning_check.
#
# Three states of the day, read from the last fetched origin snapshot of the day
# ledger (no network call from a prompt hook):
#   (a) answered (Telegram reply for WP 561, or a morning_check answer): silent;
#   (b) the Telegram question was delivered (morning_question_sent), no answer:
#       one line at the start of the reply, the question is not repeated;
#   (c) no delivery recorded: the conversation asks the two questions itself,
#       at the start of its first reply, before the work it was asked to do.
# 21.11 the first conversation asked at the end of a 52-minute answer, as this
# hook then told it to, and the question went unanswered.
#
# The day is marked only when a conversation actually asked or reminded: the
# agent runs `morning-check-reminder.sh --asked` right after doing it. Until then
# each new conversation gets the instruction once (per session_id from the hook
# input), so one conversation that ignores it no longer loses the day.
#
# Other rules: only interactive Claude Code (CLAUDE_CODE_ENTRYPOINT set and not
# sdk-*); not before 05:00 local time; IWE_MORNING_CHECK=off disables it.
# Always prints valid JSON ('{}' when silent).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

silent() { echo '{}'; exit 0; }

TODAY="${IWE_MORNING_CHECK_TODAY:-$(date +%F)}"
STATE_DIR="${IWE_MORNING_CHECK_STATE_DIR:-$HOME/IWE/.claude/state}"
DAY_MARKER="${STATE_DIR}/morning-check-${TODAY}"

# The agent's own call after it asked or reminded: mark the day for this host.
if [ "${1:-}" = --asked ]; then
  mkdir -p "${DAY_MARKER}" || { echo "morning-check: day marker ${DAY_MARKER} not created" >&2; exit 1; }
  echo "morning-check: ${TODAY} marked as asked on this host"
  exit 0
fi

command -v jq >/dev/null 2>&1 || silent
[ "${IWE_MORNING_CHECK:-on}" = off ] && silent
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  "" | sdk*) silent ;;
esac

HOUR="${IWE_MORNING_CHECK_HOUR:-$(date +%H)}"
[ "$((10#${HOUR}))" -lt 5 ] && silent
[ -d "${DAY_MARKER}" ] && silent

INPUT=""
[ -t 0 ] || INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "${INPUT}" | jq -r '.session_id // empty' 2>/dev/null || true)

ROOT="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
GOV="${IWE_MORNING_CHECK_GOV_REPO:-${ROOT}/DS-my-strategy}"
LEDGER_TEXT=$(git -C "${GOV}" show "origin/main:machine/ledger/day/${TODAY:0:4}/${TODAY:5:2}/day-${TODAY}.yaml" 2>/dev/null || true)

# (a) Answered: a Telegram reply routed to WP 561 (the poller writes pilot_answer
# with wp 561 and channel telegram-reply) or a morning_check answer for today.
# The first accepted answer counts; no second question.
answered_today() {
  printf '%s\n' "${LEDGER_TEXT}" | awk -v day="${TODAY}" '
    function done_event() { if (kind && ((wp && tg) || (mc && fd))) found = 1; kind = wp = tg = mc = fd = 0 }
    /^- ts:/ { done_event() }
    /^  kind: pilot_answer$/ { kind = 1 }
    /^    wp: .?561.?$/ { wp = 1 }
    /^    channel: telegram-reply$/ { tg = 1 }
    /^    subtype: morning_check$/ { mc = 1 }
    /^    for_date: / { if (index($0, day)) fd = 1 }
    END { done_event(); exit !found }'
}
answered_today && silent

# (b) The Telegram question for today was delivered (morning-check-telegram.sh).
delivered_in_telegram() {
  printf '%s\n' "${LEDGER_TEXT}" | awk -v day="${TODAY}" '
    function done_event() { if (sent && fd) found = 1; sent = fd = 0 }
    /^- ts:/ { done_event() }
    /^  kind: morning_question_sent$/ { sent = 1 }
    /^    for_date: / { if (index($0, day)) fd = 1 }
    END { done_event(); exit !found }'
}

# Once per conversation until the day is marked. Without a session id (older
# host input) fall back to marking the day now, as before 21.11.
mkdir -p "${STATE_DIR}" 2>/dev/null || silent
if [ -n "${SESSION_ID}" ]; then
  mkdir -p "${STATE_DIR}/morning-check-${TODAY}.seen" 2>/dev/null || silent
  mkdir "${STATE_DIR}/morning-check-${TODAY}.seen/${SESSION_ID}" 2>/dev/null || silent
else
  mkdir "${DAY_MARKER}" 2>/dev/null || silent
fi

# Evening focus: day close writes tomorrow's WP items to priorities.yaml with
# last_updated = tomorrow. Anything older is not last night's answer.
# The shared checkout may lag behind the published close; the last fetched
# origin snapshot is the fallback (no network call from a prompt hook).
PRIORITIES_TEXT=""
if grep -q "^last_updated: \"${TODAY}\"" "${GOV}/current/priorities.yaml" 2>/dev/null; then
  PRIORITIES_TEXT=$(cat "${GOV}/current/priorities.yaml")
else
  SNAPSHOT=$(git -C "${GOV}" show origin/main:current/priorities.yaml 2>/dev/null || true)
  if printf '%s\n' "${SNAPSHOT}" | grep -q "^last_updated: \"${TODAY}\""; then
    PRIORITIES_TEXT="${SNAPSHOT}"
  fi
fi
FOCUS=""
if [ -n "${PRIORITIES_TEXT}" ]; then
  FOCUS=$(printf '%s\n' "${PRIORITIES_TEXT}" | awk '/^today:/{f=1; next} f && /^[^ #]/{f=0} f && /^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/, ""); printf "%s%s", sep, $0; sep=", "}')
fi
EVENING_JSON=$(printf '%s' "${FOCUS}" | jq -R -c 'split(", ") | map(select(length > 0))')
if [ -n "${FOCUS}" ]; then
  FOCUS_LINE="Выбор на сегодня, названный вчера на закрытии дня: ${FOCUS}. Вопрос: «Выбор на сегодня — ${FOCUS}: подтвердить, поправить или назвать своё?»"
  CHOICE="offered"
else
  FOCUS_LINE="Вчера вечером выбор на сегодня не записан (priorities.yaml не обновлён на ${TODAY}). Вопрос открытый: «Что сегодня в выборе? 1–3 пункта — РП или потребность»."
  CHOICE="open"
fi

if delivered_in_telegram; then
  ASK="Утренний вопрос уже доставлен пилоту в Telegram, ответа пока нет. Не повторяй вопрос. Первой строкой твоего ответа, до работы по поручению, одной фразой: «☀️ Утренний вопрос (выбор на сегодня и состояние 0–5) ждёт ответа в Telegram; можно ответить и здесь.»
Для записи ответа, если пилот ответит здесь: 1) ${FOCUS_LINE} 2) «Продуктивное состояние сейчас по шкале 0–5?»"
else
  ASK="Первым блоком твоего ответа, до работы по поручению, задай два коротких вопроса:
1) ${FOCUS_LINE}
2) «Продуктивное состояние сейчас по шкале 0–5?»
Затем делай то, о чём просит пилот; работу ответом не блокировать."
fi

CTX="☀️ УТРЕННЯЯ СВЕРКА (РП-561 Ф78, протокол слотов РП-151, окно до 01.12; вопрос дня ещё не задан ни одной беседой на этой машине).
${ASK}
Сразу, в этом же ответе, после того как задал вопрос или напомнил, отметь день, чтобы другие беседы молчали: bash \"\$HOME/IWE/.claude/hooks/morning-check-reminder.sh\" --asked
Когда пилот ответит (в любом следующем сообщении этой беседы), сначала проверь, нет ли уже ответа за ${TODAY} в журнале дня (событие pilot_answer из Telegram для wp 561 или morning_check): засчитывается первый ответ; если ответ уже есть и отличается — покажи пилоту расхождение как уточнение и второй раз не записывай. Иначе запиши одно событие: JSON — инструментом записи файлов в \${TMPDIR:-/tmp}/morning-check-${TODAY}.json:
{\"subtype\": \"morning_check\", \"question_id\": \"morning-${TODAY}\", \"for_date\": \"${TODAY}\", \"channel\": \"chat\", \"focus\": {\"stage\": \"morning\", \"choice\": \"${CHOICE}\", \"evening_items\": ${EVENING_JSON}, \"answer\": \"confirmed\", \"items\": [\"WP-561\"]}, \"state_morning\": 3}
(образец: answer — confirmed, corrected или own; items — итоговые пункты пилота; state_morning — число 0–5 или null, если на этот вопрос пилот не ответил)
затем: bash \"\$HOME/IWE/DS-my-strategy/scripts/ledger-append.sh\" day ${TODAY} pilot_answer \"\$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding=\"utf-8\")), ensure_ascii=False))' \"\${TMPDIR:-/tmp}/morning-check-${TODAY}.json\")\" morning-check
Пропущенный ответ — null («нет данных»), не 0; при открытом вопросе answer всегда own; голое «да» на предложенный выбор — confirmed. Блок называть «выбор на сегодня», не «фокус»: «фокус дня» утром показывает Визионер (РП-622), это другое (РП-561 И-19). Пилот не ответил ни на один вопрос — событие не записывать."

jq -n --arg ctx "${CTX}" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
