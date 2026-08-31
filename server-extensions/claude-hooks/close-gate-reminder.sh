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
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Fallback + exact-reject (WP-484 Ф148, cold-context review 31.08, peer-session
# 2026-08-31-40-close-runner-gate-session): this hook (UserPromptSubmit) writes
# the sentinel that close-runner-gate.sh (PreToolUse) reads at
# "$SENTINEL_DIR/$SESSION_ID.flag" -- the two MUST resolve session_id the same
# way, or the writer files under one id while the reader looks under another
# and the whole gate silently no-ops (fail-open, not fail-closed). Mirrors the
# resolution now used there: env fallback before giving up, then a strict
# charset check instead of `tr -cd` silently stripping bad characters into a
# different (colliding) value. "unknown" stays the last-resort bucket here
# (unlike the PreToolUse gate, this hook can't just exit -- it always has to
# emit an additionalContext JSON), not for lookups that must not misfire.
if [ -z "$SESSION_ID" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  SESSION_ID="$CLAUDE_CODE_SESSION_ID"
fi
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*) SESSION_ID="unknown" ;;
esac

IWE_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
OBLIGATION_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/close_obligation.py"
SENTINEL_DIR="/tmp/iwe-close-intent"
REASON=$(printf '%s' "$PROMPT" | cut -c1-200)

# WP-484 Ф118 (19.08, пир-сессия с Codex): сессия, открытая с "session-guard
# open --close-path peer-session", закрывается по DP.SC.154 Шаг 3.8/4.5, не
# через /run-protocol close — у этого протокола свой Close-Trigger Gate внутри
# самого диалога. Инструкция ниже "вызови /run-protocol close" для такой
# сессии не просто бесполезна, а прямо вредна: заставляет писателя прервать
# пир-протокол и вызвать чужой скилл. Обязательство (armed) тоже не взводим —
# Stop-гейт ждал бы RUN-quick-close карточку, которую пир-протокол никогда не
# создаёт (тот самый живой симптом, из-за которого писалась эта фаза: закрытие
# пир-сессии каждый раз требовало cancel-close + --no-verify).
CLOSE_PATH_MATCH=$(grep -l "harness_session_id: $SESSION_ID" \
  "$IWE_ROOT"/.iwe-runtime/sessions/*.open 2>/dev/null | head -1)
if [ -n "$CLOSE_PATH_MATCH" ] && grep -q '^close_path: peer-session$' "$CLOSE_PATH_MATCH" 2>/dev/null; then
  echo '{"additionalContext": "Сессия объявлена как пир-сессия (close_path=peer-session) — закрытие идёт по её собственному протоколу (DP.SC.154 Шаг 3.8/4.5), не через /run-protocol close. Этот гейт не вмешивается."}'
  exit 0
fi

# WP-520 (тридцать вторая находка, 14.08.2026, пир-сессия с Codex): pending-
# reflection state. Читается ЗДЕСЬ, до любых arm/record-intent вызовов этого
# исполнения — иначе pending, поставленный этим же вызовом (см. ниже), тут же
# проверялся бы и снимался в нём самом (edge case, поймано Codex ход 4).
PENDING_DIR="/tmp/iwe-close-intent"
PENDING_FILE="$PENDING_DIR/$SESSION_ID.pending-reflection"
PENDING_EXISTED_BEFORE_THIS_RUN="false"
[ -f "$PENDING_FILE" ] && PENDING_EXISTED_BEFORE_THIS_RUN="true"

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
  # WP-484 (peer-session 2026-08-31-43-close-obligation-orphan-recovery,
  # consensus with Codex): SESSION_ID falls into the "unknown" bucket
  # (resolution block above) only when BOTH the payload and
  # CLAUDE_CODE_SESSION_ID are empty, or the resolved value fails the
  # charset check. Arming an obligation under "unknown" and telling the
  # agent "Обязательство закрытия зафиксировано" was a LIE in the one case
  # that matters: protocol-stop-gate.sh resolves its own SESSION_ID
  # independently (protocol-stop-gate.sh:34+43) and, with both sources
  # empty there too, skips the ENTIRE obligation check silently (fail-open)
  # -- the "unknown" obligation this hook just armed can never be found and
  # verified on Stop. Fail loud instead of a false "зафиксировано" (P1/P4,
  # engineering code style: no silent success on an unverifiable claim).
  # This is fail-VISIBLE, not fail-closed: UserPromptSubmit hooks in this
  # repo never use exit 2 to block the prompt itself (that pattern is
  # PreToolUse-only here, see close-runner-gate.sh/wp-gate-check.sh/etc.) --
  # refusing to arm/sentinel plus a loud additionalContext is the maximum
  # degradation available at this hook's event type (cold-context review,
  # session 2026-08-31-40, High finding; closed here, not silently deferred
  # again).
  if [ "$SESSION_ID" = "unknown" ]; then
    echo '{"additionalContext": "❌ session_id не определён (payload и CLAUDE_CODE_SESSION_ID оба пусты, либо в найденном значении недопустимые символы) — обязательство НЕ создано, sentinel НЕ записан. Stop-гейт не сможет подтвердить выполнение Close для этой сессии. Не заявляй, что закрытие отслежено — проведи Close вручную с повышенным вниманием."}'
    exit 0
  fi
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

# WP-520 (тридцать вторая находка, 14.08.2026, пир-сессия с Codex, consensus
# ход 4): явный маркер начала рефлексии. Без него хвост триггерной фразы —
# ненадёжный источник (живой инцидент: "заливай и закрывай сессию. рефлексия
# -- <мысль пилота>" — весь хвост включает случайный текст ДО маркера).
# raw_text показывается пилоту дословно (см. session-reflection-release.sh) —
# должен содержать только то, что пилот сам пометил как рефлексию.
REFLECTION_MARKER_RE='[Рр]ефлекси[яю][[:space:]]*[:—–-]+'

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
  # WP-520 (тридцать вторая находка, 14.08.2026): $2=marker_already_matched —
  # вызов из pending-ветки (trigger_re сам = REFLECTION_MARKER_RE-слово) уже
  # прошёл проверку маркера СНАРУЖИ; повторный поиск маркера внутри tail ниже
  # нашёл бы 0 совпадений (маркер уже вырезан этим же извлечением) и ошибочно
  # решил бы "маркера нет".
  local marker_already_matched="${2:-false}"
  local tail before_trigger
  tail=$(printf '%s' "$PROMPT_ORIGINAL_CASE" | awk -v re="$trigger_re" '
    match($0, re) {
      print substr($0, RSTART + RLENGTH)
      exit
    }
  ' | sed -E 's/^[[:space:],.:;-]+//')
  # WP-520 (consensus ход 5 с Codex): текст ДО первого триггера — источник для
  # случая "рефлексия: X, закрывай" (маркер стоит раньше триггера в фразе).
  before_trigger=$(printf '%s' "$PROMPT_ORIGINAL_CASE" | awk -v re="$trigger_re" '
    match($0, re) {
      print substr($0, 1, RSTART - 1)
      exit
    }
  ')

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

  # WP-520 (тридцать вторая находка, consensus ход 4 с Codex): raw_text
  # показывается пилоту дословно — источником может быть только текст после
  # явного маркера рефлексии, не весь хвост. skip_reflection — отдельная явная
  # команда пропуска, её обработка не меняется (raw_text там не значим).
  local raw_text="$tail"
  local before_has_marker="false"
  echo "$before_trigger" | grep -qE "$REFLECTION_MARKER_RE" && before_has_marker="true"
  if [ "$marker_already_matched" = "true" ]; then
    raw_text="$tail"
  elif { [ -n "$tail" ] || [ "$before_has_marker" = "true" ]; } && [ "$skip_reflection" = "false" ]; then
    if echo "$tail" | grep -qE "$REFLECTION_MARKER_RE"; then
      raw_text=$(printf '%s' "$tail" | awk -v re="$REFLECTION_MARKER_RE" '
        match($0, re) {
          print substr($0, RSTART + RLENGTH)
          exit
        }
      ' | sed -E 's/^[[:space:]]+//')
    elif echo "$before_trigger" | grep -qE "$REFLECTION_MARKER_RE"; then
      # WP-520 (consensus ход 5 с Codex): маркер стоит ДО триггера в фразе
      # ("рефлексия: X, закрывай") — брать текст между КОНЦОМ маркера и
      # НАЧАЛОМ триггера, не "весь текст после маркера" (иначе захватило бы
      # саму команду закрытия внутрь raw_text).
      raw_text=$(printf '%s' "$before_trigger" | awk -v re="$REFLECTION_MARKER_RE" '
        match($0, re) {
          print substr($0, RSTART + RLENGTH)
          exit
        }
      ' | sed -E 's/^[[:space:]]+//; s/[[:space:],.:;-]+$//')
    else
      raw_text=""
      mkdir -p "$PENDING_DIR" 2>/dev/null
      printf '{"session_id":"%s","created_at":"%s","reason":"reflection_marker_missing"}' \
        "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$PENDING_FILE" 2>/dev/null
      echo "[close-gate-reminder] session=$SESSION_ID reflection_marker_missing — pending set, tail withheld from raw_text" >&2
    fi
  fi

  python3 "$OBLIGATION_CLI" record-intent --session-id "$SESSION_ID" --raw-text "$raw_text" --skip-reflection "$skip_reflection" >/dev/null 2>&1 || \
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

# WP-520 (тридцать вторая находка, 14.08.2026, consensus ход 4 с Codex):
# pending_reflection — рефлексия пришла отдельным следующим сообщением, без
# триггера закрытия в НЁМ САМОМ (иначе она уже была бы обработана веткой
# _record_close_intent выше). Смотрит на pending, СУЩЕСТВОВАВШИЙ ДО этого
# запуска — pending, поставленный веткой закрытия/заливки этого же запуска,
# не обрабатывается здесь же (self-consuming edge case, Codex ход 4).
# Детерминированный контракт: маркер есть → перезаписать intent, снять
# pending; маркера нет → снять pending без записи. Никакой эвристики темы.
if [ "$PENDING_EXISTED_BEFORE_THIS_RUN" = "true" ]; then
  if echo "$PROMPT_ORIGINAL_CASE" | grep -qE "$REFLECTION_MARKER_RE"; then
    _record_close_intent "$REFLECTION_MARKER_RE" "true"
    echo "[close-gate-reminder] session=$SESSION_ID pending_reflection consumed with marker" >&2
  else
    echo "[close-gate-reminder] session=$SESSION_ID pending_reflection dropped — no marker in follow-up prompt" >&2
  fi
  rm -f "$PENDING_FILE" 2>/dev/null
fi

# Пилот перешёл к другой теме → «намерение закрыть» больше не действует для
# неё; ждать TTL блокировало не связанные с закрытием commit'ы (найдено
# 04.08.2026, bug-2026-08-04-peer-session-commit-blocked-by-close-runner-gate.md,
# решение пилота п.2). NB: снимается только sentinel (gate коммитов, Ф74а);
# obligation Ф74б НЕ снимается — её снимают verified completed / cancel / override.
rm -f "$SENTINEL_DIR/$SESSION_ID.flag" 2>/dev/null
echo '{}'
exit 0
