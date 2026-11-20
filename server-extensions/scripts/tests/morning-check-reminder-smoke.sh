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

run_hook() {  # <state dir> <entrypoint> <hour> [today]
  CLAUDE_PROJECT_DIR="${WORK}/project-$RANDOM" IWE_MORNING_CHECK_STATE_DIR="$1/.claude/state" \
    CLAUDE_CODE_ENTRYPOINT="$2" IWE_MORNING_CHECK_HOUR="$3" \
    IWE_MORNING_CHECK_TODAY="${4:-2026-11-21}" IWE_MORNING_CHECK_GOV_REPO="${GOV}" \
    bash "${HOOK}"
}
context_of() { jq -r '.hookSpecificOutput.additionalContext // ""'; }

# 1. Headless run is silent and does not take the day's question.
P1="${WORK}/p1"; mkdir -p "${P1}"
[ "$(run_hook "${P1}" sdk-cli 09)" = '{}' ] || fail "headless run must be silent"
[ ! -e "${P1}/.claude/state/morning-check-2026-11-21" ] || fail "headless run must not take the marker"

# 2. Before 05:00 is silent and does not take the marker.
[ "$(run_hook "${P1}" claude-vscode 04)" = '{}' ] || fail "before 05:00 must be silent"
[ ! -e "${P1}/.claude/state/morning-check-2026-11-21" ] || fail "before 05:00 must not take the marker"

# 3. First interactive conversation gets the offered focus and the state question.
CTX="$(run_hook "${P1}" claude-vscode 08 | context_of)"
case "${CTX}" in *"Выбор на сегодня, названный вчера"*"WP-561, WP-151"*) ;; *) fail "first conversation must see the evening choice: ${CTX:0:120}" ;; esac
case "${CTX}" in *'"choice": "offered"'*) ;; *) fail "evening focus must be recorded as offered" ;; esac
case "${CTX}" in *"шкале 0–5"*) ;; *) fail "state question missing" ;; esac
# The write command stays literal text for the agent (no substitution at hook time).
case "${CTX}" in *'ledger-append.sh" day 2026-11-21 pilot_answer "$(python3 -c'*) ;; *) fail "write command must stay literal" ;; esac
# The sample event is valid JSON with the evening items.
SAMPLE="$(printf '%s\n' "${CTX}" | grep -m1 '^{"subtype": "morning_check"')"
printf '%s' "${SAMPLE}" | jq -e '.focus.evening_items == ["WP-561","WP-151"] and .focus.choice == "offered"' >/dev/null \
  || fail "sample event must be valid JSON with evening items: ${SAMPLE:0:120}"

# 4. Second conversation the same day is silent, even from another project dir
#    (run_hook gives every call a fresh CLAUDE_PROJECT_DIR; the marker is host-wide).
[ "$(run_hook "${P1}" claude-vscode 09)" = '{}' ] || fail "second conversation must be silent"

# 5. Next day with a stale focus file asks the open question.
CTX="$(run_hook "${P1}" cli 07 2026-11-22 | context_of)"
case "${CTX}" in *"Что сегодня в выборе"*'"choice": "open"'*) ;;
  *) fail "stale focus must give the open question: ${CTX:0:120}" ;; esac

# 5a. Answered in Telegram already (pilot_answer wp 561 via telegram-reply on origin): silent.
LEDGER="machine/ledger/day/2026/11/day-2026-11-23.yaml"
mkdir -p "${GOV}/$(dirname "${LEDGER}")"
cat > "${GOV}/${LEDGER}" <<'EOF2'
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
git -C "${GOV}" -c user.email=t@t -c user.name=t add "${LEDGER}" >/dev/null
git -C "${GOV}" -c user.email=t@t -c user.name=t commit -qm ledger
git -C "${GOV}" update-ref refs/remotes/origin/main HEAD
[ "$(run_hook "${P1}" claude-vscode 08 2026-11-23)" = '{}' ] || fail "answered in Telegram must be silent"
# An answer to another WP question in Telegram does not count.
sed -i.bak "s/wp: '561'/wp: '484'/" "${GOV}/${LEDGER}"
git -C "${GOV}" -c user.email=t@t -c user.name=t commit -qam other
git -C "${GOV}" update-ref refs/remotes/origin/main HEAD
P8="${WORK}/p8"; mkdir -p "${P8}"
CTX="$(run_hook "${P8}" claude-vscode 08 2026-11-23 | context_of)"
[ -n "${CTX}" ] || fail "a Telegram answer to another WP must not silence the question"

# 6. Kill switch.
P6="${WORK}/p6"; mkdir -p "${P6}"
[ "$(IWE_MORNING_CHECK=off run_hook "${P6}" claude-vscode 08)" = '{}' ] || fail "IWE_MORNING_CHECK=off must be silent"

# Every output is valid JSON for Claude Code.
P7="${WORK}/p7"; mkdir -p "${P7}"
run_hook "${P7}" claude-vscode 10 | jq -e . >/dev/null || fail "output must be valid JSON"

if [ "${FAILS}" -eq 0 ]; then
  echo "PASS: morning-check-reminder (7 scenarios)"
else
  echo "morning-check-reminder: ${FAILS} failure(s)"
  exit 1
fi
