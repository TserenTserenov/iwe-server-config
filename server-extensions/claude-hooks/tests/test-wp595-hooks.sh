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

first=$(nudge 'закрывай сессию')
printf '%s' "$first" | jq -e '.hookSpecificOutput.additionalContext | contains("Принципы")' >/dev/null
bytes=$(printf '%s' "$first" | jq -j '.hookSpecificOutput.additionalContext' | LC_ALL=C wc -c | tr -d ' ')
[ "$bytes" -le 1536 ]
[ "$(nudge_with_session 'не закрывай сессию' negative)" = '{}' ]
[ "$(nudge_with_session 'напомни через час' reminder)" = '{}' ]
[ "$(nudge_with_session 'закрой пир-сессию' peer-close)" = '{}' ]
[ "$(nudge_with_session 'продолжаем РП595' mention)" = '{}' ]
[ "$(nudge_with_session 'открой РП595' cross-gate)" != '{}' ]
mkdir "$TEST_ROOT/.claude/state/principle-nudge-collision.lock"
[ "$(nudge_with_session 'закрывай сессию' collision)" = '{}' ]
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
