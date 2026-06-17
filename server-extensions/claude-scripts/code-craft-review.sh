#!/bin/bash
# code-craft-review.sh — see DP.SC.179, DP.ROLE.076 (WP-420 Ф4)
#
# Семантический ревью git diff по чек-листу инженерного стиля P1-P9 (DP.SC.172).
# Контрольная роль (DP.D.080): read-only на код, пишет ТОЛЬКО в свой канал (лог стиля).
# Advisory: сам скрипт не блокирует коммит — gating это политика потребителя.
#
# Использование:
#   code-craft-review.sh [<git-diff-range>]      # default: HEAD (несохранённые правки)
# Env:
#   CODE_REVIEW_AGENT_CMD  — команда-агент (читает промпт из stdin, отдаёт JSON в stdout).
#                            default: "claude -p". Pluggable ради тестируемости.
#   CODE_REVIEW_MIN_LINES  — cost-гейт: не звать LLM на diff меньше N добавленных строк (default 10).
#
# Выход: находки в ~/.claude/logs/style-violations.log (interim-формат WP-388):
#   TS | agent | P<N> | <file>:<lines> [<severity>] <почему> | <context>
# Режим отказа: LLM недоступен → sentinel-строка (rule=SKIP), НЕ пустой результат (не ложный зелёный).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}"

LOG_FILE="${HOME}/.claude/logs/style-violations.log"
AGENT_ID="code-craft-reviewer"
MIN_DIFF_LINES="${CODE_REVIEW_MIN_LINES:-10}"
AGENT_CMD="${CODE_REVIEW_AGENT_CMD:-claude -p}"

# --- редактирование секретов в строке лога (тот же контракт, что code-style-hook.sh B7.7a) ---
redact() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-200 \
    | sed -E 's/(gh[pousr]_|sk-|xox[baprs]-|AKIA)[A-Za-z0-9_-]+/<REDACTED>/g; s/[A-Za-z0-9_-]{32,}/<REDACTED>/g; s/\|/¦/g'
}

# --- запись одной строки лога в формате WP-388 ---
log_line() {
  local rule="$1" desc="$2" context="$3"
  printf '%s | %s | %s | %s | %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$AGENT_ID" "$rule" "$(redact "$desc")" "$(redact "$context")" >> "$LOG_FILE"
}

# --- sentinel при отказе LLM: явная пометка «не оценено», не ложный зелёный ---
log_sentinel() {
  log_line "SKIP" "review skipped: $1" "diff-range=${DIFF_RANGE:-?}"
}

# --- промпт с чек-листом P1-P9 для cold-context агента ---
build_prompt() {
  local diff="$1"
  cat <<PROMPT
Ты — ревьюер инженерного стиля кода (DP.ROLE.076). Проверь git diff по чек-листу P1-P9.
Только семантические запахи, которые регекс не ловит: P2 копипаста, P3 мёртвый код/ветка,
P5 смешение обязанностей, P6 нет логов, P7 баннер=скрытая декомпозиция, P8 неидиоматичность,
P9 ручной парсинг формата. P1/P4 — только если очевидны. Контр-критерии: P5 не флагуй глубокий
модуль; P8 не флагуй осмысленный цикл; P7 не флагуй модульный маркер.

Верни ТОЛЬКО JSON-массив (без markdown-обёртки), каждый элемент:
{"rule":"P3","file":"path.py","lines":"10-12","severity":"high|medium|low","why":"одной фразой"}
Если запахов нет — верни [].

GIT DIFF:
$diff
PROMPT
}

# --- разобрать JSON-вердикт и записать находки ---
write_findings() {
  local verdict="$1"
  # Извлечь ПЕРВЫЙ '[', с которого начинается ВАЛИДНЫЙ JSON-массив (raw_decode-скан):
  # агент мог обернуть массив в прозу/markdown-fence, а в прозе быть свои '['/']'
  # (напр. "[важно]"). Наивный «первый [ … последний ]» захватил бы прозу между ними
  # (улов Kimi). Скан пропускает невалидные '[' и берёт первый валидный список.
  local json
  json=$(printf '%s' "$verdict" | python3 -c 'import sys,json
s=sys.stdin.read(); dec=json.JSONDecoder(); k=0
while True:
    i=s.find("[",k)
    if i<0: sys.exit(1)
    try:
        v,end=dec.raw_decode(s[i:])
        if isinstance(v,list): sys.stdout.write(s[i:i+end]); break
    except ValueError: pass
    k=i+1' 2>/dev/null)
  if [ -z "$json" ]; then
    log_sentinel "agent returned non-JSON"
    echo "code-craft-review: вердикт не JSON — sentinel" >&2
    return 0
  fi
  local count
  count=$(printf '%s' "$json" | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "code-craft-review: запахов не найдено (чисто, $DIFF_LINES строк)" >&2
    return 0
  fi
  # по каждой находке — строка лога; rule в поле P<N> → метрика code-compliance её посчитает
  printf '%s' "$json" | jq -c '.[]' | while IFS= read -r item; do
    local rule file lines sev why
    rule=$(printf '%s' "$item" | jq -r '.rule // "P?"')
    file=$(printf '%s' "$item" | jq -r '.file // "?"')
    lines=$(printf '%s' "$item" | jq -r '.lines // "?"')
    sev=$(printf '%s' "$item" | jq -r '.severity // "low"')
    why=$(printf '%s' "$item" | jq -r '.why // ""')
    log_line "$rule" "${file}:${lines} [${sev}] ${why}" "semantic-review"
  done
  echo "code-craft-review: записано находок: $count" >&2
}

# ======== main ========
DIFF_RANGE="${1:-HEAD}"
mkdir -p "$(dirname "$LOG_FILE")"

command -v jq >/dev/null 2>&1 || { echo "code-craft-review: нет jq — пропуск" >&2; exit 0; }

DIFF=$(git diff -U25 "$DIFF_RANGE" -- '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.sh' '*.go' '*.rs' '*.rb' '*.java' '*.sql' 2>/dev/null || echo "")
DIFF_LINES=$(printf '%s\n' "$DIFF" | grep -c '^+' || true)

if [ -z "$DIFF" ] || [ "$DIFF_LINES" -lt "$MIN_DIFF_LINES" ]; then
  echo "code-craft-review: diff пуст или меньше порога ($DIFF_LINES < $MIN_DIFF_LINES) — пропуск" >&2
  exit 0
fi

# shellcheck disable=SC2086  # $AGENT_CMD намеренно word-split (напр. "claude -p"); значение операторское, доверенное
VERDICT=$(build_prompt "$DIFF" | $AGENT_CMD 2>/dev/null || echo "")
if [ -z "$VERDICT" ]; then
  log_sentinel "LLM unavailable"
  echo "code-craft-review: агент не ответил — sentinel записан (НЕ чисто)" >&2
  exit 0
fi

write_findings "$VERDICT"
