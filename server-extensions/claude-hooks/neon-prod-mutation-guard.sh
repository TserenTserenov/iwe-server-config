#!/usr/bin/env bash
# neon-prod-mutation-guard.sh — PreToolUse-хук (Bash): прямое обращение к боевой
# Neon-ветке требует активной аренды замка Local Gateway (WP-544, найдено 02.09 -
# дрейф search_path на проде без единого следа в git/сессиях, источник не
# установлен).
#
# ВАЖНО, по итогу трёх раундов ревью Кодекс+Kimi (02.09): это эвристическая
# страховка одного рантайма (Claude Code) против ЧЕСТНОЙ ошибки, не защитная
# граница против определённого обхода. Регекс на свободном тексте bash-команды
# принципиально не может быть полным - каждый раунд ревью находил новые
# конкретные формы обхода, и это будет продолжаться. Дальше по этому пути
# закон убывающей отдачи; настоящий технический барьер - отдельная задача
# (единый запускатель продовых миграций, предложение Кодекса, см. WP-544).
# Значение этого хука - поднять цену случайной ошибки, не исключить намеренный
# обход.
#
# История находок (все подтверждены и починены, детали → WP-544):
# Раунд 1 (Кодекс): (1) `-f файл.sql` не ловился; (2) битый вход тихо
#   пропускался; (3) AGENT_ID схлопывался в общий дефолт для любой сессии.
# Раунд 2 (Кодекс): (4) пустой/null command тихо пропускался; (5) список
#   known-переменных был заведомо неполон; (6) `curl --request=X`, неявные
#   POST/PUT не ловились; (7) граница слова после psql требовала пробел;
#   (8) молчаливая смена политики (гейт всех read, не только мутаций) плюс
#   ложные блокировки на поиске по документации; (9) тест делил ключ замка
#   с реальной продовой мутацией.
# Раунд 3 (Kimi через Кодекса, перепроверено фактическими контрпримерами):
#   (10) `< file.sql`, `\i`, компактный `-ffile`, переменная с `--file` -
#   опасный SQL всё ещё проходил; (11) компактные curl-флаги (`-dDATA`,
#   `-Fdata`, `-Tfile`), метод после нескольких пробелов - не ловились;
#   (12) MERGE/COPY FROM/CALL не входили в список мутирующих SQL-слов;
#   (13) исключение по первому слову команды (grep и т.п.) открывало обход
#   через `grep ... && psql ...` - убрано целиком, заменено точечным
#   исключением по контексту перед словом psql (см. ниже); (14) список
#   маркеров охватывал только БД `learning`, хотя в проекте минимум 12
#   канонических БД (DP.ARCH.004 §3) - расширен; (15) широкий регистронезависимый
#   матч "learning" ловил и обычные файлы вроде `learning-schema.sql` - маркер
#   БД теперь регистрозависим (переменные окружения пишут заглавными).
#
# Семантика (exit 2 = блок для Claude Code):
#   вход невалиден (не JSON/не тот event/нет валидного command) → БЛОК (fail-closed)
#   команда не похожа на прямое обращение к прод-ветке                    → пропустить молча
#   похожа, но видимого мутирующего сигнала нет (чистый read)             → пропустить молча
#   аренда моя (session_id совпал)                                        → пропустить
#   аренда чужая                                                          → БЛОК (названа сессия-держатель)
#   аренды нет                                                            → БЛОК (дана готовая команда acquire)
#   шлюз недоступен                                                       → БЛОК (fail-closed, как у соседних гардов)

set -uo pipefail

IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
GATEWAY_LOCK="$IWE_ROOT/$GOV_REPO/scripts/lib/gateway-lock.py"
LOCK_KEY="${NEON_PROD_MUTATION_LOCK_KEY:-/virtual-locks/neon-production-mutation}"

security_failure() {
  printf '%s\n' "neon-prod-mutation-guard: $1" >&2
  exit 2
}

INPUT=$(cat) || security_failure "не удалось прочитать stdin"

# Один атомарный блок валидации схемы: любое отклонение (не JSON, не тот
# event, нет session_id, tool_input не объект, command не строка/пусто)
# фейлит блоком, а не молчаливым пропуском отдельных полей.
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict) or d.get("hook_event_name") != "PreToolUse":
    sys.exit(1)
session_id = d.get("session_id")
if not isinstance(session_id, str) or not session_id.strip():
    sys.exit(1)
ti = d.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(1)
command = ti.get("command")
if not isinstance(command, str) or not command.strip():
    sys.exit(1)
print(session_id)
print(command)
' 2>/dev/null) || security_failure "не удалось разобрать вход хука (невалидный JSON/схема/пустая команда) - fail-closed"

SESSION_ID=$(printf '%s\n' "$PARSED" | sed -n '1p')
COMMAND=$(printf '%s\n' "$PARSED" | sed -n '2,$p')
AGENT_ID="claude-code-$SESSION_ID"

# Маркер боевой БД - регистрозависимо: реальные переменные окружения пишут
# ЗАГЛАВНЫМИ (NEON_LEARNING_URL, DATABASE_URL_PERSONA_DIRECT), а обычный файл
# вроде learning-schema.sql - нет. 12 канонических БД проекта (DP.ARCH.004
# §3: persona/journal/payment/subscription/indicators/learning/knowledge/
# reference/publication/community/lead/rewards) + 4 специальных
# (secrets/metabase/health/payment_registry, последняя ловится через PAYMENT)
# + известные не-БД-именованные переменные того же прод-контура
# (PRIVACY_DELETION_URL - живой Railway-переменная сервиса удаления,
# найдена 02.09, не содержит имени БД). Список не может быть исчерпывающим
# по конструкции (новый сервис волен назвать переменную как угодно) -
# единственные по-настоящему устойчивые признаки ниже, во втором грепе: ID
# production-ветки и её хост.
MARKER_VARNAME_RE='[A-Z][A-Z0-9_]*(PERSONA|JOURNAL|PAYMENT|SUBSCRIPTION|INDICATORS|LEARNING|KNOWLEDGE|REFERENCE|PUBLICATION|COMMUNITY|LEAD|REWARDS|SECRETS|METABASE|HEALTH)[A-Z0-9_]*|PRIVACY_DELETION_URL'
MARKER_ID_RE='br-lingering-cake-aggtcdft|ep-dark-hall-ag8bo8lf'

printf '%s' "$COMMAND" | grep -qE "$MARKER_VARNAME_RE" || \
  printf '%s' "$COMMAND" | grep -qiE "$MARKER_ID_RE" || exit 0

# Видимая в самой команде мутация. MERGE/COPY/CALL добавлены по находке Kimi
# раунда 3 (COPY гейтится целиком, не только COPY FROM - over-inclusion
# безопаснее пропуска).
MUTATION_RE='\b(ALTER|DROP|INSERT[[:space:]]+INTO|UPDATE|DELETE[[:space:]]+FROM|GRANT|REVOKE|TRUNCATE|CREATE|MERGE|COPY|CALL)\b'

# Признак непрозрачного источника SQL: файл через -f/--file (компактная
# форма -ffile и через `=`), редирект `<`, или psql-метакоманда \i.
# Проверяется НЕЗАВИСИМО от позиции слова psql в команде (не только "сразу
# после psql") - правит обход через переменную-косвенность вида
# `X=--file; psql ... "$X" файл.sql`, где сам флаг стоит раньше вызова.
OPAQUE_SQL_RE='([^A-Za-z0-9_]|^)-f([[:space:]]|[A-Za-z0-9._/-])|([^A-Za-z0-9_]|^)--file([^A-Za-z0-9_]|$)|([^A-Za-z0-9_]|^)<[[:space:]]*[^[:space:];&|]+|\\i([^A-Za-z0-9_]|$)'

# Мутирующий вызов Neon Management API: явный -X/--request (в т.ч. через =,
# с любым числом пробелов), компактные короткие флаги данных без пробела
# (-dDATA/-Fdata/-Tfile) и их длинные формы (--data*/--json/--form/
# --upload-file), с раздельным пробелом или слитно через =.
CURL_MUTATION_RE='(-X|--request)[[:space:]=]+.?(POST|PUT|PATCH|DELETE)|(^|[[:space:]])(-d|-F|-T)[A-Za-z0-9]|(^|[[:space:]])(-d|-F|-T)([[:space:]=]|$)|(^|[[:space:]])(--data(-raw|-binary|-urlencode)?|--json|--form|--upload-file)([[:space:]=]|$)'

# psql как реальный вызов, а не как поисковый паттерн внутри чужой команды
# (grep/rg и т.п.): единственный практичный признак различия - "psql" внутри
# кавычек почти всегда аргумент ДРУГОЙ программе (искомый текст), не сам
# вызов. Символ прямо перед "psql" не кавычка/буква/цифра/подчёркивание (или
# начало строки) - тогда это позиция вызова программы. Правит находку Kimi
# раунда 3: раньше исключение по первому слову команды открывало обход
# `grep ... && psql ...` - теперь оцениваем контекст самого слова psql, а не
# первое слово всей команды, так что цепочка после `&&` по-прежнему ловится.
PSQL_INVOKE_RE='(^|[^A-Za-z0-9_"'"'"'])psql([^A-Za-z0-9_]|$)'

printf '%s' "$COMMAND" | grep -qE "$PSQL_INVOKE_RE" && PSQL_SIGNAL=1 || PSQL_SIGNAL=0
printf '%s' "$COMMAND" | grep -qiE "$MUTATION_RE|$OPAQUE_SQL_RE" && SQL_RISK_SIGNAL=1 || SQL_RISK_SIGNAL=0
printf '%s' "$COMMAND" | grep -qiE "$CURL_MUTATION_RE" && CURL_MUTATION_SIGNAL=1 || CURL_MUTATION_SIGNAL=0

# Опасный сигнал = psql реально вызывается (не просто упомянут внутри
# чужого поискового паттерна) И (видимая мутация ИЛИ непрозрачный источник
# SQL) - ИЛИ мутирующий вызов Neon Management API (curl, не требует psql).
if { [ "$PSQL_SIGNAL" = "0" ] || [ "$SQL_RISK_SIGNAL" = "0" ]; } && [ "$CURL_MUTATION_SIGNAL" = "0" ]; then
  exit 0
fi

LOCK_JSON=$(IWE_AGENT_ID="$AGENT_ID" python3 "$GATEWAY_LOCK" check "$LOCK_KEY" 2>/dev/null)
CHECK_RC=$?

case "$CHECK_RC" in
  0)
    HOLDER=$(printf '%s' "$LOCK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("holder",""))' 2>/dev/null)
    if [ "$HOLDER" = "$AGENT_ID" ]; then
      exit 0
    fi
    security_failure "боевая Neon-ветка сейчас под правкой другой сессии ($HOLDER). Дождись освобождения или согласуй с пилотом. Проверка: python3 $GATEWAY_LOCK check '$LOCK_KEY'"
    ;;
  3)
    security_failure "команда обращается напрямую к боевой Neon-ветке (мутация) без аренды замка. Возьми аренду и повтори: mcp acquire_file_lock (file='$LOCK_KEY') или IWE_AGENT_ID=$AGENT_ID python3 $GATEWAY_LOCK acquire '$LOCK_KEY' 900, после выполнения - release. Дополнительно: сохрани саму мутацию файлом миграции и закоммить, даже если применяешь вручную."
    ;;
  *)
    security_failure "шлюз замков недоступен, а команда обращается к боевой Neon-ветке с мутацией (fail-closed). Подними Local Gateway и повтори."
    ;;
esac
