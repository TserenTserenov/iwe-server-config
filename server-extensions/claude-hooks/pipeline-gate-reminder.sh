#!/bin/bash
# Pipeline Gate Reminder Hook (UserPromptSubmit)
# Зеркало close-gate-reminder.sh (WP-484 Ф74б) для WP-503 (умный конвейер).
#
# Проблема, которую решает: 17.08.2026, живой инцидент — агент объявил
# «запускаю умный конвейер (РП503) на список карточек 515,476,427,...»,
# фактически разведал их субагентами общего назначения и правил файлы
# напрямую, ни разу не вызвав wp-run-scheduled-tsekh1.sh. Работа была
# реальна, но заявленный конвейерный механизм подменён собой — обнаружено
# постфактум пилотом по отсутствию событий в ledger, не самим агентом.
#
# Sentinel здесь — только маркер «в этой сессии объявлено намерение прогнать
# конвейер на список WP-N». Фактическую блокировку прямого Edit/Write
# заявленных карточек делает pipeline-runner-gate.sh (PreToolUse).
#
# Триггер: фраза со словом «конвейер» (или «РП503»/«WP-503») И списком
# номеров РП через запятую в той же фразе. Широкая эвристика, не идеальный
# парсер естественного языка — тот же компромисс, что close-gate-reminder
# уже принял для broad-triggers (заливай/запуши -> mode=warn вместо жёсткого
# block, если фраза неоднозначна).

INPUT=$(cat)
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT_ORIGINAL_CASE=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty')
PROMPT=$(printf '%s' "$PROMPT_ORIGINAL_CASE" | tr '[:upper:]' '[:lower:]')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

IWE_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
OBLIGATION_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/pipeline_obligation.py"

_obligation_available() {
  [ -x "$(command -v python3)" ] && [ -f "$OBLIGATION_CLI" ]
}

# --- явная отмена (полная или по одному WP) ---
# «не через конвейер», «работай сама» -- полная отмена.
# «515 не через конвейер» / «427 сама делай» -- отмена одного WP (номер уже
# должен быть в тексте фразы; при отсутствии числа падаем в полную отмену).
if echo "$PROMPT" | grep -qE '(не через конвейер|без конвейера|работай сама|сама делай|в обход конвейера)'; then
  if _obligation_available; then
    WP_IN_PHRASE=$(printf '%s' "$PROMPT" | grep -oE '[0-9]{2,4}' | head -1)
    if [ -n "$WP_IN_PHRASE" ]; then
      python3 "$OBLIGATION_CLI" cancel --session-id "$SESSION_ID" --wp "$WP_IN_PHRASE" \
        --actor pilot --reason "$(printf '%s' "$PROMPT" | cut -c1-200)" >/dev/null 2>&1
      echo "{\"additionalContext\": \"Обязательство конвейера снято для РП$WP_IN_PHRASE — можно править файл напрямую.\"}"
    else
      python3 "$OBLIGATION_CLI" cancel --session-id "$SESSION_ID" \
        --actor pilot --reason "$(printf '%s' "$PROMPT" | cut -c1-200)" >/dev/null 2>&1
      echo '{"additionalContext": "Обязательство конвейера снято целиком — можно работать напрямую без wp-run-scheduled-tsekh1.sh."}'
    fi
    exit 0
  fi
fi

# --- arm: «конвейер»/«РП503»/«WP-503» + список чисел через запятую ---
if echo "$PROMPT" | grep -qE '(конвейер|рп[ -]?503|wp[ -]?503)'; then
  # Список чисел из 2-4 цифр, разделённых запятой (с опциональным пробелом),
  # минимум 2 числа подряд -- одно число само по себе слишком похоже на
  # случайное упоминание (дату, версию), не на список карточек.
  NUMBERS_RAW=$(printf '%s' "$PROMPT_ORIGINAL_CASE" | grep -oE '([0-9]{2,4}[, ]+){1,}[0-9]{2,4}' | head -1)
  if [ -n "$NUMBERS_RAW" ]; then
    WP_LIST=$(printf '%s' "$NUMBERS_RAW" | grep -oE '[0-9]{2,4}' | paste -sd, -)
    NUM_COUNT=$(printf '%s' "$WP_LIST" | tr ',' '\n' | grep -c .)
    if [ "$NUM_COUNT" -ge 2 ] && _obligation_available; then
      python3 "$OBLIGATION_CLI" arm --session-id "$SESSION_ID" --wp-numbers "$WP_LIST" --mode block >/dev/null 2>&1
      cat <<EOF
{"additionalContext": "Обязательство конвейера (WP-503) взведено для карточек: $WP_LIST. Прямая правка их файлов (Edit/Write) заблокирована, пока wp-run-scheduled-tsekh1.sh не будет вызван для каждой (или пилот явно не отменит обязательство фразой «не через конвейер»/«работай сама»). Разведка (Read, Agent-субагенты общего назначения) не блокируется -- только Edit/Write самих карточек."}
EOF
      exit 0
    fi
  fi
fi

echo '{}'
exit 0
