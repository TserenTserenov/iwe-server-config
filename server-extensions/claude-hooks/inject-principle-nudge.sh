#!/bin/bash
# inject-principle-nudge.sh — WP-595 Ф5 — «толчок принципом на воротах решения»
#
# Registered for UserPromptSubmit in .claude/settings.json. The hook is
# non-blocking and runs only for explicit work gates.
#
# Revised per ArchGate (Кими+Кодекс, round 1, 2026-10-08):
# - word-boundary matching + negative examples (condition 2)
# - global cooldown across ALL gates, not per-gate (condition 3)
# - does not ask the agent to name or report use of the principle; the hook
#   records only that a nudge was shown (condition 4, later F11 refinement)
# - single kill-switch file, no env var duplicate (condition 6)
# - fixed fpf-usage.log schema (condition 5)
#
# Data: .claude/principles/nudge-table.tsv (gate, pack_ref, fpf_ref, text).
# Kill-switch: file .claude/state/principle-nudge.off
# Log: memory/fpf-usage.log, event "nudge" (one JSON line per injection).
# Non-blocking: any failure -> '{}' (valid empty hook output).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE="$HOOK_DIR/../principles/nudge-table.tsv"
LOG_FILE="$PROJECT_DIR/memory/fpf-usage.log"
MAX_ROWS=3
# A UTF-8 byte is at least as small as a model token. This conservative
# ceiling proves that the injected text stays within 1536 tokens without
# depending on a runtime tokenizer.
MAX_CONTEXT_BYTES=1536
# Condition 3: cooldown is now global (one counter for all gates), not per-gate.
REINJECT_TURNS=10

[ -f "$STATE_DIR/principle-nudge.off" ] && { echo '{}'; exit 0; }
[ -r "$TABLE" ] || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
[ -n "$PROMPT" ] || { echo '{}'; exit 0; }
PROMPT_LOWER=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || { echo '{}'; exit 0; }

# Word boundaries are checked with the host grep (covered by the macOS test).
# Closing a peer conversation, negated commands, and calendar reminders are
# outside these work gates.
if printf '%s' "$PROMPT_LOWER" | grep -qE '\bнапомни (мне )?через\b|\bперенеси встречу\b|\bне (закрывай|закрой|открывай|открой)\b|\b(закрой|закрывай) (пир|peer)[- ]сесси'; then
  echo '{}'; exit 0
fi

GATE=""
if   printf '%s' "$PROMPT_LOWER" | grep -qE '\bзакрывай\b|\bзакрой сесси|\bзаливай и закрывай\b|\bпочинил\b|\bсломал(ся)?\b|\bоткат(ить)?\b|\bвозобнов(ить|ляем)\b|\bобслужива(ние|ть)\b'; then GATE="close"
elif printf '%s' "$PROMPT_LOWER" | grep -qE '\bархитектур|/archgate|\bкак организовать\b|\bспроектир|\bкакой механизм\b|\bвыбери вариант\b|\bвариант архитектур|\bновый инструмент\b|\bподключ(и|ить) сервис\b'; then GATE="arch"
elif printf '%s' "$PROMPT_LOWER" | grep -qE '\bзафиксир|\bреализ(уй|овать) сейчас\b|decision gate|\bпир-сесси|\bpeer-сесси|\bконсенсус\b'; then GATE="decision"
elif printf '%s' "$PROMPT_LOWER" | grep -qE '\bоткрой\b|\bоткрывай\b|\bновый рп\b|\bзаведи рп\b|\bсделай(те)? рп\b|\bставк[аиу]\b|\bгипотез|\bоцени (объ[её]м|бюджет)\b|\bплан (недели|на неделю|дня)\b'; then GATE="open"
fi
[ -n "$GATE" ] || { echo '{}'; exit 0; }

mkdir -p "$STATE_DIR" 2>/dev/null || { echo '{}'; exit 0; }
STATE_FILE="$STATE_DIR/principle-nudge-$SESSION_ID"
# A session may submit two prompts nearly together. Keep the counter and
# cooldown decision in one critical section; on collision, omit the nudge.
LOCK_DIR="$STATE_FILE.lock"
mkdir "$LOCK_DIR" 2>/dev/null || { echo '{}'; exit 0; }
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
TURN=0; LAST_TURN=$((1 - REINJECT_TURNS))
if [ -f "$STATE_FILE" ]; then
  read -r saved_turn saved_last_turn < "$STATE_FILE" 2>/dev/null || true
  if [[ "${saved_turn:-}" =~ ^[0-9]{1,9}$ && "${saved_last_turn:-}" =~ ^-?[0-9]{1,9}$ ]]; then
    TURN="$saved_turn"
    LAST_TURN="$saved_last_turn"
  fi
fi
TURN=$((TURN + 1))
if [ $((TURN - LAST_TURN)) -lt "$REINJECT_TURNS" ]; then
  echo "$TURN $LAST_TURN" > "$STATE_FILE"
  echo '{}'; exit 0
fi

CONTEXT="## 🧭 Принципы на воротах «${GATE}» (WP-595 Ф5; отключить: touch .claude/state/principle-nudge.off)"
CODES=""
ROW_COUNT=0
while IFS=$'\t' read -r gate pack_ref fpf_ref principle_text; do
  [ "$gate" = "$GATE" ] || continue
  [ "$ROW_COUNT" -lt "$MAX_ROWS" ] || break
  row="- **${pack_ref}** (FPF: ${fpf_ref}) — ${principle_text}"
  candidate=$(printf '%s\n\n%s' "$CONTEXT" "$row")
  candidate_bytes=$(LC_ALL=C printf '%s' "$candidate" | wc -c | tr -d ' ')
  [ "$candidate_bytes" -le "$MAX_CONTEXT_BYTES" ] || break
  CONTEXT="$candidate"
  CODES="${CODES:+$CODES;}${fpf_ref}"
  ROW_COUNT=$((ROW_COUNT + 1))
done < "$TABLE"
[ "$ROW_COUNT" -gt 0 ] || { echo '{}'; exit 0; }

echo "$TURN $TURN" > "$STATE_FILE"
find "$STATE_DIR" -type f -name "principle-nudge-*" -mmin +1440 -delete 2>/dev/null || true

if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg gate "$GATE" --arg codes "$CODES" --arg sid "$SESSION_ID" \
    '{ts:$ts,code:$codes,event:"nudge",source:"inject-principle-nudge",gate:$gate,session:$sid,result:"injected"}' \
    >> "$LOG_FILE" 2>/dev/null || true
fi

jq -n --arg ctx "$CONTEXT" '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":$ctx}}'
