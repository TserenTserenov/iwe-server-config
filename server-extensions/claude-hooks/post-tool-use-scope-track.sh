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

HARNESS_SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)

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

# WP-484 Ф101 Находка 1 (16.08): the old singleton current-<agent>.ptr names one
# semaphore per agent, not per session -- a second concurrent `open` of the same
# agent overwrites it, so every parallel session's edits land in whichever
# semaphore opened last (found live: 8+ concurrent claude-code semaphores,
# cross-contamination confirmed both directions by reading all eight). Match by
# the harness session id instead (recorded in the semaphore's frontmatter by
# `session-guard.sh open` since this fix) -- exactly one semaphore can carry
# this session's id. No match (old semaphore predates the field, or none open)
# or more than one (should not happen, but never guess) -- stay silent, same
# fail-closed contract as the old "no ptr file" case.
[ -z "$HARNESS_SESSION_ID" ] && exit 0
SEM_MATCHES=$(grep -lF "harness_session_id: $HARNESS_SESSION_ID" "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null)
SEM_COUNT=$(printf '%s\n' "$SEM_MATCHES" | grep -c . || true)
[ "$SEM_COUNT" -ne 1 ] && exit 0
SEM_FILE="$SEM_MATCHES"

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
