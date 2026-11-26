#!/bin/bash
# Pilot Witness Recorder (UserPromptSubmit, WP-484 Ф56, 2026-08-05)
#
# Problem this solves: the Quick Close session-reflection step used to accept
# `answer` from the closing agent's --input with no check on who actually wrote
# it -- judge and offender were the same party (3 recurrences in one day, MAJOR
# fault). This hook records every genuine pilot chat message to a dedicated
# witness file; the session-reflection-append.sh handler sources the answer
# ONLY from here -- the agent's own input never reaches `answer` at all
# (WP-484.md §Ф56, consensus with Codex+Kimi 2026-08-05).
#
# Passive recorder: NEVER blocks pilot input (always exits 0) -- the integrity
# guarantee lives in the append handler's fail-closed behavior (empty witness
# with no trusted autonomous marker => Close blocks), not in this hook.
#
# UserPromptSubmit contract (Claude Code): stdin JSON {"session_id", "prompt", ...}.
set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0
SESSION_ID_SAFE=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID_SAFE" ] || exit 0

PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0

# WP-484 (19.11, live case 18.11 x3): a background-task notification arrives as a
# prompt and used to be recorded as if the pilot wrote it; the reflection step then
# took it as the pilot's answer. Skip the three confirmed machine signatures below (after
# leading whitespace/CR). Text that merely resembles them is still the pilot's.
# The same list is skipped on read in handlers/session-reflection-append.sh.
PROMPT_PROBE=${PROMPT#"${PROMPT%%[![:space:]]*}"}
case "$PROMPT_PROBE" in
  "[SYSTEM NOTIFICATION"*|"<task-notification"*|"<agent-message from="*) exit 0 ;;
esac

# WP-484 I-47 (26.11, live case WP-529 x3): a ScheduleWakeup prompt arrives as a
# prompt too. It is skipped only on a direct sign that THIS message is the wakeup:
# the hook input itself, or the transcript's latest prompt entry with the same text,
# marked as a wakeup and written within the last 10 s. A text that merely equals a
# scheduled prompt is still recorded, with suspected_wakeup: true (pilot's words are
# never dropped on a guess). Input field names (not values) go into every record so
# the next wakeup shows which signs the hook actually receives.
if printf '%s' "$INPUT" | jq -e '((.wakeupSource // .wakeup_source // null) != null)
    or ((.turnOrigin // .turn_origin // "") == "scheduled")' >/dev/null 2>&1; then
  exit 0
fi
INPUT_KEYS=$(printf '%s' "$INPUT" | jq -c 'keys' 2>/dev/null) || INPUT_KEYS='[]'
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
WAKEUP_VERDICT=keep
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  WAKEUP_VERDICT=$(WITNESS_PROMPT="$PROMPT" python3 -I "$(dirname "$0")/lib/wakeup_prompt_check.py" "$TRANSCRIPT" 2>/dev/null) \
    || WAKEUP_VERDICT=keep
fi
[ "$WAKEUP_VERDICT" = skip ] && exit 0

# WP-537 (18.08, пир-сессия с Codex): было ${CLAUDE_PROJECT_DIR:-$HOME/IWE} --
# единственное оставшееся место в этой связке hook/handler-скриптов с этим
# паттерном (close_obligation.py, session-guard.sh, close-runner-gate.sh уже
# используют IWE_ROOT env var + $HOME/IWE фолбэк с 16.08, Ф42 -- CLAUDE_PROJECT_DIR
# ненадёжна для worktree-изолированных сессий). Пропущено при рассылке Ф42,
# закрываю тем же паттерном.
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
WITNESS_DIR="$IWE_ROOT/.iwe-runtime/pilot-witness"
mkdir -p "$WITNESS_DIR" 2>/dev/null || exit 0
chmod 700 "$WITNESS_DIR" 2>/dev/null || true

WITNESS_FILE="$WITNESS_DIR/$SESSION_ID_SAFE.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -cn --arg ts "$TS" --arg session_id "$SESSION_ID" --arg text "$PROMPT" \
  --argjson input_keys "$INPUT_KEYS" --arg verdict "$WAKEUP_VERDICT" \
  '{ts: $ts, session_id: $session_id, text: $text, input_keys: $input_keys}
   + (if $verdict == "suspected" then {suspected_wakeup: true} else {} end)' >> "$WITNESS_FILE" 2>/dev/null
chmod 600 "$WITNESS_FILE" 2>/dev/null || true

exit 0
