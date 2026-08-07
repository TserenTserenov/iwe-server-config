#!/bin/bash
# test-close-runner-gate-forms.sh — корпус форм git-вызова для close-runner-gate.sh
# (WP-484 Ф74а, 07.08.2026, пир-сессия 2026-08-07-08-quick-close-runner-bypass).
#
# Прогоняет PreToolUse JSON через хук и проверяет код выхода:
#   exit 2 = блок, exit 0 = пропуск.
# Негативный корпус (armed, раннер не запущен) — всё должно блокироваться;
# позитивный — всё должно пропускаться (нет sentinel, есть runner-маркер,
# plumbing-команды, упоминания в строках, не-git вызовы).
#
# Запуск: bash .claude/hooks/tests/test-close-runner-gate-forms.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-runner-gate.sh"
SID="test-f74a-$$"
SENTINEL_DIR="/tmp/iwe-close-intent"
MARKER_DIR="/tmp/iwe-close-runner-started"
PASS=0
FAIL=0

cleanup() { rm -f "$SENTINEL_DIR/$SID.flag" "$MARKER_DIR/$SID.flag"; }
trap cleanup EXIT

arm() {
  mkdir -p "$SENTINEL_DIR"
  printf '{"session_id":"%s","created_at":"test"}' "$SID" > "$SENTINEL_DIR/$SID.flag"
  rm -f "$MARKER_DIR/$SID.flag"
}

run_gate() { # $1 = command → печатает exit code хука
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' \
    "$json_cmd" "$SID" | bash "$HOOK" >/dev/null 2>&1
  echo $?
}

expect() { # $1 = описание, $2 = ожидаемый код (0|2), $3 = команда
  local got
  got=$(run_gate "$3")
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $1 (ожидалось $2, получено $got): $3"
  fi
}

# === Негативный корпус: armed, runner-маркера нет → блок (exit 2) ===
arm
expect "bare commit"            2 'git commit -m x'
expect "cd && commit"           2 'cd DS-my-strategy && git commit -m x'
expect "git -C commit"          2 'git -C DS-my-strategy commit -m x'
expect "git -c commit"          2 'git -c user.email=a@b commit -m x'
expect "git --git-dir= commit"  2 'git --git-dir=/tmp/x commit -m x'
expect "git --git-dir space"    2 'git --git-dir /tmp/x commit -m x'
expect "git --work-tree commit" 2 'git --git-dir=/tmp/x --work-tree=/tmp/y commit -m x'
expect "multispace"             2 'git   commit -m x'
expect "command prefix"         2 'command git commit -m x'
expect "subshell"               2 '(git commit -m x)'
expect "cmd substitution"       2 'msg=$(git commit -m x)'
expect "bare push"              2 'git push'
expect "git -C push"            2 'git -C DS-my-strategy push origin main'
expect "push after semicolon"   2 'git add x; git push'
expect "push after pipe"        2 'git log | git push'
expect "multiline add+commit"   2 "$(printf 'git add x\ngit commit -m x')"
expect "combined flags"         2 'git -c a=b -C repo commit -m x'
expect "git -P commit"          2 'git -P commit -m x'
expect "git --no-pager commit"  2 'git --no-pager commit -m x'

# === Позитивный корпус: armed, но команда не является commit/push → пропуск ===
expect "commit-tree plumbing"   0 'git commit-tree -m x'
expect "commit-graph plumbing"  0 'git commit-graph write'
expect "git status with -C"     0 'git -C repo status --short'
expect "echo mentions commit"   0 'echo "git commit"'
expect "word boundary"          0 'git commitment'
expect "pushd-like word"        0 'git pushd'
expect "non-git command"        0 'ls -la'
expect "runner start observed"  0 'python3 scripts/process-runner.py start quick-close --slug x'

# === Нет sentinel → штатная работа не блокируется ===
rm -f "$SENTINEL_DIR/$SID.flag"
expect "no sentinel: commit"    0 'git commit -m x'
expect "no sentinel: -C commit" 0 'git -C repo commit -m x'
expect "no sentinel: push"      0 'git push'

# === Sentinel есть, runner-маркер есть → раннер запущен, пропуск ===
arm
mkdir -p "$MARKER_DIR"
touch "$MARKER_DIR/$SID.flag"
expect "runner marked: commit"  0 'git commit -m x'
expect "runner marked: -C push" 0 'git -C repo push'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
