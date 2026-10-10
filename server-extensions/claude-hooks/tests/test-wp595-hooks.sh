#!/bin/bash
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d /private/tmp/wp595-hooks.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/.claude/hooks" "$TEST_ROOT/.claude/principles" "$TEST_ROOT/.claude/state" "$TEST_ROOT/memory"
cp "$HOOKS_DIR/inject-principle-nudge.sh" "$TEST_ROOT/.claude/hooks/"
cp "$HOOKS_DIR/fpf-read-logger.sh" "$TEST_ROOT/.claude/hooks/"
cp "$HOOKS_DIR/../principles/nudge-table.tsv" "$TEST_ROOT/.claude/principles/"

nudge_with_session() {
  jq -nc --arg prompt "$1" --arg session_id "$2" '{prompt:$prompt,session_id:$session_id}' |
    CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$TEST_ROOT/.claude/hooks/inject-principle-nudge.sh"
}
nudge() { nudge_with_session "$1" probe; }
start_subagent() {
  jq -nc --arg session_id "$1" --arg agent_id "${2:-agent-probe}" \
    '{hook_event_name:"SubagentStart",session_id:$session_id,agent_id:$agent_id,agent_type:"general-purpose"}' |
    CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$TEST_ROOT/.claude/hooks/inject-principle-nudge.sh"
}
end_session() {
  jq -nc --arg session_id "$1" '{hook_event_name:"SessionEnd",session_id:$session_id,reason:"other"}' |
    CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$TEST_ROOT/.claude/hooks/inject-principle-nudge.sh"
}

first=$(nudge 'закрывай сессию')
printf '%s' "$first" | jq -e '.hookSpecificOutput.additionalContext | contains("Принципы")' >/dev/null
[ "$(start_subagent probe)" = '{}' ]
printf 'wrong-experiment\n' > "$TEST_ROOT/.claude/state/principle-nudge-f7-enabled-probe"
[ "$(start_subagent probe)" = '{}' ]
printf 'WP-595-F7\n' > "$TEST_ROOT/.claude/state/principle-nudge-f7-enabled-probe"
subagent=$(start_subagent probe)
printf '%s' "$subagent" | jq -e --arg main "$(printf '%s' "$first" | jq -r '.hookSpecificOutput.additionalContext')" \
  '.hookSpecificOutput.hookEventName == "SubagentStart" and .hookSpecificOutput.additionalContext == $main' >/dev/null
[ "$(jq -sc '[.[] | select(.event == "nudge" and .recipient == "subagent" and .agent_id == "agent-probe")] | length' "$TEST_ROOT/memory/fpf-usage.log")" -eq 1 ]
nudge 'обычный запрос' >/dev/null
[ "$(start_subagent probe)" = '{}' ]
bytes=$(printf '%s' "$first" | jq -j '.hookSpecificOutput.additionalContext' | LC_ALL=C wc -c | tr -d ' ')
[ "$bytes" -le 1536 ]
[ "$(nudge_with_session 'не закрывай сессию' negative)" = '{}' ]
[ "$(nudge_with_session 'напомни через час' reminder)" = '{}' ]
[ "$(nudge_with_session 'закрой пир-сессию' peer-close)" = '{}' ]
[ "$(nudge_with_session 'продолжаем РП595' mention)" = '{}' ]
[ "$(nudge_with_session 'открой РП595' cross-gate)" != '{}' ]
nudge_with_session 'открой РП595' stale-context >/dev/null
printf 'WP-595-F7\n' > "$TEST_ROOT/.claude/state/principle-nudge-f7-enabled-stale-context"
jq '.timestamp = 0' "$TEST_ROOT/.claude/state/principle-nudge-context-stale-context" > "$TEST_ROOT/stale-context.json"
mv "$TEST_ROOT/stale-context.json" "$TEST_ROOT/.claude/state/principle-nudge-context-stale-context"
[ "$(start_subagent stale-context)" = '{}' ]
touch -t 202001010000 "$TEST_ROOT/.claude/state/principle-nudge-f7-enabled-stale-context"
[ "$(start_subagent stale-context)" = '{}' ]
[ ! -e "$TEST_ROOT/.claude/state/principle-nudge-f7-enabled-stale-context" ]
nudge_with_session 'закрывай сессию' collision >/dev/null
printf 'WP-595-F7\n' > "$TEST_ROOT/.claude/state/principle-nudge-f7-enabled-collision"
mkdir "$TEST_ROOT/.claude/state/principle-nudge-collision.lock"
[ "$(nudge_with_session 'закрывай сессию' collision)" = '{}' ]
rmdir "$TEST_ROOT/.claude/state/principle-nudge-collision.lock"
[ "$(start_subagent collision)" = '{}' ]
mkdir "$TEST_ROOT/.claude/state/principle-nudge-stale.lock"
touch -t 202001010000 "$TEST_ROOT/.claude/state/principle-nudge-stale.lock"
nudge_with_session 'закрывай сессию' cleanup >/dev/null
[ -d "$TEST_ROOT/.claude/state/principle-nudge-stale.lock" ]
for ((turn=1; turn<=9; turn++)); do
  if [ "$turn" -eq 1 ]; then
    [ "$(nudge 'открой РП595')" = '{}' ]
  else
    [ "$(nudge 'закрывай сессию')" = '{}' ]
  fi
done
nudge 'закрывай сессию' | jq -e '.hookSpecificOutput.additionalContext | contains("Принципы")' >/dev/null
touch "$TEST_ROOT/.claude/state/principle-nudge.off"
[ "$(nudge 'закрывай сессию')" = '{}' ]
[ "$(start_subagent probe)" = '{}' ]
end_session probe >/dev/null
[ ! -e "$TEST_ROOT/.claude/state/principle-nudge-f7-enabled-probe" ]
[ ! -e "$TEST_ROOT/.claude/state/principle-nudge-context-probe" ]

logger="$TEST_ROOT/.claude/hooks/fpf-read-logger.sh"
read_path="$TEST_ROOT/FPF/FPF-Spec.md"
jq -nc --arg path "$read_path" '{tool_name:"Read",tool_input:{file_path:$path},session_id:"probe"}' |
  CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$logger"
jq -nc --arg path "$read_path" '{tool_name:"Read",tool_input:{file_path:$path},session_id:"probe"}' |
  CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$logger"
jq -nc --arg path "$read_path" '{tool_name:"Read",tool_input:{file_path:$path},tool_response:{is_error:true},session_id:"probe"}' |
  CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$logger"
jq -nc '{tool_name:"Bash",tool_input:{command:"echo FPF/FPF-Spec.md"},session_id:"probe"}' |
  CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$logger"
jq -nc '{tool_name:"Bash",tool_input:{command:"rg -n F.1 FPF/FPF-Spec.md"},session_id:"probe"}' |
  CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$logger"
jq -nc '{tool_name:"Grep",tool_input:{path:"FPF/SYSE.6.md",pattern:"Solution"},session_id:"probe"}' |
  CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$logger"
jq -nc '{tool_name:"Bash",tool_input:{command:"rg DP.001 ./FPF/DP.002.md"},session_id:"probe"}' |
  CLAUDE_PROJECT_DIR="$TEST_ROOT" bash "$logger"
[ "$(jq -sc '[.[] | select(.event == "direct_read")] | length' "$TEST_ROOT/memory/fpf-usage.log")" -eq 3 ]
grep -q '"code":"SYSE.6"' "$TEST_ROOT/memory/fpf-usage.log"
grep -q '"code":"DP.002"' "$TEST_ROOT/memory/fpf-usage.log"
echo 'WP-595 hooks: OK'
