#!/bin/bash
# shellcheck disable=SC2016
# Fixture strings below use literal $VAR text on purpose (they are sample
# command text for the hook, never executed by this shell).
# test-neon-prod-mutation-guard.sh — регрессионный корпус для
# neon-prod-mutation-guard.sh (WP-544, найдено 02.09 - дрейф search_path на
# проде без следа в git). Четыре раунда ревью Кодекс+Kimi 02.09 нашли 15
# конкретных дыр в первых трёх версиях хука - каждой посвящён отдельный кейс
# ниже (полная история - в шапке самого хука).
#
# Изоляция: тест использует СВОЙ ключ замка (NEON_PROD_MUTATION_LOCK_KEY), не
# тот, что реальная продовая мутация - конфликт с настоящей боевой операцией
# исключён по конструкции.
#
# Фикстуры лежат в файлах, а не в теле команды: сам хук матчится на ЛЮБОЙ
# Bash-вызов, и синтетическая команда, вписанная прямо в тело теста, рискует
# триггерить тот же хук на самом тестовом раннере.
#
# Запуск: bash .claude/hooks/tests/test-neon-prod-mutation-guard.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/neon-prod-mutation-guard.sh"
IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
GATEWAY_LOCK="$IWE_ROOT/$GOV_REPO/scripts/lib/gateway-lock.py"
export NEON_PROD_MUTATION_LOCK_KEY="/virtual-locks/neon-production-mutation-TEST-$$"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
  IWE_AGENT_ID="claude-code-sess-A" python3 "$GATEWAY_LOCK" release "$NEON_PROD_MUTATION_LOCK_KEY" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# fixture $1=session_id $2=command → печатает путь к JSON-файлу входа хука
fixture() {
  local session="$1" command="$2" path
  path="$TMP_DIR/input-$$-$RANDOM.json"
  python3 -c 'import json,sys; open(sys.argv[3],"w").write(json.dumps({
      "hook_event_name": "PreToolUse", "session_id": sys.argv[1],
      "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' \
    "$session" "$command" "$path"
  echo "$path"
}

# expect $1=описание $2=exit_ожидаемый $3=фикстура_путь
expect() {
  local desc="$1" want="$2" path="$3" got
  bash "$HOOK" < "$path" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидался exit=$want, получен exit=$got)"
  fi
}

PROD_ALTER='psql "$NEON_LEARNING_URL" -c "ALTER FUNCTION public.domain_event_forget_account(uuid,text) SET search_path = pg_catalog"'
PROD_SELECT='psql "$NEON_LEARNING_URL" -c "SELECT 1"'
OTHER_ALTER='psql "$SOME_TEST_URL" -c "ALTER FUNCTION foo() SET x = 1"'

### Раунд 1-2 (Кодекс) ###

expect "мутация прод-ветки без замка -> блок" 2 \
  "$(fixture "sess-A" "$PROD_ALTER")"

expect "read-only psql на прод-ветке без замка -> пропуск (политика: читаем без замка)" 0 \
  "$(fixture "sess-A" "$PROD_SELECT")"

expect "мутация НЕсвязанной (не прод) ветки -> пропуск" 0 \
  "$(fixture "sess-A" "$OTHER_ALTER")"

expect "мутация через -f файл, без видимых SQL-слов -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -f mvp/312-wp554-f6-forget-account-search-path-hardening.sql')"

expect "мутация прод-ветки через curl -X DELETE (Management API) -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS -X DELETE "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft" -H "Authorization: Bearer $NEON_API_KEY"')"

expect "невалидный JSON на входе -> блок (fail-closed)" 2 \
  "$(python3 -c 'import sys; p=sys.argv[1]+"/bad.json"; open(p,"w").write("not even json"); print(p)' "$TMP_DIR")"

expect "валидный JSON, но не PreToolUse -> блок (fail-closed, как у secret-leak-block.sh)" 2 \
  "$(python3 -c 'import json,sys; p=sys.argv[1]+"/wrong-event.json"; json.dump({"hook_event_name":"Stop","session_id":"sess-A"}, open(p,"w")); print(p)' "$TMP_DIR")"

expect "command = null -> блок (fail-closed)" 2 \
  "$(python3 -c 'import json,sys; p=sys.argv[1]+"/null-command.json"; json.dump({"hook_event_name":"PreToolUse","session_id":"sess-A","tool_input":{"command":None}}, open(p,"w")); print(p)' "$TMP_DIR")"

expect "command отсутствует вовсе -> блок (fail-closed)" 2 \
  "$(python3 -c 'import json,sys; p=sys.argv[1]+"/missing-command.json"; json.dump({"hook_event_name":"PreToolUse","session_id":"sess-A","tool_input":{}}, open(p,"w")); print(p)' "$TMP_DIR")"

expect "мутация через переменную PRIVACY_DELETION_URL -> блок" 2 \
  "$(fixture "sess-A" 'psql "$PRIVACY_DELETION_URL" -c "DELETE FROM public.domain_event WHERE 1=1"')"

expect "мутация через переменную DATABASE_URL_LEARNING_DIRECT -> блок" 2 \
  "$(fixture "sess-A" 'psql "$DATABASE_URL_LEARNING_DIRECT" -c "TRUNCATE public.domain_event"')"

expect "curl --request=DELETE (форма через =) -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS --request=DELETE "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft" -H "Authorization: Bearer $NEON_API_KEY"')"

expect "curl без -X, но с --data (неявный POST) -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches" -H "Authorization: Bearer $NEON_API_KEY" --data "{\"branch\":{\"parent_id\":\"br-lingering-cake-aggtcdft\"}}"')"

expect "curl --upload-file (неявный PUT) -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS --upload-file backup.sql "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft"')"

expect "psql; сразу после команды (граница - не пробел) -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -c "ALTER FUNCTION foo() SET x=1"; echo done')"

expect "подстановка P=psql; \"\$P\" ... -> блок" 2 \
  "$(fixture "sess-A" 'P=psql; "$P" "$NEON_LEARNING_URL" -c "ALTER FUNCTION foo() SET x=1"')"

expect "grep ищет упоминания psql и NEON_LEARNING_URL в докам -> пропуск (не вызов psql)" 0 \
  "$(fixture "sess-A" 'grep -rn "psql.*NEON_LEARNING_URL" docs/')"

expect "cat печатает файл с примером ALTER на NEON_LEARNING_URL -> пропуск (не вызов psql)" 0 \
  "$(fixture "sess-A" 'cat docs/example-alter-NEON_LEARNING_URL.md')"

### Раунд 3 (Kimi через Кодекса, перепроверено фактическими контрпримерами) ###

expect "psql < file.sql (редирект) -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" < mvp/312.sql')"

expect "psql -ffile.sql (компактный флаг без пробела) -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -fmvp/312.sql')"

expect "psql-метакоманда \\i внутри heredoc -> блок" 2 \
  "$(fixture "sess-A" $'psql "$NEON_LEARNING_URL" <<SQL\n\\\\i mvp/312.sql\nSQL')"

expect "флаг --file через переменную-косвенность (X=--file; ... \"\$X\" ...) -> блок" 2 \
  "$(fixture "sess-A" 'X=--file; psql "$NEON_LEARNING_URL" "$X" mvp/312.sql')"

expect "curl -dDATA (компактный флаг данных, неявный POST) -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches" -H "Authorization: Bearer $NEON_API_KEY" -d"{\"branch\":{\"parent_id\":\"br-lingering-cake-aggtcdft\"}}"')"

expect "curl -X    DELETE (метод после нескольких пробелов) -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS -X    DELETE "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft" -H "Authorization: Bearer $NEON_API_KEY"')"

expect "MERGE (мутирующее SQL-слово вне старого списка) -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -c "MERGE INTO public.domain_event USING src ON true WHEN MATCHED THEN DELETE"')"

expect "COPY FROM (bulk-мутация) -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -c "COPY public.domain_event FROM STDIN"')"

expect "CALL хранимой процедуры -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -c "CALL public.some_mutating_procedure()"')"

expect "grep ... && psql ... (обход через цепочку после первого слова grep) -> блок" 2 \
  "$(fixture "sess-A" 'grep -q x file.txt && psql "$NEON_LEARNING_URL" -c "DROP TABLE public.domain_event"')"

expect "мутация через NEON_REWARDS_URL (другая каноническая БД проекта) -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_REWARDS_URL" -c "DELETE FROM public.point_balances"')"

expect "мутация через DATABASE_URL_PERSONA_DIRECT (другая каноническая БД проекта) -> блок" 2 \
  "$(fixture "sess-A" 'psql "$DATABASE_URL_PERSONA_DIRECT" -c "DROP TABLE public.consent_grants"')"

expect "тестовый файл learning-schema.sql (строчными) -> пропуск (не переменная окружения)" 0 \
  "$(fixture "sess-A" 'cat fixtures/learning-schema.sql')"

expect "read-only на URL с текстом --data= в самой строке -> пропуск (не реальный флаг)" 0 \
  "$(fixture "sess-A" 'curl -fsS "https://example.com/api?config--data=foo"')"

### Держатель замка ###

IWE_AGENT_ID="claude-code-sess-A" python3 "$GATEWAY_LOCK" acquire "$NEON_PROD_MUTATION_LOCK_KEY" 60 >/dev/null 2>&1

expect "та же мутация под своим же замком (sess-A) -> пропуск" 0 \
  "$(fixture "sess-A" "$PROD_ALTER")"

expect "та же мутация от ДРУГОЙ сессии (sess-B), не державшей замок -> блок" 2 \
  "$(fixture "sess-B" "$PROD_ALTER")"

IWE_AGENT_ID="claude-code-sess-A" python3 "$GATEWAY_LOCK" release "$NEON_PROD_MUTATION_LOCK_KEY" >/dev/null 2>&1

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
