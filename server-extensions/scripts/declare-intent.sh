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
  echo "usage: declare-intent.sh <WP-N|outside-wp>" >&2
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
jq -nc --arg session "$SESSION_ID" --arg agent "$AGENT" --arg intent "$INTENT" --arg at "$DECLARED_AT" \
  '{session_id: $session, agent: $agent, intent: $intent, declared_at: $at}' \
  > "$TMP_FILE"
mv -f "$TMP_FILE" "$INTENT_DIR/$SESSION_ID.json"

echo "Намерение записано: $INTENT (сессия $SESSION_ID, агент $AGENT)"
