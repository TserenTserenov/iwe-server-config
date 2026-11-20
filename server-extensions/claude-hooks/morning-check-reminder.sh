#!/bin/bash
# morning-check-reminder.sh
# Event: UserPromptSubmit
# WP-561 F77/F78 (pilot decision 20.11, option A): the slot protocol of WP-151
# needs a morning answer, but day open runs unattended at 03:03. The first
# interactive conversation of the local day asks the pilot two questions:
# confirm today's focus named at last night's day close, and the productive
# state mark 0-5; the agent records the answer as one ledger event
# pilot_answer/morning_check.
#
# Behaviour:
#   - only interactive Claude Code (CLAUDE_CODE_ENTRYPOINT set and not sdk-*):
#     headless `claude -p` runs never take the day's question;
#   - not before 05:00 local time: a conversation after midnight belongs to
#     the previous working day;
#   - once per host and local date: an atomic mkdir marker in the host-wide
#     state dir (not per project), the first conversation that gets it wins,
#     the rest stay silent. Known limit: if that conversation never asks, the
#     day's morning answer is lost ("no data"), by design no re-asking;
#   - IWE_MORNING_CHECK=off disables it.
# Always prints valid JSON ('{}' when silent).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

silent() { echo '{}'; exit 0; }

command -v jq >/dev/null 2>&1 || silent
[ "${IWE_MORNING_CHECK:-on}" = off ] && silent
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  "" | sdk*) silent ;;
esac

TODAY="${IWE_MORNING_CHECK_TODAY:-$(date +%F)}"
HOUR="${IWE_MORNING_CHECK_HOUR:-$(date +%H)}"
[ "$((10#${HOUR}))" -lt 5 ] && silent

ROOT="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="${IWE_MORNING_CHECK_STATE_DIR:-$HOME/IWE/.claude/state}"
mkdir -p "${STATE_DIR}" 2>/dev/null || silent
mkdir "${STATE_DIR}/morning-check-${TODAY}" 2>/dev/null || silent

GOV="${IWE_MORNING_CHECK_GOV_REPO:-${ROOT}/DS-my-strategy}"
# Already answered in Telegram (morning-check-telegram.sh on tsekh-1; the poller writes
# pilot_answer with wp 561 and channel telegram-reply): this conversation does not ask
# again. Read from the last fetched origin snapshot, no network call from a prompt hook.
answered_in_telegram() {
  git -C "${GOV}" show "origin/main:machine/ledger/day/${TODAY:0:4}/${TODAY:5:2}/day-${TODAY}.yaml" 2>/dev/null \
    | awk '
        /^- ts:/ { if (kind && wp && tg) found = 1; kind = wp = tg = 0 }
        /^  kind: pilot_answer$/ { kind = 1 }
        /^    wp: .?561.?$/ { wp = 1 }
        /^    channel: telegram-reply$/ { tg = 1 }
        END { if (kind && wp && tg) found = 1; exit !found }'
}
answered_in_telegram && silent

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

CTX="☀️ УТРЕННЯЯ СВЕРКА (РП-561 Ф78, протокол слотов РП-151, окно до 01.12; это первая беседа дня на этой машине, вопрос задаётся один раз в день).
Сделай то, о чём просит пилот, как обычно, а в конце этого же ответа, перед строкой «Дальше:», отдельным коротким блоком задай два вопроса:
1) ${FOCUS_LINE}
2) «Продуктивное состояние сейчас по шкале 0–5?»
Работу ответом не блокировать и вопрос не повторять. Когда пилот ответит (в любом следующем сообщении этой беседы), запиши одно событие: JSON — инструментом записи файлов в \${TMPDIR:-/tmp}/morning-check-${TODAY}.json:
{\"subtype\": \"morning_check\", \"for_date\": \"${TODAY}\", \"focus\": {\"stage\": \"morning\", \"choice\": \"${CHOICE}\", \"evening_items\": ${EVENING_JSON}, \"answer\": \"confirmed\", \"items\": [\"WP-561\"]}, \"state_morning\": 3}
(образец: answer — confirmed, corrected или own; items — итоговые пункты пилота; state_morning — число 0–5 или null, если на этот вопрос пилот не ответил)
затем: bash \"\$HOME/IWE/DS-my-strategy/scripts/ledger-append.sh\" day ${TODAY} pilot_answer \"\$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding=\"utf-8\")), ensure_ascii=False))' \"\${TMPDIR:-/tmp}/morning-check-${TODAY}.json\")\" morning-check
Пропущенный ответ — null («нет данных»), не 0; при открытом вопросе answer всегда own; голое «да» на предложенный выбор — confirmed. Блок называть «выбор на сегодня», не «фокус»: «фокус дня» утром показывает Визионер (РП-622), это другое (РП-561 И-19). Пилот не ответил ни на один вопрос — событие не записывать."

jq -n --arg ctx "${CTX}" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
