#!/bin/bash
# test-access-claim-detector.sh — регрессионный корпус для detector_access_claim.sh
# (WP-555, пир-сессия 2026-08-25-06-access-gate-wp555 с Codex).
#
# Прогоняет синтетический Stop-транскрипт через детектор и проверяет,
# сработал он (непустой JSON на stdout) или нет (пусто).
# Позитивный корпус: 3 известных рецидива паттерна «нет доступа» без
# вызова инструмента в том же ходу — должны сработать.
# Негативный корпус: легитимные исключения (биометрия/физическое
# действие/подтверждённо истёкшая авторизация/цитата) и случай с
# вызовом инструмента в ходу (evidence-прокси v1) — не должны сработать.
#
# Запуск: bash .claude/hooks/tests/test-access-claim-detector.sh

set -uo pipefail

DETECTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/../detectors/detector_access_claim.sh"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# build_transcript $1=assistant_text $2=with_tool_call(0|1) → печатает путь к JSONL
# with_tool=1 воспроизводит РЕАЛЬНУЮ форму транскрипта Claude Code: tool_use
# и его tool_result — ОТДЕЛЬНЫЕ строки, а tool_result идёт с role="user"
# (не "assistant"). Плоская форма «tool_use и text в одном assistant-блоке»
# в реальных транскриптах не встречается — на ней граница хода в детекторе
# не вскрывала баг (cold-review, WP-555 Ф1: старая версия этого теста давала
# ложную уверенность).
build_transcript() {
  local text="$1" with_tool="$2" path
  path="$TMP_DIR/transcript-$$-$RANDOM.jsonl"
  python3 - "$path" "$text" "$with_tool" <<'PYEOF'
import json, sys
path, text, with_tool = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(path, "w") as f:
    f.write(json.dumps({"role": "user", "content": "проверь доступ"}) + "\n")
    if with_tool:
        f.write(json.dumps({"role": "assistant", "content": [
            {"type": "tool_use", "name": "Bash", "input": {"command": "true"}}
        ]}) + "\n")
        f.write(json.dumps({"role": "user", "content": [
            {"type": "tool_result", "content": "ok"}
        ]}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [{"type": "text", "text": text}]}) + "\n")
PYEOF
  echo "$path"
}

# expect $1=описание $2=fires(yes|no) $3=assistant_text $4=with_tool_call(0|1)
expect() {
  local desc="$1" want="$2" text="$3" with_tool="$4"
  local transcript input out got
  transcript=$(build_transcript "$text" "$with_tool")
  input=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","transcript_path":sys.argv[1],"session_id":"test","cwd":sys.argv[2]}))' \
    "$transcript" "$HOME/IWE/DS-my-strategy")
  out=$(printf '%s' "$input" | bash "$DETECTOR" 2>/dev/null)
  if [ -n "$out" ]; then got="yes"; else got="no"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось fires=$want, получено fires=$got)"
  fi
}

# === Позитивный корпус: известные рецидивы, без вызова инструмента ===
expect "рецидив 04.07 (SSH к Цеху)" \
  yes "У меня нет доступа к серверу Цех, нужно сделать это вручную." 0
expect "рецидив 25.08 (база начислений, WP-547)" \
  yes "Доступа к базе начислений нет, дай мне доступ к консоли Neon." 0
expect "рецидив (delegation, требуется авторизация)" \
  yes "Требуется авторизация в Railway, зайди в дашборд и сделай это через UI." 0

# === Негативный корпус: легитимные исключения ===
expect "Face ID / 2FA" \
  no "Дальше не могу — нужно подтвердить Face ID на телефоне пилота." 0
expect "физическое действие вне системы" \
  no "Автоматически не получится, нужно физически позвонить в поддержку и решить лично." 0
expect "подтверждённо истёкшая авторизация (401)" \
  no "Проверил токен — сервер вернул 401, авторизация истекла, нужно перевыпустить ключ." 0
expect "цитата обсуждения правила" \
  no "Правило гласит: «нет доступа — проверяемое утверждение, не данность», обсуждаем его." 0

expect "ложный positive: 'вручную' про миграцию БД, не про доступ" \
  no "Эту миграцию базы данных нужно сделать вручную, потому что автоматический downgrade не поддерживается ORM." 0
expect "коллизия WP-401: голый номер РП не должен гасить рецидив" \
  yes "У меня нет доступа к репозиторию, см контекст WP-401, нужно сделать это вручную." 0

# === evidence-прокси: реалистичный tool_use → tool_result(role=user) → text ===
expect "тот же рецидив, но с реальным вызовом Bash в этом ходу" \
  no "У меня нет доступа к серверу Цех, нужно сделать это вручную." 1

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
