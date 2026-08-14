#!/bin/bash
# Close Gate Reminder Hook (v6 — close-obligation, WP-484 Ф74б, 07.08.2026)
# Event: UserPromptSubmit
# Day Close → ПРЯМАЯ ИНСТРУКЦИЯ вызвать /run-protocol day-close (не напоминание).
# Session Close → compact-чеклист + sentinel для close-runner-gate.sh (PreToolUse)
#   + obligation armed (close_obligation.py) — автомат обязательства Ф74б.
# Cancel/override фразы пилота → аудируемый переход (ledger close_obligation),
#   не молчаливое удаление. Ошибки arm/cancel НЕ маскируются || true — hook
#   честно сообщает неуспех и не заявляет, что obligation создана/снята.
# Read-only на прошлое (не меняет файлы репо), кроме sentinel в /tmp и state-файлов
# obligation в .iwe-runtime (через close_obligation.py).
# Версия: 2026-08-07 (Ф74б). Fix: multiline prompt ломал jq (6-й инцидент 3 апр).
#
# Sentinel (WP-482, 25.07.2026): текстовая инструкция «раннер — первое действие
# Quick Close» уже стояла в protocol-close.md с 17.07 — 24.07 LLM прочитал её
# буквально и всё равно продублировал шаги руками (найдено живьём, см. WP-482
# «Осталось» запись 24.07). Инструкция внутри текста, который сам же LLM
# интерпретирует, не может быть механизмом принуждения. Sentinel здесь —
# только маркер «в этой сессии объявлено намерение Close»; фактическую
# блокировку прямого `git commit` в обход раннера делает close-runner-gate.sh.
#
# Ф74б: obligation НЕ снимается следующим нерелевантным промптом (в отличие от
# sentinel, чьё удаление на любой другой фразе — фикс 04.08 против ложных
# блокировок коммитов, он сохранён). Обязательство снимают только: verified
# completed (Stop-гейт), cancel-close, close-override. Режимы: точный intent
# («закрывай/закрой») → mode=block; широкая эвристика («заливай/запуши») →
# mode=warn (консенсус пир-сессии 2026-08-07-08, ход 4-6).

INPUT=$(cat)
# Устойчивость к многострочным промптам: literal \n в JSON value
# невалиден для jq. Заменяем все control chars на пробелы до парсинга.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT_ORIGINAL_CASE=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty')
PROMPT=$(printf '%s' "$PROMPT_ORIGINAL_CASE" | tr '[:upper:]' '[:lower:]')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

IWE_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
OBLIGATION_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/close_obligation.py"
SENTINEL_DIR="/tmp/iwe-close-intent"
REASON=$(printf '%s' "$PROMPT" | cut -c1-200)

_obligation_available() {
  [ -x "$(command -v python3)" ] && [ -f "$OBLIGATION_CLI" ]
}

_run_obligation() {
  python3 "$OBLIGATION_CLI" "$@" 2>&1
}

# --- Ф74б: явная отмена обязательства пилотом (аудируемый cancel-close) ---
# Голое «нет» (+ опционально одно слово) добавлено 11.08: полноценное
# распознавание «это команда закрыть vs цитата/упоминание» регэкспом на
# свободном тексте уже обсуждалось и отклонено (пир-сессия 2026-08-11-05,
# см. комментарий в _record_close_intent ниже) — не переоткрывать. Это
# точечное расширение самого частого случая отмены, не попытка решить класс.
if echo "$PROMPT" | grep -qE '(не закрывай|не надо закрывать|отмена закрытия|отмени закрытие|отставить закрытие|^нет[,.!]?( [а-яё]+)?[,.!]?$)'; then
  if _obligation_available; then
    OUT=$(_run_obligation cancel --session-id "$SESSION_ID" \
      --action cancel-close --actor pilot --reason "$REASON")
    RC=$?
    if [ "$RC" -ne 0 ] || printf '%s' "$OUT" | grep -q '"status": "error"'; then
      echo '{"additionalContext": "❌ ОШИБКА cancel-close: ledger append не удался, obligation остаётся активной. Не утверждай, что закрытие отменено. Пилот должен разрешить ситуацию вручную или повторить cancel-close позже."}'
      exit 0
    fi
  fi
  rm -f "$SENTINEL_DIR/$SESSION_ID.flag" 2>/dev/null
  echo '{"additionalContext": "Обязательство закрытия сессии снято пилотом (cancel-close записан в ledger). Продолжай работу, Quick Close не требуется."}'
  exit 0
fi

# --- Ф74б: явный обход раннера по команде пилота (аудируемый close-override) ---
if echo "$PROMPT" | grep -qE '(в обход раннера|без раннера|в обход process-runner)'; then
  if _obligation_available; then
    OUT=$(_run_obligation cancel --session-id "$SESSION_ID" \
      --action close-override --actor pilot --reason "$REASON")
    RC=$?
    if [ "$RC" -ne 0 ] || printf '%s' "$OUT" | grep -q '"status": "error"'; then
      echo '{"additionalContext": "❌ ОШИБКА close-override: ledger append не удался, obligation остаётся активной. Не утверждай, что пилот разрешил обход раннера."}'
      exit 0
    fi
  fi
  rm -f "$SENTINEL_DIR/$SESSION_ID.flag" 2>/dev/null
  echo '{"additionalContext": "Пилот явно разрешил закрытие В ОБХОД раннера (close-override записан в ledger с цитатой). Закрывай вручную, но в отчёте честно назови это «закрытие в обход раннера по команде пилота», а не «Quick Close»."}'
  exit 0
fi

# Day Close → ПРИНУДИТЕЛЬНЫЙ вызов /run-protocol
if echo "$PROMPT" | grep -qE '(итоги дня|закрываю день|закрывай день)'; then
  cat <<'EOF'
{"additionalContext": "⛔ БЛОКИРУЮЩЕЕ: Day Close выполняется ТОЛЬКО через skill /run-protocol с аргументом 'day-close'. ПЕРВОЕ И ЕДИНСТВЕННОЕ действие = вызвать Skill tool: skill='run-protocol', args='day-close'. НЕ читать protocol-close.md вручную. НЕ выполнять шаги самостоятельно. НЕ писать итоги без /run-protocol. Причина: 5 инцидентов пропуска шагов при ручном исполнении (15, 18, 19, 27 мар). /run-protocol гарантирует пошаговый TodoList + верификацию Haiku R23."}
EOF
  exit 0
fi

# Session Close (точный intent) → mode=block; широкая эвристика → mode=warn
_arm_and_sentinel() {
  local mode="$1"
  local broad="$2"
  if _obligation_available; then
    OUT=$(_run_obligation arm --session-id "$SESSION_ID" --mode "$mode")
    RC=$?
    if [ "$RC" -ne 0 ] || printf '%s' "$OUT" | grep -q '"status": "error"'; then
      echo '{"additionalContext": "❌ ОШИБКА arm close-obligation: не удалось создать obligation. Не утверждай, что Quick Close заармирован. Без obligation тихое завершение сессии не будет заблокировано на Stop-гейте."}'
      exit 0
    fi
  fi
  mkdir -p "$SENTINEL_DIR" 2>/dev/null
  printf '{"session_id":"%s","created_at":"%s"}' \
    "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$SENTINEL_DIR/$SESSION_ID.flag" 2>/dev/null
  echo "[close-gate-reminder] session=$SESSION_ID close-intent sentinel written${broad:+ (broad/warn)}" >&2
}

# WP-484, пир-сессия 2026-08-11-05 (консенсус с Codex): фиксирует текст ПОСЛЕ
# триггерного слова закрытия как есть, без попытки распознать "это рефлексия"
# vs "это ещё одно поручение" — та классификация ненадёжна регэкспом на
# свободном тексте (обсуждалось и отклонено в самой сессии). Пустой хвост —
# тоже валидный факт (голое "закрывай"), не ошибка.
#
# skip_reflection (2026-08-11, прямое поручение пилота в этой же сессии,
# сразу после консенсуса выше): "закрывай без рефлексии" — ОТДЕЛЬНЫЙ явный
# сигнал, не то же самое, что tail_present=true с raw_text="без рефлексии".
# Разница для пилота: raw_text показывается ЕМУ ЖЕ обратно как "записал: ...",
# а skip_reflection означает "не показывай мне ничего про рефлексию вообще,
# сразу к «ты свободен»" — команда пропуска, не содержание для записи.
# Проверяется НЕЗАВИСИМО от tail_present: команда может стоять где угодно
# в хвосте фразы, не обязательно быть всем хвостом целиком.
# WP-520 (14.08.2026): фразы отказа от рефлексии — единый паттерн для обеих
# точек детекции (внутри intent-записи и standalone-ветки в конце файла).
SKIP_REFLECTION_RE='(без *рефлекс|не спрашивай.{0,20}рефлекс|пропусти.{0,20}рефлекс|нет *рефлекс|рефлекс[^ ]* *(нет|не нуж|не надо|отсутствует|пропу))'

_record_close_intent() {
  if ! _obligation_available; then
    return 0
  fi
  # Извлечь текст после ПЕРВОГО вхождения триггерного слова, из оригинального
  # регистра (PROMPT_ORIGINAL_CASE, не lowercased $PROMPT — иначе raw_text,
  # который потом дословно показывается пилоту в release-фразе, будет искажён).
  # awk match()+substr(), не sed: POSIX sed не поддерживает non-greedy `.*?`,
  # а greedy `^.*слово` матчит до ПОСЛЕДНЕГО вхождения слова во фразе, не до
  # первого (найдено code review 2026-08-11: "рефлексия: ... закрывай ... а
  # сейчас просто закрывай" терял всю рефлексию, обрезая после второго
  # повтора). match() находит первое вхождение по конструкции.
  # WP-520 case 7 adjacent gap (11.08, peer session with Kimi): the broad branch
  # ("заливай"/"запуши") armed the obligation but never recorded the intent tail,
  # so "заливай, рефлексия — X" lost the reflection. Same recorder, per-branch
  # trigger alternation passed as $1 (defaults to the close-trigger set).
  local trigger_re="${1:-[Зз]акрыва[йю]|[Зз]акрой}"
  local tail
  tail=$(printf '%s' "$PROMPT_ORIGINAL_CASE" | awk -v re="$trigger_re" '
    match($0, re) {
      print substr($0, RSTART + RLENGTH)
      exit
    }
  ' | sed -E 's/^[[:space:],.:;-]+//')

  local skip_reflection="false"
  # WP-520 (14.08.2026, прямое поручение пилота): любые слова пилота про отказ
  # от рефлексии засчитываются — «нет рефлексии», «рефлексии нет», «рефлексия
  # не нужна/не надо», включая опечатки («рефлекссии»): матч по основе
  # «рефлекс» без хвоста. Один паттерн, два места вызова (см. ветку ниже).
  if echo "$PROMPT" | grep -qE "$SKIP_REFLECTION_RE"; then
    skip_reflection="true"
  fi

  # Broad triggers ("заливай"/"запуши") arrive many times during the commit
  # phase; a bare one must not clobber an earlier recorded reflection tail with
  # an empty record (review-01 High, reproduced live). Explicit-trigger calls
  # (no $1) keep the original semantics: an empty tail is a valid fact.
  if [ -n "${1:-}" ] && [ -z "$tail" ] && [ "$skip_reflection" = "false" ]; then
    return 0
  fi

  python3 "$OBLIGATION_CLI" record-intent --session-id "$SESSION_ID" --raw-text "$tail" --skip-reflection "$skip_reflection" >/dev/null 2>&1 || \
    echo "[close-gate-reminder] session=$SESSION_ID record-intent failed (non-fatal — render falls back to interactive path)" >&2
}

if echo "$PROMPT" | grep -qE '(закрывай|закрываю|закрой)'; then
  _arm_and_sentinel block ""
  _record_close_intent

  cat <<'EOF'
{"additionalContext": "⛔ БЛОКИРУЮЩЕЕ: Session Close выполняется ТОЛЬКО через skill /run-protocol с аргументом 'close'. ПЕРВОЕ И ЕДИНСТВЕННОЕ действие = вызвать Skill tool: skill='run-protocol', args='close'. НЕ выполнять шаги самостоятельно. /run-protocol гарантирует пошаговый TodoList + верификацию. Обязательство закрытия (Ф74б) зафиксировано: тихое завершение без карточки RUN-quick-close будет заблокировано на Stop. Если в этой же фразе уже была названа рефлексия — она уже записана как close-intent record, повторно не спрашивай (session-reflection-render прочитает её сам)."}
EOF
  exit 0
fi

if echo "$PROMPT" | grep -qE '(заливай|запуши|запушь)'; then
  _arm_and_sentinel warn "1"
  _record_close_intent '[Зз]алива[йю]|[Зз]апуш[иь]'

  cat <<'EOF'
{"additionalContext": "⚠️ ПРЕДУПРЕЖДЕНИЕ (Ф74б): похоже, ты упомянул push/заливку. Если это попытка закрыть сессию — Session Close выполняется ТОЛЬКО через skill /run-protocol с аргументом 'close'. ПЕРВОЕ действие = вызвать Skill tool: skill='run-protocol', args='close'. НЕ выполнять шаги самостоятельно. Обязательство закрытия зафиксировано в режиме warn: при отсутствии карточки RUN-quick-close Stop-гейт выдаст предупреждение. Если это не close — скажи явно, и sentinel будет снят."}
EOF
  exit 0
fi

# WP-520 (14.08.2026): отказ от рефлексии БЕЗ триггеров закрытия в той же
# фразе («нет рефлексии» отдельным сообщением, когда прогон уже спросил) тоже
# записывается — иначе render перезапущенного прогона не видит волеизъявление
# и переспрашивает. Обязательство здесь не взводится (это не команда закрыть):
# пишется только intent-запись; broad-guard в _record_close_intent пропускает
# пустой tail, потому что skip_reflection=true.
if echo "$PROMPT" | grep -qE "$SKIP_REFLECTION_RE"; then
  _record_close_intent '[Рр]ефлекс'
fi

# Пилот перешёл к другой теме → «намерение закрыть» больше не действует для
# неё; ждать TTL блокировало не связанные с закрытием commit'ы (найдено
# 04.08.2026, bug-2026-08-04-peer-session-commit-blocked-by-close-runner-gate.md,
# решение пилота п.2). NB: снимается только sentinel (gate коммитов, Ф74а);
# obligation Ф74б НЕ снимается — её снимают verified completed / cancel / override.
rm -f "$SENTINEL_DIR/$SESSION_ID.flag" 2>/dev/null
echo '{}'
exit 0
