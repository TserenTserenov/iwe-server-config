#!/bin/bash
# Claude Code → WakaTime heartbeat hook
# Sends heartbeats to track AI coding time per project.
# Events: UserPromptSubmit, PostToolUse, Stop

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Detect project from git or folder name
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  PROJECT=$(cd "$CWD" && git config --local remote.origin.url 2>/dev/null | sed 's#.*/\([^.]*\)#\1#;s#\.git$##')
  PROJECT=${PROJECT:-$(basename "$CWD")}
else
  PROJECT="Unknown"
fi

# Category based on event/tool
CATEGORY="ai coding"
if [ "$EVENT" = "PostToolUse" ]; then
  case "$TOOL" in
    WebSearch|WebFetch) CATEGORY="researching" ;;
    Read|Grep|Glob)    CATEGORY="code reviewing" ;;
    Edit|Write)        CATEGORY="coding" ;;
  esac
fi

# Send heartbeat in background (non-blocking, silent)
(~/.wakatime/wakatime-cli \
  --entity-type app \
  --entity "Claude Code" \
  --category "$CATEGORY" \
  --project "$PROJECT" \
  --plugin "claude-code-wakatime/0.1.0" \
  --write \
  >/dev/null 2>&1 &)

exit 0
