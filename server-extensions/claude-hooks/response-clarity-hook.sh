#!/usr/bin/env bash
# response-clarity-hook.sh — детектор нарушений разговорного стиля (WP-388 Ф5/Ф9)
#
# Тип: Stop hook (проверяет ответы агента в ЗАВЕРШЁННОМ ходу)
# Уровень: warning (nudge), не блокирует — всегда exit 0
# Лог: ~/.claude/logs/style-violations.log
# Формат строки (контракт WP-388): TIMESTAMP | agent | A-rule | description | context(redacted)
#
# Детерминированные правила (консенсус peer-session 2026-06-04-56):
#   A1   путь к файлу как подлежащее предложения
#   A8   журнал процесса в начале ответа (Reading…, Проверяю…)
#   A10  голые английские маркеры статуса (exit 0, PASS, SHA, status: done)
#   BASE5 длинное тире вне конструкции «— это» (базовое правило стиля #5)
#
# A11 (пассивный залог) — НЕ ловится: высокий риск ложных срабатываний,
# отложен до ручной калибровки на данных недели обкатки (см. WP-388 Ф6).
#
# Поведенческая ось (WP-5 фаза 2026-06-10) — B-нумерация ОТДЕЛЬНА от A-стиля,
# чтобы не смешивать «как сказал» (стиль) и «что сделал до того» (поведение):
#   B1   агент просит пилота «сделать вручную / дать доступ» ДО проверки
#        доступных инструментов (MCP/Bash). Счётчик рецидивов постфактум:
#        НЕ блокирует и НЕ лечит — лечение идёт через профиль косяков
#        (memory/feedback_check_tools_before_asking.md, инжекция в Day Open).
#        Ложные срабатывания при цитировании фраз-маркеров возможны и приемлемы
#        (это счётчик, не gate). FMT-промоция — после недели обкатки.
#
# Вход: Stop-хук Claude Code передаёт JSON со stdin, поле transcript_path
# указывает на JSONL-стенограмму. assistant_response в Stop НЕ передаётся —
# поэтому извлекаем текст ассистента текущего хода из стенограммы.

set -euo pipefail

# AGENT identifies the caller for the shared log (WP-388 Ф17): claude-code
# when invoked by this hook directly, overridable for the other agents that
# route through style-check-text.sh (same core, no parallel reimplementation).
AGENT="${STYLE_AGENT:-claude-code}"
# Consumer mode (WP-388 Ф24): "peer" = the reply is read by a program (peer-session
# adapter), not by the pilot, so the "pilot has already seen it" rewrite request is
# false there and only produces a lost or fully repeated answer (Kimi, 2026-10-23,
# overlap 0.91). Peer mode never blocks; the log column carries "-peer" so precision
# is calibrated per mode. Declared by the caller (IWE_STYLE_CONTEXT, set in
# peer-adapter-common.sh), never guessed here.
STYLE_CONTEXT="${STYLE_CONTEXT:-${IWE_STYLE_CONTEXT:-direct}}"
export STYLE_CONTEXT
[ "$STYLE_CONTEXT" = "peer" ] && AGENT="${AGENT}-peer"
INPUT=$(cat)
if [ -z "$INPUT" ]; then exit 0; fi

# --- A12_CROSS_TURN_REPEAT (РП-605 Ф6, 29.10.2026): повтор между ходами после служебной записи ---
# Два соседних ответа без сообщения пилота между ними: возврат из фоновой работы или
# переписанный ответ после блокировки этого же хука (обратная связь стража — служебная
# запись). Стоит ДО защиты от рекурсии нарочно: переписанный после блокировки ответ идёт
# с stop_hook_active=true, и ниже хук выходит раньше всех детекторов — повтор, о котором
# пилот и сообщил, иначе был бы невидим. Диагностика, warn-only: в BLOCKABLE не входит,
# счётчик нарушений не наращивает, сбой детектора не ломает ход. Живёт в уже
# зарегистрированной команде, а файл на диске читается при каждом вызове — так сигнал
# доходит и до давно идущих (--resume) разговоров.
CROSS_TURN_TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -n "$CROSS_TURN_TRANSCRIPT" ] && [ -f "$CROSS_TURN_TRANSCRIPT" ]; then
  CROSS_TURN_MATCH=$(python3 "$(dirname "${BASH_SOURCE[0]}")/a12-cross-turn-repeat.py" "$CROSS_TURN_TRANSCRIPT" 2>/dev/null || true)
  if [ -n "$CROSS_TURN_MATCH" ]; then
    CROSS_TURN_LOG="${HOME}/.claude/logs/style-violations.log"
    mkdir -p "$(dirname "$CROSS_TURN_LOG")" 2>/dev/null || true
    echo "$(date +"%Y-%m-%d %H:%M:%S") | $AGENT | A12_CROSS_TURN_REPEAT | repeat-after-service-record | $CROSS_TURN_MATCH" >> "$CROSS_TURN_LOG" 2>/dev/null || true
  fi
fi

# Guard от рекурсии: если хук уже активен — выходим
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then exit 0; fi

# session_id для счётчика нарушений за сессию (peer-session 2026-06-08-23)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-'); [ -n "$SESSION_ID" ] || SESSION_ID="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
COUNT_DIR="$PROJECT_DIR/.claude/state"
COUNT_FILE="$COUNT_DIR/style-violations-count-$SESSION_ID"

# --- Текст ассистента ТЕКУЩЕГО хода ---
# Один ход = несколько JSONL-записей (text / tool_use / text). Берём все
# assistant text-блоки после последнего user-сообщения, склеиваем. Разбор —
# одним проходом на Python (надёжнее поэлементного shell + jq под set -e).
RESPONSE=$(TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 <<'PY' 2>/dev/null || echo ""
import json, os
path = os.environ["TRANSCRIPT_PATH"]
rows = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue

def role_of(r):
    return r.get("type") or r.get("role") or ""

# индекс последнего user-сообщения; всё после — текущий ход
last_user = -1
for i, r in enumerate(rows):
    if role_of(r) == "user":
        last_user = i

out = []
for r in rows[last_user + 1:]:
    if role_of(r) != "assistant":
        continue
    content = r.get("message", {}).get("content", r.get("content", []))
    if isinstance(content, str):
        out.append(content)
    elif isinstance(content, list):
        for blk in content:
            if isinstance(blk, dict) and blk.get("type") == "text":
                out.append(blk.get("text", ""))
print("\n".join(out))
PY
)

if [ -z "$RESPONSE" ]; then exit 0; fi

LOG_FILE="${HOME}/.claude/logs/style-violations.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
VIOLATIONS=""

# Знаменатель для частотной статистики (peer-session
# 2026-10-16-14-wp412-base5-mechanism, консенсус Kimi+Codex): лог нарушений
# сам по себе не говорит, стало ли меньше нарушений или просто меньше
# проверенных ходов. Одна строка на каждый реально проверенный ход
# (RESPONSE непустой, мы уже прошли ранний exit выше), отдельно от строк
# нарушений — не смешиваем формат.
# Обе записи ниже защищены `|| true` (code review этой же сессии, High):
# под `set -euo pipefail` неудачный mkdir/echo (диск полон, нет прав,
# read-only home) иначе прервал бы ВЕСЬ хук до проверки правил — нарушая
# жёсткий инвариант «хук всегда exit 0».
CHECKS_LOG="${HOME}/.claude/logs/style-checks-total.log"
mkdir -p "$(dirname "$CHECKS_LOG")" 2>/dev/null || true
echo "$TIMESTAMP | $AGENT" >> "$CHECKS_LOG" 2>/dev/null || true

# redact: обрезать до 100 символов, замаскировать токены (в т.ч. короткие
# провайдерские), заменить разделитель | чтобы не ломать парсер агрегатора
redact() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-100 \
    | sed -E 's/(gh[pousr]_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]+/<REDACTED>/g; s/[A-Za-z0-9_-]{32,}/<REDACTED>/g; s/[a-f0-9]{16,}/<REDACTED>/g; s/\|/¦/g'
}

log_violation() {
  local rule="$1" desc="$2" example="$3"
  VIOLATIONS="${VIOLATIONS}${rule} "
  echo "$TIMESTAMP | $AGENT | $rule | $desc | $(redact "$example")" >> "$LOG_FILE" 2>/dev/null || true
}

# --- A1: путь к файлу как подлежащее ---
# Осознанный узкий предел (РП-388 Ф15, 20.10, round-loop Kimi+Codex): правило
# ловит только одну синтаксическую форму (путь — первое слово строки перед
# глаголом), не весь класс «техническая плотность в прозе» — именно поэтому
# утечка 19.10 (путь как дополнение предлога «в», не подлежащее) не поймалась.
# Расширение через предлоги (в/на/из/к + путь/файл/скрипт + глагол) рассмотрено
# и отклонено: Kimi оценила, что обычная техническая фраза почти всегда так
# устроена («файл лежит в `...`», «пишем лог в `...`») — расширение дало бы
# запретительно высокий false-positive rate. Класс проблемы (объём/плотность
# технического текста целиком) закрывает A13 ниже, не это правило.
A1_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '^\s*`?[A-Za-z0-9_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?`?\s+(—|is|was|has|содержит|отвечает|обрабатывает|делает|создаёт|хранит|возвращает|пишет|читает)' | head -1 || true)
[ -n "$A1_MATCH" ] && log_violation "A1" "path-as-subject" "$A1_MATCH"

# --- A10: голые английские маркеры статуса ---
# exit 0 / SHA: / status: done — детерминированы. PASS/FAIL ловим только в
# тест-контексте (рядом тест/smoke/проверка/G-гейт) — иначе ложный позитив
# на обычное слово («полный FAIL»).
A10_MATCH=$(printf '%s\n' "$RESPONSE" | grep -E '(\bexit\s+0\b|SHA:\s*[a-f0-9]{7,}|status:\s*(done|success)|\bG[0-9]\s+(PASS|FAIL)\b|(smoke|тест[а-я]*|проверк[а-я]*)\s*:\s*(PASS|FAIL)\b|`(PASS|FAIL)`)' | head -1 || true)
# Вариант без пробела вида `close_exit=0` (РП-388 калибровка, 19.10, найден
# в реальном golden-set) — требует perl: `grep -E` не поддерживает lookahead,
# а он обязателен, чтобы не ловить `close_exit=0.5`/`exit:0.7` (Codex,
# peer-session 2026-10-19-11, второй найденный баг этой же фазы — первая
# версия с `\b` после `0` матчила дробную часть, т.к. `\b` стоит на границе
# цифра/точка независимо от того, что после точки). `some_exit0` (без
# разделителя `=`/`:`) и `_exit0.5` (тоже без разделителя) не матчатся —
# проверено отдельно от lookahead-случая.
if [ -z "$A10_MATCH" ]; then
  A10_MATCH=$(printf '%s\n' "$RESPONSE" | perl -ne 'print if /exit[=:]0(?!\.?[0-9])/' | head -1 || true)
fi
# Жирные вердикт-слова из словаря инструментов code-review (PASS/FAIL уже
# ловились только в тест-контексте выше; PLAUSIBLE/CONFIRMED — из схемы
# ReportFindings, новый источник того же класса маркера, найден на живом
# примере 20.10 с Mac: «**FAIL** (форматирование):», «**PLAUSIBLE** (...):»
# — оба жирным, без backtick и без слова «тест» рядом, старый паттерн их не
# видел). Codex (round 4) предложил требовать и закрывающий `**` сразу после
# слова — отклонено: проверка на реальном примере показала, что в живом
# тексте жирным помечена вся фраза («**FAIL (форматирование):**», закрывающий
# `**` после запятой/двоеточия, не сразу после слова) — с его паттерном фикстура
# стала бы ложным пропуском. Текущий `\b` после слова достаточен: не матчит
# слитные формы («FAILED», «CONFIRMEDLY»), остаточный риск на дефисных
# сращениях («FAIL-safe») — редкий случай, не наблюдался, не хеджируем заранее.
if [ -z "$A10_MATCH" ]; then
  A10_MATCH=$(printf '%s\n' "$RESPONSE" | grep -oE '\*\*(PASS|FAIL|PLAUSIBLE|CONFIRMED)\b' | head -1 || true)
fi
# Голое PASS/FAIL отдельным словом в прозе («всё PASS», «статус FAIL») — Ф18,
# живой отчёт пилота 22.10: прежние шаблоны требовали «тест:»/«smoke:» рядом.
# Код, backtick и цитаты («…»/"…") вырезаны; слово как предмет разговора
# («слово PASS», «термин FAIL») и дефисные сращения (FAIL-safe) не нарушение.
if [ -z "$A10_MATCH" ]; then
  A10_MATCH=$(printf '%s\n' "$RESPONSE" \
    | perl -CSD -Mutf8 -0777 -pe 's/```.*?```//gs; s/`[^`\n]*`//g; s/«[^»\n]*»//g; s/"[^"\n]*"//g' \
    | perl -CSD -Mutf8 -ne 's/(слов|термин|метк|маркер|надпис)[а-яё]*\s+\W?(PASS|FAIL)//gi; s/(PASS|FAIL)\W{0,3}(это\s+)?(слов|термин|метк|маркер|надпис)[а-яё]*//gi; if (/(?<![\p{L}\p{N}_-])(PASS|FAIL)(?![\p{L}\p{N}_-])/) { print "$1\n"; last }' \
    | head -1 || true)
fi
[ -n "$A10_MATCH" ] && log_violation "A10" "bare-english-marker" "$A10_MATCH"

# --- A2 (новое правило, РП-388 калибровка 19.10, WARN-ONLY — в BLOCKABLE не
# входит): непереведённый английский/программистский идентификатор. ---
# golden-set на 25 реальных ответах нашёл 3 случая непереведённого термина
# (`origin/main` дважды, `verification_class`) без единой сигнатуры в коде —
# правило из feedback_response_clarity_for_pilot.md (A2) было только в
# памяти, не в коде. Narrow-first: ловим только snake_case-идентификаторы
# (две+ части через `_`) ВНЕ backtick-кода — внутри backtick термин уже
# оформлен по конвенции (код/термин в скобках после русского описания —
# допустимо). `origin/main` (слеш, не подчёркивание) этим правилом НЕ
# покрыт — отдельный паттерн под git-ref не писал без доказанной
# необходимости (P13), это открытый хвост, не этот коммит. Зафиксирован как
# known_gap-фикстура `A2-OPEN-TAIL-01` в tests/fixtures (РП-388 Ф15, 20.10),
# чтобы хвост не потерялся молча между сессиями.
# `verification_class` из golden-set (sample 21) в реальном тексте был в
# backtick — правило его не ловит. Это подтверждает только исключение по
# backtick, не доказывает наличие русского пояснения рядом (Codex,
# peer-session 2026-10-19-11): backtick-термин как грамматическое
# подлежащее («`X` несёт...») без перевода — отдельный, не этот класс
# нарушения, никем не покрыт.
# Список исключений — пока пустой. Пополнять по будущим ложным
# срабатываниям, не выдумывать заранее — риск ложных позитивов на старте
# выше, чем у детерминированных правил, поэтому правило не blockable.
# `sed -E 's/`[^`]*`//g'` обрезает backtick-пары только В ПРЕДЕЛАХ ОДНОЙ
# СТРОКИ (sed обрабатывает вход построчно) — backtick-спан, открытый на одной
# строке ответа и закрытый на другой, не вырезался бы вообще, и snake_case
# внутри него ложно засчитывался как A2-нарушение (найдено Codex, round-loop
# 20.10). `perl -0777` читает весь `$RESPONSE` одной строкой (slurp), поэтому
# `[^`]*` в паттерне видит и вырезает спан независимо от переводов строк внутри.
A2_BODY=$(printf '%s' "$RESPONSE" | perl -0777 -pe 's/`[^`]*`//g')
A2_MATCH=$(printf '%s\n' "$A2_BODY" | grep -oE '\b[a-z][a-z0-9]*_[a-z0-9_]+\b' | head -1 || true)
[ -n "$A2_MATCH" ] && echo "$TIMESTAMP | $AGENT | A2 | untranslated-term | $(redact "$A2_MATCH")" >> "$LOG_FILE" 2>/dev/null || true

# A2 второй признак: CamelCase/PascalCase составное слово вне backtick-кода
# (пилот, живой пример 20.10: «CommonMark», «FileNotFoundError» в чате с Клодом
# на Mac — snake_case-паттерн выше их не ловит, это другая форма того же
# нарушения). Список исключений — ТОЛЬКО три имени, явно названных допустимыми
# в базовом своде стиля (feedback_response_clarity_for_pilot.md): NixOS,
# PostgreSQL, Aisystant. Не расширять списком на глаз (GitHub/GitLab/iPhone и
# т.п.) без реального ложного срабатывания — тот же принцип узкого старта,
# что уже применён к snake_case-ветке выше (P13: не хеджировать воображаемым
# риском).
# Расширено 22.10 (РП-388 Ф16 п.3, живой журнал за 2 дня после доставки): из 25
# срабатываний 21 — имена собственные (OpenRouter 10, GitHub 7, OpenAI, macOS,
# LiteLLM, логин пилота), а база стиля имена собственные явно разрешает.
# Добавлены ровно встреченные имена; жаргон (OwnerIntegrity, SoT) по-прежнему ловится.
# `\b` в grep -E/ugrep ненадёжен на границе с кириллицей без пробела (тот же
# класс бага, что уже чинили сегодня в hex-детекторе A7.1) — проверено живьём:
# `тутCommonMark` (кириллица впритык, без пробела) не матчился вообще.
# perl-lookaround на классах [[:alnum:]_] границу видит независимо от того,
# какой алфавит стоит по другую сторону.
# Расширено 22.10 (РП-605/РП-388 сверка Ф16, тот же день, несколько часов
# позже): «ChatGPT» дало 4 срабатывания уже ПОСЛЕ прошлой правки этого же дня —
# тот же класс (имя собственное), тот же принцип узкого старта (только
# встреченное имя, не упреждающий список брендов).
A2_CAMEL_EXCEPT='NixOS|PostgreSQL|Aisystant|OpenRouter|GitHub|OpenAI|macOS|LiteLLM|TserenTserenov|ChatGPT'
A2_CAMEL_MATCH=$(printf '%s\n' "$A2_BODY" | perl -ne 'while (/(?<![[:alnum:]_])([A-Za-z]*[a-z][A-Z][A-Za-z]*)(?![[:alnum:]_])/g){print "$1\n"}' | grep -vE "^(${A2_CAMEL_EXCEPT})\$" | head -1 || true)
[ -n "$A2_CAMEL_MATCH" ] && echo "$TIMESTAMP | $AGENT | A2 | untranslated-term-camelcase | $(redact "$A2_CAMEL_MATCH")" >> "$LOG_FILE" 2>/dev/null || true

# --- A8: журнал процесса в начале строки ответа ---
# Проверяем начало КАЖДОЙ строки склейки: один ход = несколько text-блоков,
# каждый начинается с новой строки; промежуточное «Проверяю…» перед tool-call
# попадёт в начало своей строки (кейс, важный по консенсусу с Kimi).
A8_MATCH=$(printf '%s\n' "$RESPONSE" | grep -iE '^(Reading|Checking|Looking|Searching|Let me|Сейчас (посмотрю|проверю|прочитаю)|Читаю|Проверяю|Ищу|Смотрю)' | head -1 || true)
[ -n "$A8_MATCH" ] && log_violation "A8" "process-journal" "$A8_MATCH"

# --- BASE5: длинное тире вне конструкции «— это» ---
# Построчная проверка, не по всему тексту (найдено Codex, peer-session
# 2026-10-16-14-wp412-base5-mechanism): прежняя версия проверяла и грепала
# ВЕСЬ склеенный ответ одним regex'ом. Два следствия:
#   (1) `\s*` между тире и «это» матчится и через перевод строки — тире в
#       конце строки и «это» в начале СЛЕДУЮЩЕЙ ложно считались разрешённым
#       исключением;
#   (2) журнал брал первую строку с ЛЮБЫМ тире (`grep '—' | head -1`) — если
#       разрешённое «X — это Y» стояло раньше настоящего нарушения, в лог
#       попадал разрешённый пример, не нарушающий.
# Построчный разбор чинит оба бага одним заходом: `\s*` внутри одной строки
# не пересекает границу строк, и первая НАРУШАЮЩАЯ строка — это и есть то,
# что логируется.
# Граница слова после «это» (Codex): без неё «— этот»/«— этому» матчили
# исключение, хотя «это» там не самостоятельное слово. Negative lookahead на
# продолжение кириллицей после «это» закрывает это; `\*{0,2}` перед «это» —
# разрешённое выделение жирным/курсивом («X — **это** Y»), не нарушение.
BASE5_MATCH=$(printf '%s\n' "$RESPONSE" | perl -CSD -Mutf8 -ne '
  if (/—(?!\s*\*{0,2}это(?![а-яёА-ЯЁ]))/) { print; exit }
' 2>/dev/null || true)
[ -n "$BASE5_MATCH" ] && log_violation "BASE5" "em-dash-outside-eto" "$BASE5_MATCH"

# --- A14: part-whole wording applied to a non-system (base style rule 8) ---
# Three shapes, whole reply at once (-0777), text in «…» and `…` stripped first
# so quoted anti-examples do not fire:
#   (1) composition list — a header announcing parts ("состоит из …:", "в ней
#       есть:", "компонентов:") followed by list items whose head names a
#       non-system kind (memory, rules, prompt, card…). The live acceptance run
#       (РП-388 Ф21, 23.10) showed every real violation took this shape, which
#       the per-sentence check could not see across lines.
#   (2) per sentence: a part-whole marker with a non-system kind at most three
#       words away; negated markers ("не входит", "не часть") are removed
#       first — both false positives of that run were negations — and so are
#       system heads with a non-system complement ("сервер памяти"). Parts of a
#       description or document ("ответ делится на две части", "протокол
#       состоит из шагов") fire too: pilot decision 23.10, part-whole is for
#       systems only.
#   (3) "X — это Y" naming a description as a type of a non-description.
#   (4) a non-system called a system ("проект как систему", "процесс — это система",
#       "назвал проект системой"); pilot decision 24.10: project, process, method, life and
#       any activity are not systems (registry rule 6).
# Every stem has a left word boundary ($b): without it "работ" matched inside
# "Обработчик" and "план" inside "Планировщик".
# Warn-only: regex cannot settle ontology, the log feeds calibration.
# Concept lists come from the registry copy (lib/concept-kinds.tsv, generated from
# PACK-digital-platform concept-kinds-registry.yaml): systems vs non-systems. Collections
# never trigger A14. Ambiguous words never BLOCK (FPF C.3.2: "unknown" is not a verdict):
# a part-whole sentence with one is logged as A14_AMBIGUOUS, a warn-only signal that feeds
# registry calibration. No copy -> the built-in lists in the perl block below (fail-open).
A14_TSV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/concept-kinds.tsv"
A14_NONSYS=""; A14_SYS=""; A14_AMBIG=""
if [ -r "$A14_TSV" ]; then
  A14_NONSYS=$(awk -F'\t' '!/^#/ && NF==2 && $1!="system" && $1!="ambiguous" && $1!="collection" {print $2}' "$A14_TSV" | paste -sd'|' -)
  A14_SYS=$(awk -F'\t' '!/^#/ && NF==2 && $1=="system" {print $2}' "$A14_TSV" | paste -sd'|' -)
  A14_AMBIG=$(awk -F'\t' '!/^#/ && NF==2 && $1=="ambiguous" {print $2}' "$A14_TSV" | paste -sd'|' -)
fi
export A14_NONSYS A14_SYS A14_AMBIG
A14_MATCH=$(printf '%s\n' "$RESPONSE" | perl -0777 -CSD -Mutf8 -ne '
  s/«[^»]*»//g; s/`[^`]*`//g;
  my $b = qr/(?<![а-яёА-ЯЁ])/;
  # agent nouns built on a description stem are systems: Планировщик, Процессор
  my $notagent = qr/(?![а-яё]*(щик|чик|тель|тор|ор)(?![а-яё]))/i;
  my $nonsys_src = $ENV{A14_NONSYS} || "инструкци|промпт|метод|процесс|описани|документ|состояни|характеристик|управлени[ея]\\s+выполнени|контекст|памят|правил|ритуал|протокол|знани|карточк|запис|файл|репозитори|ответ|план|скилл";
  my $sys_src = $ENV{A14_SYS} || "модул|клиент|сервер|сервис|исполнител|хранилищ|баз[аеыу]";
  # %ENV holds raw bytes; decode so the Cyrillic stems match the decoded reply text
  utf8::decode($nonsys_src) if $ENV{A14_NONSYS};
  utf8::decode($sys_src) if $ENV{A14_SYS};
  my $amb_src = $ENV{A14_AMBIG} || ""; utf8::decode($amb_src);
  my $nonsys = qr/$b($nonsys_src)/i;
  my $syshead = qr/$b($sys_src)\S*/i;
  my $part = qr/$b(входи[тл]|входят|входить|состо[ия]т\s+из|в\s+состав(?![а-яё])|(является|являются|будет|быть)\s+частью|част(ью|ь|и)\s+(агента|системы|программы))/i;
  my $end = qr/[а-яё]{0,3}(?![а-яё])/i;
  my $nonsys_s = qr/$b($nonsys_src)$notagent$end/i;
  my $ambw = $amb_src ? qr/$b($amb_src)$notagent$end/i : undef;
  # a window of up to three words never crosses a comma or semicolon (clause boundary)
  my $win = qr/(?:\s+[^\s,;]+){0,3}?/;
  # first real hit wins and is printed at once; an ambiguous-head hit is only held back and
  # printed (prefixed AMBIG) by END when no real hit exists
  our ($REAL, $AMB) = (0, "");
  sub hit { $REAL = 1; print $_[0]; exit }
  my @lines = split /\n/;
  for my $i (0 .. $#lines) {
    my $h = $lines[$i];
    next unless $h =~ /:\s*\**\s*$/
      && $h =~ /$b(состо[ия]т\s+из|входят|компонент|элемент|сло[яёе]в?(?![а-яё])|состав(?![а-яё])|составн\S*\s+част|в\s+(ней|нём|него|неё)\s+(есть|работают|собран\S*)|соединены|к\s+(нему|ней)\s+добавлен)/i;
    next if $h =~ /(^|\s)не\s+(входи|входя|явля|состо)/i;
    # a header whose SUBJECT (first word) is a description/method ("Промпт ... несколько слоёв:")
    # introduces the content parts of that description (ConstituentOf), not system parts;
    # a non-system word elsewhere in the header ("... со своим состоянием ...") does not count
    next if $h =~ /^\W*$nonsys/;
    for my $j ($i + 1 .. $#lines) {
      my $it = $lines[$j];
      next if $it =~ /^\s*$/;
      last unless $it =~ /^\s*([-*]|\d+[.)]|\*\*\d+[.)])\s*/;
      my $head = $it =~ /\*\*([^*]+)\*\*/ ? $1 : ($it =~ /^\s*(?:[-*]|\d+[.)])\s*([^—:,(]+)/ ? $1 : "");
      # head noun is the first word: "Модуль памяти" is a system or an ambiguous head (decided
      # by the sentence, not by the word), "Правила пилота" is a plain non-system
      next if $head =~ /^\s*$syshead/;
      # cut an ambiguous head with its one complement word ("Модуль памяти"): what is left decides;
      # "Контекст и память" keeps "память" and still counts
      (my $rest = $head) =~ s/^\s*$ambw\s+\S+// if $ambw;
      $rest = $head unless defined $rest;
      if ($rest =~ $nonsys) { $h =~ s/\s+$//; hit("$h $it") }
    }
  }
  s/\*\*//g;
  for my $s (split /(?<=[.!?;:])\s+|\n+/) {
    (my $t = $s) =~ s/(^|\s)не\s+(входи\S*|входя\S*|состо\S*\s+из|явля\S*\s+частью|част\S*)(\s+в\s+состав\S*)?/$1/gi;
    my $t0 = $t;  # before heads are cut: the ambiguity warning must still see them
    $t =~ s/$syshead\s+\S+//g;
    # "модуль памяти": an ambiguous head with its complement is not a verdict, but the link verb
    # after it ("отчёт входит") must stay visible
    $t =~ s/$ambw\s+(?!$part)\S+//g if $ambw;
    if ($t =~ /$nonsys_s$win\s+$part/ || $t =~ /$part$win\s+$nonsys_s/) {
      hit($s)
    }
    if ($t =~ /$nonsys_s$win\s+(состо[ия]т\s+из|дел[ия]тся\s+на)\s+(\S+\s+)?(част|раздел|этап|шаг)/i) {
      hit($s)
    }
    if (!$AMB && $ambw
        && ($t0 =~ /$ambw$win\s+$part/ || $t0 =~ /$part$win\s+$ambw/
            || $t0 =~ /$ambw$win\s+(состо[ия]т\s+из|дел[ия]тся\s+на)\s+(\S+\s+)?(част|раздел|этап|шаг)/i)) {
      $AMB = $s
    }
    # (4) a non-system called a system ("проект как систему", "процесс — это система",
    # "назвал проект системой"): only the system kind is a system (pilot decision 24.10,
    # registry rule 6).
    # A negation anywhere in the sentence ("нельзя назвать", "не стоит называть",
    # "как система не рассматривается") says the opposite, so the check is skipped.
    my $n = $t;
    $n = "" if $n =~ /$b(нельзя|не\s+(стоит|надо|нужно|следует|можно|как|явля\S*|назыв\S*|назва\S*|счита\S*|рассматрива\S*))/i;
    if ($n =~ /$nonsys_s$win\s+(как\s+систем\S*|явля\S+\s+систем\S*|назва\S+\s+систем\S*|назыв\S+\s+систем\S*)/
        || $n =~ /$nonsys_s\s*[-—–]\s+это\s+систем/i
        || $n =~ /$b(назва\S*|назыв\S*|счита\S*|рассматрива\S*)\s+$nonsys_s$win\s+систем/i) {
      hit($s)
    }
    # "X - это Y" assigns a type; "state is a set of values" names a description, not a type
    if ($t =~ /$b(состояни|систем|агент|метод|работ)\S*\s+[-—–]\s+это\s+(набор|совокупност|множеств|комплекс|сочетани|список|профиль)/i
        || $t =~ /$b(метод)\S*\s+[-—–]\s+это\s+(описани|документ|текст|файл|инструкци)/i
        || $t =~ /$b(протокол|инструкци|описани|документ|файл)\S*\s+[-—–]\s+это\s+метод/i) {
      hit($s)
    }
  }
  END { print "AMBIG\t$AMB" if $AMB && !$REAL }
' 2>/dev/null || true)
if [ -n "$A14_MATCH" ]; then
  case "$A14_MATCH" in
    AMBIG$'\t'*) log_violation "A14_AMBIGUOUS" "ambiguous-head-in-part-whole" "${A14_MATCH#AMBIG$'\t'}" ;;
    *) log_violation "A14" "non-system-as-part" "$A14_MATCH" ;;
  esac
fi

# --- B1 (поведение): просит пилота «сделать вручную / дать доступ» до проверки ---
# Ось ПОВЕДЕНИЯ, не стиля: ловит фразы-маркеры, когда агент перекладывает
# действие на пилота вместо вызова доступного инструмента (MCP/Bash). Счётчик
# рецидивов постфактум — НЕ блокирует (см. шапку, WP-5 фаза 2026-06-10).
# Альтернатива авторизации сужена до ОБРАЩЕНИЯ к пилоту (повелит. + 2-е лицо):
# generic «требуется авторизация в X» — техническое описание, не перекладывание,
# в этом репо частое (Kratos/Ory/JWT) → ложные срабатывания (cold-review 13 июня).
B1_MATCH=$(printf '%s\n' "$RESPONSE" | grep -iE '(нужно сделать (это )?вручную|сделай(те)? (это )?вручную|да(й|йте)( мне| тебе)? доступ к |да(й|йте)( мне| тебе)? права на |авторизуйся в|пройди(те)? авторизаци|тебе (надо|нужно) (авторизова|войти)|ты можешь зайти в .* и (сделай|сделать|нажми|нажать)|это нужно сделать через (UI|интерфейс|админ))' | head -1 || true)
[ -n "$B1_MATCH" ] && log_violation "B1" "asks-pilot-before-checking-tools" "$B1_MATCH"

# --- A12_UNSOLICITED_CLOSE_CANDIDATE (WP-561, 29.09.2026): непрошеное предложение закрыть сессию ---
# Кандидат, не факт: warn-only (в BLOCKABLE не входит). Условия и матрица примеров —
# a12-unsolicited-close.py и tests/test-a12-unsolicited-close.sh. Сбой детектора
# не ломает ход: пустой вывод = нет сигнала.
A12_CLOSE_MATCH=$(python3 "$(dirname "${BASH_SOURCE[0]}")/a12-unsolicited-close.py" "$TRANSCRIPT_PATH" 2>/dev/null || true)
# Пишем строку лога напрямую, не через log_violation: кандидат не нарушение, он не должен
# наращивать счётчик сессии и «3+ нарушений». Хвост строки, а не голова: триггер обычно в конце.
[ -n "$A12_CLOSE_MATCH" ] && echo "$TIMESTAMP | $AGENT | A12_UNSOLICITED_CLOSE_CANDIDATE | close-proposed-without-pilot-intent | $(redact "${A12_CLOSE_MATCH: -100}")" >> "$LOG_FILE" 2>/dev/null || true

# --- A12_NEXT_MISSING / A12_NEXT_EMPTY_CONTENT (РП-605 Ф1/Ф5/Ф6) ---
# Наличие и непустота строки «Дальше:» (A12, пак правило 6) — не её ясность
# (двусмысленность проверяется выборочным чтением, не лексиконом; сигнал
# «нет обращения к пилоту» снят в Ф6, 23.10.2026) и не истинность (РП-603).
# Warn-only, в BLOCKABLE не входят: a12-next-block.py печатает ровно три
# строки (пусто = нет сигнала), не ломает ход при сбое. Третья строка —
# A12_NEXT_UNNAMED_LAUNCHER: «следующая сессия ...» без названного запускающего
# (РП-605 Ф6, 30.10.2026, разрешение пилота).
A12_NEXT_RESULT=$(python3 "$(dirname "${BASH_SOURCE[0]}")/a12-next-block.py" "$TRANSCRIPT_PATH" 2>/dev/null || printf '\n\n\n')
A12_NEXT_MISSING_LINE=$(printf '%s\n' "$A12_NEXT_RESULT" | sed -n '1p')
A12_NEXT_EMPTY_LINE=$(printf '%s\n' "$A12_NEXT_RESULT" | sed -n '2p')
A12_NEXT_UNNAMED_LINE=$(printf '%s\n' "$A12_NEXT_RESULT" | sed -n '3p')
[ -n "$A12_NEXT_UNNAMED_LINE" ] && echo "$TIMESTAMP | $AGENT | A12_NEXT_UNNAMED_LAUNCHER | next-session-without-named-launcher | $(redact "$A12_NEXT_UNNAMED_LINE")" >> "$LOG_FILE" 2>/dev/null || true
[ -n "$A12_NEXT_MISSING_LINE" ] && echo "$TIMESTAMP | $AGENT | A12_NEXT_MISSING | no-next-line-in-last-3-lines | -" >> "$LOG_FILE" 2>/dev/null || true
[ -n "$A12_NEXT_EMPTY_LINE" ] && echo "$TIMESTAMP | $AGENT | A12_NEXT_EMPTY_CONTENT | next-line-emoji-or-punctuation-only | $(redact "$A12_NEXT_EMPTY_LINE")" >> "$LOG_FILE" 2>/dev/null || true

# --- A7.1 (стиль): технический журнал в чат под видом <details> ---
# A7.1 запрещает журнал (SHA, коммиты, итоги peer, пути отчёта) в чате — он идёт
# в report.md/sessions. Распознаём по ДВУМ независимым признакам внутри спойлера:
#   (1) ярлык журнала: «журнал сессии / для протокола / для фиксации»;
#   (2) начинка журнала: хэши коммитов, маркеры SHA/commit/push/деплой.
# Признак (2) добавлен 2026-06-13: спойлер «Технические детали» с хэшами коммитов
# без слова «журнал» проходил мимо (label-based детектор смотрел на заголовок, а
# не на содержимое). Признак машинного журнала — начинка, а не как назван блок.
# Гейт <details> сохранён для точности: краткое упоминание хэша в обычном тексте
# по явному запросу пилота не ловим, ловим именно упаковку журнала в спойлер.
# Попытка снять гейт для признаков 1-2 (РП-388 калибровка, 19.10) отклонена
# в той же пир-сессии — Codex нашёл реальные ложные блокировки без <details>:
# «Автодеплой отключён по вашей просьбе», «Запретите push в main», «Для
# фиксации ошибки нужен пример» — все три матчат признаки 1-2 буквально,
# но ни одна не журнал. Фразы-ярлыки однозначны ТОЛЬКО в контексте спойлера;
# без него это обычные слова.
# Расширенная находка (РП-388 Ф15, round-loop Claude+Kimi+Codex, 20.10):
# набор НЕ-нарушений (tests/fixtures/response-clarity-fixtures.jsonl,
# A71-NEG-01..08) показал, что гейт <details> защищает ТОЛЬКО от обычного
# текста без спойлера — ВНУТРИ спойлера признаки 1-2 всё ещё не отличают
# техжурнал от инструкции/объяснения, использующих те же слова (TP=0 на
# этом наборе: 8 из 8 adversarial-примеров дают ложное срабатывание).
# Системный предел правила, не почищен сегодня осознанно. Round 3 того же дня:
# нашли 2 реальных позитива в истории проекта (A71-POS-01-HISTORICAL — прямая
# цитата footer'а из инцидента 13 июня; A71-POS-02-RECONSTRUCTED — структура
# по инциденту 4 июня, не verbatim) и проверили на них кандидат Codex «2-из-3
# с closure-сигналом в <summary>» АНАЛИТИЧЕСКИ (код кандидата не писали и не
# запускали — только прочитали оба позитива вручную). Оба реальных случая
# НЕ содержат closure-слова (closed/resolved/fixed/done) в <summary> — у
# одного вообще нет тега <summary>. Кандидат дал бы recall=0 именно на
# случаях, под которые правило изначально писалось — хуже некуда. Решение
# (консенсус Claude+Kimi+Codex, 2 раунда): known_gap остаётся, дальше не
# трогать в этой фазе. Метрика ТЕКУЩЕГО (не кандидата) детектора на полном
# наборе фикстур: precision=0.18, recall=1.00 (tests/fixtures/response-
# clarity-fixtures.jsonl, актуально на момент коммита — пересчитывать при
# правке фикстур, не доверять этому числу бессрочно).
if printf '%s' "$RESPONSE" | grep -qiE '<details'; then
  # признак 1: ярлык журнала
  A71_MATCH=$(printf '%s\n' "$RESPONSE" | grep -iE '(журнал сесси|для протокола|для фиксац)' | head -1 || true)
  # признак 2: техжурнальная начинка — явные маркеры деплоя/коммита ИЛИ хэш
  # коммита (7-40 hex как отдельный токен). Хэш фильтруем двумя проходами:
  # сперва вырезаем hex-токены 7-40 в границах, затем оставляем только те, что
  # содержат букву a-f — иначе чисто-цифровое число (7+ цифр, «1234567 строк»)
  # даёт ложную блокировку. Реальный хэш коммита почти всегда с буквой.
  # Без \b/\w вокруг кириллицы: здешний grep (ugrep) ломается на границе слова
  # перед кириллицей — границы токена только ASCII-классами [^0-9a-z].
  if [ -z "$A71_MATCH" ]; then
    A71_MATCH=$(printf '%s\n' "$RESPONSE" | grep -iE '(push в main|автодеплой|SHA[[:space:]:])' | head -1 || true)
  fi
  if [ -z "$A71_MATCH" ]; then
    A71_MATCH=$(printf '%s\n' "$RESPONSE" | grep -ioE '(^|[^0-9a-z])[0-9a-f]{7,40}([^0-9a-z]|$)' | grep -iE '[a-f]' | head -1 || true)
  fi
  [ -n "$A71_MATCH" ] && log_violation "A7.1" "journal-in-chat" "$A71_MATCH"
fi

# --- A13 (стиль): длинный/технически плотный ответ вместо короткого вывода ---
# РП-388 калибровка 19.10 (пир-сессия с Codex, 2026-10-19-27): сегодняшняя реальная
# утечка техжурнала в чат не ловилась НИ ОДНОЙ версией A1 — дело не в форме одной
# фразы (путь как подлежащее), а в ОБЪЁМЕ и ПЛОТНОСТИ технических деталей всего
# ответа. Warn-only, пороги черновые: >120 слов ИЛИ есть блок кода ИЛИ ≥3 технических
# совпадений (путь/команда/snake_case-идентификатор/маркер статуса) по всему тексту.
# Длинный МНОГОСЛОВНЫЙ ответ без единого технического маркера тоже обязан сработать —
# запрос пилота был про общий объём, не только про техническую лексику.
#
# Первая версия считала ДОЛЮ технических СТРОК среди непустых строк ответа — сломалась
# на первом же живом тесте (пир-сессия, та же фаза): обычный ответ пилоту почти всегда
# один цельный абзац без переводов строк, поэтому "непустых строк" была одна, и доля
# вырождалась в 0 или 1 независимо от реального объёма технических деталей. Заменено
# на подсчёт СОВПАДЕНИЙ по всему тексту (не по строкам) — устойчиво к форматированию.
#
# Единичное уместное упоминание пути/термина (например, "файл конфигурации (config.yaml)
# не содержит ключ") НЕ ловится этим правилом и не должно — это не превышение объёма,
# а вопрос необходимости детали, который решает A4 (самопроверка "зачем читателю эта
# фраза"), не детектор. A13 ловит только избыток: много маркеров сразу или слишком
# длинный текст целиком.
#
# Исключение по решению пилота (19.10): номера коммитов и ссылки на MC-сессию в
# финальном сообщении о закрытии сессии — не вычищать, даже если правило сработало.
# Детектор это не знает (warn-only, не блокирует) — исключение применяет сам агент
# при самопроверке, см. feedback_response_clarity_for_pilot.md, A13.
A13_RESULT=$(RESPONSE="$RESPONSE" python3 <<'PY' 2>/dev/null || echo ""
import os, re
text = os.environ.get("RESPONSE", "")
words = len(text.split())
has_code_block = "```" in text
# Снимаем fenced-блоки ПЕРЕД инлайн-бэктиками (cold-review этой же сессии,
# Medium): обратный порядок на блоке с внутренним инлайн-кодом (````date`\n...```)
# давал нечётное число "одиночных" бэктиков и инлайн-regex откусывал кусок
# текста ПОСЛЕ открывающей тройки непредсказуемо — редкий, но реальный случай.
body_no_fence = re.sub(r'```.*?```', '', text, flags=re.S)
body_no_code = re.sub(r'`[^`]*`', '', body_no_fence)
path_re = re.compile(r'[A-Za-z0-9_/.-]+\.(py|md|ts|sh|js|yaml|json)(:[0-9]+)?')
# ls/cd/rm сознательно исключены (cold-review этой же сессии): двух-трёхбуквенные
# "команды" совпадают с обычными словами в русской прозе ("использовал ls для
# просмотра") — ложный позитив без единого технического намерения в тексте.
# Единая константа (РП-388 Ф17): A13.1 ниже строит свой cmd_inline_re из той же
# строки, второй список команд не завести.
CMD_WORDS = "bash|python3|git|grep|sed|curl|npm|mkdir"
cmd_re = re.compile(r'(^|\s)(' + CMD_WORDS + r')\s+\S')
# Та же пара вариантов "exit 0", что в A10 (bash-уровень, строки выше) — включая
# вариант без пробела close_exit=0 через negative lookahead, чтобы не ловить
# close_exit=0.5/exit:0.7 (cold-review этой же сессии, Medium: до этой правки
# A13 и A10 определяли один и тот же класс маркера с разной полнотой).
exit_re = re.compile(r'(\bexit\s+0\b|exit[=:]0(?!\.?[0-9])|SHA:\s*[a-f0-9]{7,}|status:\s*(done|success)|`(PASS|FAIL)`)')
snake_re = re.compile(r'\b[a-z][a-z0-9]*_[a-z0-9_]+\b')
func_re = re.compile(r'\b[a-zA-Z_][a-zA-Z0-9_]*\(')

tech_hits = (
    len(path_re.findall(text))
    + len(cmd_re.findall(text))
    + len(exit_re.findall(text))
    + len(snake_re.findall(body_no_code))
    + len(func_re.findall(text))
)

triggered = words > 120 or has_code_block or tech_hits >= 3
if triggered:
    reason = []
    if words > 120:
        reason.append(f"{words} слов")
    if has_code_block:
        reason.append("блок кода")
    if tech_hits >= 3:
        reason.append(f"{tech_hits} тех.совпадений")
    print("TRIGGERED|" + "; ".join(reason))

# --- A13.1 (РП-388 Ф17, 22.10): техтокен в backtick без русского пояснения ---
# Дырка, найденная пир-сессией 22.10 (пилот: `ds-publish.sh`/`git apply --3way`
# без перевода): A2 вырезает весь backtick-спан, поэтому не видит токен внутри;
# A13 считает его тех.совпадением (path_re идёт по ПОЛНОМУ тексту, включая
# backtick), но это одно совпадение из трёх нужных для порога — ниже порога
# и не триггерит. Дыра в ПОРОГЕ A13, не в вырезании A2 (Codex пересчитал живой
# пример: tech_hits=2, не 3 — cmd_re не засчитывает команду сразу после
# backtick). Отдельный под-идентификатор A13.1, не расширение A2/A13: другой
# признак (одиночный токен, не порог по всему тексту), другая фикстура-ось.
cmd_inline_re = re.compile(r'^(' + CMD_WORDS + r')\s+\S')
bt_descriptor_re = re.compile(r'(скрипт|команд|файл|пут[ьи]|ветк|директори|папк|каталог|репозитори|хук|сценари)[а-яё]*', re.IGNORECASE)
# Форма "русское описание (`термин`)" — та же, что уже разрешена A2 выше.
bt_paren_form_re = re.compile(r'[а-яё][а-яё-]*\s*\($', re.IGNORECASE)
# Ф18 (22.10, живой отчёт пилота про `note-commit --forget-unprovable`,
# `close_delivery_source_commits`, `iwe-local-config@eadd57139`, `PREPARED`):
# список CMD_WORDS не угнаться за именами команд, поэтому добавлен признак
# ФОРМЫ — латинский идентификатор без кириллицы с дефисом/подчёркиванием/@/
# точкой между буквами, флагом `--x` или ВЕРХНИМ регистром ≥4 букв. Только `/`
# не считается формой (`origin/main` — граница класса, фикстура NEG-04).
# Исключения для ALLCAPS (TODO/INFO) и дефисных слов в backtick НЕ заводим
# заранее (P13): сначала живое ложное срабатывание в журнале, потом список.
bt_cyr_re = re.compile(r'[А-Яа-яЁё]')
bt_shape_re = re.compile(r'[A-Za-z][-_@][A-Za-z0-9]|[A-Za-z]\.[A-Za-z]|(^|\s)--?[A-Za-z]|\b[A-Z]{4,}\b')


def is_bare_tech_token(content):
    if path_re.fullmatch(content) or cmd_inline_re.match(content):
        return True
    return not bt_cyr_re.search(content) and bool(bt_shape_re.search(content))


bt_token = None
for bt_match in re.finditer(r'`([^`\n]{1,200})`', body_no_fence):
    content = bt_match.group(1)
    if not is_bare_tech_token(content):
        continue
    window_start = max(0, bt_match.start() - 60)
    window = body_no_fence[window_start:bt_match.start()]
    newline_pos = window.rfind("\n")
    if newline_pos != -1:
        window = window[newline_pos + 1:]
    if bt_descriptor_re.search(window) or bt_paren_form_re.search(window):
        continue
    bt_token = content
    break
if bt_token:
    print("BT|" + bt_token)
PY
)
A13_TRIGGERED_LINE=$(printf '%s\n' "$A13_RESULT" | grep '^TRIGGERED|' || true)
A13_1_LINE=$(printf '%s\n' "$A13_RESULT" | grep '^BT|' || true)
if [ -n "$A13_TRIGGERED_LINE" ]; then
  A13_DESC="${A13_TRIGGERED_LINE#TRIGGERED|}"
  log_violation "A13" "long-or-technical-dump" "$A13_DESC"
fi
if [ -n "$A13_1_LINE" ]; then
  A13_1_TOKEN="${A13_1_LINE#BT|}"
  log_violation "A13.1" "bare-backtick-tech-token" "$A13_1_TOKEN"
fi

# --- Реакция на нарушения (peer-session 2026-06-08-23) ---
# Два режима. По умолчанию warning (как было). STYLE_ENFORCE_BLOCK=1 включает
# блокирующий режим для правил высокой уверенности (A1/A10): Stop-хук просит
# переписать ответ со строкой-исправлением STYLE_FIX. BASE5/A8 НЕ блокируют
# (BASE5 слишком частое; «авто-фикс» уже показанного текста невозможен).
# В шаблоне флаг по умолчанию выключен — у нового пользователя ещё нет лога
# для калибровки точности (гейт промоции ≥90% precision).
if [ -z "$VIOLATIONS" ]; then exit 0; fi

# Счётчик нарушений за сессию
# Оба write здесь защищены `|| true` (code review, РП-388 Ф15, 20.10, Critical):
# без защиты неудачный mkdir/echo (диск полон, read-only HOME) под set -e ронял
# бы хук на ЛЮБОМ реальном нарушении — не узкий кейс, а основной путь работы.
mkdir -p "$COUNT_DIR" 2>/dev/null || true
COUNT=0; [ -f "$COUNT_FILE" ] && COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1)); echo "$COUNT" > "$COUNT_FILE" 2>/dev/null || true
# Cleanup старых счётчиков (>24h)
# -maxdepth 1: the counters sit directly in $COUNT_DIR; a full walk of a state dir
# with millions of entries cost 8-45 s on every violation (found 23.10, РП-388 Ф21),
# longer than the 10 s the Kimi/Codex end-of-reply entries wait.
find "$COUNT_DIR" -maxdepth 1 -name "style-violations-count-*" -mmin +1440 -delete 2>/dev/null || true

# Блокируемые правила высокой уверенности
BLOCKABLE=""
printf '%s' "$VIOLATIONS" | grep -qE '\bA1\b'  && BLOCKABLE="$BLOCKABLE A1"
printf '%s' "$VIOLATIONS" | grep -qE '\bA10\b' && BLOCKABLE="$BLOCKABLE A10"
printf '%s' "$VIOLATIONS" | grep -qE 'A7\.1'   && BLOCKABLE="$BLOCKABLE A7.1"
# A13.1 — только предупреждение (30.10, РП-605/РП-388, решение пилота). Ф18 (22.10) делала
# его блокирующим; за 4 дня это ~203 из 260 блокировок Stop-хука, каждая рождала второе
# видимое сообщение после уже показанного ответа. Журнал сохраняется. Возврат в блок —
# только после перемера точности (пункт 27.10 в РП-388 не выполнен).
# Ф21 (23.10): A14 блокирует только по явному флагу. Claude остаётся на предупреждении
# до сверки точности 06.11; Kimi/Codex получают флаг от style-check-text.sh в режиме
# возврата замечания (одного текста правила им не хватает, см. карточку РП-388).
if [ "${STYLE_BLOCK_A14:-0}" = "1" ] && printf '%s' "$VIOLATIONS" | grep -qE '\bA14\b'; then
  BLOCKABLE="$BLOCKABLE A14"
fi

ESC_NOTE=""
[ "$COUNT" -ge 3 ] && ESC_NOTE=" | 3+ нарушений стиля за сессию (сигнал пилоту)"

if [ "${STYLE_ENFORCE_BLOCK:-0}" = "1" ] && [ -n "$BLOCKABLE" ] && [ "$STYLE_CONTEXT" != "peer" ]; then
  REASON="Стиль нарушен (правила:${BLOCKABLE} ). НЕ повторяй и не пересказывай предыдущий ответ целиком — пилот его уже видел (найдено 22.10, РП-388 Ф19: буквальное прочтение прежней формулировки давало полный повтор ответа дважды подряд). Нарушение уже записано в журнал стража, поэтому никаких пометок о нём не пиши: ни строки коррекции, ни слов «исправляю», «было → стало», ни разбора ошибки (WP-388 Ф24: пилоту эта строка не нужна). Если в прежнем ответе была финальная часть с выводом или следующим шагом, напиши ТОЛЬКО её, переписанную по правилам ниже; остальной текст не повторяй. Строку «Дальше:» пилот уже видел: если следующий шаг не изменился, дай её заново одной короткой фразой того же смысла (до 12 слов), без прежних формулировок и деталей; если изменился, назови только изменение. Если финальной части не было, напиши одно-два предложения: то, что пилоту нужно знать из прежнего ответа, уже без нарушения. Правила: A1 путь не подлежащее; A10 без голых маркеров (exit/PASS/SHA); A7.1 техжурнал (хэши коммитов, SHA, пути отчёта) в чат не идёт — даже под <details>, он в report.md; A13.1 имя команды, файла или идентификатора в обратных кавычках без русского пояснения — опиши по-русски, что оно делает (например: «команда снятия заявок (note-commit --forget-unprovable)» без обратных кавычек) или убери; A14 «входит в / состоит из / делится на части» только о системах — об описании, документе, методе, состоянии говори глаголами («описывает», «хранит», «работает по»), в одном перечислении один род.${ESC_NOTE}"
  jq -n --arg r "$REASON" '{"decision":"block","reason":$r}'
  exit 0
fi

# Warning-режим (не блокирует): нарушение уже записано в $LOG_FILE.
# В чат пилоту plain-text НЕ выводим — Stop-хук обязан печатать валидный JSON,
# иначе Claude Code показывает строку как «спецсимволы в конце сообщения»
# (lessons_hook_json_safety.md, 6 мая). Тихий выход '{}'.
echo '{}'
exit 0
