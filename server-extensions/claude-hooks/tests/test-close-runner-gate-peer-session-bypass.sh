#!/bin/bash
# test-close-runner-gate-peer-session-bypass.sh — close_path=peer-session
# обходит требование раннера (WP-484 Ф118, 19.08.2026, пир-сессия с Codex).
#
# Живой симптом до фикса: пир-сессия каждый раз натыкалась на "process-runner
# нужен вместо закрытия пир-сессии" при обычном finalize-коммите (DP.SC.154
# Шаг 4.5.1) и обходилась через close_obligation.py cancel --action
# close-override + git commit --no-verify. Фикс — session-guard open
# --close-path peer-session записывает протокол закрытия в семафор, гейт
# читает его и структурно пропускает такую сессию, не полагаясь на regex.
#
# Запуск: bash .claude/hooks/tests/test-close-runner-gate-peer-session-bypass.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/close-runner-gate.sh"
SID="test-f118-$$"
SENTINEL_DIR="/tmp/iwe-close-intent"
MARKER_DIR="/tmp/iwe-close-runner-started"
IWE_ROOT_TEST=$(mktemp -d)
SEM_DIR="$IWE_ROOT_TEST/.iwe-runtime/sessions"
mkdir -p "$SEM_DIR"
PASS=0
FAIL=0

cleanup() {
  rm -f "$SENTINEL_DIR/$SID.flag" "$MARKER_DIR/$SID.flag"
  rm -rf "$IWE_ROOT_TEST"
}
trap cleanup EXIT

arm() {
  mkdir -p "$SENTINEL_DIR"
  printf '{"session_id":"%s","created_at":"test"}' "$SID" > "$SENTINEL_DIR/$SID.flag"
  rm -f "$MARKER_DIR/$SID.flag"
}

write_semaphore() { # $1 = close_path value
  cat > "$SEM_DIR/claude-code-fake.open" <<EOF
---
agent: claude-code
harness_session_id: $SID
close_path: $1
EOF
}

run_gate() { # $1 = command → печатает exit code хука
  local json_cmd
  json_cmd=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"%s"}' \
    "$json_cmd" "$SID" | IWE_ROOT="$IWE_ROOT_TEST" bash "$HOOK" >/dev/null 2>&1
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

# === close_path=peer-session → прямой commit пропускается без раннера ===
arm
write_semaphore "peer-session"
expect "peer-session: direct commit allowed"  0 'git commit -m x'
expect "peer-session: direct push allowed"    0 'git push'
expect "peer-session: -C form allowed"        0 'git -C repo commit -m x'

# === close_path=quick-close (явно объявлен) → прежнее поведение, блок ===
write_semaphore "quick-close"
expect "quick-close: still blocks commit"     2 'git commit -m x'

# === нет семафора вовсе (unknown) → прежнее поведение, блок (regression guard) ===
rm -f "$SEM_DIR"/*.open
expect "no semaphore: still blocks commit"    2 'git commit -m x'

# === close_path=unknown (легаси-вызов open без флага) → прежнее поведение ===
write_semaphore "unknown"
expect "close_path=unknown: still blocks"     2 'git commit -m x'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
