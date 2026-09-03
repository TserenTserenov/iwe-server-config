#!/bin/bash
# test-write-path-lease-guard-identity.sh — WP-484, 03.09, пир-сессия
# 2026-09-03-11-wp484-remaining-kimi-session-open (Kimi+Codex).
#
# Регрессия на два бага, найденных в этой же сессии:
#
# 1. write-path-lease-guard.sh вычислял AGENT_ID как голый
#    "${IWE_AGENT_ID:-${IWE_AGENT:-claude-code}}", а лок, взятый через
#    интерактивный MCP-инструмент acquire_file_lock, приходит с holder'ом
#    "<base>-$CLAUDE_CODE_SESSION_ID" (proxy.js, WP-530 Ф19, 31.08) — хук
#    видел свою же только что взятую аренду как чужую. Фикс: общий резолвер
#    iwe-agent-identity.sh, используемый и gateway-lock.py, и этим хуком.
#
# 2. Найдено живым прогоном ЭТОГО ЖЕ фикса перед деплоем: подсказка "возьми
#    аренду вручную" (ветка no_lease) передавала уже РЕЗОЛВНУТЫЙ (с суффиксом
#    сессии) AGENT_ID обратно как IWE_AGENT_ID для gateway-lock.py acquire —
#    резолвер добавил бы суффикс сессии ВТОРОЙ РАЗ, и лок, взятый по этой
#    подсказке, снова не совпал бы с тем, что видит хук. Фикс: подсказка
#    вызывает gateway-lock.py без явного IWE_AGENT_ID вообще — резолвер сам
#    вычислит ту же identity из того же окружения.
#
# Изоляция: MANIFEST/HOOK_DIR всегда реальные (хук берёт их от собственного
# расположения, не зависят от IWE_WORKSPACE) — паттерны манифеста начинаются
# с "*/", поэтому реальные паттерны матчатся и на путь под фейковым корнем.
# GATEWAY_LOCK/IDENTITY_RESOLVER подставляются через IWE_WORKSPACE +
# IWE_GOVERNANCE_REPO, указывающие на временный каталог с поддельным
# gateway-lock.py (контролируемое поведение) и РЕАЛЬНЫМ iwe-agent-identity.sh
# (копия — сам резолвер это и есть тестируемый код, копия сохраняет байты).
#
# Запуск: bash .claude/hooks/tests/test-write-path-lease-guard-identity.sh
set -uo pipefail

HOOK_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR_REAL/write-path-lease-guard.sh"
REAL_RESOLVER="$HOOK_DIR_REAL/../../DS-my-strategy/scripts/lib/iwe-agent-identity.sh"
[ -f "$HOOK" ] || { echo "FAIL: хук не найден: $HOOK"; exit 1; }
[ -f "$REAL_RESOLVER" ] || { echo "FAIL: резолвер не найден: $REAL_RESOLVER"; exit 1; }

PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/write-path-lease-identity-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

GOV_REPO_NAME="DS-my-strategy"
FAKE_LIB="$TMP/$GOV_REPO_NAME/scripts/lib"
mkdir -p "$FAKE_LIB" "$TMP/$GOV_REPO_NAME/inbox/WP-999"
cp "$REAL_RESOLVER" "$FAKE_LIB/iwe-agent-identity.sh"
chmod +x "$FAKE_LIB/iwe-agent-identity.sh"
TEST_FILE="$TMP/$GOV_REPO_NAME/inbox/WP-999/WP-999.md"
printf '%s\n' 'test card' > "$TEST_FILE"

write_fake_gateway_lock() {  # $1 = script body
  printf '%s\n' "$1" > "$FAKE_LIB/gateway-lock.py"
  chmod +x "$FAKE_LIB/gateway-lock.py"
}

run_hook() {  # -> печатает "exit_code|stderr_output"
  local input out rc
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"a","new_string":"b"}}))' "$TEST_FILE")
  out=$(printf '%s' "$input" | IWE_WORKSPACE="$TMP" IWE_GOVERNANCE_REPO="$GOV_REPO_NAME" \
    CLAUDE_CODE_SESSION_ID="test-session-abc" bash "$HOOK" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

check() {  # $1 desc, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 -- ожидалось [$2], получено [$3]"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Ожидаемая identity для этого окружения (та же, что вычислит сам хук) ==="
EXPECTED_ID=$(IWE_AGENT_ID="claude-code" CLAUDE_CODE_SESSION_ID="test-session-abc" bash "$FAKE_LIB/iwe-agent-identity.sh")
check "резолвер детерминирован: base+session" "claude-code-test-session-abc" "$EXPECTED_ID"

echo ""
echo "=== Сценарий 1: своя аренда (holder == вычисленный хуком AGENT_ID) -- пропуск ==="
# Хук зовёт gateway-lock.py явно через "python3 <путь>" -- заглушка обязана
# быть настоящим Python, не bash со случайным shebang'ом (первая версия
# этого теста молча запускала bash-скрипт под python3, ловила SyntaxError и
# читала это как "шлюз недоступен" -- ложный провал, не про identity вообще).
write_fake_gateway_lock '#!/usr/bin/env python3
import sys, json, time
if sys.argv[1] == "check":
    print(json.dumps({"holder": "'"$EXPECTED_ID"'", "expiresAt": int(time.time() * 1000) + 60000000}))
    sys.exit(0)
sys.exit(1)'
RESULT=$(run_hook)
RC="${RESULT%%|*}"
check "своя аренда: exit 0 (пропуск)" "0" "$RC"

echo ""
echo "=== Сценарий 2: чужая аренда (другой holder) -- блок ==="
write_fake_gateway_lock '#!/usr/bin/env python3
import sys, json
if sys.argv[1] == "check":
    print(json.dumps({"holder": "claude-code-some-other-session", "expiresAt": 99999999999999}))
    sys.exit(0)
sys.exit(1)'
RESULT=$(run_hook)
RC="${RESULT%%|*}"
MSG="${RESULT#*|}"
check "чужая аренда: exit 2 (блок)" "2" "$RC"
check "чужая аренда: сообщение называет другого агента" \
  "0" "$(printf '%s' "$MSG" | grep -q 'занят другим агентом' && echo 0 || echo 1)"

echo ""
echo "=== Сценарий 3: аренды нет вообще (check rc=3) -- блок, подсказка БЕЗ повторного IWE_AGENT_ID ==="
write_fake_gateway_lock '#!/usr/bin/env python3
import sys
sys.exit(3 if sys.argv[1] == "check" else 1)'
RESULT=$(run_hook)
RC="${RESULT%%|*}"
MSG="${RESULT#*|}"
check "нет аренды: exit 2 (блок)" "2" "$RC"
check "нет аренды: подсказка НЕ передаёт уже-резолвнутый IWE_AGENT_ID повторно (регрессия найденного бага)" \
  "0" "$(printf '%s' "$MSG" | grep -q 'IWE_AGENT_ID=' && echo 1 || echo 0)"
check "нет аренды: подсказка всё ещё называет команду acquire" \
  "0" "$(printf '%s' "$MSG" | grep -q 'gateway-lock.py acquire' && echo 0 || echo 1)"

echo ""
echo "=== Сценарий 4: шлюз недоступен (check rc=2) -- fail-closed блок ==="
write_fake_gateway_lock '#!/usr/bin/env python3
import sys
sys.exit(2 if sys.argv[1] == "check" else 1)'
RESULT=$(run_hook)
RC="${RESULT%%|*}"
MSG="${RESULT#*|}"
check "шлюз недоступен: exit 2 (fail-closed)" "2" "$RC"
check "шлюз недоступен: сообщение про недоступность" \
  "0" "$(printf '%s' "$MSG" | grep -q 'шлюз замков недоступен' && echo 0 || echo 1)"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS ($PASS)"
  exit 0
else
  echo "$FAIL FAILURE(S), $PASS passed"
  exit 1
fi
