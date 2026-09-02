#!/bin/bash
# shellcheck disable=SC2016
# Fixture strings below use literal $VAR text on purpose (they are sample
# command text for the hook, never executed by this shell).
# test-neon-prod-mutation-guard.sh — регрессионный корпус для
# neon-prod-mutation-guard.sh (WP-544, найдено 02.09 - дрейф search_path на
# проде без следа в git). Раунды ревью Кодекс+Kimi и холодный post-peer аудит
# 02.09 нашли несколько классов обходов - каждому посвящён отдельный кейс
# ниже (полная история - в шапке самого хука).
#
# Изоляция: тест использует временную имитацию шлюза и СВОЙ ключ замка. Он не
# зависит от запущенного Local Gateway и не может пересечься с реальной
# боевой операцией.
#
# Фикстуры лежат в файлах, а не в теле команды: сам хук матчится на ЛЮБОЙ
# Bash-вызов, и синтетическая команда, вписанная прямо в тело теста, рискует
# триггерить тот же хук на самом тестовом раннере.
#
# Запуск: bash .claude/hooks/tests/test-neon-prod-mutation-guard.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/neon-prod-mutation-guard.sh"
TMP_DIR=$(mktemp -d)
export IWE_WORKSPACE="$TMP_DIR/workspace"
export IWE_GOVERNANCE_REPO="governance"
export FAKE_GATEWAY_STATE="$TMP_DIR/gateway-state"
GATEWAY_LOCK="$IWE_WORKSPACE/$IWE_GOVERNANCE_REPO/scripts/lib/gateway-lock.py"
export NEON_PROD_MUTATION_LOCK_KEY="/virtual-locks/neon-production-mutation-TEST-$$"
PASS=0
FAIL=0

mkdir -p "$(dirname "$GATEWAY_LOCK")"
python3 -c 'import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("""#!/usr/bin/env python3
import json
import os
import pathlib
import sys

state = pathlib.Path(os.environ[\"FAKE_GATEWAY_STATE\"])
action = sys.argv[1] if len(sys.argv) > 1 else \"\"
holder = os.environ.get(\"IWE_AGENT_ID\", \"\")
expected_key = os.environ[\"NEON_PROD_MUTATION_LOCK_KEY\"]

if len(sys.argv) < 3 or sys.argv[2] != expected_key:
    sys.exit(5)

if action == \"check\":
    if not state.exists():
        sys.exit(3)
    print(json.dumps({\"holder\": state.read_text()}))
    sys.exit(0)

if action == \"acquire\":
    if state.exists() and state.read_text() != holder:
        sys.exit(4)
    state.write_text(holder)
    print(json.dumps({\"holder\": holder}))
    sys.exit(0)

if action == \"release\":
    if state.exists() and state.read_text() == holder:
        state.unlink()
        sys.exit(0)
    sys.exit(4)

sys.exit(2)
""")' "$GATEWAY_LOCK"

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

expect_without_gateway() {
  local desc="$1" want="$2" path="$3" got
  IWE_GOVERNANCE_REPO="missing" bash "$HOOK" < "$path" >/dev/null 2>&1
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

expect "read-only psql на прод-ветке без замка -> блок (SQL нельзя доказать read-only)" 2 \
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

expect "session_id со служебными символами -> блок (fail-closed)" 2 \
  "$(python3 -c 'import json,sys; p=sys.argv[1]+"/bad-session.json"; json.dump({"hook_event_name":"PreToolUse","session_id":"sess A;other","tool_input":{"command":"echo ok"}}, open(p,"w")); print(p)' "$TMP_DIR")"

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

### Раунд 4 (Кодекс + минимальное ревью Kimi) ###

expect "SELECT доменной функции удаления -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -c "SELECT public.domain_event_forget_account(42, '\''reason'\'')"')"

expect "непрозрачный SQL через pipe в psql -> блок" 2 \
  "$(fixture "sess-A" 'python3 generate_sql.py | psql "$NEON_LEARNING_URL"')"

expect "-f с quoted-переменной без пробела -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -f"$MIGRATION_FILE"')"

expect "-c с непрозрачной SQL-переменной -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_LEARNING_URL" -c "$SQL"')"

expect "curl -XDELETE без пробела -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS -XDELETE "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft"')"

expect "curl -d с quoted compact payload -> блок" 2 \
  "$(fixture "sess-A" "curl -fsS -d'{\"branch\":{}}' https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft")"

expect "curl -F с quoted compact form -> блок" 2 \
  "$(fixture "sess-A" "curl -fsS -F'file=@payload.json' https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft")"

expect "curl -T с quoted compact upload -> блок" 2 \
  "$(fixture "sess-A" "curl -fsS -T'backup.sql' https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft")"

expect "мутация через короткий алиас NEON_URL -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_URL" -c "DROP TABLE public.domain_event"')"

expect "мутация через фактический алиас AIST_BOT_DIRECT -> блок" 2 \
  "$(fixture "sess-A" 'psql "$AIST_BOT_DIRECT" -c "TRUNCATE public.domain_event"')"

expect "read-only curl -fsS к production branch -> пропуск" 0 \
  "$(fixture "sess-A" 'curl -fsS "https://console.neon.tech/api/v2/projects/purple-bread-37001042/branches/br-lingering-cake-aggtcdft"')"

expect "печать примера мутирующего curl -> пропуск (curl не вызывается)" 0 \
  "$(fixture "sess-A" "printf '%s\\n' 'curl -XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft'")"

expect_without_gateway "недоступный шлюз при видимой мутации -> блок" 2 \
  "$(fixture "sess-A" "$PROD_ALTER")"

expect "многострочный SELECT доменной функции удаления -> блок" 2 \
  "$(fixture "sess-A" $'psql "$NEON_DSN" -c "SELECT\n public.domain_event_forget_account(NULL, NULL)"')"

expect "quoted имя доменной функции удаления -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" -c "SELECT public.\"domain_event_forget_account\"(NULL, NULL)"')"

expect "многострочный DELETE FROM -> блок" 2 \
  "$(fixture "sess-A" $'psql "$NEON_DSN" -c "DELETE\nFROM public.domain_event"')"

expect "многострочный pipe в psql -> блок" 2 \
  "$(fixture "sess-A" $'printf "%s\\n" "$SQL" |\n  psql "$NEON_DSN"')"

expect "--command с braced SQL-переменной -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" --command="${SQL}"')"

expect "here-string с непрозрачным SQL -> блок" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" <<< "$SQL"')"

expect "естественная bash -c обёртка с psql -> блок" 2 \
  "$(fixture "sess-A" "bash -c 'psql \"\$NEON_DSN\" -f\"\$MIGRATION_FILE\"'")"

expect "естественная ssh обёртка с psql -> блок" 2 \
  "$(fixture "sess-A" "ssh db-host 'psql \"\$NEON_DSN\" -c \"DROP TABLE x\"'")"

expect "естественная bash -c обёртка с curl -> блок" 2 \
  "$(fixture "sess-A" "bash -c 'curl -XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft'")"

expect "curl -X с quoted методом -> блок" 2 \
  "$(fixture "sess-A" "curl -fsS -X 'DELETE' https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft")"

expect "curl --request= с quoted методом -> блок" 2 \
  "$(fixture "sess-A" "curl -fsS --request='DELETE' https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft")"

expect "curl compact -G с data-флагом -> блок (неоднозначное тело)" 2 \
  "$(fixture "sess-A" 'curl -fsSG "https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft" --data-urlencode "limit=1"')"

expect "curl --get с data-флагом -> блок (неоднозначное тело)" 2 \
  "$(fixture "sess-A" 'curl -fsS --get "https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft" --data "limit=1"')"

expect "явный DELETE важнее -G -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsSG -XDELETE "https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft" --data "x=1"')"

expect "grep ищет psql+DROP+маркер -> пропуск (psql не вызывается)" 0 \
  "$(fixture "sess-A" 'rg "psql.*NEON_DSN.*DROP" docs/')"

expect "printf печатает psql-мутацию -> пропуск (psql не вызывается)" 0 \
  "$(fixture "sess-A" "printf '%s\\n' 'psql \"\$NEON_DSN\" -c \"DROP TABLE x\"'")"

expect "psql SELECT INTO -> блок общей политикой direct psql" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" -c "SELECT * INTO public.backup FROM public.domain_event"')"

expect "psql DELETE с SQL-комментарием -> блок общей политикой direct psql" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" -c "DELETE /* cleanup */ FROM public.domain_event"')"

expect "psql с clustered -Xf -> блок общей политикой direct psql" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" -Xf"$MIGRATION_FILE"')"

expect "psql с clustered -Atc и переменной -> блок общей политикой direct psql" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" -Atc"${SQL}"')"

expect "curl с backslash-newline после -X -> блок" 2 \
  "$(fixture "sess-A" $'curl -fsS -X \\\n DELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "psql внутри command substitution у echo -> блок" 2 \
  "$(fixture "sess-A" 'echo "$(psql "$NEON_DSN" -c "SELECT 1")"')"

expect "curl внутри command substitution у printf -> блок" 2 \
  "$(fixture "sess-A" 'printf "%s\\n" "$(curl -fsS -XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft)"')"

expect "curl --data со значением -G -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS --data "-G" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl -G с upload-флагом -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsSG -T"backup.sql" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl с непрозрачным config-файлом -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS --config "$REQUEST_CONFIG" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "говорящая переменная PSQL_BIN как команда -> блок" 2 \
  "$(fixture "sess-A" '"${PSQL_BIN}" "$NEON_DSN" -c "SELECT 1"')"

expect "говорящая переменная CURL_BIN с методом -> блок" 2 \
  "$(fixture "sess-A" '"$CURL_BIN" -XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "непрозрачная переменная программы у prod-маркера -> блок" 2 \
  "$(fixture "sess-A" '"$P" "$NEON_DSN" -c "SELECT 1"')"

expect "curl без method/body/upload/config остаётся read-only -> пропуск" 0 \
  "$(fixture "sess-A" 'curl -fsSLG https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "явный GET через -X считается неоднозначным -> блок" 2 \
  "$(fixture "sess-A" 'curl -fsS -XGET https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "direct psql блокируется даже если DROP — quoted имя столбца" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" -c "SELECT \"DROP\" FROM public.audit_log"')"

expect "direct psql блокируется даже при read-only introspection функции" 2 \
  "$(fixture "sess-A" 'psql "$NEON_DSN" -c "SELECT to_regprocedure('\''public.domain_event_forget_account(uuid,text)'\'')"')"

expect "curl quoted -X token -> блок" 2 \
  "$(fixture "sess-A" 'curl "-X" DELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl quoted -d token -> блок" 2 \
  "$(fixture "sess-A" 'curl "-d" "{}" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl quoted --data token -> блок" 2 \
  "$(fixture "sess-A" 'curl "--data" "{}" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl quoted --config token -> блок" 2 \
  "$(fixture "sess-A" 'curl "--config" "$REQUEST_CONFIG" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl numeric cluster -4X -> блок" 2 \
  "$(fixture "sess-A" 'curl -4XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl numeric cluster -4d -> блок" 2 \
  "$(fixture "sess-A" 'curl -4d"{}" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl numeric cluster -6T -> блок" 2 \
  "$(fixture "sess-A" 'curl -6T"backup.sql" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "динамическая команда после inline env assignment -> блок" 2 \
  "$(fixture "sess-A" 'PGOPTIONS="-c statement_timeout=5s" "$P" "$NEON_DSN" -c "SELECT 1"')"

expect "динамическая команда после command -> блок" 2 \
  "$(fixture "sess-A" 'command "$P" "$NEON_DSN" -c "SELECT 1"')"

expect "динамическая команда после env -> блок" 2 \
  "$(fixture "sess-A" 'env "$P" "$NEON_DSN" -c "SELECT 1"')"

expect "динамическая команда в subshell -> блок" 2 \
  "$(fixture "sess-A" '( "$P" "$NEON_DSN" -c "SELECT 1" )')"

expect "динамическая команда внутри command substitution -> блок" 2 \
  "$(fixture "sess-A" 'echo "$("$P" "$NEON_DSN" -c "SELECT 1")"')"

expect "psql внутри process substitution -> блок" 2 \
  "$(fixture "sess-A" 'cat <(psql "$NEON_DSN" -c "SELECT 1")')"

expect "curl внутри process substitution -> блок" 2 \
  "$(fixture "sess-A" 'cat <(curl -XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft)')"

expect "inline переменная curl method-флага -> блок" 2 \
  "$(fixture "sess-A" 'METHOD="-XPOST" curl "$METHOD" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "inline переменная curl body-флага -> блок" 2 \
  "$(fixture "sess-A" 'DATA="--data" curl "$DATA" "{}" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "inline переменная curl config-флага -> блок" 2 \
  "$(fixture "sess-A" 'CFG="-K" curl "$CFG" request.conf https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

# Финальное возражение Kimi оказалось неверной ручной трассировкой regex:
# короткая альтернатива не требует конца строки и поэтому матчит префикс -X,
# а long-альтернатива принимает пробел после --data. Закрепляем фактический
# результат, чтобы это доказательство не зависело от повторного рассуждения.
expect "inline curl method-флаг с пробелом в значении -> блок" 2 \
  "$(fixture "sess-A" 'FLAGS="-X DELETE"; curl "$FLAGS" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "inline curl -X и метод как два слова -> блок" 2 \
  "$(fixture "sess-A" 'METHOD="-X POST"; curl "$METHOD" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "inline curl --data с payload в значении -> блок" 2 \
  "$(fixture "sess-A" 'DATA="--data {'\''x'\'':1}"; curl $DATA https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

### Холодный post-peer аудит ###

expect "psql после настоящего newline у echo -> блок" 2 \
  "$(fixture "sess-A" $'echo ready\npsql "$NEON_DSN" -c "SELECT 1"')"

expect "curl после настоящего newline у printf -> блок" 2 \
  "$(fixture "sess-A" $'printf ready\ncurl -XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "psql после одиночного background & у echo -> блок" 2 \
  "$(fixture "sess-A" 'echo ready & psql "$NEON_DSN" -c "SELECT 1"')"

expect "curl punctuation cluster -#XDELETE -> блок" 2 \
  "$(fixture "sess-A" 'curl -#XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl-флаги через inline array expansion -> блок" 2 \
  "$(fixture "sess-A" 'ARGS=(-XDELETE); curl "${ARGS[@]}" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "динамическая команда после time -> блок" 2 \
  "$(fixture "sess-A" 'time "$P" "$NEON_DSN" -c "SELECT 1"')"

expect "динамическая команда после path-qualified env -> блок" 2 \
  "$(fixture "sess-A" '/usr/bin/env "$P" "$NEON_DSN" -c "SELECT 1"')"

expect "динамическая команда после if -> блок" 2 \
  "$(fixture "sess-A" 'if "$P" "$NEON_DSN" -c "SELECT 1"; then echo ok; fi')"

expect "динамическая команда после negation -> блок" 2 \
  "$(fixture "sess-A" '! "$P" "$NEON_DSN" -c "SELECT 1"')"

expect "динамическая команда в brace group -> блок" 2 \
  "$(fixture "sess-A" '{ "$P" "$NEON_DSN" -c "SELECT 1"; }')"

expect "quote-split psql command token -> блок" 2 \
  "$(fixture "sess-A" 'p"sq"l "$NEON_DSN" -c "SELECT 1"')"

expect "quote-split curl production marker -> блок" 2 \
  "$(fixture "sess-A" 'curl -XDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-"cake"-aggtcdft')"

expect "backslash-split curl long option -> блок" 2 \
  "$(fixture "sess-A" 'curl --re\quest DELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "ANSI-C quoted curl option -> блок" 2 \
  "$(fixture "sess-A" 'curl $'\''-4XDELETE'\'' https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl --expand-request -> блок" 2 \
  "$(fixture "sess-A" 'curl --expand-request DELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl --expand-data -> блок" 2 \
  "$(fixture "sess-A" 'curl --expand-data "{}" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl --expand-json -> блок" 2 \
  "$(fixture "sess-A" 'curl --expand-json "{}" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl --expand-form -> блок" 2 \
  "$(fixture "sess-A" 'curl --expand-form "x=y" https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl --expand-upload-file -> блок" 2 \
  "$(fixture "sess-A" 'curl --expand-upload-file backup.sql https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl --expand-config -> блок" 2 \
  "$(fixture "sess-A" 'curl --expand-config request.conf https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "curl -o с аргументом, содержащим d, остаётся read-only -> пропуск" 0 \
  "$(fixture "sess-A" 'curl -o/dev/null https://ep-dark-hall-ag8bo8lf.eu-central-1.aws.neon.tech/rest/v1/items')"

expect "echo с quoted semicolon и psql-примером -> пропуск" 0 \
  "$(fixture "sess-A" "echo 'example; psql \"\$NEON_DSN\" -c \"SELECT 1\"'")"

expect "echo с quoted ampersand и psql-примером -> пропуск" 0 \
  "$(fixture "sess-A" "echo 'example & psql \"\$NEON_DSN\" -c \"SELECT 1\"'")"

expect "echo с quoted newline и psql-примером -> пропуск" 0 \
  "$(fixture "sess-A" $'echo \'example\npsql "$NEON_DSN" -c "SELECT 1"\'')"

expect "curl штатный -B перед -X в short cluster -> блок" 2 \
  "$(fixture "sess-A" 'curl -BXDELETE https://console.neon.tech/api/v2/projects/x/branches/br-lingering-cake-aggtcdft')"

expect "cat с literal quoted heredoc -> пропуск" 0 \
  "$(fixture "sess-A" $'cat <<\'TXT\'\npsql "$NEON_DSN" -c "SELECT 1"\nTXT')"

expect "quoted heredoc, исполняемый bash, -> блок" 2 \
  "$(fixture "sess-A" $'bash <<\'TXT\'\npsql "$NEON_DSN" -c "SELECT 1"\nTXT')"

expect "cat heredoc с реальной следующей командой -> блок" 2 \
  "$(fixture "sess-A" $'cat <<\'TXT\'\npsql "$NEON_DSN" -c "SELECT 1"\nTXT\npsql "$NEON_DSN" -c "SELECT 1"')"

### Держатель замка ###

IWE_AGENT_ID="claude-code-sess-A" python3 "$GATEWAY_LOCK" acquire "$NEON_PROD_MUTATION_LOCK_KEY" 60 >/dev/null 2>&1

expect "та же мутация под своим же замком (sess-A) -> пропуск" 0 \
  "$(fixture "sess-A" "$PROD_ALTER")"

expect "та же мутация от ДРУГОЙ сессии (sess-B), не державшей замок -> блок" 2 \
  "$(fixture "sess-B" "$PROD_ALTER")"

IWE_AGENT_ID="claude-code-sess-A" python3 "$GATEWAY_LOCK" release "$NEON_PROD_MUTATION_LOCK_KEY" >/dev/null 2>&1

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
