#!/bin/bash
# repo-touch-gate.sh — PreToolUse hook для AR.010 (Repo-Touch Gate)
# WP-272 Ф5.3: session-state + READ-ONLY block
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {tool_name, tool_input, session_id}
# - Exit 0 = allow
# - Exit 2 = block (stderr → причина блокировки)
# - Stdout JSON = additionalContext (warn-level)

set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("tool_name",""))' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("session_id",""))' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-default}"

# Применимо только к Read/Write/Edit/MultiEdit
case "$TOOL_NAME" in
    Read|Write|Edit|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

# Извлечь путь из tool_input
TOOL_ARG=$(echo "$INPUT" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
ti = d.get("tool_input", {})
print(ti.get("file_path") or ti.get("path") or "")
' 2>/dev/null)

[ -z "$TOOL_ARG" ] && exit 0

# Только для путей в ~/IWE/
[[ "$TOOL_ARG" == "$HOME/IWE/"* ]] || exit 0

# Быстрый путь для Read: пропустить уже-touched репо без вызова rule-engine.sh
if [ "$TOOL_NAME" = "Read" ]; then
    STATE_FILE="$HOME/.claude/state/repo-touched-${SESSION_ID}.json"
    if [ -f "$STATE_FILE" ]; then
        REPO_NAME="${TOOL_ARG#$HOME/IWE/}"
        REPO_NAME="${REPO_NAME%%/*}"
        ALREADY=$(REPO_NAME="$REPO_NAME" STATE_FILE="$STATE_FILE" python3 -c '
import json, os
try:
    repos = json.load(open(os.environ["STATE_FILE"]))
    print("yes" if os.environ["REPO_NAME"] in repos else "no")
except Exception:
    print("no")
' 2>/dev/null)
        [ "$ALREADY" = "yes" ] && exit 0
    fi
fi

ENGINE="$HOME/IWE/.claude/hooks/rule-engine.sh"
[ ! -x "$ENGINE" ] && exit 0

CTX=$(TOOL_ARG="$TOOL_ARG" TOOL_NAME="$TOOL_NAME" SESSION_ID="$SESSION_ID" python3 -c '
import json, os
print(json.dumps({
    "tool_arg":   os.environ["TOOL_ARG"],
    "tool_name":  os.environ["TOOL_NAME"],
    "session_id": os.environ["SESSION_ID"]
}))
' 2>/dev/null)

RESULT=$(RULE_EVENT="first_repo_action" RULE_CONTEXT="$CTX" "$ENGINE" dispatch 2>/dev/null)
VERDICT=$(echo "$RESULT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("verdict","ok"))' 2>/dev/null)
REASON=$(echo "$RESULT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("reason",""))' 2>/dev/null)

case "$VERDICT" in
    block)
        printf '⛔ AR.010 (Repo-Touch Gate): %s\n' "$REASON" >&2
        exit 2
        ;;
    warn)
        printf '{"additionalContext": "⚠️ AR.010 Repo-Touch Gate: %s"}\n' "$REASON"
        ;;
esac

exit 0
