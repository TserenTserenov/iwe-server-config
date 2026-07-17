#!/bin/bash
# sql-pii-guard.sh — PostToolUse hook for AR.112/AR.113 SQL security checks
# Fires on Write|Edit when file has .sql extension or content looks like SQL migration.
# Calls rule-engine with RULE_EVENT=sql_file_write to dispatch AR.112 + AR.113.
# Non-blocking on rule-engine failure (fail-open by design — guard, not gate).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

HOOK_EVENT=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("hook_event_name",""))' 2>/dev/null)
[ "$HOOK_EVENT" != "PostToolUse" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_name",""))' 2>/dev/null)
case "$TOOL_NAME" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
t = d.get("tool_input", {})
print(t.get("file_path", "") or t.get("path", ""))
' 2>/dev/null)

[ -z "$FILE_PATH" ] && exit 0

# Only process SQL files or migration-named files
case "$FILE_PATH" in
    *.sql|*/migrations/*|*/migrate/*) ;;
    *) exit 0 ;;
esac

# Read file content (prefer tool_input new_string for edits, else read file)
FILE_CONTENT=$(echo "$INPUT" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
t = d.get("tool_input", {})
print(t.get("content","") or t.get("new_string",""))
' 2>/dev/null)

if [ -z "$FILE_CONTENT" ] && [ -f "$FILE_PATH" ]; then
    FILE_CONTENT=$(head -200 "$FILE_PATH" 2>/dev/null || true)
fi

[ -z "$FILE_CONTENT" ] && exit 0

ENGINE="$HOME/IWE/.claude/hooks/rule-engine.sh"
[ ! -x "$ENGINE" ] && exit 0

CTX=$(python3 -c '
import sys, json
content = sys.argv[1]
path = sys.argv[2]
print(json.dumps({"file_path": path, "file_content": content}))
' -- "$FILE_CONTENT" "$FILE_PATH" 2>/dev/null) || exit 0

RESULT=$(RULE_EVENT="sql_file_write" RULE_CONTEXT="$CTX" "$ENGINE" dispatch 2>/dev/null) || exit 0

VERDICT=$(echo "$RESULT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("verdict","ok"))' 2>/dev/null)
RULE_ID=$(echo "$RESULT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("rule_id",""))' 2>/dev/null)
REASON=$(echo "$RESULT"  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("reason",""))' 2>/dev/null)

case "$VERDICT" in
    warn)
        echo ""
        echo "⚠️  SQL Security (${RULE_ID}): ${REASON}"
        ;;
    block)
        echo ""
        echo "🚫 SQL Security BLOCK (${RULE_ID}): ${REASON}" >&2
        exit 2
        ;;
esac

exit 0
