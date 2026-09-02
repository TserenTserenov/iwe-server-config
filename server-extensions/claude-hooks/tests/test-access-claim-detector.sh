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

# === evidence-прокси v1 vs relevance-прокси v2 (WP-555, четвёртый рецидив 25.08) ===
# build_transcript_with_command — как build_transcript, но с реальным текстом
# Bash-команды (v1 проверял только факт вызова, не его содержимое — v2
# сверяет содержимое с RESOURCE_TERMS детектора).
build_transcript_with_command() {
  local text="$1" command="$2" path
  path="$TMP_DIR/transcript-$$-$RANDOM.jsonl"
  python3 - "$path" "$text" "$command" <<'PYEOF'
import json, sys
path, text, command = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as f:
    f.write(json.dumps({"role": "user", "content": "проверь доступ"}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [
        {"type": "tool_use", "name": "Bash", "input": {"command": command}}
    ]}) + "\n")
    f.write(json.dumps({"role": "user", "content": [
        {"type": "tool_result", "content": "ok"}
    ]}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [{"type": "text", "text": text}]}) + "\n")
PYEOF
  echo "$path"
}

expect_with_command() {
  local desc="$1" want="$2" text="$3" command="$4"
  local transcript input out got
  transcript=$(build_transcript_with_command "$text" "$command")
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

# v1 регрессия (до фикса relevance): Bash вызывался, но по ДРУГОЙ причине —
# содержимое команды не пересекается с заявленным ресурсом ("сервер Цех") →
# теперь ДОЛЖЕН сработать (раньше подавлялся любым фактом вызова).
expect_with_command "нерелевантный Bash в ходу (session-guard, не про доступ)" \
  yes "У меня нет доступа к серверу Цех, нужно сделать это вручную." "bash session-guard.sh close"

# v2: релевантный Bash (команда упоминает тот же термин ресурса, что и
# заявление — "ssh") — подавление всё ещё работает, фикс не сломал штатный
# случай. Term-overlap проверяет буквальное совпадение термина из общего
# списка, не семантическое родство ("сервер Цех" ~ "tsekh-1" сюда не входит —
# это за пределами простого списка терминов, см. остаточный предел в
# заголовке файла детектора).
expect_with_command "релевантный Bash в ходу (ssh упомянут и в заявлении, и в команде)" \
  no "У меня нет ssh-доступа к серверу, нужно сделать это вручную." \
  "ssh -o BatchMode=yes -o ConnectTimeout=5 tsekh-1 echo OK"

# === WP-7 инцидент 25.08 (Cloudflare/wrangler) — реальные формулировки, которые v1 пропустил ===
expect "обратный порядок слов: 'доступа ... нет' вместо 'нет доступа к'" \
  yes "Не смог выложить на боевой сервер - это отдельный облачный сервис, доступа к нему в этой сессии нет." 0
expect "синоним отказа 'не нашёл' рядом с термином credential" \
  yes "Wrangler CLI не установлен и Cloudflare API token в моём окружении не нашёл." 0

# Write/Edit-контент хода тоже сканируется (заявление адресовано напарнику
# внутри файла пир-сессии, не пилоту в чате) — воспроизводим форму реального
# transcript: tool_use Write с input.content, без отдельного text-блока.
expect_write_content() {
  local desc="$1" want="$2" content="$3"
  local path input out got
  path="$TMP_DIR/transcript-$$-$RANDOM.jsonl"
  python3 - "$path" "$content" <<'PYEOF'
import json, sys
path, content = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    f.write(json.dumps({"role": "user", "content": "продолжай"}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [
        {"type": "tool_use", "name": "Write", "input": {"file_path": "00-writer.md", "content": content}}
    ]}) + "\n")
PYEOF
  input=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","transcript_path":sys.argv[1],"session_id":"test","cwd":sys.argv[2]}))' \
    "$path" "$HOME/IWE/DS-my-strategy")
  out=$(printf '%s' "$input" | bash "$DETECTOR" 2>/dev/null)
  if [ -n "$out" ]; then got="yes"; else got="no"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось fires=$want, получено fires=$got)"
  fi
}
expect_write_content "заявление внутри Write-файла хода (напарнику, не пилоту)" \
  yes "Cloudflare API token в моём окружении не нашёл, деплой без него не сделать."

# === v3 (02.09.2026, WP-544, пятый рецидив — WP-547): отклонённый хуком вызов ===
# Реальная форма транскрипта Claude Code при PreToolUse-deny (снята живьём
# 02.09): tool_use получает id, а tool_result — is_error=true и текст
# «PreToolUse:Bash hook error: [...]». Команда НЕ выполнялась, значит это не
# проверка доступа. $4=denied(0|1): 1 — tool_result отклонён хуком.
build_transcript_with_result() {
  local text="$1" command="$2" denied="$3" path
  path="$TMP_DIR/transcript-$$-$RANDOM.jsonl"
  python3 - "$path" "$text" "$command" "$denied" <<'PYEOF'
import json, sys
path, text, command, denied = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
result = {"type": "tool_result", "tool_use_id": "toolu_test01", "content": "ok"}
if denied:
    result = {"type": "tool_result", "tool_use_id": "toolu_test01", "is_error": True,
              "content": "PreToolUse:Bash hook error: [$CLAUDE_PROJECT_DIR/.claude/hooks/secret-leak-block.sh]: Чтение чувствительного файла через Bash заблокировано"}
with open(path, "w") as f:
    f.write(json.dumps({"role": "user", "content": "проверь доступ"}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_test01", "name": "Bash", "input": {"command": command}}
    ]}) + "\n")
    f.write(json.dumps({"role": "user", "content": [result]}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [{"type": "text", "text": text}]}) + "\n")
PYEOF
  echo "$path"
}

expect_with_result() {
  local desc="$1" want="$2" text="$3" command="$4" denied="$5"
  local transcript input out got
  transcript=$(build_transcript_with_result "$text" "$command" "$denied")
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

# Релевантная команда (neon/credential в обеих сторонах), но хук её отклонил —
# v2 подавлял детектор, v3 обязан сработать: проверки не было.
expect_with_result "отклонённый хуком релевантный Bash (WP-547 02.09) — не проверка" \
  yes "Доступа к базе neon нет — штатного пути к credential в этой сессии не нашёл." \
  "grep NEON_REFERENCE_URL ~/.config/aist/env" 1

# Та же команда, но прошедшая (tool_result без ошибки) — подавление сохраняется.
expect_with_result "прошедший релевантный Bash с id — подавление не сломано" \
  no "Доступа к базе neon нет — штатного пути к credential в этой сессии не нашёл." \
  "grep NEON_REFERENCE_URL ~/.config/aist/env" 0

# Ревью Codex/Kimi 02.09: (1) content отклонённого tool_result бывает массивом
# блоков, не строкой; (2) в одном ходу один вызов отклонён, другой релевантный
# прошёл — прошедший остаётся evidence, детектор молчит.
build_transcript_mixed() {
  local text="$1" path
  path="$TMP_DIR/transcript-$$-$RANDOM.jsonl"
  python3 - "$path" "$text" <<'PYEOF'
import json, sys
path, text = sys.argv[1], sys.argv[2]
denied = {"type": "tool_result", "tool_use_id": "toolu_denied", "is_error": True,
          "content": [{"type": "text", "text": "PreToolUse:Bash hook error: [$CLAUDE_PROJECT_DIR/.claude/hooks/secret-leak-block.sh]: заблокировано"}]}
passed = {"type": "tool_result", "tool_use_id": "toolu_passed", "content": "env loaded: yes"}
with open(path, "w") as f:
    f.write(json.dumps({"role": "user", "content": "проверь доступ"}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_denied", "name": "Bash", "input": {"command": "grep NEON_REFERENCE_URL ~/.config/aist/env"}}
    ]}) + "\n")
    f.write(json.dumps({"role": "user", "content": [denied]}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_passed", "name": "Bash", "input": {"command": "scripts/with-aist-env.sh python3 probe.py  # neon credential probe"}}
    ]}) + "\n")
    f.write(json.dumps({"role": "user", "content": [passed]}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [{"type": "text", "text": text}]}) + "\n")
PYEOF
  echo "$path"
}

expect_mixed() {
  local desc="$1" want="$2" text="$3"
  local transcript input out got
  transcript=$(build_transcript_mixed "$text")
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

expect_mixed "отклонённый (массив content) + прошедший релевантный Bash в одном ходу — прошедший остаётся evidence" \
  no "Доступа к базе neon нет — credential в этой сессии не нашёл."

# Отклонённый tool_result с content-массивом в одиночку — должен сработать
# (проверяем ветку map(.text) в детекторе, не только строковую форму).
build_transcript_denied_array() {
  local text="$1" path
  path="$TMP_DIR/transcript-$$-$RANDOM.jsonl"
  python3 - "$path" "$text" <<'PYEOF'
import json, sys
path, text = sys.argv[1], sys.argv[2]
denied = {"type": "tool_result", "tool_use_id": "toolu_denied", "is_error": True,
          "content": [{"type": "text", "text": "PreToolUse:Bash hook error: [$CLAUDE_PROJECT_DIR/.claude/hooks/secret-leak-block.sh]: заблокировано"}]}
with open(path, "w") as f:
    f.write(json.dumps({"role": "user", "content": "проверь доступ"}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_denied", "name": "Bash", "input": {"command": "grep NEON_REFERENCE_URL ~/.config/aist/env"}}
    ]}) + "\n")
    f.write(json.dumps({"role": "user", "content": [denied]}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [{"type": "text", "text": text}]}) + "\n")
PYEOF
  echo "$path"
}
transcript=$(build_transcript_denied_array "Доступа к базе neon нет — credential в этой сессии не нашёл.")
input=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","transcript_path":sys.argv[1],"session_id":"test","cwd":sys.argv[2]}))' \
  "$transcript" "$HOME/IWE/DS-my-strategy")
if [ -n "$(printf '%s' "$input" | bash "$DETECTOR" 2>/dev/null)" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL: отклонённый tool_result с content-массивом должен считаться отказом (ожидалось fires=yes)"
fi

# Граница матча (Codex, ревью 02.09): is_error без префикса PreToolUse — это
# ошибка УЖЕ выполненной команды (connection refused, 401), т.е. настоящая
# проверка доступа. Она обязана подавлять детектор, как и раньше. Живого
# образца отказа пользователем (не хуком) в транскриптах Мака на 02.09 нет —
# такая форма сознательно не матчится до появления fixture.
build_transcript_exec_error() {
  local text="$1" path
  path="$TMP_DIR/transcript-$$-$RANDOM.jsonl"
  python3 - "$path" "$text" <<'PYEOF'
import json, sys
path, text = sys.argv[1], sys.argv[2]
err = {"type": "tool_result", "tool_use_id": "toolu_exec", "is_error": True,
       "content": "psql: error: connection to server failed: Connection refused (neon endpoint)"}
with open(path, "w") as f:
    f.write(json.dumps({"role": "user", "content": "проверь доступ"}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_exec", "name": "Bash", "input": {"command": "scripts/with-aist-env.sh psql-probe neon"}}
    ]}) + "\n")
    f.write(json.dumps({"role": "user", "content": [err]}) + "\n")
    f.write(json.dumps({"role": "assistant", "content": [{"type": "text", "text": text}]}) + "\n")
PYEOF
  echo "$path"
}
transcript=$(build_transcript_exec_error "Доступа к базе neon нет — подключение отклонено сервером.")
input=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","transcript_path":sys.argv[1],"session_id":"test","cwd":sys.argv[2]}))' \
  "$transcript" "$HOME/IWE/DS-my-strategy")
if [ -z "$(printf '%s' "$input" | bash "$DETECTOR" 2>/dev/null)" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL: is_error выполненной команды (не хук) — это проверка, детектор не должен срабатывать (ожидалось fires=no)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
