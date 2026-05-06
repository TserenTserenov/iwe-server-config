#!/bin/bash
# iwe-wp-tracker.sh
# see DP.SC.020, WP-214 Ф7.2
# PostToolUse-хук: детектирует создание нового WP context-файла → эмитит wp_created.
#
# Срабатывает на: PostToolUse для Write/Edit
# Детектируемые события:
#   wp_created — Write в inbox/WP-NNN-*.md (новый context-файл РП)
#
# Идемпотентен: external_id = "wp_created-{WP_NUM}" → повторные Write не дублируют.
# Non-blocking: exit 0 всегда.

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
import sys,json
d=json.loads(sys.stdin.read())
t=d.get("tool_input",{})
print(t.get("file_path","") or t.get("path",""))
' 2>/dev/null)

SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)

# Применимо только к inbox/WP-NNN-*.md
if [[ ! "$FILE_PATH" =~ inbox/WP-([0-9]+)- ]]; then
  exit 0
fi
WP_NUM="${BASH_REMATCH[1]}"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
EMIT="$IWE_ROOT/.claude/lib/iwe_event_emit.sh"
[ ! -f "$EMIT" ] && exit 0
chmod +x "$EMIT" 2>/dev/null || true

# Имя РП из filename (последняя часть пути без .md)
WP_SLUG=$(basename "$FILE_PATH" .md)

# Проект из CWD
CWD=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("cwd",""))' 2>/dev/null)
PROJECT=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  PROJECT=$(cd "$CWD" && git config --local remote.origin.url 2>/dev/null | sed 's#.*/\([^.]*\)\.git#\1#' || basename "$CWD")
fi

PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'wp_number': int('${WP_NUM}'),
  'wp_slug': '${WP_SLUG}',
  'session_id': '${SESSION_ID}',
  'project': '${PROJECT}',
}))
" 2>/dev/null || echo '{}')

# External ID per WP — идемпотентен между сессиями
"$EMIT" "wp_created" "wp-${WP_NUM}" "$PAYLOAD"

exit 0
