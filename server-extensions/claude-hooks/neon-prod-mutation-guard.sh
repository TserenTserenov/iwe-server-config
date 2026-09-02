#!/usr/bin/env bash
# neon-prod-mutation-guard.sh — PreToolUse-хук (Bash): прямое обращение к боевой
# Neon-ветке требует активной аренды замка Local Gateway (WP-544, найдено 02.09 -
# дрейф search_path на проде без единого следа в git/сессиях, источник не
# установлен).
#
# ВАЖНО, по итогу четырёх раундов ревью Кодекс+Kimi (02.09): это эвристическая
# страховка одного рантайма (Claude Code) против ЧЕСТНОЙ ошибки, не защитная
# граница против определённого обхода. Регекс на свободном тексте bash-команды
# принципиально не может быть полным - каждый раунд ревью находил новые
# конкретные формы обхода, и это будет продолжаться. Дальше по этому пути
# закон убывающей отдачи; настоящий технический барьер - отдельная задача
# (единый запускатель продовых миграций, предложение Кодекса, см. WP-544).
# Значение этого хука - поднять цену случайной ошибки, не исключить намеренный
# обход.
#
# Граница прямого литерального вызова включает обычные shell-обёртки и
# переменные с говорящим именем (`$PSQL`, `$CURL_BIN`). Она принципиально не
# включает команду, содержимое которой отсутствует во входе хука:
# `eval "$CMD"`, заранее заданный `$METHOD`/`$ARGS`, `source script.sh`,
# `make migrate`, `npm run ...` и иной task runner/сторонний скрипт. Inline
# присваивание опасного флага видно и блокируется. Блокировать все остальные
# переменные/команды без анализа внешнего состояния означало бы остановить
# несвязанные действия; этот класс закрывает только будущий обязательный
# запускатель с изоляцией credentials.
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
# Раунд 4 (Кодекс, затем минимальное ревью Kimi): (16) SELECT-вызов
#   доменной функции удаления, pipe в psql и `-f"$FILE"` обходили SQL-сигнал;
#   (17) `curl -XDELETE` и compact quoted data-флаги обходили API-сигнал;
#   (18) регистронезависимый матч curl-флагов принимал read-only `-fsS` за
#   мутирующий `-F`; (19) `$NEON_URL` и фактически используемые алиасы
#   подключения не считались прод-маркерами; (20) текст с примером curl мог
#   ложно блокироваться без реального вызова curl; (21) естественные обёртки
#   `bash -c`/`ssh` с psql/curl внутри кавычек обходили сигнал; (22) кавычки и
#   переносы строк обходили HTTP-метод, функцию удаления и составной SQL-глагол;
#   (23) `curl -G --data*` ложно считался POST; (24) `${SQL}` не считалась
#   непрозрачным аргументом `--command`; (25) говорящие переменные `$PSQL*` /
#   `$CURL*` не считались прямым вызовом; (26) HEAD с data-флагом ложно
#   считался POST; (27) quoted/numeric curl-флаги и inline-переменные флагов
#   обходили сигнал; (28) динамическая программа после env-prefix/command/env/
#   subshell не считалась командой; (29) psql/curl внутри process substitution
#   ошибочно принимались за простой вывод cat/echo; (30) массивы/переменные
#   curl-аргументов и shell-keyword/path wrappers оставляли новые обходы.
# Холодный post-peer аудит: (31) реальный вызов после newline/одиночного `&`
#   ошибочно принимался за текст echo/printf; (32) допустимый curl-кластер
#   `-#XDELETE`, а также quote/backslash-splitting токена/маркера обходили scan.
# Повторный cold-review: (33) curl `--expand-{request,data,json,form,
#   upload-file,config}` не считался риском; (34) слишком широкий short-cluster
#   ложно принимал аргумент `-o/dev/null` за `-d`; (35) удаление кавычек делало
#   литеральные `;`, `&` и newline внутри echo мнимыми shell-операторами.
# Короткий recheck: (36) штатный no-arg `-B` отсутствовал в prefix allowlist;
#   (37) literal quoted heredoc у `cat` ложно считался второй командой.
#
# Семантика (exit 2 = блок для Claude Code):
#   вход невалиден (не JSON/не тот event/нет валидного command) → БЛОК (fail-closed)
#   команда не похожа на прямое обращение к прод-ветке                    → пропустить молча
#   обычный curl без method/body/upload/config (доказуемый GET/HEAD)       → пропустить молча
#   любой прямой/динамический psql или неоднозначный curl                  → требовать аренду
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
if len(session_id) > 128 or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-" for c in session_id):
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

# Shell-команда может законно занимать несколько строк. Для эвристического
# scan удаляем line continuation, но сохраняем настоящий newline как shell-
# границу `;`. Quote/backslash removal собирает формы, которые сам shell
# превращает в `p"sq"l`, `--re\quest` и split production-id. Это намеренно
# консервативная нормализация: хук снижает риск честной ошибки, не парсит Bash.
COMMAND_SCAN=$(printf '%s' "$COMMAND" | python3 -c '
import sys
s = sys.stdin.read().replace("\\\r\n", "").replace("\\\n", "")
if "\r" in s or "\n" in s:
    s = s.replace("\r\n", " ; ").replace("\r", " ; ").replace("\n", " ; ")
sys.stdout.write(s.replace("\\", "").replace(chr(34), "").replace(chr(39), ""))
') || security_failure "не удалось нормализовать shell-команду"

# Для display-only исключения недостаточно удалять кавычки: `echo "x; psql"`
# содержит литеральный `;`, а `echo x; psql` — реальную вторую команду. Этот
# малый scanner различает control-операторы вне literal quotes и выполняемые
# substitutions внутри double quotes. Это не полный Bash parser, но его
# наблюдаемый контракт уже, чем прежняя regex-эвристика, и покрыт тестами.
COMMAND_HAS_CONTROL=$(printf '%s' "$COMMAND" | python3 -c '
import sys

s = sys.stdin.read().replace("\\\r\n", "").replace("\\\n", "")
state = "plain"
i = 0
found = False
while i < len(s):
    ch = s[i]
    nxt = s[i + 1] if i + 1 < len(s) else ""
    if state == "single":
        if ch == chr(39):
            state = "plain"
        i += 1
        continue
    if state == "double":
        if ch == "\\":
            i += 2
            continue
        if ch == chr(34):
            state = "plain"
            i += 1
            continue
        if ch == "`" or (ch == "$" and nxt == "("):
            found = True
            break
        i += 1
        continue
    if ch == "\\":
        i += 2
        continue
    if ch == chr(39):
        state = "single"
    elif ch == chr(34):
        state = "double"
    elif ch in "\r\n;&|`" or (ch in "<>$" and nxt == "("):
        found = True
        break
    i += 1
print("1" if found else "0")
') || security_failure "не удалось разобрать структуру shell-команды"

# Узкое исключение для literal heredoc у команды показа: тело `cat <<'TXT'`
# не исполняется shell-ом. Потребитель ограничен display-командами, delimiter
# обязан быть quoted, после terminator допустимы только пустые строки. Поэтому
# `bash <<'TXT'`, `cat <<'TXT' | bash` и команда после TXT не получают bypass.
DISPLAY_LITERAL_HEREDOC=$(printf '%s' "$COMMAND" | python3 -c '
import re, sys

s = sys.stdin.read().replace("\\\r\n", "").replace("\\\n", "")
lines = s.splitlines()
if not lines:
    print("0")
    raise SystemExit
m = re.fullmatch(
    r"\s*(?:cat|sed|head|tail|less)\b[^;|&]*?<<(-?)\s*(?:\x27([^\x27]+)\x27|\x22([^\x22]+)\x22|\\([^\s]+))\s*",
    lines[0],
)
if not m:
    print("0")
    raise SystemExit
strip_tabs = bool(m.group(1))
delimiter = next(value for value in m.groups()[1:] if value is not None)
end = None
for index, line in enumerate(lines[1:], 1):
    candidate = line.lstrip("\t") if strip_tabs else line
    if candidate == delimiter:
        end = index
        break
safe_tail = end is not None and all(not line.strip() for line in lines[end + 1:])
print("1" if safe_tail else "0")
') || security_failure "не удалось проверить literal heredoc"

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
MARKER_VARNAME_RE='[A-Z][A-Z0-9_]*(PERSONA|JOURNAL|PAYMENT|SUBSCRIPTION|INDICATORS|LEARNING|KNOWLEDGE|REFERENCE|PUBLICATION|COMMUNITY|LEAD|REWARDS|SECRETS|METABASE|HEALTH)[A-Z0-9_]*|NEON[A-Z0-9_]*(URL|DSN|DIRECT)|PRIVACY_DELETION_URL|AIST_BOT_DIRECT|AISYSTANT_PG_URL|DATABASE_URL|DIRECT_URL|POOLED_URL|TARGET_URL'
MARKER_ID_RE='br-lingering-cake-aggtcdft|ep-dark-hall-ag8bo8lf'

printf '%s' "$COMMAND_SCAN" | grep -qE "$MARKER_VARNAME_RE" || \
  printf '%s' "$COMMAND_SCAN" | grep -qiE "$MARKER_ID_RE" || exit 0

# Для psql нет надёжного локального способа доказать read-only: SELECT может
# вызвать VOLATILE-функцию, SQL может прийти из файла/stdin/переменной, а
# штатные флаги кластеризуются. Поэтому любой прямой psql к prod-маркеру
# требует аренду. У curl остаётся узкий доказуемый по видимому входу read: нет
# явного method, body/form/upload и config-файла. Любой такой флаг считается
# неоднозначным и требует аренду, даже если рядом указан -G/--get.
# Только short options без аргумента могут предшествовать риск-флагу в одном
# кластере. Например, `-#XDELETE` — `-#` + `-X`, но `-o/dev/null` целиком
# является `-o` с аргументом и не содержит `-d`.
CURL_SHORT_NOARG_PREFIX='[aBqfGgI0ik46jlLMnN:Z#pJORSs231vV]*'
CURL_SHORT_RISK_RE="(^|[[:space:]])-${CURL_SHORT_NOARG_PREFIX}[XdFTK]"
CURL_LONG_RISK_RE='(^|[[:space:]])(--request|--data|--data-ascii|--data-raw|--data-binary|--data-urlencode|--json|--form|--form-string|--upload-file|--config|--expand-request|--expand-data|--expand-data-ascii|--expand-data-raw|--expand-data-binary|--expand-data-urlencode|--expand-json|--expand-form|--expand-form-string|--expand-upload-file|--expand-config)([[:space:]=]|$)'
CURL_ASSIGNMENT_RISK_RE="(^|[[:space:];])[A-Za-z_][A-Za-z0-9_]*=(-${CURL_SHORT_NOARG_PREFIX}[XdFTK]|--(request|data|data-ascii|data-raw|data-binary|data-urlencode|json|form|form-string|upload-file|config|expand-request|expand-data|expand-data-ascii|expand-data-raw|expand-data-binary|expand-data-urlencode|expand-json|expand-form|expand-form-string|expand-upload-file|expand-config)([=[:space:]]|$))"
# При буквальном curl любая shell-подстановка в аргументах неоднозначна: она
# может раскрыться в method/body/config-флаг. Это намеренно блокирует и часть
# динамических read-only запросов; полностью литеральный `curl -fsS URL`
# остаётся разрешённым.
# shellcheck disable=SC2016
CURL_EXPANSION_RE='[$]|`'

# Буквальный токен psql/curl считается вызовом и внутри естественной обёртки
# (`bash -c '...'`, ssh, docker exec). Исключение — чистые команды показа/поиска
# без исполняемого shell-control вне literal quotes: это оставляет безопасными
# `rg 'psql ...' docs`, но блокирует `rg ... && psql ...` и `printf ... | psql`.
DISPLAY_ONLY_RE='^[[:space:]]*(grep|rg|ack|ag|printf|echo|cat|sed|head|tail|less)([[:space:]]|$)'
PSQL_TOKEN_RE='(^|[^A-Za-z0-9_])(psql([^A-Za-z0-9_]|$)|[$][{]?[A-Za-z0-9_]*[Pp][Ss][Qq][Ll][A-Za-z0-9_]*[}]?)'
CURL_TOKEN_RE='(^|[^A-Za-z0-9_])(curl([^A-Za-z0-9_]|$)|[$][{]?[A-Za-z0-9_]*[Cc][Uu][Rr][Ll][A-Za-z0-9_]*[}]?)'
DYNAMIC_BOUNDARY_RE='(^|&&|&|\|\||;|\||[(]|[)]|[!]|[{])[[:space:]]*"?[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?'
DYNAMIC_ASSIGNMENT_RE='(^|&&|&|\|\||;|\||[(]|[)]|[!]|[{])[^;&|]*=[^;&|]*[[:space:]]+"?[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?'
DYNAMIC_WRAPPER_RE='(^|[[:space:]])([^[:space:]]*/)?(command|env|exec|nohup|timeout|nice|sudo|xargs|parallel|time|if|elif|while|until|then|do|coproc|watch|setsid|chroot|stdbuf)[[:space:]]+([^[:space:]]+[[:space:]]+)*"?[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?'

command_token_is_invoked() {
  local token_re="$1"
  printf '%s' "$COMMAND_SCAN" | grep -qE "$token_re" || return 1
  if printf '%s' "$COMMAND_SCAN" | grep -qE "$DISPLAY_ONLY_RE" && \
     { [ "$COMMAND_HAS_CONTROL" = "0" ] || [ "$DISPLAY_LITERAL_HEREDOC" = "1" ]; }; then
    return 1
  fi
  return 0
}

command_token_is_invoked "$PSQL_TOKEN_RE" && PSQL_SIGNAL=1 || PSQL_SIGNAL=0
command_token_is_invoked "$CURL_TOKEN_RE" && CURL_SIGNAL=1 || CURL_SIGNAL=0
printf '%s' "$COMMAND_SCAN" | grep -qE "$CURL_SHORT_RISK_RE|$CURL_LONG_RISK_RE|$CURL_ASSIGNMENT_RISK_RE" && CURL_RISK_SIGNAL=1 || CURL_RISK_SIGNAL=0
if [ "$CURL_SIGNAL" = "1" ] && printf '%s' "$COMMAND_SCAN" | grep -qE "$CURL_EXPANSION_RE"; then
  CURL_RISK_SIGNAL=1
fi
printf '%s' "$COMMAND_SCAN" | grep -qE "$DYNAMIC_BOUNDARY_RE|$DYNAMIC_ASSIGNMENT_RE|$DYNAMIC_WRAPPER_RE" && DYNAMIC_COMMAND_SIGNAL=1 || DYNAMIC_COMMAND_SIGNAL=0

# Опасный сигнал = любой прямой psql, динамическая команда у prod-маркера
# или curl с method/body/upload/config. Обычный curl GET без этих флагов
# остаётся разрешённым без аренды.
if [ "$PSQL_SIGNAL" = "0" ] && [ "$DYNAMIC_COMMAND_SIGNAL" = "0" ] && \
   { [ "$CURL_SIGNAL" = "0" ] || [ "$CURL_RISK_SIGNAL" = "0" ]; }; then
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
    security_failure "команда обращается напрямую или неоднозначно к боевой Neon-ветке без аренды замка. Возьми аренду и повтори: mcp acquire_file_lock (file='$LOCK_KEY') или IWE_AGENT_ID=$AGENT_ID python3 $GATEWAY_LOCK acquire '$LOCK_KEY' 900, после выполнения - release. Если это мутация, сохрани её файлом миграции и закоммить, даже если применяешь вручную."
    ;;
  *)
    security_failure "шлюз замков недоступен, а команда обращается напрямую или неоднозначно к боевой Neon-ветке (fail-closed). Подними Local Gateway и повтори."
    ;;
esac
