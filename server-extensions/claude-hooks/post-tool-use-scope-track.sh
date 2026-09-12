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
SESSION_GUARD="$IWE_ROOT/scripts/session-guard.sh"

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
GUARD_SESSION_ID=$(sed -n 's/^session_id: //p' "$SEM_FILE" 2>/dev/null)
if ! [[ "$GUARD_SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]]; then
  exit 0
fi

# The hook is intentionally non-blocking, but it must never write the
# semaphore itself. `note-file` re-resolves this exact guard session, takes
# the persistent session-transition lock, revalidates the open inode and
# serializes the append against close. A close in this window simply makes
# the guarded call fail; no shell redirection can recreate `.open`.
if [ -f "$SESSION_GUARD" ] && [ -n "${IWE_GOVERNANCE_REPO:-}" ]; then
  bash "$SESSION_GUARD" note-file "$FILE_PATH" --agent "$AGENT" \
    --session-id "$GUARD_SESSION_ID" >/dev/null 2>&1 || true
fi
exit 0
