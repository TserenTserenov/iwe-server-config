#!/usr/bin/env bash
# ritual-shown-detector.sh — проверяемый по факту вывода признак показа
# Ритуала согласования (TACT-01, РП-544 Д31, РП-561 Ф6-а).
#
# Тип: Stop hook. Уровень: наблюдатель, не блокирует — всегда exit 0.
# Лог: machine/ledger/day-<date>.yaml, событие "ritual_shown" (ledger-append.sh).
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
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
if [ -z "$SESSION_ID" ]; then exit 0; fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/ritual-checked-$SESSION_ID"
[ -f "$STATE_FILE" ] && exit 0

# --- Один проход по всей стенограмме (не только текущего хода): нетривиальность
# и сигнатура Ритуала считаются по накопленной истории, потому что порог
# ">20 записей" может быть пересечён на N-м ходу, а сам блок Ритуала обычно
# показывается на первом. Один Python-проход надёжнее поэлементного shell+jq.
RESULT=$(TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 <<'PY' 2>/dev/null || echo ""
import json, os, re

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

def blocks_of(r):
    content = r.get("message", {}).get("content", r.get("content", []))
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []

def has_tool_use(r):
    return any(b.get("type") == "tool_use" for b in blocks_of(r))

def assistant_text(r):
    return "\n".join(b.get("text", "") for b in blocks_of(r) if b.get("type") == "text")

total_records = len(rows)
tool_use_present = any(role_of(r) == "assistant" and has_tool_use(r) for r in rows)

if not (total_records > 20 and tool_use_present):
    print(json.dumps({"applies": False}))
    raise SystemExit

# Сигнатура блока Ритуала — структурный якорь, не голые ключевые слова.
# Только "три фразы встречаются где-то в тексте" ловит и пересказ/обсуждение
# протокола (этот же файл, WP-544/561, онбординг — обычное дело в этой
# кодовой базе): один такой пересказ на первом ходу навсегда блокирует
# детекцию настоящего Ритуала позже (проверка идёт один раз за сессию).
# Поэтому требуем формат реального объявления (protocol-open.md §Ритуал
# согласования, Шаг 1): blockquote-строка с жирным лейблом в начале строки
# ("> **Роль пользователя:**"), и все три поля — в пределах одного окна
# ±15 строк одного сообщения (сам блок компактный, 5 строк подряд).
FIELD_PATTERNS = [
    re.compile(r"^>\s*\*\*Роль\s+(пользователя|Claude)\s*:\*\*", re.IGNORECASE | re.MULTILINE),
    re.compile(r"^>\s*\*\*РП\s*:\*\*", re.IGNORECASE | re.MULTILINE),
    re.compile(r"^>\s*\*\*Целевой переход состояния\s*:\*\*", re.IGNORECASE | re.MULTILINE),
]
PROXIMITY_WINDOW_LINES = 15

def ritual_block_present(text):
    lines = text.split("\n")
    match_lines = []
    for pattern in FIELD_PATTERNS:
        found_at = None
        for i, line in enumerate(lines):
            if pattern.search(line):
                found_at = i
                break
        if found_at is None:
            return False
        match_lines.append(found_at)
    return max(match_lines) - min(match_lines) <= PROXIMITY_WINDOW_LINES

ritual_row_idx = None
for i, r in enumerate(rows):
    if role_of(r) != "assistant":
        continue
    text = assistant_text(r)
    if not text:
        continue
    if ritual_block_present(text):
        ritual_row_idx = i
        break

if ritual_row_idx is None:
    print(json.dumps({"applies": True, "ritual_status": "absent", "total_records": total_records}))
    raise SystemExit

# Между блоком Ритуала и следующим tool_use — искать ход пользователя.
next_tool_use_idx = None
for i in range(ritual_row_idx, total_records):
    if role_of(rows[i]) == "assistant" and has_tool_use(rows[i]):
        next_tool_use_idx = i
        break

pause_found = False
if next_tool_use_idx is not None:
    for i in range(ritual_row_idx + 1, next_tool_use_idx):
        if role_of(rows[i]) == "user":
            pause_found = True
            break
else:
    # tool_use после блока не найден вообще в текущей стенограмме —
    # трактуем как паузу (агент ничего не предпринял после блока).
    pause_found = True

status = "text_and_pause" if pause_found else "text_only"
print(json.dumps({"applies": True, "ritual_status": status, "total_records": total_records}))
PY
)

[ -n "$RESULT" ] || exit 0

APPLIES=$(printf '%s' "$RESULT" | jq -r '.applies // false' 2>/dev/null || echo false)
[ "$APPLIES" = "true" ] || exit 0

RITUAL_STATUS=$(printf '%s' "$RESULT" | jq -r '.ritual_status // empty' 2>/dev/null || echo "")
[ -n "$RITUAL_STATUS" ] || exit 0

GOV_REPO_ROOT="$PROJECT_DIR/${IWE_GOVERNANCE_REPO:-DS-my-strategy}"
LEDGER_APPEND="$GOV_REPO_ROOT/scripts/ledger-append.sh"
LEDGER_WRITTEN=false
if [ -x "$LEDGER_APPEND" ]; then
  EVENT_JSON=$(python3 -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "ritual_status": sys.argv[2]}))
' "$SESSION_ID" "$RITUAL_STATUS" 2>/dev/null) || EVENT_JSON=""
  if [ -n "$EVENT_JSON" ]; then
    if bash "$LEDGER_APPEND" day "$(date +%Y-%m-%d)" ritual_shown "$EVENT_JSON" ritual-shown-detector \
      >/dev/null 2>&1; then
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
  find "$STATE_DIR" -name "ritual-checked-*" -mmin +1440 -delete 2>/dev/null || true
fi

echo '{}'
exit 0
