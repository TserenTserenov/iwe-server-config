#!/usr/bin/env bash
# language-check-hook.sh — детектор ответа не на русском (WP-484 Ф89, WP-510)
#
# Тип: Stop hook (проверяет ответ агента в ЗАВЕРШЁННОМ ходу)
# Уровень: warning (self-check), никогда не блокирует — всегда exit 0
#
# Контекст: дважды за одну сессию (11.08, WP-510 Ф30) финальный ответ пилоту
# вышел на английском после плотного англоязычного технического участка
# (git log/diff, commit-хэши, промпты внешним агентам). Второй раз — сразу
# после того, как первый эпизод был зафиксирован в память той же сессии:
# текстовое правило без механической проверки не сработало дважды подряд.
# Peer-session 2026-08-12-06-wp484-watchdog-lang-check выбрала вариант В —
# adapter-слой (peer-реплики в *-peer-adapter.sh) + этот Stop hook
# (одиночные интерактивные ответы, которые adapter-слой не видит вообще).
#
# Использует ту же эвристику доли кириллицы, что и adapter-слой:
# DS-my-strategy/scripts/lib/language-check.py — одна логика, два места
# вызова, не дублировать проверку двумя разными реализациями.

set -euo pipefail

INPUT=$(cat)
if [ -z "$INPUT" ]; then exit 0; fi

# Guard от рекурсии (тот же паттерн, что protocol-stop-gate.sh/response-clarity-hook.sh)
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then exit 0; fi

# --- Текст ассистента ТЕКУЩЕГО хода (тот же паттерн, что response-clarity-hook.sh) ---
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

LANG_CHECK="$HOME/IWE/DS-my-strategy/scripts/lib/language-check.py"
if [ ! -f "$LANG_CHECK" ]; then exit 0; fi

RESULT=$(printf '%s' "$RESPONSE" | python3 "$LANG_CHECK" 2>/dev/null || echo "")
if [ -z "$RESULT" ]; then exit 0; fi

if ! printf '%s' "$RESULT" | grep -q '"alert": true'; then
  echo '{}'
  exit 0
fi

LOG_FILE="${HOME}/.claude/logs/language-check.log"
mkdir -p "$(dirname "$LOG_FILE")"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
echo "$TIMESTAMP | ${RESULT}" >> "$LOG_FILE"

# Warning-only (решение Ф89: self-check шаг, не блок). additionalContext
# попадает в следующий ход агента как ненавязчивая подсказка, не форсирует
# переписывание уже показанного пилоту ответа (в отличие от decision:block).
jq -nc --arg ctx "⚠️ language-check: последний ответ мог выйти не на русском ($RESULT) — если это не код/пути/термины, следующий ответ пиши на русском." \
  '{additionalContext: $ctx}'
