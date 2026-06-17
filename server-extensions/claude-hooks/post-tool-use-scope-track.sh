#!/bin/bash
# post-tool-use-scope-track.sh — PostToolUse-хук для логирования тронутых файлов в семафор сессии.
# see WP-5 "Предохранитель scope коммита"
#
# Срабатывает на: Write / Edit / MultiEdit / NotebookEdit
# Действие: дописывает git-root-relative путь в append-log семафора (file: <path>).
# Использование: scope gate читает этот лог как fallback для удалённых файлов.
# Non-blocking: exit 0 всегда.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

HOOK_EVENT=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("hook_event_name",""))' 2>/dev/null)
[ "$HOOK_EVENT" != "PostToolUse" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_name",""))' 2>/dev/null)
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c '
import sys,json
d=json.loads(sys.stdin.read())
t=d.get("tool_input",{})
print(t.get("file_path","") or t.get("path",""))
' 2>/dev/null)

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
AGENT="${IWE_AGENT:-claude-code}"
PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"

if [ ! -f "$PTR_FILE" ]; then
  exit 0
fi

SEM_FILE=$(cat "$PTR_FILE" 2>/dev/null)
if [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
  exit 0
fi

# Normalize to git-root-relative path (resolve symlinks/macOS /tmp vs /private/tmp)
REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$REPO_ROOT" ]; then
  REL_PATH=$(python3 -c "
import os,sys
f = os.path.realpath(sys.argv[2])
r = os.path.realpath(sys.argv[3])
print(os.path.relpath(f, r))
" -- "$FILE_PATH" "$REPO_ROOT")
else
  REL_PATH="$FILE_PATH"
fi

# Avoid duplicate consecutive entries
LAST=$(tail -1 "$SEM_FILE" 2>/dev/null || true)
if [ "$LAST" = "file: $REL_PATH" ]; then
  exit 0
fi

echo "file: $REL_PATH" >> "$SEM_FILE"
exit 0
