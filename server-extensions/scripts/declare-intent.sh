#!/bin/bash
# declare-intent.sh -- DP.SC.204 (pre-action intent gate). Writes a lightweight
# record of what the calling agent is about to work on, BEFORE it calls any
# tool: a WP number or an explicit "outside-wp" marker. Read by
# .claude/hooks/intent-gate-check.sh. Separate from DP.SC.201/DR-03's
# plan-hour admission machinery (plan_allocation.py) -- this is an
# announcement, not an admission to a contested resource (pilot decision,
# WP-561 F33, MC-sessions:2026-10/13/2026-10-13-07-wp561-f33-archgate-receiver).
set -euo pipefail

INTENT="${1:-}"
if [[ ! "$INTENT" =~ ^(WP-[0-9]+|outside-wp)$ ]]; then
  echo "usage: declare-intent.sh <WP-N|outside-wp> [--ritual \"<agreed Ritual, one line>\"]" >&2
  exit 1
fi
shift
# WP-484 Ф267 п.4: the pilot-agreed Ritual is kept in this per-conversation
# record, so ritual-hard-gate.sh need not find it in the transcript again after
# the conversation is compacted (the summary names the WP, the Ritual text is gone).
RITUAL=""
RITUAL_REQUESTED=0
if [ "${1:-}" = "--ritual" ]; then
  RITUAL_REQUESTED=1
  RITUAL="${2:-}"
  if [ -z "$RITUAL" ] || [ "$INTENT" = "outside-wp" ]; then
    echo "declare-intent.sh: --ritual требует непустой текст и номер РП (не outside-wp)" >&2
    exit 1
  fi
  shift 2
fi
if [ "$#" -ne 0 ]; then
  echo "usage: declare-intent.sh <WP-N|outside-wp> [--ritual \"<agreed Ritual, one line>\"]" >&2
  exit 1
fi
# One line; bounded to 2000 characters in jq below (the record is read by hooks on every tool call).
# Two parallel calls for one conversation could overwrite each other's record:
# one conversation is driven by one agent, so the race is accepted, not locked.
RITUAL=$(printf '%s' "$RITUAL" | tr '\n\r' '  ')
if [ "${RITUAL_REQUESTED:-0}" = 1 ] && [[ ! "$RITUAL" =~ [^[:space:]] ]]; then
  echo "declare-intent.sh: --ritual не должен быть пустым после нормализации" >&2
  exit 1
fi

SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
  echo "declare-intent.sh: CLAUDE_CODE_SESSION_ID не задан -- не знаю, для какой сессии писать" >&2
  exit 1
fi
# M4 (Fable cold review, 13.10): CLAUDE_CODE_SESSION_ID becomes a filename
# below -- reject anything that could escape intent-declarations/ (e.g. "../x")
# before it's used in a path, not after.
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "declare-intent.sh: CLAUDE_CODE_SESSION_ID имеет недопустимый формат: $SESSION_ID" >&2
  exit 1
fi

INTENT_DIR="${IWE_RUNTIME_DIR:-$HOME/IWE/.iwe-runtime}/intent-declarations"
mkdir -p "$INTENT_DIR"

DECLARED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
AGENT="${IWE_AGENT:-unknown}"

# M1 (Fable cold review): write to a temp file and rename, not a direct `>`
# truncate -- a reader hitting the file mid-write would otherwise see a
# partial/empty JSON and the gate would misread it as badly stale.
TMP_FILE=$(mktemp "$INTENT_DIR/.$SESSION_ID.XXXXXX")
# A repeated declaration for the SAME WP keeps the Ritual already agreed; a
# different WP or outside-wp starts without one (it needs its own agreement).
KEEP_RITUAL="null"
if [ -z "$RITUAL" ] && [ -f "$INTENT_DIR/$SESSION_ID.json" ]; then
  KEEP_RITUAL=$(jq -c --arg intent "$INTENT" 'select(.intent == $intent) | .ritual // null' \
    "$INTENT_DIR/$SESSION_ID.json" 2>/dev/null || true)
  [ -n "$KEEP_RITUAL" ] || KEEP_RITUAL="null"
fi
jq -nc --arg session "$SESSION_ID" --arg agent "$AGENT" --arg intent "$INTENT" --arg at "$DECLARED_AT" \
  --arg ritual "$RITUAL" --argjson keep "$KEEP_RITUAL" \
  '{session_id: $session, agent: $agent, intent: $intent, declared_at: $at}
   + (if $ritual != "" then {ritual: {text: $ritual[:2000], agreed_at: $at}}
      elif $keep != null then {ritual: $keep} else {} end)' \
  > "$TMP_FILE"
mv -f "$TMP_FILE" "$INTENT_DIR/$SESSION_ID.json"

echo "Намерение записано: $INTENT (сессия $SESSION_ID, агент $AGENT)"
[ -z "$RITUAL" ] || echo "Согласованный Ритуал записан в запись беседы: проверка Ритуала не потребует его заново после сжатия."

# WP-484 F257 M3: show where the previous session stopped, straight after the
# intent is recorded.  Optional: a slow or failing reader never blocks the
# declaration (`|| true`), and `outside-wp` has no card to read.
case "$INTENT" in
  WP-*)
    SHOW_SCRIPT="${IWE_SCRIPTS:-$HOME/IWE/scripts}/wp-handoff-show.sh"
    if [ -x "$SHOW_SCRIPT" ]; then
      # The reader's own network check is limited to 10 s; this outer limit is longer
      # so a hanging network still lets it print the card fields before it is cut.
      LIMIT_LIB="$(dirname "$SHOW_SCRIPT")/lib/run-limited.sh"
      if [ -r "$LIMIT_LIB" ]; then
        # shellcheck source=lib/run-limited.sh
        . "$LIMIT_LIB"
        run_limited 20 bash "$SHOW_SCRIPT" "$INTENT" </dev/null || true
      else
        bash "$SHOW_SCRIPT" "$INTENT" </dev/null || true
      fi
    fi
    ;;
esac
