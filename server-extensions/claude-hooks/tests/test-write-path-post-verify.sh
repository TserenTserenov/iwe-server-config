#!/bin/bash
# test-write-path-post-verify.sh — WP-530 Ф45, пир-сессия Claude+Kimi
# MC-sessions:2026-09/17/2026-09-17-11-wp530-peer-finish.
#
# Регрессия на два дефекта, найденных при написании этого хука:
#
# 1. Первая версия проверяла присутствие new_string голым substring-поиском
#    (без проверки old_string) — ложный "OK", если замена не применилась,
#    но текст new_string случайно уже встречался в файле в другом месте.
#    Найдено Kimi (критик, ход 2 сессии) до деплоя. Сценарий 4 ниже — прямая
#    регрессия на этот случай.
#
# 2. Первая версия хука передавала JSON через pipe В python3, чей СЦЕНАРИЙ
#    ТОЖЕ читался из heredoc на том же stdin — heredoc съедал stdin как
#    исходный код python, `json.load(sys.stdin)` внутри уже не видел
#    payload и тихо падал в "SKIP bad_json" на любом входе. Не поймано бы
#    юнит-тестом самого паттерна match_manifest_class (он не пайпит стдин) —
#    только сквозным вызовом хука целиком, как делают все сценарии ниже.
#
# Запуск: bash .claude/hooks/tests/test-write-path-post-verify.sh

set -uo pipefail

HOOK_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOK_DIR_REAL/write-path-post-verify.sh"
[ -f "$HOOK" ] || { echo "FAIL: хук не найден: $HOOK"; exit 1; }

PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/write-path-post-verify-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

GOV_REPO_NAME="DS-my-strategy"
TEST_FILE="$TMP/$GOV_REPO_NAME/inbox/WP-999/WP-999.md"
mkdir -p "$(dirname "$TEST_FILE")"

# Заглушки identity-резолвера и ledger-append.sh -- без них [ -x "$LEDGER" ]
# в хуке всегда ложно, и путь "правка потеряна -> запись в ledger" (та самая
# телеметрия, ради которой хук существует) не исполняется НИ ОДНИМ сценарием
# ниже (найдено code review, WP-530 Ф45 -- первая версия теста молчаливо
# оставляла этот путь непроверенным).
SCRIPTS_DIR="$TMP/$GOV_REPO_NAME/scripts"
LEDGER_CAPTURE="$TMP/ledger-capture.log"
mkdir -p "$SCRIPTS_DIR/lib"
printf '#!/bin/bash\necho "test-agent-id"\n' > "$SCRIPTS_DIR/lib/iwe-agent-identity.sh"
chmod +x "$SCRIPTS_DIR/lib/iwe-agent-identity.sh"
printf '#!/bin/bash\nprintf "%%s|%%s|%%s|%%s|%%s\\n" "$@" >> "%s"\n' "$LEDGER_CAPTURE" > "$SCRIPTS_DIR/ledger-append.sh"
chmod +x "$SCRIPTS_DIR/ledger-append.sh"

check() {  # $1 desc, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 -- ожидалось [$2], получено [$3]"
    FAIL=$((FAIL + 1))
  fi
}

run_hook_edit() {  # $1=old_string $2=new_string -> "rc|stderr"
  local input out rc
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]}}))' \
    "$TEST_FILE" "$1" "$2")
  out=$(printf '%s' "$input" | IWE_WORKSPACE="$TMP" IWE_GOVERNANCE_REPO="$GOV_REPO_NAME" bash "$HOOK" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

echo "=== Сценарий 1: правка реально на диске -- тихий exit 0, без stderr ==="
printf 'line1\nOLD_TEXT\nline3\n' > "$TEST_FILE"
sed -i '' 's/OLD_TEXT/NEW_TEXT/' "$TEST_FILE"
RESULT=$(run_hook_edit "OLD_TEXT" "NEW_TEXT")
check "успех: exit 0" "0" "${RESULT%%|*}"
check "успех: пустой stderr" "" "${RESULT#*|}"

echo ""
echo "=== Сценарий 1б: успех НЕ пишет в ledger (телеметрия только на потерю) ==="
check "успех: ledger-capture пуст" "0" "$([ ! -s "$LEDGER_CAPTURE" ] && echo 0 || echo 1)"

echo ""
echo "=== Сценарий 2: правку откатили между записью и хуком -- громкий FAIL + запись в ledger ==="
: > "$LEDGER_CAPTURE"
printf 'line1\nOLD_TEXT\nline3\n' > "$TEST_FILE"  # имитация внешнего отката до состояния "до Edit"
RESULT=$(run_hook_edit "OLD_TEXT" "NEW_TEXT")
MSG="${RESULT#*|}"
check "потеря: exit 0 (хук advisory, не блокирует)" "0" "${RESULT%%|*}"
check "потеря: stderr называет файл потерянным" \
  "0" "$(printf '%s' "$MSG" | grep -q 'не найдена на диске сразу после записи' && echo 0 || echo 1)"
check "потеря: ledger-append.sh реально вызван (путь телеметрии исполнен, не только описан)" \
  "0" "$([ -s "$LEDGER_CAPTURE" ] && echo 0 || echo 1)"
check "потеря: событие в ledger -- write_verify_failed" \
  "0" "$(cut -d'|' -f3 "$LEDGER_CAPTURE" | grep -qx 'write_verify_failed' && echo 0 || echo 1)"
check "потеря: agent в ledger взят из iwe-agent-identity.sh, не из голого fallback claude-code" \
  "0" "$(grep -q '"agent": "test-agent-id"' "$LEDGER_CAPTURE" && echo 0 || echo 1)"

echo ""
echo "=== Сценарий 3: файл вне манифеста -- тихий exit 0 ==="
OTHER="$TMP/random.md"
printf 'a\nb\n' > "$OTHER"
INPUT=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"a","new_string":"z"}}))' "$OTHER")
OUT=$(printf '%s' "$INPUT" | IWE_WORKSPACE="$TMP" IWE_GOVERNANCE_REPO="$GOV_REPO_NAME" bash "$HOOK" 2>&1)
check "вне манифеста: exit 0" "0" "$?"
check "вне манифеста: пустой stderr" "" "$OUT"

echo ""
echo "=== Сценарий 4: ложное совпадение -- new_string уже в файле, old_string НЕ ушёл (регрессия) ==="
printf 'ALREADY_HERE\nOLD_TEXT\n' > "$TEST_FILE"  # Edit тул якобы применился, файл реально не тронут
RESULT=$(run_hook_edit "OLD_TEXT" "ALREADY_HERE")
MSG="${RESULT#*|}"
check "ложное совпадение: exit 0 (advisory)" "0" "${RESULT%%|*}"
check "ложное совпадение: FAIL пойман (не проглочен голым substring-поиском)" \
  "0" "$(printf '%s' "$MSG" | grep -q 'old_string_still_present' && echo 0 || echo 1)"

echo ""
echo "=== Сценарий 4б: правка-продолжение (new_string содержит old_string целиком) -- НЕ ложная тревога (регрессия, найдено холодным ревью перед закрытием) ==="
printf 'line1\nOLD_TEXT\nline3\n' > "$TEST_FILE"
sed -i '' 's/OLD_TEXT/OLD_TEXT_EXTENDED/' "$TEST_FILE"  # реальная, успешная правка -- old_string физически остаётся внутри new_string
RESULT=$(run_hook_edit "OLD_TEXT" "OLD_TEXT_EXTENDED")
check "правка-продолжение: exit 0" "0" "${RESULT%%|*}"
check "правка-продолжение: тихо, без ложного FAIL" "" "${RESULT#*|}"

echo ""
echo "=== Сценарий 5: MultiEdit, одна из двух правок пропала -- называет конкретный индекс ==="
printf 'AAA\nBBB\nCCC\n' > "$TEST_FILE"
INPUT=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"MultiEdit","tool_input":{"file_path":sys.argv[1],"edits":[
  {"old_string":"AAA","new_string":"XXX"},
  {"old_string":"BBB","new_string":"YYY"}]}}))' "$TEST_FILE")
sed -i '' 's/AAA/XXX/' "$TEST_FILE"  # только первая правка реально применилась
OUT=$(printf '%s' "$INPUT" | IWE_WORKSPACE="$TMP" IWE_GOVERNANCE_REPO="$GOV_REPO_NAME" bash "$HOOK" 2>&1)
check "MultiEdit частичная потеря: пойман индекс edit[1]" \
  "0" "$(printf '%s' "$OUT" | grep -q 'edit\[1\]_new_string_missing' && echo 0 || echo 1)"
check "MultiEdit частичная потеря: edit[0] (применился) не в списке проблем" \
  "0" "$(printf '%s' "$OUT" | grep -q 'edit\[0\]_new_string_missing' && echo 1 || echo 0)"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS ($PASS)"
  exit 0
else
  echo "$FAIL FAILURE(S), $PASS passed"
  exit 1
fi
