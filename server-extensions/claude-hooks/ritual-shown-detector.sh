#!/usr/bin/env bash
# ritual-shown-detector.sh — проверяемый по факту вывода признак показа
# Ритуала согласования (TACT-01, РП-544 Д31, РП-561 Ф6-а).
#
# Тип: Stop hook. Уровень: чистый наблюдатель — всегда exit 0, только пишет
# ritual_shown в ledger (machine/ledger/day-<date>.yaml, ledger-append.sh).
#
# РП-544 Д31 (13.10.2026) на один день превратил этот хук в блокирующий —
# возвращал {"decision":"block"} с текстом "покажи Ритуал задним числом".
# Диагноз той же даты (пир-сессия 2026-10-13-19-retroactive-ritual-gate,
# Claude+Kimi+Codex): блок на Stop физически не может сработать РАНЬШЕ
# начала работы — Stop срабатывает, когда ход уже произведён и большая
# часть вывода уже видна пилоту (стриминг). Поэтому блокирующая ветка
# убрана целиком; наблюдение (эта логика) используется новым хуком
# ritual-pre-gate.sh (PreToolUse, warn-only), см. тот файл.
#
# Не путать с полем session_opened.sync_gate_marker_present — то фиксирует
# ТОЛЬКО свежесть .claude/state/wp-sync-<WP>.done (шаг Sync Gate), не имеет
# отношения к Ритуалу согласования (отдельный, более поздний шаг протокола).
# Обе переменные независимы; смешение их было найдено и исправлено внутри
# peer-session 2026-09-06-06-tact-01-ritual-gate (Kimi critic-consistency).
#
# Нетривиальность сессии — тот же операциональный критерий, что уже
# применялся в ручном аудите 202 транскриптов (РП-544 Д31): >20 записей в
# стенограмме И ≥1 вызов инструмента. Факт о самой стенограмме, не
# самоотчёт маршрутизатора или агента — снимает циркулярную зависимость,
# в которую упирался вариант «фильтровать по sync_gate_marker_present».
#
# Вход: Stop-хук передаёт JSON со stdin, поле transcript_path указывает на
# JSONL-стенограмму (паттерн — response-clarity-hook.sh).
#
# Признак ritual_status:
#   absent        — сигнатура блока Ритуала не найдена нигде в стенограмме
#   text_only     — сигнатура найдена, но следующий tool_use идёт без хода
#                   пользователя между ними (паузы на согласие не было)
#   text_and_pause — сигнатура найдена, перед следующим tool_use есть ход
#                   пользователя (пилоту дали возможность ответить — это
#                   признак процедурной формы, не факта согласия по
#                   содержанию, см. peer-session ход 3)
#
# Проверка идёт один раз за сессию (state-файл, ключ session_id — НЕ slug,
# см. peer-session ход 6 risk D: повторное открытие с тем же slug не должно
# читаться как «уже проверено»).

set -euo pipefail

INPUT=$(cat)
if [ -z "$INPUT" ]; then exit 0; fi

STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then exit 0; fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
SESSION_ID="${SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -z "$SESSION_ID" ] || [[ "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ ]] || {
  echo 'ritual-shown-detector: invalid session_id; ledger write withheld' >&2
  exit 0
}
if [ -z "$SESSION_ID" ]; then exit 0; fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/ritual-checked-$SESSION_ID"
[ -f "$STATE_FILE" ] && exit 0

# shellcheck source=lib/ritual-detect.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ritual-detect.sh"
RESULT=$(ritual_detect_status "$TRANSCRIPT_PATH")

[ -n "$RESULT" ] || exit 0

APPLIES=$(printf '%s' "$RESULT" | jq -r '.applies // false' 2>/dev/null || echo false)
[ "$APPLIES" = "true" ] || exit 0

RITUAL_STATUS=$(printf '%s' "$RESULT" | jq -r '.ritual_status // empty' 2>/dev/null || echo "")
[ -n "$RITUAL_STATUS" ] || exit 0

GOV_REPO_ROOT="$PROJECT_DIR/${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
LEDGER_APPEND="$GOV_REPO_ROOT/scripts/ledger-append.sh"
LEDGER_WRITTEN=false
if [ -f "$LEDGER_APPEND" ] || [ -f "$PROJECT_DIR/.iwe-runtime/day-close-ledger-route.py" ]; then
  # shellcheck source=lib/day-close-ledger-route.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/day-close-ledger-route.sh"
  if ledger_route_configure "$INPUT" "$PROJECT_DIR" "${IWE_GOVERNANCE_REPO:-DS-my-strategy}"; then
    ROUTE_RC=0
  else
    ROUTE_RC=$?
  fi
  if [ "$ROUTE_RC" -ne 0 ] && [ "$ROUTE_RC" -ne 10 ]; then
    echo "ritual-shown-detector: owner-aware route unavailable; will retry next Stop" >&2
    exit 0
  fi
  EVENT_JSON=$(python3 -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "ritual_status": sys.argv[2]}))
' "$SESSION_ID" "$RITUAL_STATUS" 2>/dev/null) || EVENT_JSON=""
  if [ -n "$EVENT_JSON" ]; then
    if ledger_route_append ritual_shown "$EVENT_JSON" ritual-shown-detector; then
      LEDGER_WRITTEN=true
    else
      echo "ritual-shown-detector: ledger write failed for session $SESSION_ID (will retry next Stop)" >&2
    fi
  fi
else
  echo "ritual-shown-detector: ledger-append.sh not found at $LEDGER_APPEND (will retry next Stop)" >&2
fi

# Маркер «сессия проверена» ставим только после успешной записи в ledger —
# иначе транзиентный сбой (flock, недоступный governance-репо) навсегда
# теряет событие без повторной попытки на следующем Stop-ходе.
if [ "$LEDGER_WRITTEN" = "true" ]; then
  mkdir -p "$STATE_DIR"
  : > "$STATE_FILE"
  # Уборка старых маркеров (>24ч) — тот же паттерн, что response-clarity-hook.sh.
  # ritual-confirmed-* принадлежит ritual-pre-gate.sh/ritual-hard-gate.sh
  # (не этому хуку), но уборка живёт здесь централизованно, той же меткой
  # времени — два отдельных find-а по одному state-каталогу не нужны.
  find "$STATE_DIR" \( -name "ritual-checked-*" -o -name "ritual-confirmed-*" \) \
    -mmin +1440 -delete 2>/dev/null || true
fi

echo '{}'
exit 0
