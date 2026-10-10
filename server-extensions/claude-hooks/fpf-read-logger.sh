#!/bin/bash
# fpf-read-logger.sh — WP-595 Ф6 — log direct reads of the FPF/DPF corpus
# that bypass /fpf.
#
# Registered for PostToolUse in .claude/settings.json.
#
# Event: PostToolUse (matcher: Read|Grep|Bash). Before this hook only /fpf
# wrote memory/fpf-usage.log, so an agent that grep'ed FPF/ with its own
# tools left no trace (found live 2026-10-07).
# Non-blocking: exit 0 always, no stdout.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
FPF_DIR="$PROJECT_DIR/FPF"
LOG_FILE="$PROJECT_DIR/memory/fpf-usage.log"

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
case "$TOOL" in Read|Grep|Bash) ;; *) exit 0 ;; esac

TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.file_path // .path // .command // "")' 2>/dev/null)
[ -n "$TARGET" ] || exit 0
# Bash is broad: a command that merely prints an FPF path is not a read.
if [ "$TOOL" = "Bash" ] && ! printf '%s' "$TARGET" | grep -qE '(^|[[:space:]|;&(])(rg|grep)([[:space:]]|$)'; then
  exit 0
fi
# Do not claim success if the envelope explicitly reports a tool failure.
if printf '%s' "$INPUT" | jq -e '(.tool_response | if type == "object" then (.is_error // .isError // false) else false end) == true' >/dev/null 2>&1; then
  exit 0
fi
printf '%s' "$TARGET" | grep -qF "$FPF_DIR/" || printf '%s' "$TARGET" | grep -qE '(^|[ /"])FPF/' || exit 0

# A search term can contain a code different from the file being read.
# Attribute a named code only when it appears after the last FPF/ path.
PATH_TARGET="${TARGET##*FPF/}"
PATH_TARGET="${PATH_TARGET%%[[:space:];|]*}"
CODE=$(printf '%s' "$PATH_TARGET" | grep -oE '\b[A-Z]{1,6}\.[0-9]{1,3}\b' | head -1)
[ -n "$CODE" ] || CODE="FPF_DIR"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -cd 'A-Za-z0-9._-')

# Condition (ArchGate): dedupe FPF_DIR hits — only log the generic
# directory-level event once per session per 10-minute window, so a run of
# bare `grep FPF/...` calls doesn't flood the log the way card-coded reads
# wouldn't (a named pattern code is never deduped, only the generic case).
if [ "$CODE" = "FPF_DIR" ]; then
  DEDUPE_FILE="$PROJECT_DIR/.claude/state/fpf-dir-log-$SESSION_ID"
  mkdir -p "$(dirname "$DEDUPE_FILE")" 2>/dev/null || exit 0
  DEDUPE_LOCK="$DEDUPE_FILE.lock"
  mkdir "$DEDUPE_LOCK" 2>/dev/null || exit 0
  trap 'rmdir "$DEDUPE_LOCK" 2>/dev/null || true' EXIT
  NOW=$(date +%s)
  if [ -f "$DEDUPE_FILE" ]; then
    read -r LAST_LOGGED < "$DEDUPE_FILE" 2>/dev/null || true
    if [[ "${LAST_LOGGED:-}" =~ ^[0-9]{1,12}$ ]] && [ $((NOW - LAST_LOGGED)) -lt 600 ]; then
      exit 0
    fi
  fi
  printf '%s\n' "$NOW" > "$DEDUPE_FILE" 2>/dev/null || exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || exit 0
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg code "$CODE" --arg tool "$TOOL" --arg sid "$SESSION_ID" \
  '{ts:$ts,code:$code,event:"direct_read",source:("tool:"+$tool),session:$sid,result:"success"} | if $sid == "" then del(.session) else . end' \
  >> "$LOG_FILE" 2>/dev/null || true
exit 0
