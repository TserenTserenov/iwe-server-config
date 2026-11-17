#!/usr/bin/env bash
# Codex adapter for destructive-guard.sh: a guard "ask" (FMT #1568) must reach
# Codex as deny, a guard block stays deny, a harmless command stays allowed.
# Before WP-529 F274 the adapter dropped the guard's stdout and let "ask" pass.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WRAP="$ROOT/.codex/hooks/destructive_guard_codex.sh"
fail=0

decision_for() {
  local out
  out=$(jq -n --arg c "$1" --arg d "$ROOT" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$WRAP")
  if [ -z "$out" ]; then echo allow; return; fi
  jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$out"
}

expect() {
  local want=$1 cmd=$2 got
  got=$(decision_for "$cmd")
  if [ "$got" = "$want" ]; then
    echo "ok   $want: $cmd"
  else
    echo "FAIL want $want, got $got: $cmd"
    fail=1
  fi
}

expect allow 'ls docs'
expect deny  'grep zzz README.md > params.yaml'
expect deny  'cat README.md > .claude//hooks/x.sh'

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
